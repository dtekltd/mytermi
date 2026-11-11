import 'dart:io';

import 'package:flutter/foundation.dart';

/// Desktop builds (Windows, macOS, Linux) use a mouse and a hardware keyboard:
/// the terminal gets native mouse selection/scrolling instead of touch gestures,
/// and the on-screen extra-keys row is hidden.
bool get isDesktop =>
    debugIsDesktop ?? (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux));

/// Tests override [isDesktop] (they run on a desktop OS but may render the phone UI).
@visibleForTesting
bool? debugIsDesktop;
