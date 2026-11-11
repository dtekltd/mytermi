import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/env.dart';
import 'package:mytermi/screens/settings_screen.dart';
import 'package:mytermi/services/app_services.dart';
import 'package:mytermi/theme.dart';
import 'package:mytermi/util/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppServices app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = await AppServices.load(startSync: false);
  });
  tearDown(() => debugIsDesktop = null);

  Future<void> pumpSettings(WidgetTester t) async {
    t.view.physicalSize = const Size(800, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(AppPalette.dark), home: Scaffold(body: SettingsScreen(app: app))));
    await t.pump();
  }

  test('PayPal links', () {
    expect(donateAmounts, [5, 10, 20]);
    expect(donateUrl(10).toString(), 'https://paypal.me/phthosting/10USD');
  });

  testWidgets('desktop shows the donate buttons', (t) async {
    debugIsDesktop = true;
    await pumpSettings(t);
    expect(find.text('Buy me a coffee'), findsOneWidget);
    for (final usd in donateAmounts) {
      expect(find.text('$usd USD'), findsOneWidget);
    }
    expect(find.text('Source code'), findsOneWidget);
  });

  testWidgets('phones never show the donate buttons (store rules)', (t) async {
    debugIsDesktop = false;
    await pumpSettings(t);
    expect(find.text('Buy me a coffee'), findsNothing);
    expect(find.text('5 USD'), findsNothing);
    expect(find.text('Source code'), findsOneWidget);
  });

  testWidgets('About shows the app version', (t) async {
    appVersion = '1.2.3';
    await pumpSettings(t);
    expect(find.textContaining('version 1.2.3'), findsOneWidget);
  });

  testWidgets('desktop marks touch settings as mobile-only', (t) async {
    debugIsDesktop = true;
    await pumpSettings(t);
    expect(find.text('Touch gestures · mobile app only'), findsOneWidget);
    for (final label in ['Match app', 'Bar', 'High']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('phone shows the plain touch section', (t) async {
    debugIsDesktop = false;
    await pumpSettings(t);
    expect(find.text('Touch gestures'), findsOneWidget);
  });
}
