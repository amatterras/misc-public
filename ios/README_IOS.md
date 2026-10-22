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
| Hub token in the Keychain | tested with a fake Keychain; failure never falls back to plain text | untested |
| `theapp://capture?url=…&text=…` links → Inbox | tested (also links that arrive before the app is ready) | `SceneDelegate.swift`, untested |
| Share Extension → Inbox | import tested with files in the extension's format | `ShareExtension/`, untested, **needs paid account** |
| Sync with the PC hub | same engine as Windows (tested) | network path from an iPhone untested |
| PDFs: pick (document picker) and open (Quick Look) | tested with a simulated channel; only `.pdf` passed on | `AppDelegate.swift`, untested; the "inside this app" path check may need adjusting for `/private/var` |
| Mind-map connections, version history | shared Dart code (tested on Windows) | — |
| Task reminders | in-app notice while the app is open (shared code) | no iOS notification when the app is closed (would need `UNUserNotificationCenter`; not written) |
| Channel contract | every Dart method has a Swift case and vice versa (checked by reading, 2026-10-22) | — |

## Free ways to capture from other apps
1. **iOS Shortcut (free account is enough):** in the Shortcuts app create
   "Save to THEapp", turn on *Show in Share Sheet* (URLs, Text), add the action
   *Open URLs* with `theapp://capture?url=` followed by *Shortcut Input*
   (choose "URL Encode" for the input). The app adds it to the Inbox. Any web
   page could open such a link too, so these links can only ever **add Inbox
   items** (text capped at 20,000 characters); they can't change settings,
   delete or pair.
2. **Share Extension (paid account only):** the files in `ShareExtension/` need
   the App Groups capability, which Apple only grants to the paid Developer
   Program ($99/year). Not required; the Shortcut covers links and text.

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
asks for local-network permission. **Untested.**

## Checklist for the first run on a Mac
1. `flutter build ios --debug --no-codesign` — fix any Swift compile errors.
2. Run in the Simulator: open a canvas, draw, rotate (portrait/landscape).
3. Settings → Sync hub → pair with the PC (simulator can reach the PC on the
   same network); confirm a note arrives both ways.
4. In Safari (simulator) open `theapp://capture?text=hello` → Inbox shows it.
5. Add a photo from the picker → it appears on the canvas.
6. On a real iPad: Apple Pencil drawing, palm resting on the screen, pinch.
