# THEapp — architecture notes

## Where data lives
Everything is local, in `%APPDATA%\THEapp` (Settings → "Open data folder"):

| Folder | Contents |
|---|---|
| `canvases\<id>.json` | One file per canvas: items, positions, sizes, styling, drawings, camera |
| `data\*.json` | Notes, folders, assets (links/photos), inbox, calendar entries, calendar days, tasks, projects |
| `attachments\` | Copies of photos and link preview images (never modified or deleted) |
| `backups\<time>-<reason>\` | Daily automatic snapshots (14 kept), manual ones, `pre-v2`, `before-restore` |
| `inbox_requests\` | Hand-off files from Explorer "Send to" launches |
| `sync\` | Device identity and deleted-canvas markers (for future sync) |
| `logs\app.log` | Local log of errors, recoveries, start and close (never sent anywhere) |

Safety rules:
- Only one THEapp window uses the data folder at a time; a second launch brings the
  open window forward and quits.
- A damaged file is renamed `*.corrupt-<time>` (never overwritten) and its `.bak` is
  restored; you're told once after start-up. Records this version can't read are kept
  and written back unchanged.
- Open editors (Notes, task details, calendar day note) follow changes made elsewhere,
  so they never write stale text back.

Every write goes to a temp file and is renamed into place; the previous version is
kept as `.bak` and used automatically if a file is damaged.

## One record, many views
Links and photos are `Asset` records stored once and referenced by id from canvas
cards, notes, calendar days and entries. Canvas note cards reference a `Note`.
Calendar grid labels are computed from `CalendarEntry` and `Task` records
(`Workspace.itemsOn`) — nothing is copied, so edits show up everywhere.

## Code layout
- `lib/data/` — models, `RecordCollection` (one JSON file per collection), `Workspace`
  (shared records + rules such as the five-active-entries limit), storage, backups.
- `lib/features/` — one folder per page plus `capture/` (clipboard, Quick Add,
  link previews, Send to) and `search/`, `settings/`.
- `lib/platform/windows_native.dart` — direct Windows calls (clipboard images, file
  picker, open URL) via `dart:ffi`, because Flutter plugins need Developer Mode.

## Testing
- **Manual testing never uses real data.** `tool/testenv.ps1` manages a separate
  environment in `Documents\THEapp\THEapp-TESTENV` (`app\`, `hub\`, `bin\`): `setup`,
  `build` (profile build copied to `bin\`), `hub-start` (port 47799, own folder),
  `hub-pair`, `hub-status`, `hub-stop`, `app`, `info`, `clean` (type DELETE). The test
  app is started with `--data-dir=<folder>` and only accepts a folder holding the
  `.theapp-test-data` marker and outside `%APPDATA%\THEapp` / `THEapp-hub`
  (`lib/app/test_environment.dart`). In that mode it shows a red TEST DATA banner,
  refuses to pair with port 47710 and leaves the Explorer "Send to" menu alone.
- `flutter test` runs everything that is safe to run anytime: data layer,
  migrations, backups, sync preparation, and end-to-end interaction tests
  (`test/interaction_test.dart`) that drive the real widgets with simulated mouse and
  keyboard, save to real files and restart the app.
- `test/windows_native_test.dart` checks the real Windows clipboard (copied pictures,
  copied files) and a real link preview. It changes your clipboard and uses the
  network, so it only runs when asked:
  `$env:THEAPP_NATIVE_TESTS='1'; flutter test test/windows_native_test.dart`

Not covered by automated tests — try these by hand:
- the Windows photo picker dialog itself (the code after it is tested);
- a link actually opening in your browser (the address handed to Windows is tested);
- Explorer's right-click "Send to → THEapp" (the hand-over and Inbox are tested);
- the date pickers and time pickers (Flutter's own dialogs);
- look and feel, and speed with very large canvases (thousands of items).

Known limitations: images can't be copied *out* to other apps yet; no drag-and-drop
from Explorer; no PDFs on the canvas; reminders don't notify; no version history;
records written by a newer app version keep unknown *records* but not unknown *fields*
inside a known record (needed before sync ships).

## Sync
Implemented: Windows hub, sync engine, optional read-only mirror. See
[SYNC_ARCHITECTURE.md](SYNC_ARCHITECTURE.md) for the protocol, conflict rules,
security, backups and commands.

## Platform-specific code
Pages never call operating-system APIs directly; they use `lib/platform/platform.dart`,
which picks `windows_native.dart` (dart:ffi, Windows) or `ios_bridge.dart` (method
channel "theapp/ios", Swift in `ios/Runner/AppDelegate.swift`). Elsewhere these calls
do nothing. Windows-only start-up steps (single-window guard, Explorer "Send to") run
only on Windows.

## iOS / iPad
Dart side implemented and tested on Windows with a simulated native channel; Swift side
written but **never compiled or run** (no Mac). Status, blockers and free test options:
[ios/README_IOS.md](ios/README_IOS.md).

## AI
Not implemented. Any future AI feature must only send content the user selects, after
explicit confirmation each time.
