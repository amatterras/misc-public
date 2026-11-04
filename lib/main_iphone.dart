// Entry point of the dedicated iPhone build:
//
//   flutter build ios --target lib/main_iphone.dart
//
// It starts the very same app (same start-up, storage, sync, encryption and
// pages as lib/main.dart; nothing is duplicated) but marks the run as the
// iPhone interface, so the phone layout in lib/phone is used for sure and
// never depends on how the device reports itself. The iPad and Windows
// builds keep using lib/main.dart and are not touched by anything here.
import 'main.dart' as app;
import 'phone/phone_profile.dart';

Future<void> main(List<String> args) async {
  PhoneProfile.forced = true;
  await app.main(args);
}
