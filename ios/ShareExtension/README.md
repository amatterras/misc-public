# iOS Share Extension — implemented, NOT verified on a device

"Add to THEapp" in the iPhone/iPad share sheet. The extension stages durable
import requests in the App Group. When THEapp next opens, its existing import
pipeline creates Archive records and queues them for normal synchronization.

## What exists (code)
- `ShareViewController.swift`: native SwiftUI review popup; reads URL, text,
  image, video and supported file representations, previews each item, requires
  exactly one existing Archive category tag, then stages request JSON atomically
  under `inbox_requests/` and original file bytes under `inbox_files/`. Filename
  and UTI are carried through as Archive metadata.
- THEapp publishes the canonical tag catalog from `LinkTag` to the App Group.
  Rotating messages are empty until supplied; add them to `THEappShareMessages`
  in `Info.plist` or a shared `share_messages.json` file.
- `Info.plist`: activation rules include URLs, text, images, media, content and
  files.
- `ShareExtension.entitlements`: declares the App Group.
- The Xcode project already contains the `ShareExtension` target
  (`com.amaterasu.theapp.share`), embedded in Runner. Nothing has to be added by hand.
- App side (Dart): when misc. starts or returns to the front it reads the request
  files (`AppState.importSharedItems` → `SendToBridge.processRequests` →
  `CaptureService.captureToArchive`) and saves Archive objects: a link becomes a
  website item, text a note, a photo/PDF an image/document item. Repeats add no duplicate.

## What has been verified
- Dart importer/Archive tests run on Windows, including selected tag and URL/title
  preservation.
- The native extension, App Group entitlement signing and share-sheet behavior
  have not been compiled or run in this session; `xcodebuild` is unavailable on
  this Windows machine.

## What is still needed (nothing here is set up yet)
1. **For the route that always works: Apple Developer Program membership (paid, $99/year).** Free Apple IDs cannot use
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

## The App Group name depends on how the install was signed (2026-11-05)
The project declares `group.com.theapp.shared` in all three `.entitlements`
files, and that is the group a build signed with the Developer Program has
(`ios-signed`). A free-Apple-ID sideloader does **not** keep it. Read from the
source of `isideload` 0.3.7 (the signing library inside iLoader): it ignores the
group in the IPA, registers `group.<new bundle id>.<team id>` instead (the bundle
id also gets `.<team id>` appended) and signs the app and its extensions with
that. The Swift code used to ask for the fixed name, the system answered "no
such group", and the extension showed "App Group missing" although the install
did have an App Group.

Fix: `ios/Shared/AppGroup.swift` is compiled into Runner, ShareExtension and
TheAppWidget. It asks the system, in a fixed order, for the declared name, the
names a sideloader wrote into `Info.plist` (`ALTAppGroups`), the groups in the
embedded provisioning profile, `group.<host bundle id>` and the declared name
plus the team id, and uses the first the system accepts (the system returns
nothing for a group the signature does not grant). All three targets run the
same code, so they agree on one folder. If none is accepted nothing is faked:
the extension still says "App Group missing" and now lists the names it asked
for; the app writes the same line to its log ("Share inbox: ...").

The cloud build now fails if the App Group entitlement is missing from, or
differs between, the app and either extension in the packed IPA, and if the
resolver is not in all three binaries (`codemagic.yaml`, step "Verify the App
Group ...").

**Still not verified (needs a device):** that iLoader's signature really grants
the group to the *extension* (isideload embeds a provisioning profile only in
the main app, and the same entitlements are used for all bundles; iOS may refuse
an extension whose profile is missing). If the sheet still says "App Group
missing" after this fix, the line under it shows which names were asked for and
whether the host has a profile; send it. The route that always works is the
`ios-signed` workflow (paid Developer Program).

## What happens when no sideloader route grants a group
The extension shows "misc. cannot receive shared items on this install (App Group
missing)" with the names it asked for, and saves nothing; the app has no shared
folder to read. The free iOS Shortcut route in `../README_IOS.md` still works.
