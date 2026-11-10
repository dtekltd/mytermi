// Package config reads server settings from environment variables.
// Everything an admin may change at runtime (SMTP, sign-in providers...) lives
// in the database instead and is edited from the console.
package config

import (
	"errors"
	"os"
	"strings"
)

type Config struct {
	DatabaseURL string // MYTERMI_DATABASE_URL (required)
	Addr        string // MYTERMI_ADDR, default ":8080"
	PublicURL   string // MYTERMI_PUBLIC_URL, e.g. https://sync.example.com (used in emails)
	JWTSecret   string // MYTERMI_JWT_SECRET; generated and stored in the DB if empty
	TrustProxy  bool   // MYTERMI_TRUST_PROXY: take the client IP from X-Forwarded-For
	Dev         bool   // MYTERMI_DEV: log emails instead of failing when SMTP isn't set up

	// Bootstrap admin, created/promoted at startup if both are set.
	AdminEmail    string // MYTERMI_ADMIN_EMAIL
	AdminPassword string // MYTERMI_ADMIN_PASSWORD
}

func FromEnv() (Config, error) {
	c := Config{
		DatabaseURL:   os.Getenv("MYTERMI_DATABASE_URL"),
		Addr:          env("MYTERMI_ADDR", ":8080"),
		PublicURL:     strings.TrimRight(os.Getenv("MYTERMI_PUBLIC_URL"), "/"),
		JWTSecret:     os.Getenv("MYTERMI_JWT_SECRET"),
		TrustProxy:    truthy(os.Getenv("MYTERMI_TRUST_PROXY")),
		Dev:           truthy(os.Getenv("MYTERMI_DEV")),
		AdminEmail:    os.Getenv("MYTERMI_ADMIN_EMAIL"),
		AdminPassword: os.Getenv("MYTERMI_ADMIN_PASSWORD"),
	}
	if c.DatabaseURL == "" {
		return c, errors.New("MYTERMI_DATABASE_URL is required (e.g. postgres://user:pass@localhost:5432/mytermi)")
	}
	return c, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func truthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}
