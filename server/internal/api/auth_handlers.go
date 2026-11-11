package api

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"html"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/db"
	mailer "github.com/dtekltd/mytermi/server/internal/mail"
)

const (
	refreshTTL = 60 * 24 * time.Hour // app sessions slide on every refresh
	consoleTTL = 12 * time.Hour
)

type deviceInfo struct {
	ID       string `json:"id"`       // stable per install
	Name     string `json:"name"`     // "Tuan's iPhone"
	Platform string `json:"platform"` // ios | android
}

type tokenResponse struct {
	AccessToken  string     `json:"access_token"`
	ExpiresAt    time.Time  `json:"expires_at"`
	RefreshToken string     `json:"refresh_token"`
	User         meResponse `json:"user"`
	IsNewUser    bool       `json:"is_new_user"`
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) error {
	st, err := s.Settings(r.Context())
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"app_name":       st.General.AppName,
		"signup_enabled": st.General.SignupEnabled,
		"support_email":  st.General.SupportEmail,
		"providers": map[string]bool{
			"email":  s.emailEnabled(st),
			"google": st.Google.Enabled && len(st.Google.ClientIDs) > 0,
			"apple":  st.Apple.Enabled && len(st.Apple.Audiences) > 0,
		},
	})
	return nil
}

func validEmail(e string) bool {
	a, err := mail.ParseAddress(e)
	return err == nil && a.Address == e && strings.Contains(e, ".") && len(e) <= 254
}

// ---- email code: sign up / sign in / reset password ----

func (s *Server) handleEmailStart(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email string `json:"email"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	email := db.NormalizeEmail(req.Email)
	if !validEmail(email) {
		return errf(http.StatusBadRequest, "invalid_email", "invalid email address")
	}
	ctx := r.Context()
	st, err := s.Settings(ctx)
	if err != nil {
		return err
	}
	send, err := s.mailer(st)
	if err != nil {
		return errf(http.StatusServiceUnavailable, "email_not_configured", "email sign-in is not configured on this server")
	}
	if !st.General.SignupEnabled {
		if _, err := s.db.UserByEmail(ctx, email); errors.Is(err, db.ErrNotFound) {
			return errf(http.StatusForbidden, "signup_disabled", "new sign-ups are disabled")
		}
	}
	ip := s.clientIP(r)
	if err := s.rateLimit("code-ip:"+ip, 20, time.Hour); err != nil {
		return err
	}
	// Per address: one code a minute, 6 an hour.
	n, last, err := s.db.CodesSentSince(ctx, email, time.Now().Add(-time.Hour))
	if err != nil {
		return err
	}
	if wait := time.Until(last.Add(time.Minute)); wait > 0 || n >= 6 {
		if n >= 6 {
			wait = time.Until(last.Add(time.Hour))
		}
		e := errf(http.StatusTooManyRequests, "rate_limited", "a code was sent recently")
		e.Details = map[string]any{"retry_after": int(wait.Seconds()) + 1}
		return e
	}

	code := auth.NewCode()
	if err := s.db.CreateEmailCode(ctx, email, auth.HashCode(s.secret, email, code), time.Now().Add(auth.CodeTTL), ip); err != nil {
		return err
	}
	sendCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	if err := send.Send(sendCtx, codeEmail(st.General.AppName, email, code)); err != nil {
		return errf(http.StatusBadGateway, "email_send_failed", "could not send email: "+err.Error())
	}
	writeJSON(w, http.StatusOK, map[string]any{"sent": true, "expires_in": int(auth.CodeTTL.Seconds()), "resend_after": 60})
	return nil
}

func codeEmail(app, to, code string) mailer.Message {
	text := fmt.Sprintf("Your %s verification code is: %s\n\nThe code is valid for 10 minutes. "+
		"If you did not request this code, you can ignore this email.", app, code)
	h := html.EscapeString
	body := fmt.Sprintf(`<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:420px;margin:auto;padding:24px">
<h2 style="margin:0 0 16px">%s</h2>
<p>Your verification code:</p>
<p style="font-size:32px;font-weight:700;letter-spacing:8px;margin:16px 0">%s</p>
<p style="color:#666">The code is valid for 10 minutes. If you did not request this code, you can ignore this email.</p></div>`, h(app), h(code))
	return mailer.Message{To: to, Subject: fmt.Sprintf("%s is your %s verification code", code, app), Text: text, HTML: body}
}

func (s *Server) handleEmailVerify(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email  string     `json:"email"`
		Code   string     `json:"code"`
		Device deviceInfo `json:"device"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	email := db.NormalizeEmail(req.Email)
	ctx := r.Context()
	if err := s.rateLimit("verify-ip:"+s.clientIP(r), 60, time.Hour); err != nil {
		return err
	}
	invalid := errf(http.StatusBadRequest, "invalid_code", "the code is wrong or expired")
	c, err := s.db.LatestEmailCode(ctx, email)
	if errors.Is(err, db.ErrNotFound) {
		return invalid
	} else if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(c.CodeHash, auth.HashCode(s.secret, email, req.Code)) != 1 {
		// Burn the code after too many wrong guesses.
		_ = s.db.BumpCodeAttempts(ctx, c.ID, c.Attempts+1 >= auth.CodeMaxAttempts)
		return invalid
	}
	if ok, err := s.db.ConsumeCode(ctx, c.ID); err != nil {
		return err
	} else if !ok {
		return invalid
	}

	u, err := s.db.UserByEmail(ctx, email)
	isNew := false
	if errors.Is(err, db.ErrNotFound) {
		st, err := s.Settings(ctx)
		if err != nil {
			return err
		}
		if !st.General.SignupEnabled {
			return errf(http.StatusForbidden, "signup_disabled", "new sign-ups are disabled")
		}
		if u, err = s.db.CreateUser(ctx, email, "", true); err != nil {
			return err
		}
		isNew = true
		s.db.Audit(ctx, u.ID, "user.signup", u.Email, map[string]any{"method": "email_code"}, s.clientIP(r))
	} else if err != nil {
		return err
	} else if !u.EmailVerified {
		_ = s.db.MarkEmailVerified(ctx, u.ID)
		u.EmailVerified = true
	}
	return s.signIn(w, r, u, "email_code", req.Device, isNew)
}

// ---- email + password ----

func (s *Server) handlePasswordLogin(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string     `json:"email"`
		Password string     `json:"password"`
		Device   deviceInfo `json:"device"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	email := db.NormalizeEmail(req.Email)
	if err := s.rateLimit("login-ip:"+s.clientIP(r), 30, 15*time.Minute); err != nil {
		return err
	}
	if err := s.rateLimit("login-email:"+email, 10, 15*time.Minute); err != nil {
		return err
	}
	u, err := s.checkPassword(r.Context(), email, req.Password)
	if err != nil {
		return err
	}
	return s.signIn(w, r, u, "password", req.Device, false)
}

var errBadCredentials = errf(http.StatusUnauthorized, "invalid_credentials", "wrong email or password")

func (s *Server) checkPassword(ctx context.Context, email, pw string) (*db.User, error) {
	u, err := s.db.UserByEmail(ctx, email)
	if errors.Is(err, db.ErrNotFound) {
		auth.BurnPasswordTime(pw)
		return nil, errBadCredentials
	} else if err != nil {
		return nil, err
	}
	if !u.HasPassword() {
		auth.BurnPasswordTime(pw)
		return nil, errBadCredentials
	}
	if !auth.VerifyPassword(*u.PasswordHash, pw) {
		return nil, errBadCredentials
	}
	return u, nil
}

// ---- Google / Apple ----

func (s *Server) handleGoogle(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		IDToken string     `json:"id_token"`
		Device  deviceInfo `json:"device"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	st, err := s.Settings(r.Context())
	if err != nil {
		return err
	}
	if !st.Google.Enabled {
		return errf(http.StatusForbidden, "provider_not_configured", "Google sign-in is not enabled")
	}
	return s.oidcSignIn(w, r, auth.Google, req.IDToken, st.Google.ClientIDs, "", req.Device)
}

func (s *Server) handleApple(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		IdentityToken string     `json:"identity_token"`
		Name          string     `json:"name"` // Apple only sends the name to the app, on first sign-in
		Device        deviceInfo `json:"device"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	st, err := s.Settings(r.Context())
	if err != nil {
		return err
	}
	if !st.Apple.Enabled {
		return errf(http.StatusForbidden, "provider_not_configured", "Sign in with Apple is not enabled")
	}
	return s.oidcSignIn(w, r, auth.Apple, req.IdentityToken, st.Apple.Audiences, req.Name, req.Device)
}

func (s *Server) oidcSignIn(w http.ResponseWriter, r *http.Request, p auth.Provider, token string,
	audiences []string, name string, dev deviceInfo) error {
	ctx := r.Context()
	if err := s.rateLimit("oidc-ip:"+s.clientIP(r), 60, 15*time.Minute); err != nil {
		return err
	}
	claims, err := s.verifier.Verify(ctx, p, token, audiences)
	if err != nil {
		return errf(http.StatusUnauthorized, "invalid_id_token", err.Error())
	}
	if name == "" {
		name = claims.Name
	}
	email := db.NormalizeEmail(claims.Email)

	u, err := s.db.UserByIdentity(ctx, p.Name, claims.Subject)
	isNew := false
	switch {
	case err == nil:
	case !errors.Is(err, db.ErrNotFound):
		return err
	case email == "" || !claims.EmailVerified:
		return errf(http.StatusBadRequest, "email_unverified", p.Name+" account has no verified email")
	default:
		// Same verified email as an existing account: link it.
		u, err = s.db.UserByEmail(ctx, email)
		if errors.Is(err, db.ErrNotFound) {
			st, err := s.Settings(ctx)
			if err != nil {
				return err
			}
			if !st.General.SignupEnabled {
				return errf(http.StatusForbidden, "signup_disabled", "new sign-ups are disabled")
			}
			if u, err = s.db.CreateUser(ctx, email, strings.TrimSpace(name), true); err != nil {
				return err
			}
			isNew = true
			s.db.Audit(ctx, u.ID, "user.signup", u.Email, map[string]any{"method": p.Name}, s.clientIP(r))
		} else if err != nil {
			return err
		}
		if err := s.db.LinkIdentity(ctx, u.ID, p.Name, claims.Subject, email); err != nil {
			return err
		}
	}
	return s.signIn(w, r, u, p.Name, dev, isNew)
}

// ---- sessions ----

// signIn creates an app session and writes the token response.
func (s *Server) signIn(w http.ResponseWriter, r *http.Request, u *db.User, method string, dev deviceInfo, isNew bool) error {
	ctx := r.Context()
	if u.Disabled {
		return errDisabled
	}
	plan, err := s.db.EffectivePlan(ctx, u)
	if err != nil {
		return err
	}
	if plan.MaxDevices > 0 {
		n, err := s.db.CountActiveDevices(ctx, u.ID, strings.TrimSpace(dev.ID))
		if err != nil {
			return err
		}
		if n >= plan.MaxDevices {
			e := errf(http.StatusForbidden, "device_limit", fmt.Sprintf("plan %s allows %d devices", plan.Name, plan.MaxDevices))
			e.Details = map[string]any{"max_devices": plan.MaxDevices, "plan": plan.Name}
			return e
		}
	}
	token, hash := auth.NewOpaqueToken()
	sess, err := s.db.CreateSession(ctx, db.Session{
		UserID:     u.ID,
		Kind:       "app",
		AuthMethod: method,
		DeviceID:   clip(dev.ID, 100),
		DeviceName: clip(dev.Name, 100),
		Platform:   clip(dev.Platform, 20),
		IP:         s.clientIP(r),
		UserAgent:  clip(r.UserAgent(), 300),
		ExpiresAt:  time.Now().Add(refreshTTL),
	}, hash)
	if err != nil {
		return err
	}
	s.db.TouchUser(ctx, u.ID)
	resp, err := s.tokenResponse(ctx, u, sess.ID, token)
	if err != nil {
		return err
	}
	resp.IsNewUser = isNew
	writeJSON(w, http.StatusOK, resp)
	return nil
}

func (s *Server) tokenResponse(ctx context.Context, u *db.User, sessionID, refresh string) (*tokenResponse, error) {
	access, exp, err := s.tokens.Issue(u.ID, sessionID, u.Role)
	if err != nil {
		return nil, err
	}
	me, err := s.meOf(ctx, u)
	if err != nil {
		return nil, err
	}
	return &tokenResponse{AccessToken: access, ExpiresAt: exp, RefreshToken: refresh, User: *me}, nil
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	sess, err := s.db.SessionByToken(ctx, auth.HashToken(req.RefreshToken))
	if errors.Is(err, db.ErrNotFound) || (err == nil && sess.Kind != "app") {
		return errf(http.StatusUnauthorized, "session_revoked", "refresh token invalid or revoked; sign in again")
	} else if err != nil {
		return err
	}
	u, err := s.db.UserByID(ctx, sess.UserID)
	if err != nil {
		return err
	}
	if u.Disabled {
		return errDisabled
	}
	token, hash := auth.NewOpaqueToken()
	if err := s.db.RotateSession(ctx, sess.ID, hash, time.Now().Add(refreshTTL), s.clientIP(r)); err != nil {
		return err
	}
	s.db.TouchUser(ctx, u.ID)
	resp, err := s.tokenResponse(ctx, u, sess.ID, token)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, resp)
	return nil
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	if err := s.db.RevokeSession(r.Context(), a.User.ID, a.Session.ID); err != nil && !errors.Is(err, db.ErrNotFound) {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n]
	}
	return s
}
