package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"slices"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Provider describes an OpenID Connect issuer whose ID tokens we accept.
type Provider struct {
	Name    string // "google" | "apple"
	JWKSURL string
	Issuers []string
}

var (
	Google = Provider{
		Name:    "google",
		JWKSURL: "https://www.googleapis.com/oauth2/v3/certs",
		Issuers: []string{"https://accounts.google.com", "accounts.google.com"},
	}
	Apple = Provider{
		Name:    "apple",
		JWKSURL: "https://appleid.apple.com/auth/keys",
		Issuers: []string{"https://appleid.apple.com"},
	}
)

// IDClaims are the fields we use from Google / Apple ID tokens.
type IDClaims struct {
	Subject       string
	Email         string
	EmailVerified bool
	Name          string
}

// Verifier checks ID-token signatures against cached JWKS.
type Verifier struct {
	Client *http.Client

	mu   sync.Mutex
	keys map[string]*jwksCache // by JWKS URL
}

type jwksCache struct {
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

func NewVerifier() *Verifier {
	return &Verifier{Client: &http.Client{Timeout: 10 * time.Second}, keys: map[string]*jwksCache{}}
}

var ErrInvalidIDToken = errors.New("invalid id token")

// Verify validates signature, issuer, audience and expiry of an ID token.
func (v *Verifier) Verify(ctx context.Context, p Provider, token string, audiences []string) (*IDClaims, error) {
	if len(audiences) == 0 {
		return nil, fmt.Errorf("%s sign-in is not configured", p.Name)
	}
	claims := jwt.MapClaims{}
	_, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		return v.key(ctx, p.JWKSURL, kid)
	}, jwt.WithValidMethods([]string{"RS256"}), jwt.WithExpirationRequired(), jwt.WithLeeway(time.Minute))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidIDToken, err)
	}
	iss, _ := claims.GetIssuer()
	if !slices.Contains(p.Issuers, iss) {
		return nil, fmt.Errorf("%w: issuer %q", ErrInvalidIDToken, iss)
	}
	aud, _ := claims.GetAudience()
	if !slices.ContainsFunc(aud, func(a string) bool { return slices.Contains(audiences, a) }) {
		return nil, fmt.Errorf("%w: audience %v", ErrInvalidIDToken, aud)
	}
	out := &IDClaims{}
	out.Subject, _ = claims.GetSubject()
	out.Email, _ = claims["email"].(string)
	out.Name, _ = claims["name"].(string)
	switch ev := claims["email_verified"].(type) { // Apple sends "true" as a string
	case bool:
		out.EmailVerified = ev
	case string:
		out.EmailVerified = ev == "true"
	}
	if out.Subject == "" {
		return nil, fmt.Errorf("%w: no subject", ErrInvalidIDToken)
	}
	return out, nil
}

func (v *Verifier) key(ctx context.Context, url, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	c := v.keys[url]
	v.mu.Unlock()
	if c != nil && time.Since(c.fetched) < time.Hour {
		if k := c.keys[kid]; k != nil {
			return k, nil
		}
	}
	// Unknown kid or stale cache: refetch (keys rotate), at most every 10s.
	if c != nil && time.Since(c.fetched) < 10*time.Second {
		return nil, fmt.Errorf("unknown key id %q", kid)
	}
	fresh, err := v.fetch(ctx, url)
	if err != nil {
		if c != nil && c.keys[kid] != nil {
			return c.keys[kid], nil
		}
		return nil, err
	}
	v.mu.Lock()
	v.keys[url] = fresh
	v.mu.Unlock()
	if k := fresh.keys[kid]; k != nil {
		return k, nil
	}
	return nil, fmt.Errorf("unknown key id %q", kid)
}

func (v *Verifier) fetch(ctx context.Context, url string) (*jwksCache, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := v.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch jwks: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch jwks: %s", resp.Status)
	}
	var doc struct {
		Keys []struct {
			Kid string `json:"kid"`
			Kty string `json:"kty"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return nil, fmt.Errorf("decode jwks: %w", err)
	}
	c := &jwksCache{keys: map[string]*rsa.PublicKey{}, fetched: time.Now()}
	for _, k := range doc.Keys {
		if k.Kty != "RSA" {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil {
			continue
		}
		c.keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	return c, nil
}
