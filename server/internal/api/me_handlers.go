package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/db"
)

type planInfo struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	MaxDevices  int    `json:"max_devices"`
	SyncEnabled bool   `json:"sync_enabled"`
	// ExpiresAt is when this plan ends (then the default plan applies); null = no end.
	ExpiresAt *time.Time `json:"expires_at"`
}

// planExpiry is the end date to show for the effective plan.
func planExpiry(u *db.User, effective *db.Plan) *time.Time {
	if effective.ID == u.PlanID && !u.PlanExpired(time.Now()) {
		return u.PlanExpiresAt
	}
	return nil
}

type meResponse struct {
	ID            string    `json:"id"`
	Email         string    `json:"email"`
	EmailVerified bool      `json:"email_verified"`
	Name          string    `json:"name"`
	Role          string    `json:"role"`
	HasPassword   bool      `json:"has_password"`
	Providers     []string  `json:"providers"` // google / apple accounts linked
	Plan          planInfo  `json:"plan"`
	HasVault      bool      `json:"has_vault"`
	CreatedAt     time.Time `json:"created_at"`
}

func (s *Server) meOf(ctx context.Context, u *db.User) (*meResponse, error) {
	plan, err := s.db.EffectivePlan(ctx, u)
	if err != nil {
		return nil, err
	}
	ids, err := s.db.IdentitiesOf(ctx, u.ID)
	if err != nil {
		return nil, err
	}
	providers := []string{}
	for _, i := range ids {
		providers = append(providers, i.Provider)
	}
	_, verr := s.db.VaultOf(ctx, u.ID)
	if verr != nil && !errors.Is(verr, db.ErrNotFound) {
		return nil, verr
	}
	return &meResponse{
		ID: u.ID, Email: u.Email, EmailVerified: u.EmailVerified, Name: u.Name, Role: u.Role,
		HasPassword: u.HasPassword(), Providers: providers, HasVault: verr == nil, CreatedAt: u.CreatedAt,
		Plan: planInfo{ID: plan.ID, Name: plan.Name, MaxDevices: plan.MaxDevices, SyncEnabled: plan.SyncEnabled, ExpiresAt: planExpiry(u, plan)},
	}, nil
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	me, err := s.meOf(r.Context(), a.User)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, me)
	return nil
}

func (s *Server) handleUpdateMe(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var req struct {
		Name *string `json:"name"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.Name != nil {
		n := clip(*req.Name, 100)
		req.Name = &n
	}
	u, err := s.db.UpdateUser(r.Context(), a.User.ID, db.UserUpdate{Name: req.Name})
	if err != nil {
		return err
	}
	return s.handleMe(w, r, &authCtx{User: u, Session: a.Session})
}

// handleSetPassword sets or changes the password. Changing needs the current
// password, unless this session signed in with an email code in the last 15
// minutes (that is the "forgot password" flow).
func (s *Server) handleSetPassword(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var req struct {
		CurrentPassword string `json:"current_password"`
		NewPassword     string `json:"new_password"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if err := auth.ValidatePassword(req.NewPassword); err != nil {
		return errf(http.StatusBadRequest, "weak_password", err.Error())
	}
	ctx := r.Context()
	u := a.User
	recentCode := a.Session.AuthMethod == "email_code" && time.Since(a.Session.CreatedAt) < 15*time.Minute
	if u.HasPassword() && !recentCode {
		if err := s.rateLimit("pwchange:"+u.ID, 10, 15*time.Minute); err != nil {
			return err
		}
		if !auth.VerifyPassword(*u.PasswordHash, req.CurrentPassword) {
			return errf(http.StatusForbidden, "invalid_credentials", "current password is wrong")
		}
	}
	hash, err := auth.HashPassword(req.NewPassword)
	if err != nil {
		return err
	}
	if err := s.db.SetPassword(ctx, u.ID, hash); err != nil {
		return err
	}
	s.db.Audit(ctx, u.ID, "user.password_set", u.Email, nil, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// handleDeleteMe deletes the account and all synced data (App Store 5.1.1(v)).
func (s *Server) handleDeleteMe(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var req struct {
		Confirm string `json:"confirm"` // must equal the account email
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if db.NormalizeEmail(req.Confirm) != a.User.Email {
		return badRequest("confirm must be the account email")
	}
	ctx := r.Context()
	if a.User.Role == "admin" {
		if n, err := s.db.CountAdmins(ctx); err != nil {
			return err
		} else if n <= 1 {
			return errf(http.StatusConflict, "last_admin", "the last admin can't delete their account")
		}
	}
	if err := s.db.DeleteUser(ctx, a.User.ID); err != nil {
		return err
	}
	s.db.Audit(ctx, "", "user.deleted_self", a.User.Email, nil, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleSessions(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	list, err := s.db.ActiveSessions(r.Context(), a.User.ID, "app")
	if err != nil {
		return err
	}
	type item struct {
		db.Session
		Current bool `json:"current"`
	}
	out := []item{}
	for _, x := range list {
		out = append(out, item{Session: x, Current: x.ID == a.Session.ID})
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
	return nil
}

func (s *Server) handleRevokeSession(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	err := s.db.RevokeSession(r.Context(), a.User.ID, r.PathValue("id"))
	if errors.Is(err, db.ErrNotFound) {
		return errNotFound
	} else if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// ---- vault ----

var (
	errNoVault   = errf(http.StatusNotFound, "vault_not_found", "no vault yet")
	errStaleGen  = errf(http.StatusConflict, "vault_generation", "the vault was reset on another device; unlock again")
	errSyncPlan  = errf(http.StatusForbidden, "sync_disabled", "sync is not included in your plan")
	itemTypes    = map[string]bool{"host": true, "key": true, "snippet": true, "known_host": true, "setting": true}
	uuidRE       = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	maxItemBytes = 64 << 10
)

func (s *Server) requireSync(ctx context.Context, u *db.User) error {
	plan, err := s.db.EffectivePlan(ctx, u)
	if err != nil {
		return err
	}
	if !plan.SyncEnabled {
		return errSyncPlan
	}
	return nil
}

type vaultBody struct {
	Generation         int64           `json:"generation"`
	KDF                json.RawMessage `json:"kdf"`
	Salt               []byte          `json:"salt"`
	WrappedKey         []byte          `json:"wrapped_key"`
	RecoveryWrappedKey []byte          `json:"recovery_wrapped_key"`
}

func (b vaultBody) validate() error {
	var kdf struct {
		Alg string `json:"alg"`
	}
	if len(b.KDF) == 0 || len(b.KDF) > 1024 || json.Unmarshal(b.KDF, &kdf) != nil || kdf.Alg == "" {
		return badRequest("kdf must be a JSON object with an alg field")
	}
	if len(b.Salt) < 16 || len(b.Salt) > 64 {
		return badRequest("salt must be 16-64 bytes")
	}
	for _, k := range [][]byte{b.WrappedKey, b.RecoveryWrappedKey} {
		if len(k) < 32 || len(k) > 512 {
			return badRequest("wrapped keys must be 32-512 bytes")
		}
	}
	return nil
}

func (b vaultBody) vault() db.Vault {
	return db.Vault{KDF: b.KDF, Salt: b.Salt, WrappedKey: b.WrappedKey, RecoveryWrappedKey: b.RecoveryWrappedKey}
}

func (s *Server) handleGetVault(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	v, err := s.db.VaultOf(r.Context(), a.User.ID)
	if errors.Is(err, db.ErrNotFound) {
		return errNoVault
	} else if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, v)
	return nil
}

func (s *Server) handleCreateVault(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	ctx := r.Context()
	if err := s.requireSync(ctx, a.User); err != nil {
		return err
	}
	var b vaultBody
	if err := decode(r, &b); err != nil {
		return err
	}
	if err := b.validate(); err != nil {
		return err
	}
	v, err := s.db.CreateVault(ctx, a.User.ID, b.vault())
	if errors.Is(err, db.ErrVaultExists) {
		return errf(http.StatusConflict, "vault_exists", "a vault already exists; unlock it instead")
	} else if err != nil {
		return err
	}
	s.db.Audit(ctx, a.User.ID, "vault.created", a.User.Email, nil, s.clientIP(r))
	writeJSON(w, http.StatusCreated, v)
	return nil
}

// handleRewrapVault stores the vault key re-wrapped with a new vault password
// (or after recovery). Data is not re-encrypted.
func (s *Server) handleRewrapVault(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var b vaultBody
	if err := decode(r, &b); err != nil {
		return err
	}
	if err := b.validate(); err != nil {
		return err
	}
	ctx := r.Context()
	v, err := s.db.RewrapVault(ctx, a.User.ID, b.Generation, b.vault())
	switch {
	case errors.Is(err, db.ErrNotFound):
		return errNoVault
	case errors.Is(err, db.ErrGeneration):
		return errStaleGen
	case err != nil:
		return err
	}
	s.db.Audit(ctx, a.User.ID, "vault.rewrapped", a.User.Email, nil, s.clientIP(r))
	writeJSON(w, http.StatusOK, v)
	return nil
}

// handleResetVault deletes the vault and every synced item (forgot both the
// vault password and the recovery key). Local data on devices is untouched.
func (s *Server) handleResetVault(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var req struct {
		Confirm string `json:"confirm"` // "RESET"
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.Confirm != "RESET" {
		return badRequest(`confirm must be "RESET"`)
	}
	ctx := r.Context()
	err := s.db.DeleteVault(ctx, a.User.ID)
	if errors.Is(err, db.ErrNotFound) {
		return errNoVault
	} else if err != nil {
		return err
	}
	s.db.Audit(ctx, a.User.ID, "vault.reset", a.User.Email, nil, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// ---- sync ----

func (s *Server) syncVault(ctx context.Context, u *db.User, generation int64) (*db.Vault, error) {
	if err := s.requireSync(ctx, u); err != nil {
		return nil, err
	}
	v, err := s.db.VaultOf(ctx, u.ID)
	if errors.Is(err, db.ErrNotFound) {
		return nil, errNoVault
	} else if err != nil {
		return nil, err
	}
	if generation != v.Generation {
		return nil, errStaleGen
	}
	return v, nil
}

// handlePull: GET /sync?since=<rev>&generation=<gen>
func (s *Server) handlePull(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	q := r.URL.Query()
	since, err1 := strconv.ParseInt(q.Get("since"), 10, 64)
	gen, err2 := strconv.ParseInt(q.Get("generation"), 10, 64)
	if err1 != nil || err2 != nil || since < 0 {
		return badRequest("since and generation are required integers")
	}
	ctx := r.Context()
	v, err := s.syncVault(ctx, a.User, gen)
	if err != nil {
		return err
	}
	items, more, err := s.db.ItemsSince(ctx, a.User.ID, since, 500)
	if err != nil {
		return err
	}
	rev := v.Rev
	if more && len(items) > 0 {
		rev = items[len(items)-1].Rev // continue from here
	}
	writeJSON(w, http.StatusOK, map[string]any{"generation": v.Generation, "rev": rev, "items": items, "more": more})
	return nil
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request, a *authCtx) error {
	var req struct {
		Generation int64     `json:"generation"`
		Items      []db.Item `json:"items"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if len(req.Items) > 500 {
		return badRequest("at most 500 items per request")
	}
	now := time.Now()
	for i := range req.Items {
		it := &req.Items[i]
		if !uuidRE.MatchString(it.ID) {
			return badRequest("item id must be a lower-case UUID: " + it.ID)
		}
		if !itemTypes[it.Type] {
			return badRequest("unknown item type: " + it.Type)
		}
		if !it.Deleted && (len(it.Data) == 0 || len(it.Data) > maxItemBytes) {
			return badRequest("item data must be 1 byte - 64 KiB")
		}
		if it.ModifiedAt.IsZero() || it.ModifiedAt.After(now.Add(5*time.Minute)) {
			it.ModifiedAt = now // missing or skewed clock
		}
	}
	ctx := r.Context()
	if _, err := s.syncVault(ctx, a.User, req.Generation); err != nil {
		return err
	}
	res, err := s.db.PushItems(ctx, a.User.ID, req.Generation, req.Items)
	if errors.Is(err, db.ErrGeneration) {
		return errStaleGen
	} else if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, res)
	return nil
}
