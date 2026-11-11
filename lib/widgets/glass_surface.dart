// The one "floating chrome" surface: translucent, blurred, softly lit, with a
// faint brand glow. The right-hand navigation capsule and the canvas tool
// panels are both drawn with it, so they read as parts of the same interface.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Shared measurements of floating chrome (the navigation capsule, the tool
/// panels). One place, so the bars cannot drift apart.
abstract final class ChromeMetrics {
  /// Thickness of a compact bar: the capsule's width, the tool panel's width
  /// (vertical) or height (horizontal).
  static const thickness = 60.0;

  /// Icon size in a bar.
  static const icon = 20.0;

  /// The rounded hover / selected chip behind an icon.
  static const chip = 36.0;

  /// Hairline around the surface.
  static const border = 1.0;

  /// Space along the bar taken by one control (the chip plus its margin).
  static const pitch = 40.0;

  /// Width of the separator between groups of controls.
  static const separator = 24.0;

  /// Thin selected-item marker on the bar's edge.
  static const markerLength = 20.0;
  static const markerThickness = 3.0;
}

/// Translucent, blurred, softly lit surface that floats over a page. Give it
/// a [width] (or [height]) to size it, [borderRadius] for its shape.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.width,
    this.height,
    this.glow = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double? width;
  final double? height;

  /// The faint brand-coloured light around it (on by default, like the
  /// navigation capsule).
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [...AppElevation.floating, if (glow) ...AppElevation.glow],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppBlur.glass,
            sigmaY: AppBlur.glass,
          ),
          child: AnimatedContainer(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: AppColors.glass,
              borderRadius: borderRadius,
              border: Border.all(color: AppColors.glassBorder),
            ),
            foregroundDecoration: BoxDecoration(
              gradient: AppGradients.lighting,
              borderRadius: borderRadius,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
