# Development

## Server

```sh
docker compose up -d db          # Postgres on 127.0.0.1:5432 (databases mytermi + mytermi_test)
cd server
make run                         # API + console on :8080, dev mode (email codes printed to the log)
```

**Console with hot reload:** run `cd server/console && npm run dev`, then open
http://localhost:3000/console. API calls are proxied to `MYTERMI_API` (default
`http://127.0.0.1:8080`).

**First admin:**

```sh
MYTERMI_DATABASE_URL=... ./bin/mytermi admin create --email a@b.c --password ...
```

Or set `MYTERMI_ADMIN_EMAIL` / `MYTERMI_ADMIN_PASSWORD` before `make run`.

**Tests** run against real Postgres; the target database is wiped:

```sh
make test   # uses postgres://postgres:mytermi@127.0.0.1:5432/mytermi_test
```

## App

```sh
./run                 # from the repo root; dev build on the default platform (iOS on macOS)
```

- The dev build talks to `http://localhost:8080` by default. That works from the iOS Simulator; on
  the Android emulator use `http://10.0.2.2:8080`. You can change the server in the login screen,
  or set `MYTERMI_API_URL`.
- On a real phone, use your computer's LAN IP, e.g. `http://192.168.1.10:8080`.

**Tests:**

```sh
cd app
flutter test                                      # unit + widget tests
SCREENSHOTS=1 flutter test test/screenshot_test.dart --update-goldens   # renders test/shots/*.png
```

**Live tests** are skipped unless configured:

- `SSH_TEST_DIR=<dir>` runs SSH tests against a local sshd on port 2222; see `test/ssh_live_test.dart`.
- `SYNC_TEST_SERVER=http://127.0.0.1:8080 SYNC_TEST_LOG=<server log file>` runs an end-to-end
  two-device sync test. It needs a dev-mode server whose log is written to that file.
