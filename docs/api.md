# API reference (`/api/v1`)

- **Format.** JSON in and out; send `Content-Type: application/json` with every request body.
  `[]byte` fields such as `data`, `salt` and `wrapped_key` are base64.
- **Errors.** `{"error": {"code": "...", "message": "...", "details": {...}}}`. Clients switch on
  `code`; `message` is an English hint.
- **App auth.** `Authorization: Bearer <access_token>`. When a call returns `401 token_expired`,
  call `POST /auth/refresh` and retry.
- **Console auth.** An HttpOnly cookie `mytermi_console` set by `POST /admin/login`. A Bearer
  token belonging to an admin also works.

## Public

| Method & path | Body | Response / notes |
|---|---|---|
| `GET /health` | | `{"status":"ok"}` |
| `GET /config` | | `{app_name, signup_enabled, support_email, providers: {email, google, apple}}` |
| `POST /auth/email/start` | `{email}` | `{sent, expires_in, resend_after}`. One code per minute and 6 per hour per address; 20 per hour per IP. Errors: `invalid_email`, `rate_limited`, `email_not_configured`, `signup_disabled` (new address while sign-ups are off) |
| `POST /auth/email/verify` | `{email, code, device}` | Token response. Creates the account if it's new. A code allows 5 wrong attempts and expires after 10 minutes. Error: `invalid_code` |
| `POST /auth/password` | `{email, password, device}` | Token response. Error: `invalid_credentials` |
| `POST /auth/google` | `{id_token, device}` | Token response. Errors: `provider_not_configured`, `invalid_id_token`, `email_unverified` |
| `POST /auth/apple` | `{identity_token, name?, device}` | Same as Google. `name` matters only on the first sign-in, because Apple sends it once. |
| `POST /auth/refresh` | `{refresh_token}` | New token response (the refresh token rotates). Error: `session_revoked` |

`device` is `{id, name, platform}`. `id` is stable per install; signing in again from the same `id`
replaces that device's old session.

**Token response:**

```json
{
  "access_token": "...",
  "expires_at": "...",
  "refresh_token": "...",
  "is_new_user": false,
  "user": { "...": "see GET /me" }
}
```

**Errors any sign-in can return:** `account_disabled`; `device_limit` with
`details: {max_devices, plan}`; `rate_limited` with `details: {retry_after}`.

## Account (Bearer)

| Method & path | Body | Notes |
|---|---|---|
| `GET /me` | | `{id, email, email_verified, name, role, has_password, providers[], plan: {id, name, max_devices, sync_enabled}, has_vault, created_at}` |
| `PATCH /me` | `{name}` | |
| `POST /me/password` | `{new_password, current_password?}` | `current_password` is required to change an existing password. It is not required if this session signed in with an email code less than 15 minutes ago (forgot-password flow). Errors: `weak_password` (fewer than 8 characters), `invalid_credentials` |
| `DELETE /me` | `{confirm: "<account email>"}` | Deletes the account and all data. Error: `last_admin` |
| `GET /me/sessions` | | `{sessions: [{id, device_name, platform, ip, auth_method, created_at, last_used_at, current}]}` |
| `DELETE /me/sessions/{id}` | | Signs that device out |
| `POST /auth/logout` | | Revokes the current session |

## Vault & sync (Bearer, plan must have `sync_enabled`)

| Method & path | Body | Notes |
|---|---|---|
| `GET /vault` | | Vault envelope `{generation, rev, kdf, salt, wrapped_key, recovery_wrapped_key, created_at, updated_at}`. Error: `404 vault_not_found` |
| `POST /vault` | `{kdf, salt, wrapped_key, recovery_wrapped_key}` | Creates the vault. Error: `409 vault_exists` |
| `PUT /vault` | `{generation, kdf, salt, wrapped_key, recovery_wrapped_key}` | Re-wrap (vault password change or recovery). Error: `409 vault_generation` |
| `DELETE /vault` | `{confirm: "RESET"}` | Wipes the vault and all items |
| `GET /sync?since=<rev>&generation=<g>` | | `{generation, rev, items[], more}`. Items are `{id, type, rev, modified_at, deleted, data?}`, oldest first, 500 per page. While `more` is true, call again with `since=rev`. |
| `POST /sync` | `{generation, items: [{id, type, modified_at, deleted, data?}]}` | `{rev, accepted: [{id, rev}], conflicts: [item]}`. Last-writer-wins on `modified_at`: when the server copy is newer it is returned in `conflicts`. |

**Limits on `POST /sync` items:**

- Up to 500 items per request.
- `id` is a lower-case UUID.
- `type` is one of `host`, `key`, `snippet`, `known_host`, `setting`.
- `data` is 1 byte to 64 KiB.
- A `modified_at` more than 5 minutes in the future is clamped to the server time.

## Admin (console)

| Method & path | Notes |
|---|---|
| `POST /admin/login` `{email, password}` | Sets the cookie; the account must have role `admin` |
| `POST /admin/logout`, `GET /admin/me` | |
| `GET /admin/stats` | Totals, 7-day new and active users, devices, vaults, items, users by plan and by sign-in method, 30-day daily sign-ups |
| `GET /admin/users?q=&plan=&role=&limit=&offset=` | `{users, total}` |
| `GET /admin/users/{id}` | `{user, has_password, identities, sessions, vault: {exists, items, ...}}` |
| `PATCH /admin/users/{id}` `{plan_id?, role?, disabled?, name?}` | Disabling also revokes the user's sessions. Error: `last_admin` |
| `DELETE /admin/users/{id}` | Error: `self_delete` |
| `POST /admin/users/{id}/revoke-sessions` | |
| `GET /admin/plans`, `PUT /admin/plans/{id}`, `DELETE /admin/plans/{id}` | Errors: `plan_default`, `plan_in_use` |
| `GET /admin/settings`, `PUT /admin/settings` | `{general, smtp, google, apple}`. The SMTP password is returned masked; sending the mask back keeps the stored value. |
| `POST /admin/settings/test-email` `{to, smtp?}` | `smtp` is the unsaved console form (masked password = stored one); without it the saved settings are used. Returns `{sent, to}`, or `{sent: false, logged: true}` in dev mode without SMTP. Errors: `email_not_configured`, `email_send_failed` |
| `GET /admin/audit?limit=&offset=` | |
