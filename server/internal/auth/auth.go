// Package auth has the crypto primitives for sign-in: password hashing,
// access tokens, refresh tokens and email codes.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/argon2"
)

// ---- passwords (argon2id, PHC string format) ----

const (
	argonTime    = 3
	argonMemory  = 64 * 1024
	argonThreads = 2
	argonKeyLen  = 32
)

func HashPassword(pw string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(pw), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, argonMemory, argonTime, argonThreads,
		b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

func VerifyPassword(hash, pw string) bool {
	parts := strings.Split(hash, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false
	}
	var m, t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false
	}
	b64 := base64.RawStdEncoding
	salt, err1 := b64.DecodeString(parts[4])
	want, err2 := b64.DecodeString(parts[5])
	if err1 != nil || err2 != nil {
		return false
	}
	got := argon2.IDKey([]byte(pw), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// dummyHash lets callers spend the same time when a user doesn't exist.
var dummyHash, _ = HashPassword("not-a-real-password")

func BurnPasswordTime(pw string) { VerifyPassword(dummyHash, pw) }

// ValidatePassword enforces a minimal policy; returns a user-facing reason.
func ValidatePassword(pw string) error {
	if len([]rune(pw)) < 8 {
		return errors.New("password must be at least 8 characters")
	}
	if len(pw) > 256 {
		return errors.New("password is too long")
	}
	return nil
}

// ---- access tokens (short-lived JWT) ----

const AccessTTL = 15 * time.Minute

type Claims struct {
	SessionID string `json:"sid"`
	Role      string `json:"role"`
	jwt.RegisteredClaims
}

type Tokens struct {
	secret []byte
}

func NewTokens(secret []byte) *Tokens { return &Tokens{secret: secret} }

func (t *Tokens) Issue(userID, sessionID, role string) (string, time.Time, error) {
	exp := time.Now().Add(AccessTTL)
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, Claims{
		SessionID: sessionID,
		Role:      role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			Issuer:    "mytermi",
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	})
	s, err := tok.SignedString(t.secret)
	return s, exp, err
}

func (t *Tokens) Parse(s string) (*Claims, error) {
	var c Claims
	_, err := jwt.ParseWithClaims(s, &c, func(*jwt.Token) (any, error) { return t.secret, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer("mytermi"), jwt.WithExpirationRequired())
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// ---- opaque tokens (refresh / console session) ----

// NewOpaqueToken returns a random token and the hash to store.
func NewOpaqueToken() (token string, hash []byte) {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	token = base64.RawURLEncoding.EncodeToString(b)
	return token, HashToken(token)
}

func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// ---- email codes ----

const (
	CodeTTL         = 10 * time.Minute
	CodeMaxAttempts = 5
)

func NewCode() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	return fmt.Sprintf("%06d", n.Int64())
}

// HashCode binds the code to the address with a server secret.
func HashCode(secret []byte, email, code string) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(email + "\x00" + strings.TrimSpace(code)))
	return m.Sum(nil)
}

func RandomSecret() []byte {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return b
}
