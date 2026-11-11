# MyTermi

SSH client for iOS, Android and Windows built with Flutter (dartssh2 + xterm), styled after Termius.

## Flutter version

The project is pinned to Flutter **3.47.9** in `.fvmrc`. If [FVM](https://fvm.app) is installed, `run` uses that version automatically (installing it on first run) without touching your global Flutter. Without FVM, `run` uses the `flutter` on your PATH.

For the IDE / manual commands, run `fvm use` once in the project (creates `.fvm/flutter_sdk`) and use `fvm flutter ...`.

## Run / build

```sh
./run [dev|prod|build] [ios|android]     [extra flutter args...]   # macOS / Linux
run   [dev|prod|build] [android|windows] [extra flutter args...]   # Windows (run.cmd)
```

| Mode    | What it does                                             |
|---------|----------------------------------------------------------|
| `dev`   | Debug build with hot reload (default), `APP_ENV=dev`      |
| `prod`  | Release build run on a device, `APP_ENV=prod`             |
| `build` | Release package: Android → APK, iOS → IPA, Windows → zip  |

- Default platform: macOS → `ios`, Linux/Windows → `android`.
- A connected device is picked automatically (real device first). Pass `-d <id>` to choose one.
- On macOS with no iOS device, the Simulator is opened. `prod` needs a real iPhone (release mode can't run on the simulator).
- `build ios` needs a signing team set in Xcode (`ios/Runner.xcworkspace` → Signing & Capabilities).
- Any extra arguments are passed to `flutter`, e.g. `./run build android --split-per-abi`.

## Windows

- Building needs a Windows PC with **Visual Studio 2022** and the **Desktop development with C++**
  workload (Flutter can't build Windows apps on macOS or Linux). Check with `flutter doctor`.
- `run windows` starts the app on this PC. `run build windows` writes
  `build\windows\x64\runner\Release\` (the app folder: `mytermi.exe` plus its DLLs and `data\`) and
  `build\windows\MyTermi-windows-x64.zip`. To install, unzip anywhere and run `mytermi.exe`.
- **Without a Windows PC:** the GitHub Actions workflow `.github/workflows/windows.yml` builds the
  zip on every push to `main` that changes `app/` (Actions tab → *Windows app* → run →
  Artifacts). Pushing a `v*` tag also attaches the zip to a GitHub Release. Set the repository
  variable `MYTERMI_API_URL` to bake in your sync server.
- On desktop the terminal uses the mouse (drag to select, wheel to scroll, right click copies the
  selection or pastes) and the keyboard: **Ctrl+Shift+C / Ctrl+Shift+V** copy and paste (plain
  Ctrl+C/V/A go to the shell), **Ctrl+= / Ctrl+- / Ctrl+0** change the font size. The on-screen
  extra-keys row is hidden.
- Sign in with email works. Google and Apple sign-in are mobile-only.

## App icon

Sources and instructions are in [assets/icon/README.md](assets/icon/README.md).

The environment is available in code as `appEnv` / `isProd` from `lib/env.dart`.
