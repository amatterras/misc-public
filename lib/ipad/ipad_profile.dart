// Which devices get the iPad interface (lib/ipad). Chosen by the device
// itself (it must say "iPad"), never by window width or a guess. Windows and
// iPhone never get it; the iPhone has its own layer (lib/phone).
//
// The iPad interface is the shared pages (Notes, Calendar, Archive, Mindmap,
// Safari, AI) inside a new frame: a rail of vertical words, and a Today
// page. A narrow window (Slide Over, a thin Split View) keeps the compact
// floating capsule of the New interface.
import '../phone/phone_profile.dart';
import '../platform/device_idiom.dart';

abstract final class IpadProfile {
  /// Tests set this to render the iPad interface on a PC.
  static bool forced = false;

  static bool get active =>
      !PhoneProfile.active && (forced || DeviceIdiom.isIpad);

  /// iPhone and iPad each have their own interface; the Original/New choice
  /// only exists on Windows.
  static bool get fixedInterface => PhoneProfile.active || active;

  /// Width from which the rail is used; narrower windows use the capsule.
  static const railMinWidth = 640.0;
}
