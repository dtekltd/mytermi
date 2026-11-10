// Command mytermi is the MyTermi sync server: API + embedded admin console.
//
//	mytermi serve                                  run the server (default)
//	mytermi migrate                                apply database migrations and exit
//	mytermi admin create --email E --password P    create or promote an admin
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dtekltd/mytermi/server/internal/api"
	"github.com/dtekltd/mytermi/server/internal/auth"
	"github.com/dtekltd/mytermi/server/internal/config"
	"github.com/dtekltd/mytermi/server/internal/console"
	"github.com/dtekltd/mytermi/server/internal/db"
)

var version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
	cmd := "serve"
	args := os.Args[1:]
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve()
	case "migrate":
		err = withDB(func(ctx context.Context, d *db.DB, _ config.Config) error { return nil })
	case "admin":
		err = adminCmd(args)
	case "version", "--version":
		fmt.Println(version)
	case "help", "-h", "--help":
		fmt.Println("usage: mytermi [serve | migrate | admin create --email E --password P | version]")
	default:
		err = fmt.Errorf("unknown command %q (try: mytermi help)", cmd)
	}
	if err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}
}

// withDB opens the database and applies migrations before running fn.
func withDB(fn func(context.Context, *db.DB, config.Config) error) error {
	cfg, err := config.FromEnv()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	d, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer d.Close()
	applied, err := d.Migrate(ctx)
	for _, m := range applied {
		slog.Info("applied migration", "name", m)
	}
	if err != nil {
		return err
	}
	return fn(ctx, d, cfg)
}

func serve() error {
	return withDB(func(ctx context.Context, d *db.DB, cfg config.Config) error {
		if cfg.AdminEmail != "" && cfg.AdminPassword != "" {
			if err := ensureAdmin(ctx, d, cfg.AdminEmail, cfg.AdminPassword, false); err != nil {
				return fmt.Errorf("bootstrap admin: %w", err)
			}
		}
		srv, err := api.New(ctx, cfg, d)
		if err != nil {
			return err
		}
		mux := http.NewServeMux()
		mux.Handle("/api/", srv.Routes())
		mux.Handle("/console/", console.Handler())
		mux.HandleFunc("/{$}", func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "/console/", http.StatusFound)
		})
		hs := &http.Server{
			Addr:              cfg.Addr,
			Handler:           securityHeaders(api.LogRequests(mux)),
			ReadHeaderTimeout: 10 * time.Second,
			ReadTimeout:       30 * time.Second,
			WriteTimeout:      60 * time.Second,
			IdleTimeout:       120 * time.Second,
		}
		go func() {
			for {
				if err := d.Prune(context.Background()); err != nil {
					slog.Warn("prune", "err", err)
				}
				select {
				case <-ctx.Done():
					return
				case <-time.After(6 * time.Hour):
				}
			}
		}()
		go func() {
			<-ctx.Done()
			shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = hs.Shutdown(shut)
		}()
		slog.Info("mytermi server listening", "addr", cfg.Addr, "version", version, "dev", cfg.Dev)
		if err := hs.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func adminCmd(args []string) error {
	if len(args) == 0 || args[0] != "create" {
		return errors.New("usage: mytermi admin create --email E --password P")
	}
	fs := flag.NewFlagSet("admin create", flag.ContinueOnError)
	email := fs.String("email", "", "admin email")
	password := fs.String("password", "", "admin password (min 8 characters)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *email == "" || *password == "" {
		return errors.New("--email and --password are required")
	}
	return withDB(func(ctx context.Context, d *db.DB, _ config.Config) error {
		if err := ensureAdmin(ctx, d, *email, *password, true); err != nil {
			return err
		}
		slog.Info("admin ready", "email", db.NormalizeEmail(*email))
		return nil
	})
}

// ensureAdmin creates the user if needed and makes them an admin. The password
// is set for new users, users without one, or always when overwrite is true.
func ensureAdmin(ctx context.Context, d *db.DB, email, password string, overwrite bool) error {
	if err := auth.ValidatePassword(password); err != nil {
		return err
	}
	u, err := d.UserByEmail(ctx, email)
	if errors.Is(err, db.ErrNotFound) {
		u, err = d.CreateUser(ctx, email, "Admin", true)
	}
	if err != nil {
		return err
	}
	role := "admin"
	if _, err := d.UpdateUser(ctx, u.ID, db.UserUpdate{Role: &role}); err != nil {
		return err
	}
	if overwrite || !u.HasPassword() {
		hash, err := auth.HashPassword(password)
		if err != nil {
			return err
		}
		return d.SetPassword(ctx, u.ID, hash)
	}
	return nil
}
