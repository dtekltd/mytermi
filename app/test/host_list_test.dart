import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/host.dart';
import 'package:mytermi/models/snippet.dart';
import 'package:mytermi/screens/host_list_screen.dart';
import 'package:mytermi/screens/snippets_screen.dart';
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

  Future<void> pump(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(AppPalette.dark), home: Scaffold(body: child)));
    await t.pumpAndSettle();
  }

  testWidgets('Clone opens a prefilled new host and saves it as a separate host', (t) async {
    await app.hosts.save(
      Host(id: 'h1', label: 'web1', hostname: '10.0.0.5', port: 2222, username: 'ubuntu'),
      const HostSecrets(password: 'pw'),
    );
    await pump(t, HostListScreen(app: app));

    await t.tap(find.byIcon(Icons.more_horiz));
    await t.pumpAndSettle();
    await t.tap(find.text('Clone'));
    await t.pumpAndSettle();

    expect(find.text('Clone host'), findsOneWidget);
    expect(find.text('web1 (copy)'), findsOneWidget);
    expect(find.text('2222'), findsOneWidget);
    expect(find.text('ubuntu'), findsWidgets);

    await t.enterText(find.widgetWithText(TextFormField, '10.0.0.5'), '10.0.0.6');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(app.hosts.hosts, hasLength(2));
    final copy = app.hosts.hosts.firstWhere((h) => h.id != 'h1');
    expect(copy.hostname, '10.0.0.6');
    expect(copy.port, 2222);
    expect(copy.username, 'ubuntu');
    expect((await app.hosts.secretsFor(copy)).password, 'pw');
    expect(app.hosts.hosts.firstWhere((h) => h.id == 'h1').hostname, '10.0.0.5'); // original untouched
  });

  testWidgets('desktop snippets show a single drag handle per row', (t) async {
    debugIsDesktop = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows; // where Flutter adds default handles
    for (final s in [...app.commands.snippets]) {
      await app.commands.deleteSnippet(s);
    }
    await app.commands.saveSnippet(Snippet(id: 's1', name: 'cls', command: 'clear'));
    await pump(t, SnippetsScreen(store: app.commands));
    expect(find.byIcon(Icons.drag_handle), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('hosts reorder by dragging the handle; no handles while searching', (t) async {
    for (final (id, name) in [('a', 'alpha'), ('b', 'bravo'), ('c', 'charlie')]) {
      await app.hosts.save(Host(id: id, label: name, hostname: '10.0.0.1', username: 'u'), const HostSecrets());
    }
    await pump(t, HostListScreen(app: app));
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));

    // Drag "alpha" below "charlie".
    final handle = find.byIcon(Icons.drag_handle).first;
    final g = await t.startGesture(t.getCenter(handle));
    await t.pump(const Duration(milliseconds: 50));
    await g.moveBy(const Offset(0, 300));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
    expect(app.hosts.hosts.map((h) => h.id), ['b', 'c', 'a']);

    // Persisted.
    final reloaded = await AppServices.load(startSync: false);
    expect(reloaded.hosts.hosts.map((h) => h.id), ['b', 'c', 'a']);

    await t.enterText(find.byType(TextField).first, 'a');
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNothing);
  });
}
