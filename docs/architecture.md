# Architecture

```
┌──────────────── iPhone / Android ────────────────┐        ┌──────────── mytermi (one Go binary) ────────────┐
│ Flutter app                                       │        │                                                  │
│  HostStore / CommandStore  ← local source of truth│        │  /api/v1/*      JSON API (app + console)         │
│  SessionManager → SSH (dartssh2) ─────────────────┼──SSH──▶│  /console/*     admin console (Next.js export,   │──▶ your servers
│  AccountService  → tokens in Keychain/Keystore    │        │                 embedded with go:embed)          │
│  SyncService     → encrypt / decrypt locally ─────┼─HTTPS─▶│                                                  │
└───────────────────────────────────────────────────┘        └────────────────────────┬─────────────────────────┘
                                                                                       │
                                                                                 PostgreSQL
```

The SSH connection goes straight from the phone to your servers. The MyTermi server only handles
accounts and stores encrypted sync data.

## Repository

| Path | Contents |
|------|----------|
| `app/` | Flutter app. `lib/services/` holds the stores, SSH sessions, `account_service.dart`, `sync_service.dart` and `vault_crypto.dart` |
| `server/cmd/mytermi` | Entry point: `serve`, `migrate`, `admin create` |
| `server/internal/api` | HTTP handlers: sign-in, account, vault/sync, admin |
| `server/internal/auth` | Password hashing (argon2id), JWT access tokens, refresh tokens, email codes, Google/Apple ID-token verification |
| `server/internal/db` | Postgres queries and embedded SQL migrations |
| `server/internal/mail` | SMTP sender (dev mode logs emails instead) |
| `server/internal/console` | Serves the embedded console |
| `server/console` | Next.js 16 + Tailwind 4 source for the console |

## Accounts are optional

The app works fully offline, without an account, just as before. Signing in only adds sync. Signing
out stops sync and keeps all local data.

## Sign-in

| Method | Flow |
|--------|------|
| Email code | `POST /auth/email/start` emails a 6-digit code. `POST /auth/email/verify` creates the account on first use, otherwise signs in. This is also the "forgot password" path. |
| Email + password | Optional. The user sets a password after signing in (`POST /me/password`), then `POST /auth/password` works. |
| Apple / Google | The app gets an ID token from the OS / Google SDK and posts it. The server verifies it against Apple/Google JWKS with the configured audiences. A verified email that matches an existing account links to that account. |

Each sign-in creates a session (one per device, keyed by a device id kept in the Keychain, so
reinstalling the app doesn't use up an extra device slot). The app receives:

- A short-lived **access token**: JWT HS256, 15 minutes.
- An opaque **refresh token**: valid for 60 days, rotated on every refresh, stored hashed in the database.

Logout and revoke take effect immediately, because each request also checks that the session is
still live.

The console uses the same accounts (`role = admin`) with an HttpOnly, SameSite=Strict cookie
session that lasts 12 hours and slides with use.

## Plans

`plans` define limits: `max_devices` (0 means unlimited) and `sync_enabled`. New users get the
default plan. Admins change a user's plan in the console. There are no payments yet; see
[apple-review.md](apple-review.md) before selling plans on iOS.

## Sync

See [encryption.md](encryption.md) for the crypto. The protocol:

1. Each synced entity (host, key, snippet) becomes an **item** `{id, type, rev, modified_at,
   deleted, data}`. The `id` is a UUID derived from the entity type and its local id, and `data` is
   ciphertext.
2. The server keeps a per-user revision counter. `GET /sync?since=N` returns items with a revision
   greater than N, in pages of 500.
3. The app notices local edits through store listeners and marks the items dirty with a timestamp.
   `POST /sync` pushes them.
4. **Conflicts are resolved last-writer-wins on `modified_at`.** If the server copy is newer, it is
   returned under `conflicts` and the app applies it.
5. Deletions are tombstones (`deleted: true`, no data).
6. A vault **generation** changes whenever the vault is reset. Devices holding an old generation get
   `409 vault_generation` and must unlock again.

Sync runs on app start, on resume, 2 seconds after a local change, every 5 minutes while the app is
open, and on "Đồng bộ ngay".

It does not sync: command history, trusted host keys, or app settings. These stay per device.

## Operational notes

- **Single instance.** Rate limits are kept in memory, so with several replicas each instance
  counts separately. Put a shared limiter in front if you scale out.
- **Housekeeping.** Expired sessions and email codes are pruned every 6 hours.
- **Audit log.** Sign-ups, password changes, vault events and every admin action go to `audit_log`.
