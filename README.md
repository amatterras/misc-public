# misc.

A personal workspace for **notes, mindmaps, a calendar with tasks, and an Archive** of saved links and files. It runs on Windows and on iPad/iPhone, keeps everything on your own devices, and syncs through a hub that you run yourself. There is no account, no analytics and no cloud service unless you set one up.

The app is called **misc.** (always lowercase, with the period).

> **Honest status.** Almost everything is implemented and covered by automated tests on Windows. Most iPad/iPhone behaviour (Apple Pencil feel, the share extension, home-screen widgets, syncing across different networks) has **not** been verified on a physical device. Each section below says which is which. The per-feature evidence is in [`docs/FEATURE_MATRIX.md`](docs/FEATURE_MATRIX.md).

---

## Contents

1. [What it is](#what-it-is)
2. [The six pages](#the-six-pages)
3. [Feature details](#feature-details)
4. [Where your data lives](#where-your-data-lives)
5. [Sync and storage modes](#sync-and-storage-modes)
6. [Privacy and security](#privacy-and-security)
7. [Platform support and verification status](#platform-support-and-verification-status)
8. [Getting started (development)](#getting-started-development)
9. [Windows release build](#windows-release-build)
10. [iPad / iPhone build](#ipad--iphone-build)
11. [Testing](#testing)
12. [Project layout](#project-layout)
13. [Design system](#design-system)
14. [Naming (misc. vs THEapp)](#naming-misc-vs-theapp)
15. [Known limitations](#known-limitations)
16. [Documentation index](#documentation-index)

---

## What it is

misc. is a single workspace that replaces a handful of separate apps:

- a freeform **mindmap canvas** for thinking, with handwriting
- **notes** that can be typed pages, handwritten pages, or both
- a **calendar** that also holds tasks, habits, reading plans and events
- an **Archive** for links, photos and PDFs you want to keep
- a built-in **browser** window
- an optional, off-by-default **AI** helper

Design principles that shape everything else:

- **One record, many views.** A link, photo, task or note is stored once and *referenced* from wherever it appears (canvas card, note, calendar day). Nothing is copied, so an edit shows up everywhere and nothing is duplicated.
- **Offline first.** Every edit is saved to the device first. The hub is never the only copy.
- **Your hardware.** Sync goes through a hub on your own PC (or a server you deploy). Nothing is uploaded anywhere by default.
- **Never silently lose data.** Conflicts keep both versions, deletions are recoverable for 30 days, damaged files are quarantined rather than overwritten, and backups are checksummed.
- **Nothing automatic with AI.** AI is off by default; nothing is sent without an explicit Send, and proposed changes need approval.

## The six pages

The sidebar has exactly six entries. The app reopens on the page you last used.

| Page | Purpose |
|---|---|
| **Mindmap** | Infinite, zoomable canvas: text, images, note cards, links, freehand ink, connectors between items |
| **Notes** | Folders, tags, favourites; typed and handwritten pages on selectable paper templates |
| **Calendar** | Day-note calendar with tasks, habits, reading and events; a collapsible Tasks column |
| **Archive** | Library of saved links, photos and PDFs with categories, tags and folders |
| **Safari** | A built-in floating browser window |
| **AI** | Optional assistant (local Ollama or an OpenAI-compatible API key) |

There is no Home page, no separate Tracker page and no standalone Tasks page (tasks live inside Calendar).

## Feature details

### Mindmap (canvas)

- Infinite, pannable, zoomable workspace; positions, sizes, text and drawings persist.
- Separate Move/Select and Write/Draw modes so drawing, moving and erasing do not interfere.
- Text, images, saved links, note cards (which *reference* a Note rather than copy it) and **connectors** that follow moved items and are removed with their ends.
- Freehand ink with pen, highlighter, eraser (regional repaint), lasso, several pen sizes, round pen ends, optional shape clean-up (line, triangle, rectangle, ellipse; off by default) and three ink colours.
- Selection tools: group/ungroup, lock, tag with five chosen colours (dots plus minimap glow), recolour ink and text, rotate ink, copy or move a selection to a note or another mindmap.
- Reference overlays that sit behind the ink and cannot be selected.
- Links between mindmaps (`theapp://canvas/<id>`), reusable components, and named version snapshots that can be restored (and the restore undone).
- Undo/redo, a right-click canvas menu (with a **More** button for touch), and a minimap.
- Dot-grid background with adjustable opacity.

### Notes

- Nested folders, tags, favourites and links between notes; the five most recent notes appear under Notes in the sidebar.
- **Three paper templates only**: standard grid, larger grid, and a split page (2/5 grid + 3/5 dots), with spacing, line/dot colour, opacity and page colour settings.
- Typed and handwritten pages, with lazy handwriting pages so large notebooks stay fast.
- Version history for notes (including text replaced by sync), side-by-side comparison, restore, and recovery of deleted notes.
- Text-to-record conversion bar: turn a selection into a Task, Subtask, Project or Note with a preview and duplicate check; mentions of other notes offer a link rather than linking silently.
- Notes text zoom.
- Imports from Obsidian, Notion (Markdown), Apple Notes (HTML/TXT) and plain Markdown folders, keeping folders, tags, links and images; re-importing skips what is already there.
- Export a note as Markdown, page pictures or a read-only web page.

### Calendar and tasks

- One page replaces the old Calendar + Tracker. Sections: **Reading, Habits, Events, Other**. There is no "Projects" category and no time blocking.
- Views: **month, week, day, agenda, timeline**, plus a user-chosen range of up to **38 days** shown as large squares you can zoom and pan.
- Each day can hold notes, images, links and freehand drawings saved per date; calendar tools include lasso, text, photos and eraser width.
- At most **five active entries per category**; archive and restore. If sync pushes you over the limit you get a warning, never an automatic archive.
- **Reading**: books, progress, activity, notes and a reading-goal projection.
- **Habits**: one record with many dated occurrences and per-date check-offs, optional time of day.
- **Events**: single or multi-day, optional times.
- **Tasks**: projects, subtasks, deadlines, priorities, labels, custom properties, start dates, dependencies (gentle warnings, loops refused), recurring tasks (skip or move one occurrence without touching the series), reminders, a focus timer, exam dates and revision tasks. Views: list, Kanban board, sortable table, Gantt. Smart views include overdue, no date, high priority, waiting, and blocked (derived from dependencies). Bulk actions: complete, shift dates keeping intervals, label, priority, project, delete.
- Category and colour filters on the grid.
- Google Calendar and Outlook **import** (read-only provider events) and optional two-way sync for linked local entries. This is implemented and tested against fake providers; real OAuth and live account behaviour are **not verified**.
- Handwriting-to-calendar suggestions (Windows Ink / iOS Vision), always reviewed by you before a record is created. Not verified on this Windows host.
- Calendar archive entries expire after seven days (tombstones and a ledger prevent resurrection).

### Archive

- An object library of saved **links, photos and PDFs**, with link previews.
- Five canonical categories — Resource, Projects, Other, Shopping, Second-brain — plus custom coloured tags (at most 15, shared with the Mindmap).
- Filter by category and tag (all chosen labels must match), and by project.
- Shared links, dropped files and Explorer "Send to" captures land here.
- Advisory duplicate detection, in-app PDF rendering on Windows, and an archive viewer with copy/move.
- OCR-based search is deliberately not part of the product.

### Safari (browser)

A floating browser window with a compact mode, isolated from your data.

### AI (optional, off by default)

- Master switch plus per-source permissions, image permission and a context limit.
- The window shows **exactly what will be sent** before you press Send.
- Routes: a local **Ollama** model, or an **OpenAI-compatible API key**. A personal ChatGPT subscription is not API access and is not supported.
- Streaming, cancel, retry, regenerate, persistent history, user-written working rules.
- Tools: explain, summarize, outline, quiz, flashcards, brainstorm, follow-ups with `[n]` sources. Proposed tasks, mindmaps and links are applied only after you approve.
- Verified with fake providers only; no real provider was exercised in validation.

### Everywhere

- **Command palette** (`Ctrl+Shift+P`) and unified **search** (`Ctrl+K`) across notes, tasks, calendar, Archive and projects.
- **Quick capture** (Quick Add) and Windows Explorer **Send to → misc.**; requests are idempotent so a crash never creates duplicates.
- Drag-and-drop from File Explorer (photos and PDFs onto the canvas, `.md` files into Notes).
- **Floating windows**: reusable, draggable, resizable, remembered per device, and items can be dragged between them. Optional *Always on top* on Windows.
- Light, dark and system themes; a daily greeting (600 across six time-of-day pools) and an hourly quote (1,000) in the bars.
- Welcome guide, completion messages (understated, funny or silent).
- Exports: mindmap as picture or read-only web page, notes as Markdown, pictures or web page, and a whole-workspace `.theappbackup` file.
- Optional cross-device clipboard sharing (explicitly enabled).

## Where your data lives

Everything is local, in `%APPDATA%\THEapp` on Windows (Settings → *Open data folder*):

| Folder | Contents |
|---|---|
| `canvases\<id>.json` | One file per mindmap |
| `data\*.json` | Notes, folders, assets, calendar entries/days, tasks, projects |
| `attachments\` | Managed copies of photos, documents and link previews |
| `backups\<time>-<reason>\` | Daily (14 kept), weekly and manual snapshots, plus pre-migration and pre-restore safety copies |
| `migrations\` | Finished migrations, the open checkpoint, the last failure |
| `inbox_requests\` | Hand-off files from Explorer "Send to" |
| `sync\` | Device identity and deleted-mindmap markers |
| `calendar\` | Protected OAuth token files, if configured |
| `retention\` | Ledger preventing an expired Calendar archive from being restored |
| `logs\app.log` | Local log (never sent anywhere; tokens and keys are scrubbed) |

Safety rules:

- Every write goes to a temp file and is renamed into place; the previous version is kept as `.bak` and used automatically if a file is damaged.
- A damaged file is renamed `*.corrupt-<time>` (never overwritten), and you are told once at start-up.
- Records or fields this version cannot read are kept and written back unchanged, so an older build never destroys data written by a newer one.
- Open editors follow changes made elsewhere, so they never write stale text back.
- Versioned, checkpointed migrations run only after a verified backup; a failed upgrade leaves the app read-only with Retry/Restore. See [`docs/DATA_MIGRATIONS.md`](docs/DATA_MIGRATIONS.md).
- Deleted records stay recoverable for 30 days (Settings → Data safety → *Recently deleted*), compatibly with sync tombstones. Settings → Data safety also has a read-only integrity check.

## Sync and storage modes

Settings → **Storage** offers three modes behind one provider abstraction:

| | A. This device only | B. PC hub | C. Hosted service |
|---|---|---|---|
| Where data is | this device | this device + the hub folder on your PC (`%APPDATA%\THEapp-hub`) | this device + your server's account folder |
| Needs | nothing | the hub running on your PC; Tailscale for use away from home | a server you deploy (Docker, domain, ports 80/443) |
| Transport | — | Tailscale (WireGuard) or loopback; plain HTTP only on loopback/Tailscale, HTTPS with a pinned certificate elsewhere | HTTPS (Caddy + Let's Encrypt); the app refuses `http://` and bare IPs |
| Default | **yes** | after pairing | never |

How sync behaves:

- Edits save locally first; pending changes are durable and go out exactly once (idempotent operation ids), even across restarts.
- A long-poll wakes other devices within moments; unreachable hubs are retried with back-off, plus a periodic safety-net sync.
- **Conflicts**: the higher revision wins and the other version is kept whole as a conflict record you can review (Settings → Sync conflicts). A deletion never overwrites an edit.
- **Attachments** are content-addressed (SHA-256), uploaded before their record, verified on both ends, and retried whole if interrupted.
- **Pairing** uses a one-time code (10 minutes, single use, rate-limited). A revoked device is refused immediately, the workspace key rotates for the others, and the revoked device keeps its local copy.
- **Switching modes** is copy-and-verify: a verified backup is synced to the destination from a temporary folder, every record and attachment is read back and compared, and only then does the new mode become active. Cancelling at any step leaves the active mode unchanged, and misc. never deletes remote data.
- On Windows, the app runs the hub for you when the hub folder exists. The hub can also run standalone: `dart run bin/thehub.dart …`.

Full details: [`docs/SYNC_ARCHITECTURE.md`](docs/SYNC_ARCHITECTURE.md), [`docs/STORAGE_MODES.md`](docs/STORAGE_MODES.md), and the hosted deployment in [`deploy/hosted/`](deploy/hosted/README.md).

## Privacy and security

- **No telemetry.** The only dependencies are `ffi`, `crypto` and `pointycastle` (plus Flutter). There are no Flutter plugins; native calls go through `dart:ffi` on Windows and the app's own method channel on iOS.
- **At rest**: AES-256-GCM per file with a per-file HKDF key and random nonce. The workspace key is random and kept only in Windows DPAPI or the iOS Keychain, never beside the data. **There is no recovery password, so losing the key means losing the data**, and the app says so.
- **In sync**: records are end-to-end encrypted with per-device keys; the hub stores only SHA-256 hashes of device tokens, and admin endpoints need a separate admin token.
- **Hub network rules**: binds to loopback by default; additional addresses only in private or Tailscale ranges, never `0.0.0.0` or public.
- **Backups** are checksummed, tamper-detecting, and never include key files.
- **Logs** pass through one scrubber that removes tokens, keys, bearer headers and private URL paths.
- **Out of scope**: nothing defends against malware running as your own user. The app lock exists in code but is not armed by default.
- The hosted service does not encrypt data at rest on the server (use disk encryption); vault items stay end-to-end encrypted. No quotas, e-mail verification or password reset exist yet.

This is a self-review, not an independent audit; misc. is not "certified secure". See [`docs/SECURITY_AUDIT.md`](docs/SECURITY_AUDIT.md) for the threat model and findings.

## Platform support and verification status

| Area | Windows | iPad / iPhone |
|---|---|---|
| Core app (notes, canvas, calendar, Archive) | Implemented, widely tested | Implemented; shares the same code and data layer |
| Layout | Desktop/iPad shell | Separate iPhone layout (`lib/phone/`, `main_iphone.dart`); shell is chosen by device, never by width |
| PC hub sync (same network) | Verified in automated tests, incl. cross-process checks | Same engine; **not verified on a device** |
| Sync across different networks | Hub reachable via Tailscale in a trial; **never run end to end** | **Not verified** |
| Apple Pencil (pressure, prediction, squeeze, double-tap) | n/a | Implemented; **device-unverified** |
| Home-screen widgets, share extension | n/a | Implemented; Swift cloud-compiled in an earlier run only; **unverified** |
| Reminders while the app is closed | **No** (the app must be running) | Implemented; **unverified** |
| Native shell actions (Always on top, Send to, drag-and-drop) | Implemented; real-window behaviour partly manual | n/a |
| Hosted service | Code and Docker config exist; tested in-process without TLS; **not deployed** | n/a |

"Verified" here means an automated test or recorded check; a passing fake-provider or simulated-channel test is not real-service or real-hardware verification.

## Getting started (development)

**Requirements**

- Flutter (Dart SDK `^3.13.5`)
- Windows 11 with Visual Studio's C++ desktop workload to build the Windows app
- Developer Mode is **not** required (the project has no Flutter plugins)

```
flutter pub get
flutter analyze
flutter test -j 1
flutter run -d windows
```

Entry points (one codebase):

| File | Used for |
|---|---|
| `lib/main.dart` | Windows and iPad |
| `lib/main_iphone.dart` | iPhone |
| `bin/thehub.dart` | The sync hub (pure Dart, no Flutter) |

The hub can also run on its own from `bin/thehub.dart`; its commands (for example `hosted-serve` and `hosted-invite`) are described in [`docs/SYNC_ARCHITECTURE.md`](docs/SYNC_ARCHITECTURE.md) and [`deploy/hosted/README.md`](deploy/hosted/README.md).

## Windows release build

```
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1
```

The script checks Flutter and Visual Studio, runs `pub get`, `analyze` and `build windows --release`, then writes (git-ignored):

- `dist\windows\misc-windows-x64\` — portable app: `misc.exe`, Flutter and Visual C++ runtime DLLs, `data\`
- `dist\windows\misc-windows-x64.zip` — the same folder, zipped
- `dist\windows\misc-Setup.exe` — per-user installer (Windows IExpress, no admin rights): installs to `%LOCALAPPDATA%\Programs\misc`, adds a Start Menu shortcut, an optional desktop shortcut and a Settings → Apps entry. Upgrades replace only the program files; **uninstalling keeps `%APPDATA%\THEapp`**.

Options: `-SkipAnalyze`, `-RunTests` (slow), `-SkipInstaller`. Installer sources: `scripts\installer\install.ps1` and `uninstall.ps1`.

## iPad / iPhone build

iOS binaries cannot be compiled or signed on Windows. The repository builds them on a cloud macOS runner with Codemagic:

- `codemagic.yaml` defines `ios-unsigned` (produces an unsigned IPA) and `ios-signed` (needs Apple Developer credentials as Codemagic secrets — never commit them). There is also an iPhone workflow.
- An unsigned IPA must be signed before it installs; a free Apple ID with a sideloading tool works but expires periodically.
- The project has an iOS Runner, a home-screen widget and a share extension, with an App Group shared between them.
- iOS deployment target: 15.0.

Step by step: [`docs/IOS_BUILD_GUIDE.md`](docs/IOS_BUILD_GUIDE.md), [`ios/BUILD_WITHOUT_MAC.md`](ios/BUILD_WITHOUT_MAC.md), [`ios/README_IOS.md`](ios/README_IOS.md) and, for the iPhone layer, [`docs/PHONE_UI.md`](docs/PHONE_UI.md).

## Testing

**Manual testing never uses real data.** `tool\testenv.ps1` manages a separate environment under `Documents\THEapp\THEapp-TESTENV` (`app\`, `hub\`, `bin\`) with commands such as `setup`, `build`, `hub-start` (port 47799), `hub-pair`, `hub-status`, `hub-stop`, `app`, `info` and `clean`. The test app starts with `--data-dir=<folder>`, accepts only a folder holding a `.theapp-test-data` marker that is outside the real data folders, shows a red **TEST DATA** banner, and refuses to pair with the real hub port.

Automated tests (`test/`, ~140 files) run with `flutter test -j 1` and cover:

- the data layer, migrations, backups and integrity checks
- the sync engine, hub, attacks on the hub, conflicts, and end-to-end encryption
- storage-mode switching, hosted-service accounts (in-process)
- widget and end-to-end interaction tests that drive real widgets with simulated mouse, keyboard and touch, save real files and restart the app
- layout at eight screen sizes including phone and iPad
- ink engine geometry and benchmarks, calendar tools, Archive, search, and exports

A few tests are opt-in because they touch the real clipboard or network:

```
$env:THEAPP_NATIVE_TESTS='1'; flutter test test/windows_native_test.dart
```

Tools in `tool/` include cross-process hub checks (`remote_check.dart`, `hosted_check.dart`) and screen tests for the new and phone UIs.

Not covered by automated tests: the Windows photo-picker dialog, a link opening in your browser, Explorer's "Send to" menu, Flutter's own date/time pickers, look and feel, and speed with thousands of canvas items.

## Project layout

```
lib/
  main.dart, main_iphone.dart
  data/        models, record collections, Workspace, storage, backups, migrations, integrity
  sync/        sync engine, protocol, E2EE, storage modes, hub client, conflict merge
  hub/         hub server, store, backup, start-up (no Flutter imports)
  platform/    everything that talks to the OS: dart:ffi (Windows), method channel (iOS)
  app/         shell, AppState, navigation, start-up, page windows, design system
  features/    one folder per area: canvas, notes, calendar, tasks, library, ai, browser,
               capture, search, settings, export, import, ink, vault, …
  new_ui/      sidebar, page header, atmosphere, Archive pages, folder colours
  phone/       the iPhone layout over the same data
  widgets/     small shared widgets
bin/thehub.dart    standalone sync hub
deploy/hosted/     Dockerfile, Caddyfile, docker-compose for the hosted service
ios/               Runner, ShareExtension, TheAppWidget, shared Swift code
windows/           Windows runner (C++)
scripts/           Windows release build and installer
tool/              test-environment script and cross-process checks
docs/              reference documents (history/ holds dated audits)
test/              automated tests
```

Rules that hold today:

- `lib/data/`, `lib/sync/` and `lib/hub/` do not import Flutter widgets; the hub path imports no Flutter at all, so it compiles as a plain Dart server.
- Pages never call OS APIs directly; they go through `lib/platform/`.
- Navigation has one source (`lib/app/navigation.dart`) used by the sidebar, page bar, phone tabs and command palette.
- Windows/iPad and iPhone share data and logic; only layout differs.

Documented exceptions to the intended dependency order, and the size of `app_state.dart`, are listed in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Design system

One set of tokens, one name per token, all re-exported through `lib/app/theme.dart`:

- `palette.dart` — semantic colour roles (light and dark), brand colours and gradients, and the content palettes (inks, Calendar and Archive categories, canvas tags)
- `design_tokens.dart` — type, spacing, radii, sizes, strokes, elevation, blur, motion and interaction states
- `theme.dart` — builds the Material theme from both

Neutrals sit on a single hue and the atmosphere is painted once behind every page, so page roots must stay transparent. Don't reintroduce the old duplicate names (`Space`/`NewSpace`, `NewText`, and similar).

## Naming (misc. vs THEapp)

The product was renamed from THEapp to **misc.** This is a branding change only. These keep their original spelling on purpose so existing installs keep their data and keep working without reinstalling:

- the Flutter package and repository name (`flutter_application_1`, `THEapp`)
- the iOS bundle identifier, App Group and Keychain service name
- data folders (`%APPDATA%\THEapp`, `THEapp-hub`, `THEapp Backups`, `THEapp Exports`, `THEapp Downloads`), the log file name, and the encryption key labels
- hub protocol markers, the `theapp://` link scheme and the method-channel names
- the `.theappbackup` file extension
- the Windows executable in the build folder (`flutter_application_1.exe`); the release packages ship the same file renamed to `misc.exe`

Anything the user can read (window title, iOS home-screen name, permission prompts, settings, messages, the Send-to entry) says **misc.**

## Known limitations

- Physical iPad/iPhone behaviour, Apple Pencil feel, widgets, the share extension, and cross-network sync are unverified.
- Windows reminders need the app to be running.
- Google/Outlook calendar sync and the AI providers are tested against fakes, not live services.
- Windows Ink handwriting recognition returned an error code on the development host.
- The hosted service has not been deployed; Docker image, TLS and a real domain are untested. It has no quotas, e-mail verification or password reset.
- Interrupted attachment transfers retry whole; there is no byte-range resume.
- Rotation: ink rotates in 90° steps; text, images and cards do not rotate yet.
- A shared-Archive-asset's bytes remain after a Calendar record expires, by design.
- A single-instance/focus guard is intended but has not been proven reliable.
- Older builds on other devices can list some internal calendar-drawing documents as mindmaps; update every device together.
- `lib/app/app_state.dart` is very large; new logic should live in its feature folder.
- Explicitly **never** to be added: a separate Tracker page, a Projects category in Calendar, time blocking, productivity statistics or scoring, heavy theme customisation, two-way Apple Calendar sync, automatic AI processing, or more than three notebook templates.

## Documentation index

| Document | Covers |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Data layout, code layout, layering rules, testing |
| [`docs/FEATURE_MATRIX.md`](docs/FEATURE_MATRIX.md) | Every requirement with status and evidence |
| [`docs/SYNC_ARCHITECTURE.md`](docs/SYNC_ARCHITECTURE.md) | Sync protocol, conflicts, security, backups |
| [`docs/STORAGE_MODES.md`](docs/STORAGE_MODES.md) | Local / PC hub / hosted, and switching |
| [`docs/DATA_MIGRATIONS.md`](docs/DATA_MIGRATIONS.md) | Versioned migrations, backups, deletion |
| [`docs/LIBRARY_ARCHITECTURE.md`](docs/LIBRARY_ARCHITECTURE.md) | The Archive object library |
| [`docs/PHONE_UI.md`](docs/PHONE_UI.md) | The iPhone layer |
| [`docs/IOS_BUILD_GUIDE.md`](docs/IOS_BUILD_GUIDE.md) | Building the IPA with Codemagic |
| [`docs/SECURITY_AUDIT.md`](docs/SECURITY_AUDIT.md) | Threat model and findings |
