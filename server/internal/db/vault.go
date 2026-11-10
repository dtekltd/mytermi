package db

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// ErrGeneration means the client's vault generation is stale (the vault was reset).
var ErrGeneration = errors.New("vault generation mismatch")

type Vault struct {
	Generation         int64           `json:"generation"`
	Rev                int64           `json:"rev"`
	KDF                json.RawMessage `json:"kdf"`
	Salt               []byte          `json:"salt"`
	WrappedKey         []byte          `json:"wrapped_key"`
	RecoveryWrappedKey []byte          `json:"recovery_wrapped_key"`
	CreatedAt          time.Time       `json:"created_at"`
	UpdatedAt          time.Time       `json:"updated_at"`
}

func (d *DB) VaultOf(ctx context.Context, userID string) (*Vault, error) {
	var v Vault
	err := d.Pool.QueryRow(ctx, `SELECT generation, rev, kdf, salt, wrapped_key, recovery_wrapped_key, created_at, updated_at
		FROM vaults WHERE user_id = $1`, userID).Scan(&v.Generation, &v.Rev, &v.KDF, &v.Salt, &v.WrappedKey,
		&v.RecoveryWrappedKey, &v.CreatedAt, &v.UpdatedAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &v, nil
}

// ErrVaultExists is returned when creating a vault that already exists.
var ErrVaultExists = errors.New("vault exists")

func (d *DB) CreateVault(ctx context.Context, userID string, v Vault) (*Vault, error) {
	_, err := d.Pool.Exec(ctx, `INSERT INTO vaults (user_id, kdf, salt, wrapped_key, recovery_wrapped_key)
		VALUES ($1, $2, $3, $4, $5)`, userID, v.KDF, v.Salt, v.WrappedKey, v.RecoveryWrappedKey)
	if isUniqueViolation(err) {
		return nil, ErrVaultExists
	}
	if err != nil {
		return nil, err
	}
	return d.VaultOf(ctx, userID)
}

// RewrapVault stores a re-wrapped vault key (password change / recovery). The
// vault key itself, and so every item, stays the same.
func (d *DB) RewrapVault(ctx context.Context, userID string, generation int64, v Vault) (*Vault, error) {
	tag, err := d.Pool.Exec(ctx, `UPDATE vaults SET kdf = $3, salt = $4, wrapped_key = $5,
		recovery_wrapped_key = $6, updated_at = now() WHERE user_id = $1 AND generation = $2`,
		userID, generation, v.KDF, v.Salt, v.WrappedKey, v.RecoveryWrappedKey)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		if _, err := d.VaultOf(ctx, userID); err != nil {
			return nil, err
		}
		return nil, ErrGeneration
	}
	return d.VaultOf(ctx, userID)
}

// DeleteVault wipes the vault and all items (user forgot both the vault
// password and the recovery key). A new vault gets a new generation.
func (d *DB) DeleteVault(ctx context.Context, userID string) error {
	return pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM vaults WHERE user_id = $1`, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		_, err = tx.Exec(ctx, `DELETE FROM vault_items WHERE user_id = $1`, userID)
		return err
	})
}

// ---- items ----

type Item struct {
	ID         string    `json:"id"`
	Type       string    `json:"type"`
	Rev        int64     `json:"rev"`
	ModifiedAt time.Time `json:"modified_at"`
	Deleted    bool      `json:"deleted"`
	Data       []byte    `json:"data,omitempty"` // base64 in JSON
}

// ItemsSince returns items with rev > since (oldest first) and whether more remain.
func (d *DB) ItemsSince(ctx context.Context, userID string, since int64, limit int) ([]Item, bool, error) {
	rows, err := d.Pool.Query(ctx, `SELECT id, type, rev, modified_at, deleted, data FROM vault_items
		WHERE user_id = $1 AND rev > $2 ORDER BY rev LIMIT $3`, userID, since, limit+1)
	if err != nil {
		return nil, false, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Item, error) {
		var it Item
		err := r.Scan(&it.ID, &it.Type, &it.Rev, &it.ModifiedAt, &it.Deleted, &it.Data)
		return it, err
	})
	if err != nil {
		return nil, false, err
	}
	more := len(items) > limit
	if more {
		items = items[:limit]
	}
	return items, more, nil
}

type PushResult struct {
	Rev       int64  `json:"rev"`
	Accepted  []Item `json:"accepted"`  // id + new rev
	Conflicts []Item `json:"conflicts"` // server copy is newer; client should take it
}

// PushItems applies client changes with last-writer-wins on modified_at.
func (d *DB) PushItems(ctx context.Context, userID string, generation int64, items []Item) (*PushResult, error) {
	res := &PushResult{Accepted: []Item{}, Conflicts: []Item{}}
	err := pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		var gen, rev int64
		if err := tx.QueryRow(ctx, `SELECT generation, rev FROM vaults WHERE user_id = $1 FOR UPDATE`, userID).
			Scan(&gen, &rev); err != nil {
			return notFound(err)
		}
		if gen != generation {
			return ErrGeneration
		}
		for _, it := range items {
			var cur Item
			err := tx.QueryRow(ctx, `SELECT id, type, rev, modified_at, deleted, data FROM vault_items
				WHERE user_id = $1 AND id = $2`, userID, it.ID).
				Scan(&cur.ID, &cur.Type, &cur.Rev, &cur.ModifiedAt, &cur.Deleted, &cur.Data)
			switch {
			case err == nil && cur.ModifiedAt.After(it.ModifiedAt):
				res.Conflicts = append(res.Conflicts, cur)
				continue
			case err != nil && !errors.Is(err, pgx.ErrNoRows):
				return err
			}
			rev++
			data := it.Data
			if it.Deleted {
				data = nil
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO vault_items (user_id, id, type, rev, modified_at, deleted, data)
				VALUES ($1, $2, $3, $4, $5, $6, $7)
				ON CONFLICT (user_id, id) DO UPDATE SET type = $3, rev = $4, modified_at = $5, deleted = $6, data = $7`,
				userID, it.ID, it.Type, rev, it.ModifiedAt, it.Deleted, data); err != nil {
				return err
			}
			res.Accepted = append(res.Accepted, Item{ID: it.ID, Type: it.Type, Rev: rev, ModifiedAt: it.ModifiedAt, Deleted: it.Deleted})
		}
		res.Rev = rev
		_, err := tx.Exec(ctx, `UPDATE vaults SET rev = $2, updated_at = now() WHERE user_id = $1`, userID, rev)
		return err
	})
	if err != nil {
		return nil, err
	}
	return res, nil
}
