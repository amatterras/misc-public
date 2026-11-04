// Which devices get the iPhone interface (lib/phone).
//
// The iPhone interface is its own layer: its own shell, screens and type
// scale. It reads and writes the same data through the same AppState and
// Workspace as Windows and iPad, and it never changes what they show.
//
//  * `lib/main_iphone.dart` (the iPhone build) sets [forced]: that build is
//    always the iPhone interface.
//  * The shared `lib/main.dart` build chooses by the device itself, never by
//    the window width (see device_idiom.dart): an iPhone gets it, an iPad or
//    a PC never does, however narrow their window is.
import '../platform/device_idiom.dart';
import '../platform/input_hints.dart' show touchFirst;

abstract final class PhoneProfile {
  /// Set once by `main_iphone.dart` before anything starts. Tests set it to
  /// render the phone interface on a PC.
  static bool forced = false;

  /// True when this run shows the iPhone interface.
  static bool get active => forced || (touchFirst && DeviceIdiom.isPhone);
}
