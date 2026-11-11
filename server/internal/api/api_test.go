package api_test

// Integration tests against a real Postgres. Set MYTERMI_TEST_DATABASE_URL to a
// database that may be wiped, e.g.
//   postgres://postgres:test@127.0.0.1:55432/mytermi_test?sslmode=disable

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/dtekltd/mytermi/server/internal/api"
	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/config"
	"github.com/dtekltd/mytermi/server/internal/db"
	"github.com/dtekltd/mytermi/server/internal/mail"
)

type env struct {
	t      *testing.T
	srv    *httptest.Server
	api    *api.Server
	db     *db.DB
	mail   *mail.Recorder
	jwks   *httptest.Server
	rsa    *rsa.PrivateKey
	google auth.Provider
}

func setup(t *testing.T) *env {
	t.Helper()
	url := os.Getenv("MYTERMI_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set MYTERMI_TEST_DATABASE_URL to run integration tests")
	}
	ctx := context.Background()
	d, err := db.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Close)
	if _, err := d.Pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	s, err := api.New(ctx, config.Config{}, d)
	if err != nil {
		t.Fatal(err)
	}
	rec := &mail.Recorder{}
	s.Mailer = rec

	// Fake Google/Apple JWKS endpoint signed with our own RSA key.
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "kid": "k1", "alg": "RS256",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	t.Cleanup(jwks.Close)
	auth.Google.JWKSURL = jwks.URL
	auth.Apple.JWKSURL = jwks.URL

	mux := http.NewServeMux()
	mux.Handle("/api/", s.Routes())
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &env{t: t, srv: srv, api: s, db: d, mail: rec, jwks: jwks, rsa: key}
}

type resp struct {
	Status int
	Body   map[string]any
	Raw    []byte
	Header http.Header
}

func (r resp) code() string {
	if e, ok := r.Body["error"].(map[string]any); ok {
		return e["code"].(string)
	}
	return ""
}

func (r resp) str(path ...string) string {
	var cur any = r.Body
	for _, p := range path {
		cur = cur.(map[string]any)[p]
	}
	switch v := cur.(type) {
	case string:
		return v
	case nil:
		return ""
	default:
		return fmt.Sprint(v)
	}
}

func (e *env) do(client *http.Client, method, path, token string, body any) resp {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rd)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if client == nil {
		client = http.DefaultClient
	}
	res, err := client.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	out := resp{Status: res.StatusCode, Raw: raw, Header: res.Header, Body: map[string]any{}}
	_ = json.Unmarshal(raw, &out.Body)
	return out
}

func (e *env) call(method, path, token string, body any) resp {
	return e.do(nil, method, path, token, body)
}

func (e *env) expect(r resp, status int, code string) {
	e.t.Helper()
	if r.Status != status || r.code() != code {
		e.t.Fatalf("want %d %q, got %d %s", status, code, r.Status, r.Raw)
	}
}

var codeRE = regexp.MustCompile(`\b(\d{6})\b`)

func (e *env) lastCode(email string) string {
	e.t.Helper()
	m, ok := e.mail.Last(strings.ToLower(email))
	if !ok {
		e.t.Fatalf("no email sent to %s", email)
	}
	return codeRE.FindStringSubmatch(m.Text)[1]
}

// signUp registers via email code and returns the token response.
func (e *env) signUp(email, device string) resp {
	e.t.Helper()
	e.expect(e.call("POST", "/api/v1/auth/email/start", "", map[string]any{"email": email}), 200, "")
	r := e.call("POST", "/api/v1/auth/email/verify", "", map[string]any{
		"email": email, "code": e.lastCode(email), "device": map[string]string{"id": device, "name": device, "platform": "ios"},
	})
	e.expect(r, 200, "")
	return r
}

func (e *env) idToken(iss, aud, sub, email string, verified any, exp time.Duration) string {
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": iss, "aud": aud, "sub": sub, "email": email, "email_verified": verified,
		"exp": time.Now().Add(exp).Unix(), "iat": time.Now().Unix(), "name": "Tuan",
	})
	tok.Header["kid"] = "k1"
	s, err := tok.SignedString(e.rsa)
	if err != nil {
		e.t.Fatal(err)
	}
	return s
}

func (e *env) settings(fn func(s *api.Settings)) {
	st, _ := e.api.Settings(context.Background())
	fn(&st)
	if err := e.db.PutSetting(context.Background(), "server", st); err != nil {
		e.t.Fatal(err)
	}
	// bypass the settings cache
	e.api2(st)
}

func (e *env) api2(st api.Settings) { api.SetSettingsForTest(e.api, st) }

// ---------------------------------------------------------------- tests

func TestEmailSignUpPasswordAndRefresh(t *testing.T) {
	e := setup(t)
	r := e.signUp("Tuan@Example.com", "dev-1")
	if r.str("is_new_user") != "true" || r.str("user", "email") != "tuan@example.com" || r.str("user", "has_password") != "false" {
		t.Fatalf("unexpected sign-up response: %s", r.Raw)
	}
	access, refresh := r.str("access_token"), r.str("refresh_token")

	// No password yet → password login fails generically.
	e.expect(e.call("POST", "/api/v1/auth/password", "", map[string]any{"email": "tuan@example.com", "password": "whatever1"}), 401, "invalid_credentials")

	// Set a password (no current password needed the first time).
	e.expect(e.call("POST", "/api/v1/me/password", access, map[string]any{"new_password": "short"}), 400, "weak_password")
	e.expect(e.call("POST", "/api/v1/me/password", access, map[string]any{"new_password": "hunter22!"}), 204, "")

	// Password login works, wrong password doesn't.
	e.expect(e.call("POST", "/api/v1/auth/password", "", map[string]any{"email": "TUAN@example.com", "password": "nope-nope"}), 401, "invalid_credentials")
	r2 := e.call("POST", "/api/v1/auth/password", "", map[string]any{"email": "tuan@example.com", "password": "hunter22!", "device": map[string]string{"id": "dev-2"}})
	e.expect(r2, 200, "")
	if r2.str("is_new_user") != "false" || r2.str("user", "has_password") != "true" {
		t.Fatalf("bad login response: %s", r2.Raw)
	}

	// Changing it later from a password session requires the current password.
	a2 := r2.str("access_token")
	e.expect(e.call("POST", "/api/v1/me/password", a2, map[string]any{"new_password": "another-pass"}), 403, "invalid_credentials")
	e.expect(e.call("POST", "/api/v1/me/password", a2, map[string]any{"current_password": "hunter22!", "new_password": "another-pass"}), 204, "")

	// Refresh rotates: the old refresh token stops working.
	r3 := e.call("POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": refresh})
	e.expect(r3, 200, "")
	e.expect(e.call("POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": refresh}), 401, "session_revoked")

	// Logout revokes the session: its access token is rejected immediately.
	a3 := r3.str("access_token")
	e.expect(e.call("GET", "/api/v1/me", a3, nil), 200, "")
	e.expect(e.call("POST", "/api/v1/auth/logout", a3, nil), 204, "")
	e.expect(e.call("GET", "/api/v1/me", a3, nil), 401, "session_revoked")
	e.expect(e.call("POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": r3.str("refresh_token")}), 401, "session_revoked")
}

func TestForgotPasswordViaEmailCode(t *testing.T) {
	e := setup(t)
	a := e.signUp("u@example.com", "d1").str("access_token")
	e.expect(e.call("POST", "/api/v1/me/password", a, map[string]any{"new_password": "first-pass"}), 204, "")
	// Forgot it: sign in with a fresh email code, then set a new one without the old.
	e.db.Pool.Exec(context.Background(), `UPDATE email_codes SET created_at = now() - interval '2 minutes'`)
	r := e.signUp("u@example.com", "d1")
	e.expect(e.call("POST", "/api/v1/me/password", r.str("access_token"), map[string]any{"new_password": "second-pass"}), 204, "")
	e.expect(e.call("POST", "/api/v1/auth/password", "", map[string]any{"email": "u@example.com", "password": "second-pass"}), 200, "")
}

func TestEmailCodeRules(t *testing.T) {
	e := setup(t)
	e.expect(e.call("POST", "/api/v1/auth/email/start", "", map[string]any{"email": "not-an-email"}), 400, "invalid_email")
	e.expect(e.call("POST", "/api/v1/auth/email/start", "", map[string]any{"email": "a@example.com"}), 200, "")
	// Resend within a minute is refused.
	r := e.call("POST", "/api/v1/auth/email/start", "", map[string]any{"email": "a@example.com"})
	e.expect(r, 429, "rate_limited")

	code := e.lastCode("a@example.com")
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	// 5 wrong guesses burn the code; then even the right one fails.
	for i := 0; i < 5; i++ {
		e.expect(e.call("POST", "/api/v1/auth/email/verify", "", map[string]any{"email": "a@example.com", "code": wrong}), 400, "invalid_code")
	}
	e.expect(e.call("POST", "/api/v1/auth/email/verify", "", map[string]any{"email": "a@example.com", "code": code}), 400, "invalid_code")

	// A code can't be used twice, and expired codes are rejected.
	e.db.Pool.Exec(context.Background(), `UPDATE email_codes SET created_at = now() - interval '2 minutes'`)
	e.signUp("a@example.com", "d")
	e.expect(e.call("POST", "/api/v1/auth/email/verify", "", map[string]any{"email": "a@example.com", "code": e.lastCode("a@example.com")}), 400, "invalid_code")

	// Sign-ups can be turned off; existing users still get codes.
	e.settings(func(s *api.Settings) { s.General.SignupEnabled = false })
	e.expect(e.call("POST", "/api/v1/auth/email/start", "", map[string]any{"email": "new@example.com"}), 403, "signup_disabled")
	e.db.Pool.Exec(context.Background(), `UPDATE email_codes SET created_at = now() - interval '2 minutes'`)
	e.expect(e.call("POST", "/api/v1/auth/email/start", "", map[string]any{"email": "a@example.com"}), 200, "")
}

func TestDeviceLimit(t *testing.T) {
	e := setup(t) // free plan: 2 devices
	a := e.signUp("d@example.com", "phone").str("access_token")
	e.call("POST", "/api/v1/me/password", a, map[string]any{"new_password": "password-1"})
	login := func(dev string) resp {
		return e.call("POST", "/api/v1/auth/password", "", map[string]any{"email": "d@example.com", "password": "password-1",
			"device": map[string]string{"id": dev}})
	}
	e.expect(login("ipad"), 200, "")
	r := login("laptop")
	e.expect(r, 403, "device_limit")
	// Same device signing in again replaces its old session instead of counting twice.
	e.expect(login("ipad"), 200, "")
	sessions := e.call("GET", "/api/v1/me/sessions", a, nil)
	if n := len(sessions.Body["sessions"].([]any)); n != 2 {
		t.Fatalf("want 2 sessions, got %d: %s", n, sessions.Raw)
	}
	// Admin upgrades to Pro (unlimited).
	e.db.Pool.Exec(context.Background(), `UPDATE users SET plan_id = 'pro'`)
	e.expect(login("laptop"), 200, "")
}

func TestGoogleAndAppleSignIn(t *testing.T) {
	e := setup(t)
	// Not configured yet.
	e.expect(e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": "x"}), 403, "provider_not_configured")
	e.settings(func(s *api.Settings) {
		s.Google.Enabled, s.Google.ClientIDs = true, []string{"ios-client.apps.googleusercontent.com"}
		s.Apple.Enabled, s.Apple.Audiences = true, []string{"com.mytermi.app"}
	})
	cfg := e.call("GET", "/api/v1/config", "", nil)
	if cfg.str("providers", "google") != "true" || cfg.str("providers", "apple") != "true" {
		t.Fatalf("config: %s", cfg.Raw)
	}

	// An email user exists first; Google with the same verified email links to it.
	emailUser := e.signUp("g@example.com", "d1")
	tok := e.idToken("https://accounts.google.com", "ios-client.apps.googleusercontent.com", "google-sub-1", "G@example.com", true, time.Hour)
	r := e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": tok, "device": map[string]string{"id": "d1"}})
	e.expect(r, 200, "")
	if r.str("user", "id") != emailUser.str("user", "id") || r.str("is_new_user") != "false" {
		t.Fatalf("google should link to the email account: %s", r.Raw)
	}
	if r.str("user", "providers") != "[google]" {
		t.Fatalf("providers: %s", r.Raw)
	}

	// Wrong audience, expired, bad signature, unverified email: rejected.
	bad := e.idToken("https://accounts.google.com", "someone-else", "s", "x@example.com", true, time.Hour)
	e.expect(e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": bad}), 401, "invalid_id_token")
	expired := e.idToken("https://accounts.google.com", "ios-client.apps.googleusercontent.com", "s", "x@example.com", true, -2*time.Hour)
	e.expect(e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": expired}), 401, "invalid_id_token")
	e.expect(e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": tok[:len(tok)-4] + "AAAA"}), 401, "invalid_id_token")
	unverified := e.idToken("https://accounts.google.com", "ios-client.apps.googleusercontent.com", "s2", "y@example.com", false, time.Hour)
	e.expect(e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": unverified}), 400, "email_unverified")
	wrongIss := e.idToken("https://evil.example.com", "ios-client.apps.googleusercontent.com", "s3", "z@example.com", true, time.Hour)
	e.expect(e.call("POST", "/api/v1/auth/google", "", map[string]any{"id_token": wrongIss}), 401, "invalid_id_token")

	// Apple: new user (private relay email, email_verified as a string), name from the app.
	at := e.idToken("https://appleid.apple.com", "com.mytermi.app", "apple-sub-1", "abc@privaterelay.appleid.com", "true", time.Hour)
	ra := e.call("POST", "/api/v1/auth/apple", "", map[string]any{"identity_token": at, "name": "Tuan Phan"})
	e.expect(ra, 200, "")
	if ra.str("is_new_user") != "true" || ra.str("user", "name") != "Tuan Phan" {
		t.Fatalf("apple sign-up: %s", ra.Raw)
	}
	// Next Apple sign-in (no email claim this time) finds the same user by subject.
	at2 := e.idToken("https://appleid.apple.com", "com.mytermi.app", "apple-sub-1", "", nil, time.Hour)
	ra2 := e.call("POST", "/api/v1/auth/apple", "", map[string]any{"identity_token": at2})
	e.expect(ra2, 200, "")
	if ra2.str("user", "id") != ra.str("user", "id") {
		t.Fatal("apple re-login should find the same user")
	}
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func vaultBody(gen any) map[string]any {
	return map[string]any{
		"generation":           gen,
		"kdf":                  map[string]any{"alg": "argon2id", "m": 65536, "t": 3, "p": 1},
		"salt":                 b64("0123456789abcdef"),
		"wrapped_key":          b64(strings.Repeat("w", 72)),
		"recovery_wrapped_key": b64(strings.Repeat("r", 72)),
	}
}

func TestVaultAndSync(t *testing.T) {
	e := setup(t)
	a := e.signUp("v@example.com", "phone").str("access_token")
	e.expect(e.call("GET", "/api/v1/vault", a, nil), 404, "vault_not_found")
	e.expect(e.call("POST", "/api/v1/vault", a, map[string]any{"kdf": map[string]any{}}), 400, "invalid_request")
	created := e.call("POST", "/api/v1/vault", a, vaultBody(nil))
	e.expect(created, 201, "")
	gen := int64(created.Body["generation"].(float64))
	e.expect(e.call("POST", "/api/v1/vault", a, vaultBody(nil)), 409, "vault_exists")
	if e.call("GET", "/api/v1/me", a, nil).str("has_vault") != "true" {
		t.Fatal("me.has_vault should be true")
	}

	id1, id2 := "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
	t0 := time.Now().Add(-time.Hour).UTC()
	push := func(token string, g int64, items ...map[string]any) resp {
		return e.call("POST", "/api/v1/sync", token, map[string]any{"generation": g, "items": items})
	}
	item := func(id, typ, data string, mod time.Time, deleted bool) map[string]any {
		m := map[string]any{"id": id, "type": typ, "modified_at": mod.Format(time.RFC3339Nano), "deleted": deleted}
		if data != "" {
			m["data"] = b64(data)
		}
		return m
	}
	e.expect(push(a, gen, item("not-a-uuid", "host", "x", t0, false)), 400, "invalid_request")
	e.expect(push(a, gen, item(id1, "bogus", "x", t0, false)), 400, "invalid_request")
	e.expect(push(a, gen, item(id1, "host", "", t0, false)), 400, "invalid_request")

	r := push(a, gen, item(id1, "host", "cipher-host-1", t0, false), item(id2, "key", "cipher-key-1", t0, false))
	e.expect(r, 200, "")
	if len(r.Body["accepted"].([]any)) != 2 {
		t.Fatalf("push: %s", r.Raw)
	}

	// Second device (Pro not needed: 2 devices allowed) pulls everything.
	e.call("POST", "/api/v1/me/password", a, map[string]any{"new_password": "password-1"})
	b := e.call("POST", "/api/v1/auth/password", "", map[string]any{"email": "v@example.com", "password": "password-1",
		"device": map[string]string{"id": "ipad"}}).str("access_token")
	pull := e.call("GET", fmt.Sprintf("/api/v1/sync?since=0&generation=%d", gen), b, nil)
	e.expect(pull, 200, "")
	items := pull.Body["items"].([]any)
	if len(items) != 2 || items[0].(map[string]any)["data"] != b64("cipher-host-1") {
		t.Fatalf("pull: %s", pull.Raw)
	}
	rev := int64(pull.Body["rev"].(float64))

	// Device B edits id1 later; device A pushes an older edit → conflict, server copy returned.
	e.expect(push(b, gen, item(id1, "host", "cipher-host-B", t0.Add(10*time.Minute), false)), 200, "")
	c := push(a, gen, item(id1, "host", "cipher-host-A-old", t0.Add(5*time.Minute), false))
	e.expect(c, 200, "")
	conf := c.Body["conflicts"].([]any)
	if len(conf) != 1 || conf[0].(map[string]any)["data"] != b64("cipher-host-B") {
		t.Fatalf("expected a conflict with B's copy: %s", c.Raw)
	}
	// Delete id2 (tombstone) and pull incrementally from device A.
	e.expect(push(b, gen, item(id2, "key", "", t0.Add(20*time.Minute), true)), 200, "")
	inc := e.call("GET", fmt.Sprintf("/api/v1/sync?since=%d&generation=%d", rev, gen), a, nil)
	got := inc.Body["items"].([]any)
	if len(got) != 2 || got[1].(map[string]any)["deleted"] != true || got[1].(map[string]any)["data"] != nil {
		t.Fatalf("incremental pull: %s", inc.Raw)
	}

	// Change vault password = rewrap, needs the current generation.
	e.expect(e.call("PUT", "/api/v1/vault", a, vaultBody(gen+1)), 409, "vault_generation")
	e.expect(e.call("PUT", "/api/v1/vault", a, vaultBody(gen)), 200, "")

	// Reset: items gone, new generation; old generation is rejected.
	e.expect(e.call("DELETE", "/api/v1/vault", a, map[string]any{"confirm": "nope"}), 400, "invalid_request")
	e.expect(e.call("DELETE", "/api/v1/vault", a, map[string]any{"confirm": "RESET"}), 204, "")
	time.Sleep(5 * time.Millisecond)
	nv := e.call("POST", "/api/v1/vault", b, vaultBody(nil))
	e.expect(nv, 201, "")
	if int64(nv.Body["generation"].(float64)) == gen {
		t.Fatal("generation must change after reset")
	}
	e.expect(push(a, gen, item(id1, "host", "x", time.Now(), false)), 409, "vault_generation")
	e.expect(e.call("GET", fmt.Sprintf("/api/v1/sync?since=0&generation=%d", gen), a, nil), 409, "vault_generation")

	// Plans without sync can't use the vault.
	e.db.Pool.Exec(context.Background(), `UPDATE plans SET sync_enabled = false`)
	e.expect(e.call("GET", fmt.Sprintf("/api/v1/sync?since=0&generation=%d", gen), a, nil), 403, "sync_disabled")
}

func TestDeleteAccount(t *testing.T) {
	e := setup(t)
	r := e.signUp("bye@example.com", "d")
	a := r.str("access_token")
	e.call("POST", "/api/v1/vault", a, vaultBody(nil))
	e.expect(e.call("DELETE", "/api/v1/me", a, map[string]any{"confirm": "other@example.com"}), 400, "invalid_request")
	e.expect(e.call("DELETE", "/api/v1/me", a, map[string]any{"confirm": "BYE@example.com"}), 204, "")
	e.expect(e.call("GET", "/api/v1/me", a, nil), 401, "session_revoked")
	var n int
	e.db.Pool.QueryRow(context.Background(), `SELECT count(*) FROM vaults`).Scan(&n)
	if n != 0 {
		t.Fatal("vault should be deleted with the account")
	}
}

func TestAdminConsole(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	// Bootstrap an admin the way `mytermi admin create` does.
	admin, _ := e.db.CreateUser(ctx, "admin@example.com", "Admin", true)
	role := "admin"
	e.db.UpdateUser(ctx, admin.ID, db.UserUpdate{Role: &role})
	h, _ := auth.HashPassword("admin-pass-1")
	e.db.SetPassword(ctx, admin.ID, h)
	user := e.signUp("user@example.com", "d")

	jar, _ := cookiejar.New(nil)
	console := &http.Client{Jar: jar}
	e.expect(e.do(console, "GET", "/api/v1/admin/stats", "", nil), 401, "unauthorized")
	// A normal user can't use the console.
	e.expect(e.do(console, "GET", "/api/v1/admin/stats", user.str("access_token"), nil), 403, "forbidden")
	e.expect(e.do(console, "POST", "/api/v1/admin/login", "", map[string]any{"email": "admin@example.com", "password": "wrong-pass"}), 401, "invalid_credentials")
	login := e.do(console, "POST", "/api/v1/admin/login", "", map[string]any{"email": "admin@example.com", "password": "admin-pass-1"})
	e.expect(login, 200, "")
	if c := login.Header.Get("Set-Cookie"); !strings.Contains(c, "HttpOnly") || !strings.Contains(c, "SameSite=Strict") {
		t.Fatalf("cookie flags: %s", c)
	}

	stats := e.do(console, "GET", "/api/v1/admin/stats", "", nil)
	e.expect(stats, 200, "")
	if stats.str("users") != "2" || len(stats.Body["signups_daily"].([]any)) != 30 {
		t.Fatalf("stats: %s", stats.Raw)
	}
	list := e.do(console, "GET", "/api/v1/admin/users?q=user@", "", nil)
	if list.str("total") != "1" {
		t.Fatalf("users search: %s", list.Raw)
	}
	uid := user.str("user", "id")

	// Upgrade the user to Pro; unknown plan rejected.
	e.expect(e.do(console, "PATCH", "/api/v1/admin/users/"+uid, "", map[string]any{"plan_id": "gold"}), 400, "invalid_request")
	up := e.do(console, "PATCH", "/api/v1/admin/users/"+uid, "", map[string]any{"plan_id": "pro"})
	e.expect(up, 200, "")
	if e.call("GET", "/api/v1/me", user.str("access_token"), nil).str("plan", "id") != "pro" {
		t.Fatal("plan change not visible to the user")
	}
	// Disabling revokes the user's sessions.
	e.expect(e.do(console, "PATCH", "/api/v1/admin/users/"+uid, "", map[string]any{"disabled": true}), 200, "")
	e.expect(e.call("GET", "/api/v1/me", user.str("access_token"), nil), 401, "session_revoked")

	// The last admin can't be demoted or delete themselves.
	e.expect(e.do(console, "PATCH", "/api/v1/admin/users/"+admin.ID, "", map[string]any{"role": "user"}), 409, "last_admin")
	e.expect(e.do(console, "DELETE", "/api/v1/admin/users/"+admin.ID, "", nil), 409, "self_delete")

	// Plans: create, can't delete default / in-use plans.
	e.expect(e.do(console, "PUT", "/api/v1/admin/plans/team", "", map[string]any{"name": "Team", "max_devices": 10, "sync_enabled": true}), 200, "")
	e.expect(e.do(console, "DELETE", "/api/v1/admin/plans/free", "", nil), 409, "plan_default")
	e.expect(e.do(console, "DELETE", "/api/v1/admin/plans/pro", "", nil), 409, "plan_in_use")
	e.expect(e.do(console, "DELETE", "/api/v1/admin/plans/team", "", nil), 204, "")

	// Settings: SMTP password is masked and kept when the mask is sent back.
	st := e.do(console, "GET", "/api/v1/admin/settings", "", nil).Body["settings"].(map[string]any)
	st["smtp"] = map[string]any{"host": "smtp.example.com", "port": 587, "username": "u", "password": "s3cret", "from": "MyTermi <no-reply@example.com>", "security": "starttls"}
	saved := e.do(console, "PUT", "/api/v1/admin/settings", "", st)
	e.expect(saved, 200, "")
	if saved.str("settings", "smtp", "password") != "••••••••" {
		t.Fatalf("password should be masked: %s", saved.Raw)
	}
	st["smtp"].(map[string]any)["password"] = "••••••••"
	e.do(console, "PUT", "/api/v1/admin/settings", "", st)
	var stored api.Settings
	e.db.GetSetting(ctx, "server", &stored)
	if stored.SMTP.Password != "s3cret" {
		t.Fatalf("masked password must not overwrite the real one, got %q", stored.SMTP.Password)
	}
	e.expect(e.do(console, "POST", "/api/v1/admin/settings/test-email", "", map[string]any{"to": "ops@example.com"}), 200, "")
	if _, ok := e.mail.Last("ops@example.com"); !ok {
		t.Fatal("test email not sent")
	}

	// Audit log recorded the actions; logout ends the console session.
	audit := e.do(console, "GET", "/api/v1/admin/audit", "", nil)
	if !strings.Contains(string(audit.Raw), "admin.user_update") {
		t.Fatalf("audit: %s", audit.Raw)
	}
	e.expect(e.do(console, "POST", "/api/v1/admin/logout", "", nil), 204, "")
	e.expect(e.do(console, "GET", "/api/v1/admin/stats", "", nil), 401, "unauthorized")
}

func TestSettingsDefaultsAreArrays(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	admin, _ := e.db.CreateUser(ctx, "a@example.com", "", true)
	role := "admin"
	e.db.UpdateUser(ctx, admin.ID, db.UserUpdate{Role: &role})
	h, _ := auth.HashPassword("admin-pass-1")
	e.db.SetPassword(ctx, admin.ID, h)
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar}
	e.do(c, "POST", "/api/v1/admin/login", "", map[string]any{"email": "a@example.com", "password": "admin-pass-1"})
	r := e.do(c, "GET", "/api/v1/admin/settings", "", nil)
	if !strings.Contains(string(r.Raw), `"client_ids":[]`) || !strings.Contains(string(r.Raw), `"audiences":[]`) {
		t.Fatalf("lists must be [] not null: %s", r.Raw)
	}
}
