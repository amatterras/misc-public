# THEapp on iPhone and iPad — status

**Nothing in this file has run on an Apple device or been compiled.** All work was
done on Windows. "Tested" below means automated tests on Windows, with the
iOS native side *simulated*.

## What is the same on every platform
The whole app (canvas, notes, tasks, calendar, Inbox, search, backups, sync
engine) is shared Dart code. Data is stored as JSON files in
`Library/Application Support/THEapp` on iOS (`lib/data/storage/json_file_store.dart`),
so everything works offline. Unsent changes are simply records whose revision
differs from what the hub last confirmed, saved on disk, so they survive the app
being closed and are sent on the next sync (`test/sync_engine_test.dart`,
"changes made offline survive an app restart").

## Status by feature

| Feature | Dart side | Native (Swift) side |
|---|---|---|
| Phone layout (< 640 px wide): top bar + bottom tabs | tested at 390×844 and 844×390 (layout test) | — |
| iPad layout (sidebar layout) | tested at 820×1180 and 1180×820 | — |
| Touch: pinch to zoom/pan, palm rejection while the pen is down | tested with simulated touches | — |
| Pen, highlighter, eraser, lasso, undo/redo, pressure | tested with simulated pointer events | Apple Pencil itself **never tested** |
| Pencil tilt, hover, double-tap | **not implemented** | — |
| Opening web links | `lib/platform/ios_bridge.dart`, tested (only http/https/mailto) | `AppDelegate.swift`, untested |
| Photo picker (PHPicker, saved as JPEG) | tested with simulated results | untested |
| Hub token in the Keychain | tested with a fake Keychain; failure never falls back to plain text, and pairing reports it instead of hanging | untested |
| Device id kept in the Keychain ("this device only"): a backup restored onto another iPad gets a new id and asks to pair again | tested with a fake Keychain (`test/ios_readiness_test.dart`) | untested |
| Pairing form on iPhone/iPad: empty address with a Tailscale hint; 127.0.0.1 refused (it is the iPad itself) | tested | — |
| Device name on the hub ("iPad" instead of "localhost") | tested | `deviceModel` in `AppDelegate.swift`, untested |
| Sync when the app returns to the front (timers stop in the background) | tested | — |
| Picker copies in tmp deleted after import | tested | — |
| `theapp://capture?url=…&text=…` links → Archive | tested (also links that arrive before the app is ready) | `SceneDelegate.swift`, untested |
| Share Extension → Archive | app-side import tested on Windows with request files in the extension's format | `ShareExtension/` has **never run on a device or simulator**; needs a paid Apple account (see below) |
| Sync with the PC hub | same engine as Windows (tested) | network path from an iPhone untested |
| PDFs: pick (document picker) and open (Quick Look) | tested with a simulated channel; only `.pdf` passed on | `AppDelegate.swift`, untested; the "inside this app" path check may need adjusting for `/private/var` |
| Mind-map connections, version history | shared Dart code (tested on Windows) | — |
| Task reminders | in-app notice while open; next 60 upcoming reminders handed to iOS when they change (tested with a simulated channel) | `scheduleReminders` in `AppDelegate.swift` (`UNUserNotificationCenter`, local only), untested |
| Channel contract | every Dart call has a Swift `case` and back, checked by a test that reads both files (`test/ipad_touch_test.dart`) | — |
| Touch-only use: press and hold for menus, canvas "Move to trash" in its title menu, 44 px resize target, double-tap tolerance, "tap" wording, no Windows-only settings | tested with simulated touch and `TargetPlatform.iOS` | — |

## Free ways to capture from other apps
1. **iOS Shortcut (free account is enough):** in the Shortcuts app create
   "Save to THEapp", turn on *Show in Share Sheet* (URLs, Text), add the action
   *Open URLs* with `theapp://capture?url=` followed by *Shortcut Input*
   (choose "URL Encode" for the input). The app saves it in the Archive
   (the Inbox only when there is no Archive library). Any web page could open
   such a link too, so these links can only ever **add Archive items** (text
   capped at 20,000 characters); they can't change settings, delete or pair.
2. **Share to the Links library (free):** make a second Shortcut, "Save to
   THEapp Links", the same way but with
   `theapp://capture?to=links&url=` followed by the URL-encoded *Shortcut
   Input*. The link goes straight onto the Links board as a card (tags can
   be added with `&tags=resource,projects`; ids: resource, projects, other,
   shopping, second-brain). It only ever adds a card or tags; nothing is
   deleted. Same Dart code as tested on Windows; not yet run on a device.
3. **Share Extension (paid account only):** the target already exists in the
   Xcode project (`com.amaterasu.theapp.share`, embedded in Runner), but it
   needs the App Groups capability, which Apple only grants to the paid
   Developer Program ($99/year). Requirements and status are in
   `ShareExtension/README.md`. Not required; the Shortcut covers links and text.

## What needs a Mac (cannot be done on Windows)
- Any iOS build: `flutter build ios` needs macOS with Xcode (free).
- Fixing compile errors in the Swift files. Likely spots, if any:
  the `override` keywords in `SceneDelegate.swift` (remove them and the `super`
  calls if Xcode says they override nothing) and the
  `FlutterImplicitEngineBridge` registrar call in `AppDelegate.swift`.
- Adding the Share Extension target in Xcode (File → New → Target → Share
  Extension, then use the files in `ShareExtension/`).

## Free testing options and their limits
| Option | Cost | Limits |
|---|---|---|
| Borrowed or own Mac + Xcode + iOS Simulator | free | no Apple Pencil, no real camera roll; good for layout, links, Keychain |
| Mac + free Apple ID ("Personal Team") on your own iPhone/iPad | free | app must be reinstalled every 7 days; no App Groups (so no Share Extension); Shortcut route works |
| GitHub Actions macOS runner, `flutter build ios --no-codesign` | free on public repositories, limited free minutes on private ones | only checks that it compiles; uploads the code to GitHub (your decision; not set up) |
| Paid Apple Developer Program | $99/year | **not used**; needed only for App Groups / TestFlight / App Store |

## Reaching the hub from an iPhone
Install the free Tailscale app on the PC and the iPhone, start the hub with
`serve --private-host <PC's Tailscale address>`, and pair in THEapp →
Settings → Sync hub with `http://<that address>:47710`. Traffic is encrypted by
Tailscale. `NSLocalNetworkUsageDescription` is set in `Info.plist` in case iOS
asks for local-network permission. The app talks to the hub with Dart's own
HTTP client, which does not go through App Transport Security, so no ATS
exception is needed for `http://`. On iPhone/iPad the pairing form starts
empty and refuses 127.0.0.1 (that would be the iPad itself). **Untested on a
device.**

## Checklist for the first run on a Mac
Without a Mac: [BUILD_WITHOUT_MAC.md](BUILD_WITHOUT_MAC.md) builds the app in
the cloud (Codemagic, free tier) and installs it from Windows with a free Apple
ID; steps 3 and 4 below then need the iPad instead of the Simulator. With a Mac:
1. `flutter build ios --debug --no-codesign` — fix any Swift compile errors.
2. Signing (free Apple ID, "Personal Team"): the bundle id is
   `com.amaterasu.theapp`; if Apple says it is taken, change it in Xcode →
   Runner → Signing to one of your own.
3. Run in the Simulator: open a canvas, draw, rotate (portrait/landscape),
   Split View on iPad.
4. Sync — **TEST hub only** (port 47799, `tool\testenv.ps1 hub-start
   -PrivateHost <PC's Tailscale address>`), never the real hub on 47710:
   Settings → Sync hub → `http://<PC's Tailscale address>:47799` + code from
   `tool\testenv.ps1 hub-pair`; create a synthetic note on each side and
   confirm it arrives both ways. Check the hub lists the device as "iPad".
   For the cross-network result, the iPad must be on another network (e.g.
   a phone's hotspot) and Tailscale must not show a 192.168.x.x path.
5. Send the app to the background for more than 20 s, edit on the PC test
   copy, bring the app back → the change arrives without waiting a minute.
6. In Safari (simulator) open `theapp://capture?text=hello` → Inbox shows it.
7. Add a photo and a PDF from the pickers → they appear; open the PDF
   (Quick Look). If it does not open, check the `/private/var` path prefix in
   `openDocument` (`AppDelegate.swift`).
8. Disconnect in Settings → the Keychain entry `THEapp.hub.token` is gone
   (pairing again works).
9. On a real iPad: Apple Pencil drawing, palm resting on the screen, pinch;
   without a keyboard: press and hold a canvas / project for its menu,
   double-tap to write, drag the resize handle with a finger, move a canvas
   to trash from its title menu.
9a. Reminders: give a synthetic task a reminder 2 minutes ahead, allow
   notifications when asked, close THEapp → the notification appears; mark
   the task done → no notification.
10. Share Extension (paid account only): follow "What is still needed" in
    `ShareExtension/README.md` (App Group, three App IDs, profiles, Codemagic
    signing variables). The target is already in the project. Then share a
    link, a text, a photo and a PDF from other apps and check they appear in
    the Archive. Until this is done the extension is **not verified**.

## Home-screen widgets (Today & Tomorrow)
- Source: `ios/TheAppWidget/` (WidgetKit, SwiftUI; small, medium and large;
  follows light and dark mode). THEapp writes `widget_snapshot.json` into the
  App Group folder `group.com.theapp.shared` whenever tasks or the calendar
  change, and at midnight. The widget only reads it: the snapshot is derived
  display data, never a source of truth, so it can't change your tasks.
- Tapping an item opens it (`theapp://open?task=…`, `theapp://open?day=…`).
  More items than fit show as "+N more".
- The cloud build makes two files. `THEapp-unsigned.ipa` is the same as
  before, without the widget. `THEapp-with-widgets.ipa` contains the widget
  extension. It is ad-hoc signed (no certificate) only so that the App Group
  entitlement is inside it.
- Free Apple ID: the widget needs an App Group shared by the app and the
  widget. Whether your sideloader (iLoader) keeps or registers App Groups
  with a free account is NOT verified. If it doesn't, the widget installs but
  shows "Open THEapp once…" and nothing else breaks. The extension also uses
  one more of the free account's 10 App IDs per week.
- STATUS: Dart side tested on Windows (snapshot, deep links, simulated
  channel). The Swift compiles in the cloud build. Nothing has been seen on a
  device.
- Face ID lock, privacy cover and file protection (`AppDelegate.swift`,
  `SceneDelegate.swift`, `Runner.entitlements`): Dart side tested with
  simulated channels. The Swift has NOT been compiled or run, and whether a
  free Apple ID signs the `default-data-protection` entitlement is NOT
  verified. If signing refuses it, remove that key; the explicit
  `protectPaths`/`protectTree` calls still apply the protection.
