package api

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/db"
	"github.com/dtekltd/mytermi/server/internal/mail"
)

const consoleCookie = "mytermi_console"

// admin accepts the console cookie or a bearer token, and requires role admin.
func (s *Server) admin(fn authedHandler) http.HandlerFunc {
	return s.h(func(w http.ResponseWriter, r *http.Request) error {
		var a *authCtx
		var err error
		if c, cerr := r.Cookie(consoleCookie); cerr == nil && c.Value != "" {
			a, err = s.fromConsoleCookie(r, c.Value)
		} else {
			a, err = s.fromBearer(r)
		}
		if err != nil {
			return err
		}
		if a.User.Role != "admin" {
			return errForbidden
		}
		// Cookie auth: refuse cross-site form posts (JSON only; SameSite=Strict too).
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.ContentLength > 0 &&
			!strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
			return errf(http.StatusUnsupportedMediaType, "invalid_request", "Content-Type must be application/json")
		}
		return fn(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, a)), a)
	})
}

func (s *Server) fromConsoleCookie(r *http.Request, token string) (*authCtx, error) {
	ctx := r.Context()
	sess, err := s.db.SessionByToken(ctx, auth.HashToken(token))
	if errors.Is(err, db.ErrNotFound) || (err == nil && sess.Kind != "console") {
		return nil, errf(http.StatusUnauthorized, "session_revoked", "console session expired; sign in again")
	} else if err != nil {
		return nil, err
	}
	u, err := s.db.UserByID(ctx, sess.UserID)
	if err != nil {
		return nil, notFoundAs(err, errUnauthorized)
	}
	if u.Disabled {
		return nil, errDisabled
	}
	if time.Since(sess.LastUsedAt) > time.Minute { // sliding expiry
		s.db.TouchSession(ctx, sess.ID, time.Now().Add(consoleTTL))
	}
	return &authCtx{User: u, Session: sess}, nil
}

func notFoundAs(err error, as error) error {
	if errors.Is(err, db.ErrNotFound) {
		return as
	}
	return err
}

func (s *Server) handleAdminLogin(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	ip := s.clientIP(r)
	if err := s.rateLimit("admin-login:"+ip, 10, 15*time.Minute); err != nil {
		return err
	}
	ctx := r.Context()
	u, err := s.checkPassword(ctx, db.NormalizeEmail(req.Email), req.Password)
	if err != nil {
		return err
	}
	if u.Role != "admin" {
		return errf(http.StatusForbidden, "forbidden", "this account is not an admin")
	}
	if u.Disabled {
		return errDisabled
	}
	token, hash := auth.NewOpaqueToken()
	if _, err := s.db.CreateSession(ctx, db.Session{
		UserID: u.ID, Kind: "console", AuthMethod: "password", IP: ip,
		UserAgent: clip(r.UserAgent(), 300), ExpiresAt: time.Now().Add(consoleTTL),
	}, hash); err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{
		Name: consoleCookie, Value: token, Path: "/api/v1/admin", HttpOnly: true,
		Secure: r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https", SameSite: http.SameSiteStrictMode,
		MaxAge: int((30 * 24 * time.Hour).Seconds()), // the DB session expires first
	})
	s.db.Audit(ctx, u.ID, "admin.login", u.Email, nil, ip)
	writeJSON(w, http.StatusOK, map[string]any{"user": u})
	return nil
}

func (s *Server) handleAdminLogout(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	_ = s.db.RevokeSession(r.Context(), a.User.ID, a.Session.ID)
	http.SetCookie(w, &http.Cookie{Name: consoleCookie, Value: "", Path: "/api/v1/admin", MaxAge: -1, HttpOnly: true})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleAdminMe(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	writeJSON(w, http.StatusOK, map[string]any{"user": a.User})
	return nil
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	st, err := s.db.Stats(r.Context())
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, st)
	return nil
}

func pageParams(r *http.Request) (limit, offset int) {
	limit, _ = strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ = strconv.Atoi(r.URL.Query().Get("offset"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	return
}

// ---- users ----

func (s *Server) handleListUsers(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	limit, offset := pageParams(r)
	q := r.URL.Query()
	users, total, err := s.db.ListUsers(r.Context(), db.UserFilter{
		Query: q.Get("q"), PlanID: q.Get("plan"), Role: q.Get("role"), Limit: limit, Offset: offset,
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users, "total": total, "limit": limit, "offset": offset})
	return nil
}

func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	ctx := r.Context()
	u, err := s.db.UserByID(ctx, r.PathValue("id"))
	if err != nil {
		return notFoundAs(err, errNotFound)
	}
	ids, err := s.db.IdentitiesOf(ctx, u.ID)
	if err != nil {
		return err
	}
	sessions, err := s.db.ActiveSessions(ctx, u.ID, "")
	if err != nil {
		return err
	}
	vault := map[string]any{"exists": false}
	if v, err := s.db.VaultOf(ctx, u.ID); err == nil {
		var items int
		_ = s.db.Pool.QueryRow(ctx, `SELECT count(*) FROM vault_items WHERE user_id = $1 AND NOT deleted`, u.ID).Scan(&items)
		vault = map[string]any{"exists": true, "items": items, "created_at": v.CreatedAt, "updated_at": v.UpdatedAt}
	} else if !errors.Is(err, db.ErrNotFound) {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"user": u, "has_password": u.HasPassword(), "identities": ids, "sessions": sessions, "vault": vault,
	})
	return nil
}

func (s *Server) handlePatchUser(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var up db.UserUpdate
	if err := decode(r, &up); err != nil {
		return err
	}
	ctx := r.Context()
	target, err := s.db.UserByID(ctx, r.PathValue("id"))
	if err != nil {
		return notFoundAs(err, errNotFound)
	}
	if up.Role != nil && *up.Role != "user" && *up.Role != "admin" {
		return badRequest("role must be user or admin")
	}
	if up.PlanID != nil {
		if _, err := s.db.PlanByID(ctx, *up.PlanID); err != nil {
			return notFoundAs(err, badRequest("unknown plan"))
		}
	}
	losingAdmin := target.Role == "admin" && ((up.Role != nil && *up.Role != "admin") || (up.Disabled != nil && *up.Disabled))
	if losingAdmin {
		if n, err := s.db.CountAdmins(ctx); err != nil {
			return err
		} else if n <= 1 {
			return errf(http.StatusConflict, "last_admin", "can't demote or disable the last admin")
		}
	}
	u, err := s.db.UpdateUser(ctx, target.ID, up)
	if err != nil {
		return err
	}
	if up.Disabled != nil && *up.Disabled {
		_ = s.db.RevokeAllSessions(ctx, u.ID)
	}
	s.db.Audit(ctx, a.User.ID, "admin.user_update", u.Email, map[string]any{
		"role": up.Role, "plan_id": up.PlanID, "disabled": up.Disabled, "name": up.Name,
	}, s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"user": u})
	return nil
}

func (s *Server) handleDeleteUser(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	ctx := r.Context()
	id := r.PathValue("id")
	if id == a.User.ID {
		return errf(http.StatusConflict, "self_delete", "you can't delete your own account from the console")
	}
	u, err := s.db.UserByID(ctx, id)
	if err != nil {
		return notFoundAs(err, errNotFound)
	}
	if err := s.db.DeleteUser(ctx, id); err != nil {
		return err
	}
	s.db.Audit(ctx, a.User.ID, "admin.user_delete", u.Email, nil, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleRevokeUserSessions(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	ctx := r.Context()
	u, err := s.db.UserByID(ctx, r.PathValue("id"))
	if err != nil {
		return notFoundAs(err, errNotFound)
	}
	if err := s.db.RevokeAllSessions(ctx, u.ID); err != nil {
		return err
	}
	s.db.Audit(ctx, a.User.ID, "admin.user_revoke_sessions", u.Email, nil, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// ---- plans ----

var planIDRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

func (s *Server) handleListPlans(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	plans, err := s.db.Plans(r.Context())
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"plans": plans})
	return nil
}

func (s *Server) handlePutPlan(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var p db.Plan
	if err := decode(r, &p); err != nil {
		return err
	}
	p.ID = r.PathValue("id")
	if !planIDRE.MatchString(p.ID) {
		return badRequest("plan id: lower-case letters, digits, - and _ (max 32)")
	}
	p.Name = clip(p.Name, 50)
	if p.Name == "" {
		return badRequest("name is required")
	}
	if p.MaxDevices < 0 {
		return badRequest("max_devices must be >= 0 (0 = unlimited)")
	}
	ctx := r.Context()
	if !p.IsDefault {
		if cur, err := s.db.PlanByID(ctx, p.ID); err == nil && cur.IsDefault {
			return errf(http.StatusConflict, "plan_default", "make another plan the default first")
		}
	}
	saved, err := s.db.SavePlan(ctx, p)
	if err != nil {
		return err
	}
	s.db.Audit(ctx, a.User.ID, "admin.plan_save", p.ID, map[string]any{"max_devices": p.MaxDevices,
		"sync_enabled": p.SyncEnabled, "is_default": p.IsDefault}, s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"plan": saved})
	return nil
}

func (s *Server) handleDeletePlan(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	ctx := r.Context()
	id := r.PathValue("id")
	switch err := s.db.DeletePlan(ctx, id); {
	case errors.Is(err, db.ErrNotFound):
		return errNotFound
	case errors.Is(err, db.ErrPlanDefault):
		return errf(http.StatusConflict, "plan_default", "the default plan can't be deleted")
	case errors.Is(err, db.ErrPlanInUse):
		return errf(http.StatusConflict, "plan_in_use", "move users to another plan first")
	case err != nil:
		return err
	}
	s.db.Audit(ctx, a.User.ID, "admin.plan_delete", id, nil, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// ---- settings ----

const secretMask = "••••••••"

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	st, err := s.Settings(r.Context())
	if err != nil {
		return err
	}
	if st.SMTP.Password != "" {
		st.SMTP.Password = secretMask
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": st, "dev_mode": s.cfg.Dev, "public_url": s.cfg.PublicURL})
	return nil
}

func (s *Server) handlePutSettings(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var st Settings
	if err := decode(r, &st); err != nil {
		return err
	}
	ctx := r.Context()
	cur, err := s.Settings(ctx)
	if err != nil {
		return err
	}
	if st.SMTP.Password == secretMask { // unchanged
		st.SMTP.Password = cur.SMTP.Password
	}
	st.General.AppName = clip(st.General.AppName, 50)
	if st.General.AppName == "" {
		st.General.AppName = "MyTermi"
	}
	switch st.SMTP.Security {
	case "starttls", "tls", "none":
	case "":
		st.SMTP.Security = "starttls"
	default:
		return badRequest("smtp.security must be starttls, tls or none")
	}
	if st.SMTP.Port < 0 || st.SMTP.Port > 65535 {
		return badRequest("invalid smtp.port")
	}
	st.Google.ClientIDs = cleanList(st.Google.ClientIDs)
	st.Apple.Audiences = cleanList(st.Apple.Audiences)
	if err := s.saveSettings(ctx, st); err != nil {
		return err
	}
	s.db.Audit(ctx, a.User.ID, "admin.settings_update", "", nil, s.clientIP(r))
	return s.handleGetSettings(w, r, a)
}

func cleanList(in []string) []string {
	out := []string{}
	for _, v := range in {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func (s *Server) handleTestEmail(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var req struct {
		To string `json:"to"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	to := db.NormalizeEmail(req.To)
	if to == "" {
		to = a.User.Email
	}
	ctx := r.Context()
	st, err := s.Settings(ctx)
	if err != nil {
		return err
	}
	sender, err := s.mailer(st)
	if err != nil {
		return errf(http.StatusBadRequest, "email_not_configured", "fill in the SMTP settings and save them first")
	}
	err = sender.Send(ctx, mail.Message{
		To: to, Subject: st.General.AppName + ": email thử nghiệm",
		Text: "SMTP đã được cấu hình đúng. / SMTP is configured correctly.",
	})
	if err != nil {
		return errf(http.StatusBadGateway, "email_send_failed", err.Error())
	}
	writeJSON(w, http.StatusOK, map[string]any{"sent": true, "to": to})
	return nil
}

func (s *Server) handleAudit(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	limit, offset := pageParams(r)
	entries, total, err := s.db.AuditLog(r.Context(), limit, offset)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "total": total, "limit": limit, "offset": offset})
	return nil
}
