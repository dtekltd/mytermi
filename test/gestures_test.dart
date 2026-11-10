import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/widgets/terminal_gestures.dart';

void main() {
  late List<ArrowDir> arrows;
  late int taps, doubleTaps;
  late List<Offset> selects;
  late List<double> scrolls;

  Future<void> pump(WidgetTester t) async {
    arrows = [];
    taps = doubleTaps = 0;
    selects = [];
    scrolls = [];
    await t.pumpWidget(MaterialApp(
      home: TerminalGestures(
        onTap: () => taps++,
        onDoubleTap: () => doubleTaps++,
        onArrow: arrows.add,
        onSelectStart: selects.add,
        onSelectUpdate: (_, b) => selects.add(b),
        onScroll: scrolls.add,
        onPinchStart: () {},
        onPinch: (_) {},
        child: const SizedBox.expand(),
      ),
    ));
  }

  testWidgets('swipe right/left/up/down fires one arrow per step', (t) async {
    await pump(t);
    final g = await t.startGesture(const Offset(200, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(10, 0)); // 60px → 2 steps of 26px
    }
    await g.moveBy(const Offset(0, -60)); // 2 up
    await g.up();
    expect(arrows, [ArrowDir.right, ArrowDir.right, ArrowDir.up, ArrowDir.up]);
    expect(taps, 0);
  });

  testWidgets('arrow pad appears while touching and hides on release', (t) async {
    await pump(t);
    final g = await t.startGesture(const Offset(200, 300));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    await g.up();
    await t.pump();
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
  });

  testWidgets('single tap vs double tap (= Tab)', (t) async {
    await pump(t);
    await t.tapAt(const Offset(100, 100));
    await t.pump(const Duration(milliseconds: 500));
    expect((taps, doubleTaps), (1, 0));
    await t.tapAt(const Offset(100, 100));
    await t.pump(const Duration(milliseconds: 120));
    await t.tapAt(const Offset(105, 102));
    expect((taps, doubleTaps), (2, 1));
    expect(arrows, isEmpty);
  });

  testWidgets('long press selects instead of arrows', (t) async {
    await pump(t);
    final g = await t.startGesture(const Offset(150, 150));
    await t.pump(const Duration(milliseconds: 600));
    expect(selects, [const Offset(150, 150)]);
    await g.moveBy(const Offset(80, 0));
    await g.up();
    expect(arrows, isEmpty);
    expect(selects.last, const Offset(230, 150));
  });

  testWidgets('holding the finger far away auto-repeats', (t) async {
    await pump(t);
    final g = await t.startGesture(const Offset(200, 300));
    for (var i = 0; i < 9; i++) {
      await g.moveBy(const Offset(0, -10)); // 90px up → 3 arrows
    }
    expect(arrows.length, 3);
    await t.pump(const Duration(milliseconds: 420 + 90 * 4 + 10));
    await g.up();
    expect(arrows.length, greaterThanOrEqualTo(6));
    expect(arrows.toSet(), {ArrowDir.up});
  });

  testWidgets('two-finger drag scrolls, no arrows', (t) async {
    await pump(t);
    final a = await t.startGesture(const Offset(100, 300), pointer: 1);
    final b = await t.startGesture(const Offset(200, 300), pointer: 2);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(0, 12));
      await b.moveBy(const Offset(0, 12));
    }
    await a.up();
    await b.up();
    expect(arrows, isEmpty);
    expect(scrolls.fold<double>(0, (s, v) => s + v), greaterThan(30));
  });
}
