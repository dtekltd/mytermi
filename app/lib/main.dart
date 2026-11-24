import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'env.dart';

import 'screens/home_screen.dart';
import 'services/app_services.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (_) {} // keep the placeholder
  final AppServices app;
  try {
    app = await AppServices.load();
  } catch (e) {
    // Without this the window stays blank (e.g. Linux without a keyring).
    runApp(StartupErrorApp(error: e));
    return;
  }
  runApp(MyTermiApp(app: app));
}

/// Shown instead of the app when it can't start, with what to do about it.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});
  final Object error;

  /// Passwords and keys live in the OS keychain. On Linux that is the Secret
  /// Service (GNOME Keyring, KWallet...), which minimal or non-GNOME desktops
  /// may not run.
  bool get _noKeyring =>
      (Platform.isLinux || debugKeyringHint) &&
      error is PlatformException &&
      '${(error as PlatformException).message} ${(error as PlatformException).code}'.toLowerCase().contains('secret');

  @visibleForTesting
  static bool debugKeyringHint = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyTermi',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(AppPalette.dark),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('MyTermi could not start', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                if (_noKeyring) ...[
                  const Text(
                    'MyTermi keeps passwords and keys in the system keyring (Secret Service), which is '
                    'not available: no keyring service is running, or it has no unlocked login keyring. '
                    'On Ubuntu, install GNOME Keyring, log out and back in, then open MyTermi again:',
                  ),
                  const SizedBox(height: 12),
                  const SelectableText('sudo apt install gnome-keyring', style: TextStyle(fontFamily: 'monospace')),
                  const SizedBox(height: 16),
                ],
                SelectableText('$error', style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class MyTermiApp extends StatelessWidget {
  const MyTermiApp({super.key, required this.app});
  final AppServices app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) => MaterialApp(
        title: 'MyTermi',
        debugShowCheckedModeBanner: false,
        themeMode: app.settings.themeMode, // system by default
        theme: buildTheme(AppPalette.light),
        darkTheme: buildTheme(AppPalette.dark),
        home: HomeScreen(app: app),
      ),
    );
  }
}
