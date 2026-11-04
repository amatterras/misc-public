// iPhone or iPad: decided by the device itself, never by window width. An
// iPad in Slide Over or a narrow Split View window is still an iPad (iPad
// layout, no Home); an iPhone is always an iPhone, in portrait or landscape.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

abstract final class DeviceIdiom {
  static bool? _fromModel;
  static bool? _modelIsIpad;

  /// Tests set this to decide without a device.
  @visibleForTesting
  static bool? debugIsPhone;

  /// Tests set this to decide "this is an iPad" without a device.
  @visibleForTesting
  static bool? debugIsIpad;

  /// True only when the device itself said "iPad". Unknown means no: the
  /// iPad interface is never chosen by a guess.
  static bool get isIpad => debugIsIpad ?? _modelIsIpad ?? false;

  /// Records what iOS says about itself (`UIDevice.current.model`: "iPhone",
  /// "iPod touch", "iPad"). Called once at start-up on iOS.
  static void resolve(String? model) {
    final m = model?.toLowerCase();
    if (m == null || m.isEmpty) return;
    _fromModel = !m.contains('ipad');
    _modelIsIpad = m.contains('ipad');
  }

  /// True on an iPhone/iPod touch. If the device did not say what it is, the
  /// size of the **whole screen** (not the window) decides: the smallest iPad
  /// screen is far wider than the largest iPhone, so this never depends on how
  /// big the app's window currently is.
  static bool get isPhone {
    final forced = debugIsPhone ?? _fromModel;
    if (forced != null) return forced;
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return false;
    final display = views.first.display;
    final shortest = display.size.shortestSide / display.devicePixelRatio;
    return shortest < 600;
  }
}
