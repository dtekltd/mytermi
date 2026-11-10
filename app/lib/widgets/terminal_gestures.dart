import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/settings_store.dart';
import '../theme.dart';

enum ArrowDir { up, down, left, right }

/// Touch layer over the terminal:
///  - tap             → [onTap] (show keyboard)
///  - double tap      → [onDoubleTap] (Tab)
///  - 1-finger swipe  → arrow keys, one per [step] px; shows an arrow pad.
///                      Holding the finger away from where it started repeats.
///  - long press      → text selection ([onSelectStart]/[onSelectUpdate])
///  - 2-finger drag   → [onScroll]; pinch → [onPinch]
///
/// Uses raw pointer events so it never fights the terminal's own gestures
/// (the terminal view underneath should be wrapped in IgnorePointer).
class TerminalGestures extends StatefulWidget {
  const TerminalGestures({
    super.key,
    required this.child,
    required this.onTap,
    required this.onDoubleTap,
    required this.onArrow,
    required this.onSelectStart,
    required this.onSelectUpdate,
    required this.onScroll,
    required this.onPinchStart,
    required this.onPinch,
    this.step = 26,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<ArrowDir> onArrow;
  final ValueChanged<Offset> onSelectStart;
  final void Function(Offset from, Offset to) onSelectUpdate;
  final ValueChanged<double> onScroll; // dy in px, positive = finger moved down
  final VoidCallback onPinchStart;
  final ValueChanged<double> onPinch; // cumulative scale since pinch start
  final double step;

  @override
  State<TerminalGestures> createState() => _TerminalGesturesState();
}

enum _Mode { none, pending, arrows, select, multi, scroll, pinch }

class _TerminalGesturesState extends State<TerminalGestures> {
  static const _slop = 10.0;
  static const _padSize = 132.0;
  static const _longPress = Duration(milliseconds: 550);
  static const _padDelay = Duration(milliseconds: 140);
  static const _doubleTapWindow = Duration(milliseconds: 300);

  final _pointers = <int, Offset>{};
  _Mode _mode = _Mode.none;
  Offset _origin = Offset.zero; // where the finger went down (pad centre)
  Offset _anchor = Offset.zero; // position at which the last arrow fired
  Offset _pos = Offset.zero;
  ArrowDir? _dir;
  bool _showPad = false;
  Timer? _padTimer, _longPressTimer, _repeatDelay, _repeat;

  DateTime? _lastTap;
  Offset? _lastTapPos;

  double _multiStartDist = 0;
  double _multiLastY = 0;

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _padTimer?.cancel();
    _longPressTimer?.cancel();
    _repeatDelay?.cancel();
    _repeat?.cancel();
  }

  void _setPad(bool show, [ArrowDir? dir]) {
    if (show == _showPad && dir == _dir) return;
    setState(() {
      _showPad = show;
      _dir = dir;
    });
  }

  // ------------------------------------------------------------ pointers

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      _mode = _Mode.pending;
      _origin = _anchor = _pos = e.localPosition;
      _padTimer = Timer(_padDelay, () {
        if (_mode == _Mode.pending || _mode == _Mode.arrows) _setPad(true, _dir);
      });
      _longPressTimer = Timer(_longPress, () {
        if (_mode != _Mode.pending) return;
        _mode = _Mode.select;
        _setPad(false);
        Haptics.medium();
        widget.onSelectStart(_origin);
      });
    } else if (_pointers.length == 2) {
      _cancelTimers();
      _setPad(false);
      _mode = _Mode.multi;
      final p = _pointers.values.toList();
      _multiStartDist = (p[0] - p[1]).distance;
      _multiLastY = (p[0].dy + p[1].dy) / 2;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    switch (_mode) {
      case _Mode.pending:
        if ((e.localPosition - _origin).distance > _slop) {
          _mode = _Mode.arrows;
          _longPressTimer?.cancel();
          _anchor = _origin;
          _arrowsMove(e.localPosition);
        }
      case _Mode.arrows:
        _arrowsMove(e.localPosition);
      case _Mode.select:
        widget.onSelectUpdate(_origin, e.localPosition);
      case _Mode.multi || _Mode.scroll || _Mode.pinch:
        _multiMove();
      case _Mode.none:
        break;
    }
  }

  void _up(PointerEvent e) {
    final wasSingle = _pointers.length == 1;
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) {
      // One finger of a two-finger gesture lifted: ignore the rest of it.
      if (_mode == _Mode.multi || _mode == _Mode.scroll || _mode == _Mode.pinch) _mode = _Mode.none;
      return;
    }
    if (wasSingle && _mode == _Mode.pending && e is PointerUpEvent) _tap(e.localPosition);
    _cancelTimers();
    _mode = _Mode.none;
    _setPad(false);
  }

  // ---------------------------------------------------------------- tap

  void _tap(Offset at) {
    final now = DateTime.now();
    final isDouble = _lastTap != null &&
        now.difference(_lastTap!) < _doubleTapWindow &&
        (at - _lastTapPos!).distance < 40;
    if (isDouble) {
      _lastTap = null;
      Haptics.selection();
      widget.onDoubleTap();
    } else {
      _lastTap = now;
      _lastTapPos = at;
      widget.onTap();
    }
  }

  // ------------------------------------------------------------- arrows

  void _arrowsMove(Offset p) {
    _pos = p;
    final step = widget.step;
    var d = p - _anchor;
    // Fire one arrow per `step` px along the dominant axis.
    while (d.dx.abs() >= step || d.dy.abs() >= step) {
      final ArrowDir dir;
      if (d.dx.abs() > d.dy.abs()) {
        dir = d.dx > 0 ? ArrowDir.right : ArrowDir.left;
        _anchor = _anchor.translate(d.dx.sign * step, 0);
        _anchor = Offset(_anchor.dx, p.dy); // don't accumulate cross-axis drift
      } else {
        dir = d.dy > 0 ? ArrowDir.down : ArrowDir.up;
        _anchor = _anchor.translate(0, d.dy.sign * step);
        _anchor = Offset(p.dx, _anchor.dy);
      }
      _fire(dir);
      d = p - _anchor;
    }
    _setPad(true, _dir);
    _scheduleRepeat();
  }

  void _fire(ArrowDir dir) {
    if (_dir != dir || !_showPad) {
      setState(() {
        _dir = dir;
        _showPad = true;
      });
    }
    Haptics.selection();
    widget.onArrow(dir);
  }

  /// Finger resting far from the origin → keep pressing that arrow.
  void _scheduleRepeat() {
    _repeatDelay?.cancel();
    _repeat?.cancel();
    final dir = _dir;
    if (dir == null) return;
    final off = _pos - _origin;
    final far = switch (dir) {
      ArrowDir.left || ArrowDir.right => off.dx.abs() > widget.step * 2.5,
      ArrowDir.up || ArrowDir.down => off.dy.abs() > widget.step * 2.5,
    };
    if (!far) return;
    _repeatDelay = Timer(const Duration(milliseconds: 420), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 90), (_) {
        if (_mode == _Mode.arrows) _fire(dir);
      });
    });
  }

  // -------------------------------------------------------- two fingers

  void _multiMove() {
    if (_pointers.length < 2) return;
    final p = _pointers.values.take(2).toList();
    final dist = (p[0] - p[1]).distance;
    final y = (p[0].dy + p[1].dy) / 2;
    if (_mode == _Mode.multi) {
      if ((dist - _multiStartDist).abs() > 24) {
        _mode = _Mode.pinch;
        widget.onPinchStart();
      } else if ((y - _multiLastY).abs() > 8) {
        _mode = _Mode.scroll;
      }
    }
    if (_mode == _Mode.scroll) {
      widget.onScroll(y - _multiLastY);
      _multiLastY = y;
    } else if (_mode == _Mode.pinch && _multiStartDist > 0) {
      widget.onPinch(dist / _multiStartDist);
    }
  }

  // ----------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      const half = _padSize / 2;
      final left = (_origin.dx - half).clamp(4.0, math.max(4.0, box.maxWidth - _padSize - 4)).toDouble();
      final top = (_origin.dy - half).clamp(4.0, math.max(4.0, box.maxHeight - _padSize - 4)).toDouble();
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (_showPad)
              Positioned(
                left: left,
                top: top,
                child: IgnorePointer(child: _ArrowPad(size: _padSize, active: _dir)),
              ),
          ],
        ),
      );
    });
  }
}

class _ArrowPad extends StatelessWidget {
  const _ArrowPad({required this.size, required this.active});
  final double size;
  final ArrowDir? active;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget arrow(ArrowDir d, IconData icon, Alignment a) => Align(
          alignment: a,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, size: 34, color: active == d ? c.blue : c.textDim),
          ),
        );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.surfaceHi.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.border),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 16)],
      ),
      child: Stack(children: [
        arrow(ArrowDir.up, Icons.arrow_upward_rounded, Alignment.topCenter),
        arrow(ArrowDir.down, Icons.arrow_downward_rounded, Alignment.bottomCenter),
        arrow(ArrowDir.left, Icons.arrow_back_rounded, Alignment.centerLeft),
        arrow(ArrowDir.right, Icons.arrow_forward_rounded, Alignment.centerRight),
      ]),
    );
  }
}
