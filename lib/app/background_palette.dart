// The one place that decides which colours the Mindmap dots and the Notes
// paper have in the light and the dark theme.
//
//  * Light theme: Mindmap dots are black, Notes paper is white and its grid
//    lines are black.
//  * Dark theme: exactly what was there before (white dots at the user's
//    opacity; the paper's own stored colours, the established dark ones).
//
// Only COLOURS depend on the theme. Dot size, dot opacity, grid size and grid
// opacity are the user's own settings, stored apart from the theme (dots in
// the settings under dotSize.* / dotOpacity.*, the grid in each note's paper),
// so switching theme never changes them. Nothing here writes to storage: the
// light colours are applied when drawing and a note's saved paper is left
// untouched, so going back to dark brings its exact old look back.
import 'dart:ui' show Color;

import '../data/models/paper.dart';
import 'theme.dart';

abstract final class BackgroundPalette {
  static const lightDot = Color(0xFF000000);
  static const lightPaper = Color(0xFFFFFFFF);
  static const lightLine = Color(0xFF000000);

  /// The dark theme's Mindmap dot colour (unchanged from before).
  static const darkDot = Color(0xFFFFFFFF);

  /// The theme in use; every caller may pass the one it already knows.
  static bool isLight([bool? light]) => light ?? AppColors.light;

  /// Mindmap (and Archive board) dot colour, before the user's opacity.
  static Color dot({bool? light}) => isLight(light) ? lightDot : darkDot;

  /// How [stored] is drawn in this theme. Dark: as stored. Light: white page,
  /// black lines and dots; spacing, opacity and template stay the user's.
  static NotePaper paperFor(NotePaper stored, {bool? light}) {
    if (!isLight(light)) return stored;
    return stored.copyWith(
      lineColor: lightLine.toARGB32(),
      background: lightPaper.toARGB32(),
      dotColor: lightLine.toARGB32(),
      dotBackground: lightPaper.toARGB32(),
    );
  }
}
