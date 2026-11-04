# iOS Share Extension — implemented, NOT verified on a device

"Add to THEapp" in the iPhone/iPad share sheet. Shared links, text, photos and
files (e.g. PDFs) are saved into the **Archive**.

## What exists (code)
- `ShareViewController.swift`: receives a URL, plain text, an image (stored as
  JPEG), or a file (copied). Items over 100 MB or 200 000 characters are skipped
  and the sheet says so. Each item becomes a small request file in the App Group
  folder `group.com.theapp.shared/inbox_requests/` (copies in `inbox_files/`),
  named by a hash of its content, so a share delivered twice is stored once.
  The extension has no network access and puts nothing into notes, AI or the cloud.
- `Info.plist`: the extension shows for URLs, text, images, PDFs and files.
- `ShareExtension.entitlements`: declares the App Group.
- The Xcode project already contains the `ShareExtension` target
  (`com.amaterasu.theapp.share`), embedded in Runner. Nothing has to be added by hand.
- App side (Dart): when THEapp starts or returns to the front it reads the request
  files (`AppState.importSharedItems` → `SendToBridge.processRequests` →
  `CaptureService.captureToArchive`) and saves Archive objects: a link becomes a
  website item, text a note, a photo/PDF an image/document item. Repeats add no duplicate.

## What has been verified
- **Windows only, the app side:** parsing, Archive object creation and de-duplication,
  with request files in exactly the extension's format (automated tests, including
  `test/new_archive_test.dart`).
- The Swift code compiled once in the Codemagic cloud build.
- **Never run** on an iPhone, iPad or simulator. Nothing about the share sheet itself,
  the App Group, or the import on a device is verified.

## What is still needed (nothing here is set up yet)
1. **Apple Developer Program membership (paid, $99/year).** Free Apple IDs cannot use
   App Groups.
2. In the Apple Developer portal, register the App Group **`group.com.theapp.shared`**.
3. Turn on the **App Groups** capability, with that group, for all three App IDs:
   `com.amaterasu.theapp`, `com.amaterasu.theapp.widget`, `com.amaterasu.theapp.share`.
4. Provisioning profiles that include the group for all three (the `ios-signed`
   workflow in `codemagic.yaml` creates/fetches them once steps 1–3 are done).
5. Codemagic: an environment group **`theapp_signing`** containing
   `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`,
   `APP_STORE_CONNECT_PRIVATE_KEY` (contents of the `.p8` file) and
   `CERTIFICATE_PRIVATE_KEY` (an RSA private key, PEM). The signed workflow
   has never been run.
6. Install the **signed** build. The entitlement files already contain the group;
   do not change them unless you choose a different group id (then change it in
   `Runner.entitlements`, `TheAppWidget.entitlements`, `ShareExtension.entitlements`
   and the Swift files `AppDelegate.swift`, `TheAppWidget.swift`, `ShareViewController.swift`).

## What happens without it (the free route)
With the unsigned/ad-hoc IPA and a free Apple ID, the App Group does not exist at
runtime: `containerURL(forSecurityApplicationGroupIdentifier:)` is nil, the extension
shows "THEapp cannot receive shared items on this install (App Group missing)" and
saves nothing, and the app has no shared folder to read. Whether a sideloader keeps
the entitlements is not verified. Use the free iOS Shortcut route in `../README_IOS.md`.
