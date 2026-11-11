package api_test

import (
	"context"
	"net/http"
	"net/http/cookiejar"
	"testing"
	"time"

	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/db"
)

// consoleAdmin creates an admin and returns a console client signed in as them.
func (e *env) consoleAdmin() *http.Client {
	e.t.Helper()
	ctx := context.Background()
	admin, _ := e.db.CreateUser(ctx, "admin@example.com", "Admin", true)
	role := "admin"
	e.db.UpdateUser(ctx, admin.ID, db.UserUpdate{Role: &role})
	h, _ := auth.HashPassword("admin-pass-1")
	e.db.SetPassword(ctx, admin.ID, h)
	jar, _ := cookiejar.New(nil)
	console := &http.Client{Jar: jar}
	e.expect(e.do(console, "POST", "/api/v1/admin/login", "", map[string]any{"email": "admin@example.com", "password": "admin-pass-1"}), 200, "")
	return console
}

func TestPlanExpiry(t *testing.T) {
	e := setup(t)
	console := e.consoleAdmin()
	user := e.signUp("user@example.com", "d1")
	access, id := user.str("access_token"), user.str("user", "id")
	path := "/api/v1/admin/users/" + id
	plan := func() (string, any) {
		me := e.call("GET", "/api/v1/me", access, nil)
		e.expect(me, 200, "")
		p := me.Body["plan"].(map[string]any)
		return p["id"].(string), p["expires_at"]
	}

	// Pro until next month.
	until := time.Now().Add(30 * 24 * time.Hour).UTC().Truncate(time.Second)
	r := e.do(console, "PATCH", path, "", map[string]any{"plan_id": "pro", "plan_expires_at": until})
	e.expect(r, 200, "")
	if got, exp := plan(); got != "pro" || exp != until.Format(time.RFC3339) {
		t.Fatalf("want pro until %s, got %s %v", until, got, exp)
	}

	// A PATCH without the field keeps the end date.
	e.expect(e.do(console, "PATCH", path, "", map[string]any{"name": "Tuan"}), 200, "")
	if _, exp := plan(); exp == nil {
		t.Fatal("end date lost by an unrelated update")
	}

	// Once the end date passes, the default plan applies (and its limits).
	e.expect(e.do(console, "PATCH", path, "", map[string]any{"plan_expires_at": time.Now().Add(-time.Minute)}), 200, "")
	if got, exp := plan(); got != "free" || exp != nil {
		t.Fatalf("expired plan should fall back to free, got %s %v", got, exp)
	}
	e.expect(e.do(console, "POST", path+"/password", "", map[string]any{"password": "user-pass-1"}), 204, "")
	signIn := func(device string) resp {
		return e.call("POST", "/api/v1/auth/password", "", map[string]any{
			"email": "user@example.com", "password": "user-pass-1", "device": map[string]string{"id": device},
		})
	}
	e.expect(signIn("d2"), 200, "")             // free allows 2 devices
	e.expect(signIn("d3"), 403, "device_limit") // pro (unlimited) no longer applies

	// Clearing the end date makes the plan permanent again.
	r = e.do(console, "PATCH", path, "", map[string]any{"plan_expires_at": nil})
	e.expect(r, 200, "")
	if r.Body["user"].(map[string]any)["plan_expires_at"] != nil {
		t.Fatalf("end date not cleared: %s", r.Raw)
	}
	if got, exp := plan(); got != "pro" || exp != nil {
		t.Fatalf("want permanent pro, got %s %v", got, exp)
	}
}

func TestAdminSetPassword(t *testing.T) {
	e := setup(t)
	console := e.consoleAdmin()
	user := e.signUp("user@example.com", "d1")
	path := "/api/v1/admin/users/" + user.str("user", "id") + "/password"

	e.expect(e.do(console, "POST", path, "", map[string]any{"password": "short"}), 400, "weak_password")
	e.expect(e.do(console, "POST", path, "", map[string]any{"password": "new-pass-123", "revoke_sessions": true}), 204, "")

	// The user's devices are signed out; the new password works.
	e.expect(e.call("POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": user.str("refresh_token")}), 401, "session_revoked")
	e.expect(e.call("POST", "/api/v1/auth/password", "", map[string]any{
		"email": "user@example.com", "password": "new-pass-123", "device": map[string]string{"id": "d2"},
	}), 200, "")

	// Without revoke_sessions, existing sessions stay.
	again := e.call("POST", "/api/v1/auth/password", "", map[string]any{
		"email": "user@example.com", "password": "new-pass-123", "device": map[string]string{"id": "d3"},
	})
	e.expect(e.do(console, "POST", path, "", map[string]any{"password": "third-pass-1"}), 204, "")
	e.expect(e.call("POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": again.str("refresh_token")}), 200, "")

	// A normal user can't call it.
	e.expect(e.call("POST", path, again.str("access_token"), map[string]any{"password": "x-pass-1234"}), 403, "forbidden")
}
