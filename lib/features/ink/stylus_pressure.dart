// Whether the pen in use reports pressure, decided from what it actually
// sends, stroke by stroke.
//
// Most pens do (Apple Pencil 1, 2 and Pro, Surface Pen, Wacom); some do not
// (Apple Pencil USB-C, simple capacitive pens, a Windows pen whose driver
// gives Flutter no pressure). A pen without pressure sends the same value
// for every sample, and a width made from that value would be made up, so
// its lines are drawn at exactly the chosen width instead.
//
// Before, one session-wide flag started as "no pressure" and flipped on
// the first variation ever seen: the first stroke after launch began at a
// constant width and changed part-way, a first short tap was stored without
// pressure, and a pen swapped during the session was never noticed.
//
// Now a stylus stroke is pressure ink from its first sample unless the pen
// has shown that it reports none, and every stroke re-checks:
//  * unknown / varies: the stroke starts as pressure ink;
//  * a finished stroke of at least [minFlatSamples] samples whose pressure
//    never moved by more than [flatRange] marks the pen as flat, and that
//    stroke is stored at the chosen width;
//  * flat: strokes start at the chosen width, and the first sample that
//    differs from the stroke's first by more than [variesBy] marks the pen
//    as varying again (another pen was picked up), that stroke included.
// Mouse and finger never give pressure ink.

/// What is known about the stylus in use.
enum StylusPressureState { unknown, varies, flat }

class StylusPressure {
  StylusPressure._();

  /// One for the app: a person writes with one pen at a time, on whichever
  /// surface (canvas, note page, calendar) is open.
  static final StylusPressure instance = StylusPressure._();

  /// A change of this much from a stroke's first sample is real pressure.
  static const double variesBy = 0.02;

  /// Sensor noise alone moves a real pressure reading by more than this
  /// over [minFlatSamples] samples.
  static const double flatRange = 0.005;
  static const int minFlatSamples = 16;

  StylusPressureState get state => _state;
  StylusPressureState _state = StylusPressureState.unknown;

  double _first = 0.5, _low = 0.5, _high = 0.5;
  int _samples = 0;

  /// A stylus stroke begins with [pressure]. Returns whether it is drawn
  /// as pressure ink from this first sample.
  bool begin(double pressure) {
    _first = _low = _high = pressure;
    _samples = 1;
    return _state != StylusPressureState.flat;
  }

  /// Another sample of the stroke. Returns true when this sample shows
  /// that a pen believed to be flat does report pressure (the stroke
  /// becomes pressure ink from here on).
  bool sample(double pressure) {
    _samples++;
    if (pressure < _low) _low = pressure;
    if (pressure > _high) _high = pressure;
    if ((pressure - _first).abs() > variesBy) {
      final wasFlat = _state == StylusPressureState.flat;
      _state = StylusPressureState.varies;
      return wasFlat;
    }
    return false;
  }

  /// The stroke is finished. Returns whether it is stored as pressure ink
  /// ([wasPressure]: how it was being drawn).
  bool end({required bool wasPressure}) {
    if (_samples >= minFlatSamples && _high - _low <= flatRange) {
      _state = StylusPressureState.flat;
      return false;
    }
    return wasPressure;
  }

  /// Forgets what was learned (tests; a new session starts like this).
  void reset() {
    _state = StylusPressureState.unknown;
    _samples = 0;
  }
}
