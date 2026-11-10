# MyTermi

Termius-style SSH client for iOS / Android, with optional accounts and end-to-end encrypted sync.

| Folder    | What                                                                       |
|-----------|----------------------------------------------------------------------------|
| `app/`    | Flutter app (iOS / Android). See [app/README.md](app/README.md).           |
| `server/` | Go backend API + admin console (Next.js, embedded in the server binary).   |
| `docs/`   | Architecture, API, encryption model, deployment, App Store review notes.   |

Run the app from the repo root with `./run [dev|prod|build] [ios|android]` (same as `app/run`).
