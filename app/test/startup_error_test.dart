import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/main.dart';

void main() {
  testWidgets('a missing Linux keyring explains how to fix it instead of a blank window', (t) async {
    StartupErrorApp.debugKeyringHint = true;
    addTearDown(() => StartupErrorApp.debugKeyringHint = false);
    await t.pumpWidget(StartupErrorApp(
      error: PlatformException(code: 'Libsecret error', message: 'secret_service_get_sync: The name org.freedesktop.secrets was not provided'),
    ));
    expect(find.text('MyTermi could not start'), findsOneWidget);
    expect(find.text('sudo apt install gnome-keyring'), findsOneWidget);
  });

  testWidgets('other startup errors are shown as they are', (t) async {
    await t.pumpWidget(StartupErrorApp(error: StateError('boom')));
    expect(find.text('MyTermi could not start'), findsOneWidget);
    expect(find.text('sudo apt install gnome-keyring'), findsNothing);
    expect(find.textContaining('boom'), findsOneWidget);
  });
}
