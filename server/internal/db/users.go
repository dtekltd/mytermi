package db

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// ErrEmailTaken is returned when creating a user whose email already exists.
var ErrEmailTaken = errors.New("email already registered")

type User struct {
	ID            string     `json:"id"`
	Email         string     `json:"email"`
	EmailVerified bool       `json:"email_verified"`
	PasswordHash  *string    `json:"-"`
	Name          string     `json:"name"`
	Role          string     `json:"role"`
	PlanID        string     `json:"plan_id"`
	PlanExpiresAt *time.Time `json:"plan_expires_at"`
	Disabled      bool       `json:"disabled"`
	CreatedAt     time.Time  `json:"created_at"`
	LastSeenAt    *time.Time `json:"last_seen_at"`
}

func (u *User) HasPassword() bool { return u.PasswordHash != nil && *u.PasswordHash != "" }

const userCols = `id, email, email_verified, password_hash, name, role, plan_id, plan_expires_at, disabled, created_at, last_seen_at`

func scanUser(row pgx.Row) (*User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Email, &u.EmailVerified, &u.PasswordHash, &u.Name, &u.Role, &u.PlanID, &u.PlanExpiresAt,
		&u.Disabled, &u.CreatedAt, &u.LastSeenAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &u, nil
}

func NormalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

func (d *DB) UserByID(ctx context.Context, id string) (*User, error) {
	return scanUser(d.Pool.QueryRow(ctx, `SELECT `+userCols+` FROM users WHERE id = $1`, id))
}

func (d *DB) UserByEmail(ctx context.Context, email string) (*User, error) {
	return scanUser(d.Pool.QueryRow(ctx, `SELECT `+userCols+` FROM users WHERE email = $1`, NormalizeEmail(email)))
}

// CreateUser adds a user on the default plan.
func (d *DB) CreateUser(ctx context.Context, email, name string, verified bool) (*User, error) {
	u, err := scanUser(d.Pool.QueryRow(ctx, `
		INSERT INTO users (email, name, email_verified, plan_id)
		VALUES ($1, $2, $3, COALESCE((SELECT id FROM plans WHERE is_default), 'free'))
		RETURNING `+userCols, NormalizeEmail(email), name, verified))
	if err != nil && isUniqueViolation(err) {
		return nil, ErrEmailTaken
	}
	return u, err
}

func (d *DB) SetPassword(ctx context.Context, userID, hash string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1`, userID, hash)
	return err
}

func (d *DB) MarkEmailVerified(ctx context.Context, userID string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE users SET email_verified = true, updated_at = now() WHERE id = $1`, userID)
	return err
}

func (d *DB) TouchUser(ctx context.Context, userID string) {
	_, _ = d.Pool.Exec(ctx, `UPDATE users SET last_seen_at = now() WHERE id = $1`, userID)
}

func (d *DB) DeleteUser(ctx context.Context, userID string) error {
	tag, err := d.Pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

// PlanExpired reports whether the user's plan has an end date in the past.
func (u *User) PlanExpired(now time.Time) bool {
	return u.PlanExpiresAt != nil && !u.PlanExpiresAt.After(now)
}

// UserUpdate holds optional fields an admin (or the user, for Name) can change.
type UserUpdate struct {
	Name          *string      `json:"name"`
	Role          *string      `json:"role"`
	PlanID        *string      `json:"plan_id"`
	PlanExpiresAt OptionalTime `json:"plan_expires_at"` // null clears the end date
	Disabled      *bool        `json:"disabled"`
}

// OptionalTime tells "field absent" (Set false) apart from "null" (Set, nil).
type OptionalTime struct {
	Set   bool
	Value *time.Time
}

func (o *OptionalTime) UnmarshalJSON(b []byte) error {
	o.Set = true
	if string(b) == "null" {
		o.Value = nil
		return nil
	}
	var t time.Time
	if err := t.UnmarshalJSON(b); err != nil {
		return err
	}
	o.Value = &t
	return nil
}

func (o OptionalTime) MarshalJSON() ([]byte, error) {
	if o.Value == nil {
		return []byte("null"), nil
	}
	return o.Value.MarshalJSON()
}

func (d *DB) UpdateUser(ctx context.Context, id string, up UserUpdate) (*User, error) {
	return scanUser(d.Pool.QueryRow(ctx, `
		UPDATE users SET
			name     = COALESCE($2, name),
			role     = COALESCE($3, role),
			plan_id  = COALESCE($4, plan_id),
			disabled = COALESCE($5, disabled),
			plan_expires_at = CASE WHEN $6 THEN $7 ELSE plan_expires_at END,
			updated_at = now()
		WHERE id = $1 RETURNING `+userCols, id, up.Name, up.Role, up.PlanID, up.Disabled,
		up.PlanExpiresAt.Set, up.PlanExpiresAt.Value))
}

type UserListItem struct {
	User
	Providers []string `json:"providers"`
	HasVault  bool     `json:"has_vault"`
	Items     int      `json:"items"`
}

type UserFilter struct {
	Query  string
	PlanID string
	Role   string
	Limit  int
	Offset int
}

func (d *DB) ListUsers(ctx context.Context, f UserFilter) ([]UserListItem, int, error) {
	where := []string{"true"}
	args := []any{}
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		add("(u.email ILIKE '%%' || $%[1]d || '%%' OR u.name ILIKE '%%' || $%[1]d || '%%')", q)
	}
	if f.PlanID != "" {
		add("u.plan_id = $%d", f.PlanID)
	}
	if f.Role != "" {
		add("u.role = $%d", f.Role)
	}
	cond := strings.Join(where, " AND ")

	var total int
	if err := d.Pool.QueryRow(ctx, `SELECT count(*) FROM users u WHERE `+cond, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	args = append(args, f.Limit, f.Offset)
	rows, err := d.Pool.Query(ctx, fmt.Sprintf(`
		SELECT u.id, u.email, u.email_verified, u.password_hash, u.name, u.role, u.plan_id, u.plan_expires_at, u.disabled,
		       u.created_at, u.last_seen_at,
		       COALESCE((SELECT array_agg(provider ORDER BY provider) FROM identities i WHERE i.user_id = u.id), '{}'),
		       EXISTS (SELECT 1 FROM vaults v WHERE v.user_id = u.id),
		       (SELECT count(*) FROM vault_items vi WHERE vi.user_id = u.id AND NOT vi.deleted)
		FROM users u WHERE %s ORDER BY u.created_at DESC LIMIT $%d OFFSET $%d`, cond, len(args)-1, len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []UserListItem{}
	for rows.Next() {
		var it UserListItem
		u := &it.User
		if err := rows.Scan(&u.ID, &u.Email, &u.EmailVerified, &u.PasswordHash, &u.Name, &u.Role, &u.PlanID, &u.PlanExpiresAt,
			&u.Disabled, &u.CreatedAt, &u.LastSeenAt, &it.Providers, &it.HasVault, &it.Items); err != nil {
			return nil, 0, err
		}
		if u.HasPassword() {
			it.Providers = append([]string{"password"}, it.Providers...)
		}
		out = append(out, it)
	}
	return out, total, rows.Err()
}

// CountAdmins is used to refuse removing the last admin.
func (d *DB) CountAdmins(ctx context.Context) (int, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE role = 'admin' AND NOT disabled`).Scan(&n)
	return n, err
}

// ---- identities ----

type Identity struct {
	Provider  string    `json:"provider"`
	Subject   string    `json:"-"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}

func (d *DB) UserByIdentity(ctx context.Context, provider, subject string) (*User, error) {
	return scanUser(d.Pool.QueryRow(ctx, `SELECT `+prefixed("u", userCols)+`
		FROM identities i JOIN users u ON u.id = i.user_id WHERE i.provider = $1 AND i.subject = $2`, provider, subject))
}

func (d *DB) LinkIdentity(ctx context.Context, userID, provider, subject, email string) error {
	_, err := d.Pool.Exec(ctx, `INSERT INTO identities (provider, subject, user_id, email) VALUES ($1, $2, $3, $4)
		ON CONFLICT (provider, subject) DO NOTHING`, provider, subject, userID, NormalizeEmail(email))
	return err
}

func (d *DB) IdentitiesOf(ctx context.Context, userID string) ([]Identity, error) {
	rows, err := d.Pool.Query(ctx, `SELECT provider, subject, email, created_at FROM identities WHERE user_id = $1 ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Identity, error) {
		var i Identity
		err := r.Scan(&i.Provider, &i.Subject, &i.Email, &i.CreatedAt)
		return i, err
	})
}

func prefixed(alias, cols string) string {
	parts := strings.Split(cols, ", ")
	for i, p := range parts {
		parts[i] = alias + "." + p
	}
	return strings.Join(parts, ", ")
}

// ---- plans ----

type Plan struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	MaxDevices  int       `json:"max_devices"`
	SyncEnabled bool      `json:"sync_enabled"`
	IsDefault   bool      `json:"is_default"`
	SortOrder   int       `json:"sort_order"`
	CreatedAt   time.Time `json:"created_at"`
	Users       int       `json:"users"`
}

const planCols = `id, name, description, max_devices, sync_enabled, is_default, sort_order, created_at,
	(SELECT count(*) FROM users u WHERE u.plan_id = plans.id)`

func scanPlan(row pgx.Row) (*Plan, error) {
	var p Plan
	if err := row.Scan(&p.ID, &p.Name, &p.Description, &p.MaxDevices, &p.SyncEnabled, &p.IsDefault, &p.SortOrder,
		&p.CreatedAt, &p.Users); err != nil {
		return nil, notFound(err)
	}
	return &p, nil
}

func (d *DB) Plans(ctx context.Context) ([]Plan, error) {
	rows, err := d.Pool.Query(ctx, `SELECT `+planCols+` FROM plans ORDER BY sort_order, created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Plan{}
	for rows.Next() {
		p, err := scanPlan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

func (d *DB) PlanByID(ctx context.Context, id string) (*Plan, error) {
	return scanPlan(d.Pool.QueryRow(ctx, `SELECT `+planCols+` FROM plans WHERE id = $1`, id))
}

// EffectivePlan is the plan whose limits apply to u right now: the assigned
// plan, or the default plan once the assigned plan's end date has passed.
func (d *DB) EffectivePlan(ctx context.Context, u *User) (*Plan, error) {
	if u.PlanExpired(time.Now()) {
		p, err := scanPlan(d.Pool.QueryRow(ctx, `SELECT `+planCols+` FROM plans WHERE is_default LIMIT 1`))
		if err == nil || !errors.Is(err, ErrNotFound) {
			return p, err
		}
	}
	return d.PlanByID(ctx, u.PlanID)
}

// SavePlan creates or updates a plan; making it default clears the old default.
func (d *DB) SavePlan(ctx context.Context, p Plan) (*Plan, error) {
	err := pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		if p.IsDefault {
			if _, err := tx.Exec(ctx, `UPDATE plans SET is_default = false WHERE is_default AND id <> $1`, p.ID); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO plans (id, name, description, max_devices, sync_enabled, is_default, sort_order)
			VALUES ($1, $2, $3, $4, $5, $6, $7)
			ON CONFLICT (id) DO UPDATE SET name = $2, description = $3, max_devices = $4, sync_enabled = $5,
				is_default = $6, sort_order = $7`,
			p.ID, p.Name, p.Description, p.MaxDevices, p.SyncEnabled, p.IsDefault, p.SortOrder)
		return err
	})
	if err != nil {
		return nil, err
	}
	return d.PlanByID(ctx, p.ID)
}

// ErrPlanInUse / ErrPlanDefault guard plan deletion.
var (
	ErrPlanInUse   = errors.New("plan has users")
	ErrPlanDefault = errors.New("default plan")
)

func (d *DB) DeletePlan(ctx context.Context, id string) error {
	p, err := d.PlanByID(ctx, id)
	if err != nil {
		return err
	}
	if p.IsDefault {
		return ErrPlanDefault
	}
	if p.Users > 0 {
		return ErrPlanInUse
	}
	_, err = d.Pool.Exec(ctx, `DELETE FROM plans WHERE id = $1`, id)
	return err
}
