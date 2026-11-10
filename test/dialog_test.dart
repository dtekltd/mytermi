import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/theme.dart';
import 'package:mytermi/widgets/common.dart';

// Regression: the password dialog disposed its controller as soon as showDialog
// returned; the close animation + keyboard hiding then rebuilt the TextField
// ("TextEditingController was used after being disposed").
void main() {
  Future<String?> run(WidgetTester t, Future<void> Function(WidgetTester) act) async {
    String? result = 'unset';
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(AppPalette.dark),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result =
              await showTextInputDialog(context, title: 'Password', confirmText: 'Kết nối', obscure: true),
          child: const Text('open'),
        ),
      ),
    ));
    addTearDown(t.view.reset);
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    t.view.viewInsets = const FakeViewPadding(bottom: 900); // keyboard up
    await t.pump();
    await act(t);
    t.view.resetViewInsets(); // keyboard goes down while the dialog animates out
    // Pump frame by frame through the close animation (where the old code crashed).
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    return result;
  }

  testWidgets('submit with button', variant: TargetPlatformVariant.only(TargetPlatform.iOS), (t) async {
    expect(await run(t, (t) async {
      await t.enterText(find.byType(TextField), 'hunter2');
      await t.tap(find.text('Kết nối'));
    }), 'hunter2');
  });

  testWidgets('submit with keyboard Enter', variant: TargetPlatformVariant.only(TargetPlatform.iOS), (t) async {
    expect(await run(t, (t) async {
      await t.enterText(find.byType(TextField), 'pw');
      await t.testTextInput.receiveAction(TextInputAction.done);
    }), 'pw');
  });

  testWidgets('cancel returns null', variant: TargetPlatformVariant.mobile(), (t) async {
    expect(await run(t, (t) async => t.tap(find.text('Huỷ'))), isNull);
  });
}
