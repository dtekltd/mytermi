# MyTermi

SSH client for iOS / Android built with Flutter (dartssh2 + xterm), styled after Termius.

## Flutter version

The project is pinned to Flutter **3.47.9** in `.fvmrc`. If [FVM](https://fvm.app) is installed, `run` uses that version automatically (installing it on first run) without touching your global Flutter. Without FVM, `run` uses the `flutter` on your PATH.

For the IDE / manual commands, run `fvm use` once in the project (creates `.fvm/flutter_sdk`) and use `fvm flutter ...`.

## Run / build

```sh
./run [dev|prod|build] [ios|android] [extra flutter args...]   # macOS / Linux
run   [dev|prod|build] [android]     [extra flutter args...]   # Windows (run.cmd)
```

| Mode    | What it does                                             |
|---------|----------------------------------------------------------|
| `dev`   | Debug build with hot reload (default), `APP_ENV=dev`      |
| `prod`  | Release build run on a device, `APP_ENV=prod`             |
| `build` | Release package: Android → APK, iOS → IPA                 |

- Default platform: macOS → `ios`, Linux/Windows → `android`.
- A connected device is picked automatically (real device first). Pass `-d <id>` to choose one.
- On macOS with no iOS device, the Simulator is opened. `prod` needs a real iPhone (release mode can't run on the simulator).
- `build ios` needs a signing team set in Xcode (`ios/Runner.xcworkspace` → Signing & Capabilities).
- Any extra arguments are passed to `flutter`, e.g. `./run build android --split-per-abi`.

The environment is available in code as `appEnv` / `isProd` from `lib/env.dart`.
