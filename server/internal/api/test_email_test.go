package api_test

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"net/http/cookiejar"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/dtekltd/mytermi/server/internal/api"
	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/db"
)

// fakeSMTP accepts one plain-SMTP conversation per connection and records the
// envelope recipients.
type fakeSMTP struct {
	ln  net.Listener
	mu  sync.Mutex
	rcp []string
}

func startFakeSMTP(t *testing.T) *fakeSMTP {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeSMTP{ln: ln}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(c)
		}
	}()
	return f
}

func (f *fakeSMTP) serve(c net.Conn) {
	defer c.Close()
	r := bufio.NewReader(c)
	say := func(s string) { c.Write([]byte(s + "\r\n")) }
	say("220 fake")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		cmd := strings.ToUpper(strings.TrimSpace(line))
		switch {
		case strings.HasPrefix(cmd, "EHLO"), strings.HasPrefix(cmd, "HELO"):
			say("250 fake")
		case strings.HasPrefix(cmd, "RCPT TO:"):
			f.mu.Lock()
			f.rcp = append(f.rcp, strings.Trim(strings.TrimSpace(line[8:]), "<>"))
			f.mu.Unlock()
			say("250 ok")
		case cmd == "DATA":
			say("354 go")
			for {
				l, err := r.ReadString('\n')
				if err != nil || l == ".\r\n" {
					break
				}
			}
			say("250 queued")
		case cmd == "QUIT":
			say("221 bye")
			return
		default:
			say("250 ok")
		}
	}
}

func (f *fakeSMTP) got() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.rcp...)
}

func TestTestEmailUsesUnsavedFormAndReportsDevLog(t *testing.T) {
	e := setup(t)
	e.api.Mailer = nil // use the real SMTP / dev-log senders
	ctx := context.Background()
	admin, _ := e.db.CreateUser(ctx, "admin@example.com", "Admin", true)
	role := "admin"
	e.db.UpdateUser(ctx, admin.ID, db.UserUpdate{Role: &role})
	h, _ := auth.HashPassword("admin-pass-1")
	e.db.SetPassword(ctx, admin.ID, h)
	jar, _ := cookiejar.New(nil)
	console := &http.Client{Jar: jar}
	e.expect(e.do(console, "POST", "/api/v1/admin/login", "", map[string]any{"email": "admin@example.com", "password": "admin-pass-1"}), 200, "")

	// Nothing saved, not dev: there is no way to send.
	e.expect(e.do(console, "POST", "/api/v1/admin/settings/test-email", "", map[string]any{"to": "ops@example.com"}), 400, "email_not_configured")

	// Dev mode without SMTP: the email is only logged, and the response says so.
	api.SetDevForTest(e.api, true)
	r := e.do(console, "POST", "/api/v1/admin/settings/test-email", "", map[string]any{"to": "ops@example.com"})
	e.expect(r, 200, "")
	if r.Body["logged"] != true || r.Body["sent"] != false {
		t.Fatalf("dev log should be reported, got %s", r.Raw)
	}

	// SMTP filled in the form but not saved: the test uses the form values.
	f := startFakeSMTP(t)
	host, p, _ := net.SplitHostPort(f.ln.Addr().String())
	port, _ := strconv.Atoi(p)
	form := map[string]any{"host": host, "port": port, "from": "MyTermi <no-reply@example.com>", "security": "none"}
	r = e.do(console, "POST", "/api/v1/admin/settings/test-email", "", map[string]any{"to": "ops@example.com", "smtp": form})
	e.expect(r, 200, "")
	if r.Body["sent"] != true {
		t.Fatalf("expected sent, got %s", r.Raw)
	}
	if got := f.got(); len(got) != 1 || got[0] != "ops@example.com" {
		t.Fatalf("fake SMTP recipients: %v", got)
	}
}
