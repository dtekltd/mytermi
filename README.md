# MyTermi

Termius-style SSH client for iOS, Android and Windows, with optional accounts and end-to-end encrypted sync.

| Folder    | What                                                                       |
|-----------|----------------------------------------------------------------------------|
| `app/`    | Flutter app (iOS / Android / Windows). See [app/README.md](app/README.md). |
| `server/` | Go backend API + admin console (Next.js, embedded in the server binary).   |
| `docs/`   | Architecture, API, encryption model, deployment, App Store review notes.   |

## Quick start

```sh
docker compose up -d --build     # Postgres + server: API and console on http://localhost:8080/console
./run                            # app (dev) on the default platform: iOS on macOS, Android elsewhere
```

Default console login (change it in `.env`): `admin@mytermi.local` / `change-me-now`.

More: [docs/development.md](docs/development.md) · [docs/deployment.md](docs/deployment.md) ·
[docs/encryption.md](docs/encryption.md) · [docs/apple-review.md](docs/apple-review.md)
