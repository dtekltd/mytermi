package db

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

type Session struct {
	ID         string     `json:"id"`
	UserID     string     `json:"-"`
	Kind       string     `json:"kind"`
	AuthMethod string     `json:"auth_method"`
	DeviceID   string     `json:"-"`
	DeviceName string     `json:"device_name"`
	Platform   string     `json:"platform"`
	IP         string     `json:"ip"`
	UserAgent  string     `json:"-"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt time.Time  `json:"last_used_at"`
	ExpiresAt  time.Time  `json:"expires_at"`
	RevokedAt  *time.Time `json:"-"`
}

const sessionCols = `id, user_id, kind, auth_method, device_id, device_name, platform, ip, user_agent, created_at, last_used_at, expires_at, revoked_at`

func scanSession(row pgx.Row) (*Session, error) {
	var s Session
	if err := row.Scan(&s.ID, &s.UserID, &s.Kind, &s.AuthMethod, &s.DeviceID, &s.DeviceName, &s.Platform, &s.IP, &s.UserAgent,
		&s.CreatedAt, &s.LastUsedAt, &s.ExpiresAt, &s.RevokedAt); err != nil {
		return nil, notFound(err)
	}
	return &s, nil
}

// CreateSession adds a session. An earlier live session from the same device
// (same device_id, e.g. after reinstalling the app) is revoked first.
func (d *DB) CreateSession(ctx context.Context, s Session, tokenHash []byte) (*Session, error) {
	if s.DeviceID != "" {
		if _, err := d.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now()
			WHERE user_id = $1 AND kind = $2 AND device_id = $3 AND revoked_at IS NULL`, s.UserID, s.Kind, s.DeviceID); err != nil {
			return nil, err
		}
	}
	return scanSession(d.Pool.QueryRow(ctx, `
		INSERT INTO sessions (user_id, kind, token_hash, auth_method, device_id, device_name, platform, ip, user_agent, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING `+sessionCols,
		s.UserID, s.Kind, tokenHash, s.AuthMethod, s.DeviceID, s.DeviceName, s.Platform, s.IP, s.UserAgent, s.ExpiresAt))
}

// CountActiveDevices counts live app sessions, ignoring [exceptDevice].
func (d *DB) CountActiveDevices(ctx context.Context, userID, exceptDevice string) (int, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `SELECT count(*) FROM sessions WHERE user_id = $1 AND kind = 'app'
		AND revoked_at IS NULL AND expires_at > now() AND ($2 = '' OR device_id <> $2)`, userID, exceptDevice).Scan(&n)
	return n, err
}

// SessionByToken returns an active (not revoked, not expired) session.
func (d *DB) SessionByToken(ctx context.Context, tokenHash []byte) (*Session, error) {
	return scanSession(d.Pool.QueryRow(ctx, `SELECT `+sessionCols+` FROM sessions
		WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()`, tokenHash))
}

func (d *DB) SessionByID(ctx context.Context, id string) (*Session, error) {
	return scanSession(d.Pool.QueryRow(ctx, `SELECT `+sessionCols+` FROM sessions
		WHERE id = $1 AND revoked_at IS NULL AND expires_at > now()`, id))
}

// RotateSession swaps the refresh token (refresh-token rotation) and extends expiry.
func (d *DB) RotateSession(ctx context.Context, id string, newHash []byte, expires time.Time, ip string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE sessions SET token_hash = $2, expires_at = $3, last_used_at = now(), ip = $4
		WHERE id = $1`, id, newHash, expires, ip)
	return err
}

func (d *DB) TouchSession(ctx context.Context, id string, expires time.Time) {
	_, _ = d.Pool.Exec(ctx, `UPDATE sessions SET last_used_at = now(), expires_at = $2 WHERE id = $1`, id, expires)
}

func (d *DB) RevokeSession(ctx context.Context, userID, id string) error {
	tag, err := d.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now()
		WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`, id, userID)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

func (d *DB) RevokeAllSessions(ctx context.Context, userID string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, userID)
	return err
}

// ActiveSessions lists a user's live sessions, newest use first. kind "" = all.
func (d *DB) ActiveSessions(ctx context.Context, userID, kind string) ([]Session, error) {
	rows, err := d.Pool.Query(ctx, `SELECT `+sessionCols+` FROM sessions
		WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now() AND ($2 = '' OR kind = $2)
		ORDER BY last_used_at DESC`, userID, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

// PruneSessions deletes long-dead sessions and used/expired email codes.
func (d *DB) Prune(ctx context.Context) error {
	_, err := d.Pool.Exec(ctx, `DELETE FROM sessions WHERE expires_at < now() - interval '30 days'
		OR revoked_at < now() - interval '30 days'`)
	if err != nil {
		return err
	}
	_, err = d.Pool.Exec(ctx, `DELETE FROM email_codes WHERE created_at < now() - interval '1 day'`)
	return err
}

// ---- email codes ----

type EmailCode struct {
	ID        int64
	CodeHash  []byte
	Attempts  int
	ExpiresAt time.Time
}

func (d *DB) CreateEmailCode(ctx context.Context, email string, hash []byte, expires time.Time, ip string) error {
	// A new code invalidates older ones for the same address.
	return pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE email_codes SET consumed_at = now()
			WHERE email = $1 AND consumed_at IS NULL`, email); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO email_codes (email, code_hash, expires_at, ip) VALUES ($1, $2, $3, $4)`,
			email, hash, expires, ip)
		return err
	})
}

// LatestEmailCode returns the live code for an address.
func (d *DB) LatestEmailCode(ctx context.Context, email string) (*EmailCode, error) {
	var c EmailCode
	err := d.Pool.QueryRow(ctx, `SELECT id, code_hash, attempts, expires_at FROM email_codes
		WHERE email = $1 AND consumed_at IS NULL AND expires_at > now()
		ORDER BY created_at DESC LIMIT 1`, email).Scan(&c.ID, &c.CodeHash, &c.Attempts, &c.ExpiresAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &c, nil
}

func (d *DB) BumpCodeAttempts(ctx context.Context, id int64, consume bool) error {
	_, err := d.Pool.Exec(ctx, `UPDATE email_codes SET attempts = attempts + 1,
		consumed_at = CASE WHEN $2 THEN now() ELSE consumed_at END WHERE id = $1`, id, consume)
	return err
}

func (d *DB) ConsumeCode(ctx context.Context, id int64) (bool, error) {
	tag, err := d.Pool.Exec(ctx, `UPDATE email_codes SET consumed_at = now() WHERE id = $1 AND consumed_at IS NULL`, id)
	return tag.RowsAffected() == 1, err
}

// CodesSentSince counts codes sent to an address (rate limiting).
func (d *DB) CodesSentSince(ctx context.Context, email string, since time.Time) (int, time.Time, error) {
	var n int
	var last *time.Time
	err := d.Pool.QueryRow(ctx, `SELECT count(*), max(created_at) FROM email_codes WHERE email = $1 AND created_at > $2`,
		email, since).Scan(&n, &last)
	if last == nil {
		return n, time.Time{}, err
	}
	return n, *last, err
}
