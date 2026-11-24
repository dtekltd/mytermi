import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/screens/login_screen.dart';
import 'package:mytermi/services/app_services.dart';
import 'package:mytermi/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('no sync server: the banner offers to set it', (t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final app = await AppServices.load(startSync: false);
    await app.account.setServerUrl('');
    await t.pumpWidget(MaterialApp(theme: buildTheme(AppPalette.light), home: LoginScreen(app: app)));
    await t.pump();

    expect(find.text('No sync server URL is set.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await t.tap(find.text('Set server'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'sync.example.com');
    await t.tap(find.text('Save'));
    await t.pump();
    expect(app.account.serverUrl, 'https://sync.example.com');
  });
}
