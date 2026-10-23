// Notebook paper: exactly three approved templates, each with its own
// spacing, line color/opacity and page color. Only the page background:
// text, ink, drawings and attachments are never part of it.

/// The three approved notebook templates. Do not add others.
enum PaperTemplate {
  /// Everyday notes and handwriting.
  squareGrid,

  /// Larger squares for diagrams, calculations and spacious writing.
  largeGrid,

  /// Square grid on the left 2/5 of the page, dot grid on the right 3/5.
  splitGridDots,
}

extension PaperTemplateInfo on PaperTemplate {
  String get label => switch (this) {
    PaperTemplate.squareGrid => 'Standard square grid',
    PaperTemplate.largeGrid => 'Larger square grid',
    PaperTemplate.splitGridDots => 'Split grid + dot grid',
  };

  /// Default square size (page units; a page is 816 wide).
  double get defaultGridSpacing => switch (this) {
    PaperTemplate.largeGrid => 48,
    _ => 24,
  };
}

/// Line and dot colors offered for the paper (existing design tokens only).
const paperLineColors = <int>[
  0xFF41444A, // Graphite Grey (borders)
  0xFFAAAEB6, // Warm Grey
  0xFF789BB5, // Steel Blue
  0xFF829CB5, // Dusty Blue
  0xFFE5D5B8, // Champagne
];

/// Page colors offered for the paper (existing design tokens only).
const paperBackgroundColors = <int>[
  0xFF191A1D, // Cool Graphite
  0xFF222429, // Charcoal Surface
  0xFF303239, // Soft Graphite
];

/// A note's paper. The grid side uses [gridSpacing], [lineColor],
/// [lineOpacity] and [background]; the split template's dot side (right
/// 3/5) has its own [dotSpacing], [dotColor], [dotOpacity] and
/// [dotBackground].
class NotePaper {
  const NotePaper({
    this.template = PaperTemplate.squareGrid,
    this.gridSpacing = 24,
    this.lineColor = defaultLine,
    this.lineOpacity = defaultOpacity,
    this.background = defaultBackground,
    this.dotSpacing = 24,
    this.dotColor = defaultLine,
    this.dotOpacity = defaultOpacity,
    this.dotBackground = defaultBackground,
  });

  /// Template defaults (larger grid: larger squares).
  factory NotePaper.of(PaperTemplate template) =>
      NotePaper(template: template, gridSpacing: template.defaultGridSpacing);

  static const minSpacing = 8.0;
  static const maxSpacing = 96.0;
  static const minOpacity = 0.05;
  static const defaultLine = 0xFF41444A;
  static const defaultOpacity = 0.6;
  static const defaultBackground = 0xFF191A1D;

  /// The split template's columns: grid 2/5, dots 3/5.
  static const splitGridFraction = 2 / 5;

  final PaperTemplate template;
  final double gridSpacing;
  final int lineColor;
  final double lineOpacity;
  final int background;
  final double dotSpacing;
  final int dotColor;
  final double dotOpacity;
  final int dotBackground;

  /// Another template with its default square size; colors and the dot
  /// side's settings are kept.
  NotePaper withTemplate(PaperTemplate t) =>
      copyWith(template: t, gridSpacing: t.defaultGridSpacing);

  NotePaper copyWith({
    PaperTemplate? template,
    double? gridSpacing,
    int? lineColor,
    double? lineOpacity,
    int? background,
    double? dotSpacing,
    int? dotColor,
    double? dotOpacity,
    int? dotBackground,
  }) => NotePaper(
    template: template ?? this.template,
    gridSpacing: _spacing(gridSpacing ?? this.gridSpacing),
    lineColor: lineColor ?? this.lineColor,
    lineOpacity: _opacity(lineOpacity ?? this.lineOpacity),
    background: background ?? this.background,
    dotSpacing: _spacing(dotSpacing ?? this.dotSpacing),
    dotColor: dotColor ?? this.dotColor,
    dotOpacity: _opacity(dotOpacity ?? this.dotOpacity),
    dotBackground: dotBackground ?? this.dotBackground,
  );

  static double _spacing(double v) => v.clamp(minSpacing, maxSpacing);
  static double _opacity(double v) => v.clamp(minOpacity, 1.0);

  Map<String, dynamic> toJson() => {
    'template': template.name,
    'gridSpacing': gridSpacing,
    'lineColor': lineColor,
    'lineOpacity': lineOpacity,
    'background': background,
    'dotSpacing': dotSpacing,
    'dotColor': dotColor,
    'dotOpacity': dotOpacity,
    'dotBackground': dotBackground,
  };

  /// Missing or unknown values fall back to the standard grid defaults.
  static NotePaper? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    double number(String key, double fallback) =>
        j[key] is num ? (j[key] as num).toDouble() : fallback;
    int color(String key, int fallback) =>
        j[key] is int ? j[key] as int : fallback;
    final template =
        PaperTemplate.values.asNameMap()[j['template']] ??
        PaperTemplate.squareGrid;
    return NotePaper(
      template: template,
      gridSpacing: _spacing(number('gridSpacing', template.defaultGridSpacing)),
      lineColor: color('lineColor', defaultLine),
      lineOpacity: _opacity(number('lineOpacity', defaultOpacity)),
      background: color('background', defaultBackground),
      dotSpacing: _spacing(number('dotSpacing', 24)),
      dotColor: color('dotColor', defaultLine),
      dotOpacity: _opacity(number('dotOpacity', defaultOpacity)),
      dotBackground: color('dotBackground', defaultBackground),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotePaper &&
      other.template == template &&
      other.gridSpacing == gridSpacing &&
      other.lineColor == lineColor &&
      other.lineOpacity == lineOpacity &&
      other.background == background &&
      other.dotSpacing == dotSpacing &&
      other.dotColor == dotColor &&
      other.dotOpacity == dotOpacity &&
      other.dotBackground == dotBackground;

  @override
  int get hashCode => Object.hash(
    template,
    gridSpacing,
    lineColor,
    lineOpacity,
    background,
    dotSpacing,
    dotColor,
    dotOpacity,
    dotBackground,
  );
}
