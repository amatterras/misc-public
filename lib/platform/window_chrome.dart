// The native Windows window frame (title bar, border, corners) follows the
// app's own theme instead of the Windows light/dark setting.
//
// The window keeps its standard native frame on purpose: snapping, Snap
// Layouts on the maximize button, Aero shake, DPI changes, monitor moves and
// the system menu all keep working because Windows still draws them. We only
// ask DWM (Windows 11) to colour the caption and border to match the app and
// to use rounded corners. On Windows 10 the colour calls are ignored by the
// system and the frame stays standard; on other platforms this does nothing.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter/services.dart';

import '../app/theme.dart';
import '../app/theme.dart' show AppColors;

abstract final class WindowChrome {
  static const _channel = MethodChannel('theapp/windows');

  /// What was last sent, so repeated calls are free.
  static bool? _lastDark;

  /// Last request, for tests.
  @visibleForTesting
  static Map<String, Object>? lastRequest;

  /// Colours the native frame for the dark or light theme.
  static void apply({required bool dark}) {
    if (_lastDark == dark) return;
    _lastDark = dark;
    final wasMode = AppColors.mode;
    // Read the palette of the requested theme.
    AppColors.mode = dark ? ThemeMode.dark : ThemeMode.light;
    final args = <String, Object>{
      'dark': dark,
      'caption': _bgr(AppColors.background),
      'text': _bgr(AppColors.text),
      'border': _bgr(AppColors.border),
    };
    AppColors.mode = wasMode;
    lastRequest = args;
    if (kIsWeb || !Platform.isWindows) return;
    _channel.invokeMethod<void>('setWindowTheme', args).catchError((_) {
      // Older runner without the handler: the standard frame stays.
    });
  }

  /// Forgets what was sent (tests).
  @visibleForTesting
  static void reset() {
    _lastDark = null;
    lastRequest = null;
  }

  /// DWM wants COLORREF: 0x00BBGGRR.
  static int _bgr(Color c) {
    final v = c.toARGB32();
    final r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF;
    return (b << 16) | (g << 8) | r;
  }
}
