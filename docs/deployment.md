# Deploying the server

The server is a single binary: API plus admin console. Its only dependency is PostgreSQL 14 or
later.

## Docker Compose (quickest)

```sh
git clone https://github.com/dtekltd/mytermi && cd mytermi
cat > .env <<'EOF'
POSTGRES_PASSWORD=<strong password>
MYTERMI_PUBLIC_URL=https://sync.example.com
MYTERMI_ADMIN_EMAIL=you@example.com
MYTERMI_ADMIN_PASSWORD=<strong password>
MYTERMI_DEV=0
MYTERMI_BIND=127.0.0.1
MYTERMI_TRUST_PROXY=1
EOF
docker compose up -d --build
```

`MYTERMI_BIND=127.0.0.1` keeps port 8080 private to the machine (Docker publishes ports past
`ufw`), so put a reverse proxy with TLS in front (see below). Then open
`https://<your domain>/console`, sign in as the admin, and configure SMTP (see below).

`MYTERMI_DEV=1`, the compose default, prints email codes to the server log instead of sending
them. Use it only until SMTP works.

## Binary

```sh
cd server && make build                     # needs Node 20+ and Go 1.27+; writes bin/mytermi
export MYTERMI_DATABASE_URL='postgres://mytermi:pass@localhost:5432/mytermi?sslmode=disable'
./bin/mytermi admin create --email you@example.com --password '<strong password>'
./bin/mytermi serve
```

Migrations run automatically at startup. `mytermi migrate` runs them on their own.

## Environment variables

| Variable | Default | |
|---|---|---|
| `MYTERMI_DATABASE_URL` | (required) | Postgres URL |
| `MYTERMI_ADDR` | `:8080` | Listen address |
| `MYTERMI_PUBLIC_URL` | | Public base URL, shown in the console |
| `MYTERMI_JWT_SECRET` | generated | Signing key for access tokens and email codes. If empty, one is generated and stored in the database. |
| `MYTERMI_TRUST_PROXY` | `0` | Set to `1` behind a reverse proxy or Cloudflare Tunnel so client IPs (rate limits, audit log) come from `CF-Connecting-IP` or the last `X-Forwarded-For` entry. Only enable it when clients can't reach the server directly, or they can fake their IP. |
| `MYTERMI_DEV` | `0` | Log emails instead of failing when SMTP isn't configured |
| `MYTERMI_BIND`, `MYTERMI_PORT`, `MYTERMI_DB_PORT` | `0.0.0.0`, `8080`, `5432` | docker-compose only: where the server and Postgres ports are published on the host. Change them if another service already uses 8080 or 5432. |
| `MYTERMI_ADMIN_EMAIL`, `MYTERMI_ADMIN_PASSWORD` | | At startup, create this admin (or promote the account). The password is set only if the account has none. |

Everything else is configured in **Console → Cấu hình**, stored in the database, and applied
without a restart.

## TLS (required for production)

Put the server behind a reverse proxy. Example Caddyfile, with automatic HTTPS:

```
sync.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Then set `MYTERMI_TRUST_PROXY=1`. In the app, set the server under
**Settings → Đăng nhập → Máy chủ**, or build with `MYTERMI_API_URL=https://sync.example.com ./run build`.

## SMTP (email codes)

In **Console → Cấu hình → Email (SMTP)**, fill in host, port, security and From, save, then press
**Gửi thử** (send test). Any provider works (Amazon SES, Mailgun, Postmark, Gmail with an app
password…). Configure SPF and DKIM for the From domain, or codes will land in spam.

## Sign in with Apple

1. Apple Developer → Identifiers → the app ID (bundle id `com.mytermi.mytermi`, or your own): enable
   **Sign in with Apple**. The repo already includes the entitlement (`ios/Runner/Runner.entitlements`).
2. Console → **Sign in with Apple**: turn it on and add the bundle id as an audience.
3. The button appears on iOS only. Signing in with Apple on Android would also need a Services ID
   and a web redirect, which isn't implemented.

## Google Sign-In

1. Google Cloud Console → APIs & Services → Credentials. Create OAuth client IDs:
   - **iOS** (bundle id), **Android** (package `com.mytermi.mytermi` plus the SHA-1 of your signing
     key), and **Web** (used as `serverClientId` on Android).
2. iOS: add the *reversed* iOS client id as a URL scheme in `app/ios/Runner/Info.plist`
   (`CFBundleURLTypes`). See the google_sign_in README.
3. Build the app with the IDs:

   ```sh
   GOOGLE_IOS_CLIENT_ID=xxx.apps.googleusercontent.com \
   GOOGLE_SERVER_CLIENT_ID=yyy.apps.googleusercontent.com ./run build ios
   ```

   The Google button stays hidden on iOS until `GOOGLE_IOS_CLIENT_ID` is set.
4. Console → **Đăng nhập bằng Google**: turn it on and add every client id (iOS, Android, Web). ID
   tokens must have one of them as their audience.

## Backups

Back up the Postgres database regularly (for example with `pg_dump`). Vault data is ciphertext,
but the database also holds account emails, password hashes and sessions; treat dumps as sensitive.
