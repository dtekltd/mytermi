package api

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// apiError is the JSON error body: {"error": {"code": "...", "message": "..."}}.
// Clients switch on Code; Message is a developer-facing English hint.
type apiError struct {
	Status  int            `json:"-"`
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

func (e *apiError) Error() string { return e.Code + ": " + e.Message }

func errf(status int, code, msg string) *apiError {
	return &apiError{Status: status, Code: code, Message: msg}
}

var (
	errUnauthorized = errf(http.StatusUnauthorized, "unauthorized", "missing or invalid credentials")
	errForbidden    = errf(http.StatusForbidden, "forbidden", "not allowed")
	errNotFound     = errf(http.StatusNotFound, "not_found", "not found")
	errDisabled     = errf(http.StatusForbidden, "account_disabled", "this account is disabled")
)

func badRequest(msg string) *apiError { return errf(http.StatusBadRequest, "invalid_request", msg) }

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

func writeError(w http.ResponseWriter, r *http.Request, err error) {
	var ae *apiError
	if !errors.As(err, &ae) {
		slog.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
		ae = errf(http.StatusInternalServerError, "internal", "internal server error")
	}
	writeJSON(w, ae.Status, map[string]any{"error": ae})
}

// decode reads a JSON body (max 1 MiB) into dst.
func decode(r *http.Request, dst any) error {
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		return errf(http.StatusUnsupportedMediaType, "invalid_request", "Content-Type must be application/json")
	}
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	if err := dec.Decode(dst); err != nil {
		return badRequest("invalid JSON body: " + err.Error())
	}
	return nil
}

// handler adapts error-returning handlers.
type handler func(w http.ResponseWriter, r *http.Request) error

func (s *Server) h(fn handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := fn(w, r); err != nil {
			writeError(w, r, err)
		}
	}
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		// Cloudflare (incl. Tunnel) sets CF-Connecting-IP itself. Otherwise the
		// proxy appends the peer it saw to X-Forwarded-For, so the last entry is
		// the trustworthy one; earlier entries come from the client.
		if cf := strings.TrimSpace(r.Header.Get("CF-Connecting-IP")); cf != "" {
			return cf
		}
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
		if xr := r.Header.Get("X-Real-IP"); xr != "" {
			return xr
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ---- rate limiting (in memory, per process) ----

type limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	count int
	reset time.Time
}

func newLimiter() *limiter {
	l := &limiter{buckets: map[string]*bucket{}}
	go func() {
		for range time.Tick(time.Minute) {
			l.mu.Lock()
			now := time.Now()
			for k, b := range l.buckets {
				if now.After(b.reset) {
					delete(l.buckets, k)
				}
			}
			l.mu.Unlock()
		}
	}()
	return l
}

// allow counts one hit for key; false once n hits happened within window.
func (l *limiter) allow(key string, n int, window time.Duration) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b := l.buckets[key]
	if b == nil || now.After(b.reset) {
		b = &bucket{reset: now.Add(window)}
		l.buckets[key] = b
	}
	if b.count >= n {
		return false, b.reset.Sub(now)
	}
	b.count++
	return true, 0
}

func (s *Server) rateLimit(key string, n int, window time.Duration) error {
	if ok, wait := s.limits.allow(key, n, window); !ok {
		e := errf(http.StatusTooManyRequests, "rate_limited", "too many requests, try again later")
		e.Details = map[string]any{"retry_after": int(wait.Seconds()) + 1}
		return e
	}
	return nil
}
