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

## Support the project

MyTermi is free and open source. If it's useful to you, you can buy me a coffee:

[![Donate 5 USD](https://img.shields.io/badge/PayPal-5%20USD-0070ba?logo=paypal)](https://paypal.me/phthosting/5USD)
[![Donate 10 USD](https://img.shields.io/badge/PayPal-10%20USD-0070ba?logo=paypal)](https://paypal.me/phthosting/10USD)
[![Donate 20 USD](https://img.shields.io/badge/PayPal-20%20USD-0070ba?logo=paypal)](https://paypal.me/phthosting/20USD)

## License

[Apache License 2.0](LICENSE). Copyright 2026 Tuan Phan.
