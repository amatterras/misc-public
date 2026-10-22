// Wording of on-screen hints per platform. iPhone/iPad are used by touch,
// often without a keyboard: hints say "tap" instead of "click" and leave out
// Ctrl shortcuts (an iPad keyboard uses ⌘, which the canvas also accepts).
import 'package:flutter/foundation.dart';

/// True on iPhone/iPad. Follows `debugDefaultTargetPlatformOverride` in
/// tests.
bool get touchFirst => defaultTargetPlatform == TargetPlatform.iOS;

/// [label] followed by its keyboard [shortcut] where a keyboard is expected.
String withShortcut(String label, String shortcut) =>
    touchFirst ? label : '$label  ($shortcut)';

/// "Double-click" / "Double-tap" (capitalised for the start of a hint).
String get doubleClickWord => touchFirst ? 'Double-tap' : 'Double-click';

/// Where the data lives, in plain words.
String get thisDevice => touchFirst ? 'this device' : 'this PC';
