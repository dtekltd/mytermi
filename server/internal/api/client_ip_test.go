package api

import (
	"net/http/httptest"
	"testing"

	"github.com/dtekltd/mytermi/server/internal/config"
)

func TestClientIP(t *testing.T) {
	cases := []struct {
		name    string
		trust   bool
		headers map[string]string
		want    string
	}{
		{"direct", false, nil, "192.0.2.1"},
		{"headers ignored without trust", false, map[string]string{"X-Forwarded-For": "1.1.1.1", "CF-Connecting-IP": "2.2.2.2"}, "192.0.2.1"},
		{"cloudflare", true, map[string]string{"CF-Connecting-IP": "203.0.113.7", "X-Forwarded-For": "6.6.6.6, 203.0.113.7"}, "203.0.113.7"},
		{"proxy appends the real peer", true, map[string]string{"X-Forwarded-For": "6.6.6.6, 198.51.100.4"}, "198.51.100.4"},
		{"x-real-ip", true, map[string]string{"X-Real-IP": "198.51.100.9"}, "198.51.100.9"},
		{"trust but no headers", true, nil, "192.0.2.1"},
	}
	for _, c := range cases {
		s := &Server{cfg: config.Config{TrustProxy: c.trust}}
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = "192.0.2.1:5555"
		for k, v := range c.headers {
			r.Header.Set(k, v)
		}
		if got := s.clientIP(r); got != c.want {
			t.Errorf("%s: got %s, want %s", c.name, got, c.want)
		}
	}
}
