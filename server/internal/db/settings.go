package db

import (
	"context"
	"encoding/json"
	"time"
)

// GetSetting decodes settings[key] into dst. Returns ErrNotFound if unset.
func (d *DB) GetSetting(ctx context.Context, key string, dst any) error {
	var raw []byte
	if err := d.Pool.QueryRow(ctx, `SELECT value FROM settings WHERE key = $1`, key).Scan(&raw); err != nil {
		return notFound(err)
	}
	return json.Unmarshal(raw, dst)
}

func (d *DB) PutSetting(ctx context.Context, key string, v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = d.Pool.Exec(ctx, `INSERT INTO settings (key, value) VALUES ($1, $2)
		ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`, key, raw)
	return err
}

// ---- audit ----

type AuditEntry struct {
	ID         int64           `json:"id"`
	At         time.Time       `json:"at"`
	ActorID    *string         `json:"actor_id"`
	ActorEmail *string         `json:"actor_email"`
	Action     string          `json:"action"`
	Target     string          `json:"target"`
	Meta       json.RawMessage `json:"meta"`
	IP         string          `json:"ip"`
}

func (d *DB) Audit(ctx context.Context, actorID, action, target string, meta map[string]any, ip string) {
	if meta == nil {
		meta = map[string]any{}
	}
	raw, _ := json.Marshal(meta)
	var actor *string
	if actorID != "" {
		actor = &actorID
	}
	_, _ = d.Pool.Exec(ctx, `INSERT INTO audit_log (actor_id, action, target, meta, ip) VALUES ($1, $2, $3, $4, $5)`,
		actor, action, target, raw, ip)
}

func (d *DB) AuditLog(ctx context.Context, limit, offset int) ([]AuditEntry, int, error) {
	var total int
	if err := d.Pool.QueryRow(ctx, `SELECT count(*) FROM audit_log`).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := d.Pool.Query(ctx, `SELECT a.id, a.at, a.actor_id, u.email, a.action, a.target, a.meta, a.ip
		FROM audit_log a LEFT JOIN users u ON u.id = a.actor_id ORDER BY a.at DESC LIMIT $1 OFFSET $2`, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		if err := rows.Scan(&e.ID, &e.At, &e.ActorID, &e.ActorEmail, &e.Action, &e.Target, &e.Meta, &e.IP); err != nil {
			return nil, 0, err
		}
		out = append(out, e)
	}
	return out, total, rows.Err()
}

// ---- dashboard stats ----

type DayCount struct {
	Day   string `json:"day"`
	Count int    `json:"count"`
}

type Stats struct {
	Users        int            `json:"users"`
	New7d        int            `json:"new_7d"`
	Active7d     int            `json:"active_7d"`
	Disabled     int            `json:"disabled"`
	Vaults       int            `json:"vaults"`
	Items        int            `json:"items"`
	Devices      int            `json:"devices"`
	ByPlan       map[string]int `json:"by_plan"`
	ByProvider   map[string]int `json:"by_provider"`
	SignupsDaily []DayCount     `json:"signups_daily"`
}

func (d *DB) Stats(ctx context.Context) (*Stats, error) {
	s := &Stats{ByPlan: map[string]int{}, ByProvider: map[string]int{}}
	err := d.Pool.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM users),
		(SELECT count(*) FROM users WHERE created_at > now() - interval '7 days'),
		(SELECT count(*) FROM users WHERE last_seen_at > now() - interval '7 days'),
		(SELECT count(*) FROM users WHERE disabled),
		(SELECT count(*) FROM vaults),
		(SELECT count(*) FROM vault_items WHERE NOT deleted),
		(SELECT count(*) FROM sessions WHERE kind = 'app' AND revoked_at IS NULL AND expires_at > now())`).
		Scan(&s.Users, &s.New7d, &s.Active7d, &s.Disabled, &s.Vaults, &s.Items, &s.Devices)
	if err != nil {
		return nil, err
	}
	var withPw int
	_ = d.Pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE password_hash IS NOT NULL`).Scan(&withPw)
	s.ByProvider["password"] = withPw

	rows, err := d.Pool.Query(ctx, `SELECT plan_id, count(*) FROM users GROUP BY plan_id`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var k string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, err
		}
		s.ByPlan[k] = n
	}
	rows.Close()

	rows, err = d.Pool.Query(ctx, `SELECT provider, count(DISTINCT user_id) FROM identities GROUP BY provider`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var k string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, err
		}
		s.ByProvider[k] = n
	}
	rows.Close()

	rows, err = d.Pool.Query(ctx, `SELECT to_char(day, 'YYYY-MM-DD'), count(u.id)
		FROM generate_series(current_date - 29, current_date, interval '1 day') AS day
		LEFT JOIN users u ON u.created_at >= day AND u.created_at < day + interval '1 day'
		GROUP BY day ORDER BY day`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var dc DayCount
		if err := rows.Scan(&dc.Day, &dc.Count); err != nil {
			return nil, err
		}
		s.SignupsDaily = append(s.SignupsDaily, dc)
	}
	return s, rows.Err()
}
