import 'package:flutter/material.dart';
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
  final app = await AppServices.load();
  runApp(MyTermiApp(app: app));
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
