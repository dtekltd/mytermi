// Package api implements the HTTP API (/api/v1) used by the app and the console.
package api

import (
	"context"
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/config"
	"github.com/dtekltd/mytermi/server/internal/db"
	"github.com/dtekltd/mytermi/server/internal/mail"
)

// Settings are edited in the console and stored in the settings table.
type Settings struct {
	General struct {
		AppName       string `json:"app_name"`
		SignupEnabled bool   `json:"signup_enabled"`
		SupportEmail  string `json:"support_email"`
	} `json:"general"`
	SMTP   mail.SMTPConfig `json:"smtp"`
	Google struct {
		Enabled   bool     `json:"enabled"`
		ClientIDs []string `json:"client_ids"` // iOS / Android / web OAuth client IDs (token audiences)
	} `json:"google"`
	Apple struct {
		Enabled   bool     `json:"enabled"`
		Audiences []string `json:"audiences"` // app bundle ID(s) and/or Services ID
	} `json:"apple"`
}

func defaultSettings() Settings {
	var s Settings
	s.General.AppName = "MyTermi"
	s.General.SignupEnabled = true
	s.SMTP.Security = "starttls"
	s.SMTP.Port = 587
	return s
}

type Server struct {
	cfg      config.Config
	db       *db.DB
	tokens   *auth.Tokens
	secret   []byte // HMAC key for email codes
	verifier *auth.Verifier
	limits   *limiter

	// Mailer overrides SMTP from settings (tests).
	Mailer mail.Sender

	mu         sync.Mutex
	settings   *Settings
	settingsAt time.Time
}

// New loads (or creates) the server secret and returns a ready server.
func New(ctx context.Context, cfg config.Config, d *db.DB) (*Server, error) {
	secret := []byte(cfg.JWTSecret)
	if len(secret) == 0 {
		var stored string
		err := d.GetSetting(ctx, "secret", &stored)
		if errors.Is(err, db.ErrNotFound) {
			stored = base64.RawStdEncoding.EncodeToString(auth.RandomSecret())
			err = d.PutSetting(ctx, "secret", stored)
		}
		if err != nil {
			return nil, err
		}
		secret = []byte(stored)
	}
	return &Server{
		cfg:      cfg,
		db:       d,
		tokens:   auth.NewTokens(secret),
		secret:   secret,
		verifier: auth.NewVerifier(),
		limits:   newLimiter(),
	}, nil
}

// Verifier is exposed so tests can point JWKS URLs at a local server.
func (s *Server) Verifier() *auth.Verifier { return s.verifier }

// Settings returns the current settings (cached for a few seconds).
func (s *Server) Settings(ctx context.Context) (Settings, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.settings != nil && time.Since(s.settingsAt) < 10*time.Second {
		return *s.settings, nil
	}
	st := defaultSettings()
	if err := s.db.GetSetting(ctx, "server", &st); err != nil && !errors.Is(err, db.ErrNotFound) {
		return st, err
	}
	// Lists are always arrays in JSON, never null.
	if st.Google.ClientIDs == nil {
		st.Google.ClientIDs = []string{}
	}
	if st.Apple.Audiences == nil {
		st.Apple.Audiences = []string{}
	}
	s.settings, s.settingsAt = &st, time.Now()
	return st, nil
}

func (s *Server) saveSettings(ctx context.Context, st Settings) error {
	if err := s.db.PutSetting(ctx, "server", st); err != nil {
		return err
	}
	s.mu.Lock()
	s.settings, s.settingsAt = &st, time.Now()
	s.mu.Unlock()
	return nil
}

func (s *Server) mailer(st Settings) (mail.Sender, error) {
	if s.Mailer != nil {
		return s.Mailer, nil
	}
	if st.SMTP.Configured() {
		return mail.SMTP{Config: st.SMTP}, nil
	}
	if s.cfg.Dev {
		return mail.Log{}, nil
	}
	return nil, mail.ErrNotConfigured
}

func (s *Server) emailEnabled(st Settings) bool {
	return s.Mailer != nil || st.SMTP.Configured() || s.cfg.Dev
}

// Routes returns the API handler (mounted at /api/v1/ by the caller).
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	p := "/api/v1"

	mux.HandleFunc("GET "+p+"/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET "+p+"/config", s.h(s.handleConfig))

	// sign-in
	mux.HandleFunc("POST "+p+"/auth/email/start", s.h(s.handleEmailStart))
	mux.HandleFunc("POST "+p+"/auth/email/verify", s.h(s.handleEmailVerify))
	mux.HandleFunc("POST "+p+"/auth/password", s.h(s.handlePasswordLogin))
	mux.HandleFunc("POST "+p+"/auth/google", s.h(s.handleGoogle))
	mux.HandleFunc("POST "+p+"/auth/apple", s.h(s.handleApple))
	mux.HandleFunc("POST "+p+"/auth/refresh", s.h(s.handleRefresh))
	mux.HandleFunc("POST "+p+"/auth/logout", s.user(s.handleLogout))

	// account
	mux.HandleFunc("GET "+p+"/me", s.user(s.handleMe))
	mux.HandleFunc("PATCH "+p+"/me", s.user(s.handleUpdateMe))
	mux.HandleFunc("DELETE "+p+"/me", s.user(s.handleDeleteMe))
	mux.HandleFunc("POST "+p+"/me/password", s.user(s.handleSetPassword))
	mux.HandleFunc("GET "+p+"/me/sessions", s.user(s.handleSessions))
	mux.HandleFunc("DELETE "+p+"/me/sessions/{id}", s.user(s.handleRevokeSession))

	// end-to-end encrypted vault + sync
	mux.HandleFunc("GET "+p+"/vault", s.user(s.handleGetVault))
	mux.HandleFunc("POST "+p+"/vault", s.user(s.handleCreateVault))
	mux.HandleFunc("PUT "+p+"/vault", s.user(s.handleRewrapVault))
	mux.HandleFunc("DELETE "+p+"/vault", s.user(s.handleResetVault))
	mux.HandleFunc("GET "+p+"/sync", s.user(s.handlePull))
	mux.HandleFunc("POST "+p+"/sync", s.user(s.handlePush))

	// console
	a := p + "/admin"
	mux.HandleFunc("POST "+a+"/login", s.h(s.handleAdminLogin))
	mux.HandleFunc("POST "+a+"/logout", s.admin(s.handleAdminLogout))
	mux.HandleFunc("GET "+a+"/me", s.admin(s.handleAdminMe))
	mux.HandleFunc("GET "+a+"/stats", s.admin(s.handleStats))
	mux.HandleFunc("GET "+a+"/users", s.admin(s.handleListUsers))
	mux.HandleFunc("GET "+a+"/users/{id}", s.admin(s.handleGetUser))
	mux.HandleFunc("PATCH "+a+"/users/{id}", s.admin(s.handlePatchUser))
	mux.HandleFunc("DELETE "+a+"/users/{id}", s.admin(s.handleDeleteUser))
	mux.HandleFunc("POST "+a+"/users/{id}/revoke-sessions", s.admin(s.handleRevokeUserSessions))
	mux.HandleFunc("POST "+a+"/users/{id}/password", s.admin(s.handleAdminSetPassword))
	mux.HandleFunc("GET "+a+"/plans", s.admin(s.handleListPlans))
	mux.HandleFunc("PUT "+a+"/plans/{id}", s.admin(s.handlePutPlan))
	mux.HandleFunc("DELETE "+a+"/plans/{id}", s.admin(s.handleDeletePlan))
	mux.HandleFunc("GET "+a+"/settings", s.admin(s.handleGetSettings))
	mux.HandleFunc("PUT "+a+"/settings", s.admin(s.handlePutSettings))
	mux.HandleFunc("POST "+a+"/settings/test-email", s.admin(s.handleTestEmail))
	mux.HandleFunc("GET "+a+"/audit", s.admin(s.handleAudit))

	mux.HandleFunc(p+"/", func(w http.ResponseWriter, r *http.Request) { writeError(w, r, errNotFound) })
	return mux
}

// ---- auth middleware ----

type authCtx struct {
	User    *db.User
	Session *db.Session
}

type ctxKey struct{}

func current(r *http.Request) *authCtx { return r.Context().Value(ctxKey{}).(*authCtx) }

type authedHandler func(w http.ResponseWriter, r *http.Request, a *authCtx) error

// user requires a valid access token (app sessions).
func (s *Server) user(fn authedHandler) http.HandlerFunc {
	return s.h(func(w http.ResponseWriter, r *http.Request) error {
		a, err := s.fromBearer(r)
		if err != nil {
			return err
		}
		return fn(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, a)), a)
	})
}

func (s *Server) fromBearer(r *http.Request) (*authCtx, error) {
	h := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(h, "Bearer ")
	if !ok || tok == "" {
		return nil, errUnauthorized
	}
	claims, err := s.tokens.Parse(tok)
	if err != nil {
		return nil, errf(http.StatusUnauthorized, "token_expired", "access token invalid or expired; refresh it")
	}
	// Check the session is still live (logout / revoke take effect immediately).
	sess, err := s.db.SessionByID(r.Context(), claims.SessionID)
	if errors.Is(err, db.ErrNotFound) {
		return nil, errf(http.StatusUnauthorized, "session_revoked", "session was signed out")
	} else if err != nil {
		return nil, err
	}
	u, err := s.db.UserByID(r.Context(), claims.Subject)
	if errors.Is(err, db.ErrNotFound) {
		return nil, errUnauthorized
	} else if err != nil {
		return nil, err
	}
	if u.Disabled {
		return nil, errDisabled
	}
	return &authCtx{User: u, Session: sess}, nil
}

// LogRequests is a small access-log middleware.
func LogRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(rw, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			slog.Info("http", "method", r.Method, "path", r.URL.Path, "status", rw.status, "ms", time.Since(start).Milliseconds())
		}
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}
