# misc. — the iPhone interface

Written 2026-11-04. One codebase, three interfaces. The iPhone has its own
layer in `lib/phone/`; Windows and iPad do not use it and were not redesigned.

## How it is separated

| Piece | What it does |
|---|---|
| `lib/phone/phone_profile.dart` | `PhoneProfile.active`: true in the iPhone build, or on a device that reports itself as an iPhone. Never decided by window width, so an iPad in Slide Over stays an iPad. |
| `lib/main_iphone.dart` | Entry point of the iPhone build. Sets `PhoneProfile.forced`, then runs the normal `main()` (same start-up, storage, encryption, sync). |
| `lib/phone/*` | Shell, screens, type scale and building blocks. Reads/writes the same `AppState` and `Workspace`; owns no data. |
| `codemagic.yaml` → `ios-iphone` | Builds `--target lib/main_iphone.dart`, sets `UIDeviceFamily` to iPhone only, packs `THEapp-iPhone-unsigned.ipa` and `THEapp-iPhone-with-widgets.ipa`. |

Shared files that gained an iPhone-only branch (all guarded by `PhoneProfile.active`, nothing changes elsewhere):
`app/shell.dart` (shows `PhoneShell`), `app/app_state.dart` (`interfaceVersion` is the New palette on an iPhone; the stored choice is kept), `features/settings/settings_dialog.dart` (no interface switch on iPhone), `features/canvas/canvas_page.dart` + `canvas_toolbar.dart` (tool strip along the bottom instead of the left edge; no minimap at start).

Removed (superseded, still in git history): `lib/new_ui/new_home.dart`, `lib/new_ui/new_phone_shell.dart`, `test/new_home_test.dart`. `home_agenda.dart` stays (it sorts a day; used by Today and Calendar).

## Design

Palette unchanged (graphite and steel blue; porcelain and iris in light; the periwinkle→coral gradient). What changed is how it is used:
no cards, no shadows; content sits on the page between hairlines; one left margin (20 pt); small-caps labels; a 36 pt headline per screen; a time column like a printed schedule; the gradient appears only where it means something (the "now" line, the day's progress).

- **Dock**: five words (Today, Notes, Calendar, Archive, Mindmap) and one solid "+" in the thumb zone. Hidden while the keyboard is up and on full-screen tools.
- **Today**: the date is the headline; a swipeable week; progress line; the day as a schedule with a "now" line, overdue first, past items folded. Tick on the right, long-press for edit/duplicate/reschedule/delete. Pull down to sync.
- **Notes**: search line, text tabs (All, Favourites, folders), each note = title, two lines, date. Long-press: favourite, move, delete (to Recently deleted).
- **Calendar**: month grid (chosen day is the one inverted numeral), the day's schedule under it, and a Tasks tab (overdue / today / later / no date).
- **Archive**: "Recently saved" strip, folders as an index with their own colour rule, a folder opens as a list; search across everything.
- **Mindmap**: the existing canvas under one slim bar naming the map (tap: switch, new, rename, trash).
- **+**: Note, Task, Event, Link or photo (the one for the current screen first), then Habit, Reading, Reminder, Mindmap. All open editors that already exist.
- **More (⋯)**: Safari, AI, Search, Commands, Settings, and the full desktop page of the current area (Notes in full, Calendar in full, Archive whole look) so nothing is lost.

## Verified / not verified

Verified on Windows (`flutter test test/phone_ui_test.dart`; renders in `screenshots/phone/`, made with Segoe UI, **not** SF Pro and **not** from a device): which devices get the interface; Windows/iPad never do; navigation; creating; ticking; opening notes/tasks requested from elsewhere; every place lays out at 375×667, 390×844, 430×932 and 844×390 in both themes.

**Not verified:** the iOS build itself (`ios-iphone` has never run), anything on a real iPhone (touch feel, safe areas on a notch, SF Pro metrics, Dynamic Island), widgets/share extension in this build, performance.

## Known limits (honest list)

- Task details, the event/habit/reading editors, Settings, search and the Archive item view are the existing screens (dialogs / forms) on a phone, not redesigned.
- The canvas is the shared one with a relocated tool strip; its internal overlays were not redesigned.
- Notes in full / Calendar in full / Archive whole look are the desktop pages, unchanged and not phone-optimised.

---

# The iPad interface (lib/ipad) — added 2026-11-04

Reuse first: nothing was rewritten. The shared pages (Notes, Calendar, Archive,
Mindmap, Safari, AI) are unchanged; the iPad gets a new frame and a Today page
built from the iPhone's pieces.

| Piece | What |
|---|---|
| `lib/ipad/ipad_profile.dart` | `IpadProfile.active`: only when the device itself says "iPad" (`DeviceIdiom.isIpad`), never by width or guess; never on iPhone or Windows. |
| `lib/ipad/ipad_shell.dart` | A 60 pt **rail of vertical words** (Today, Notes, Calendar, Archive, Mindmap, Safari, AI; read bottom to top) with search, settings and the solid "+" at the foot. Pages keep every other pixel. |
| `lib/ipad/ipad_today.dart` | Today in two columns: the iPhone's Today (reused) and a "Desk" of recent notes, saves and mindmaps (reuses `NoteRow`, `RecentTile`). |

- The "+" reuses the iPhone's New sheet (now at most 560 pt wide, centred).
- A window narrower than 640 pt (Slide Over, thin Split View) does not get the rail: it keeps the existing compact capsule.
- Like the iPhone, the iPad uses the New palette; the Original/New switch in Settings is hidden there (the stored choice is kept). Windows keeps the choice.
- Edits in shared files, all behind `IpadProfile`: `app/shell.dart`, `app/app_state.dart`, `features/settings/settings_dialog.dart`, `platform/device_idiom.dart`, `phone/phone_widgets.dart` (sheet width), `phone/phone_notes.dart` / `phone_archive.dart` (two widgets made public).
- Tests: `test/ipad_ui_test.dart`. Renders: `tool/ipad_screens_test.dart` → `screenshots/ipad/` (Windows renders, not an iPad).

**Not verified:** a real iPad (Pencil, Split View, Stage Manager), the iOS build. **Known limits:** the desktop-style page bar (new page / note buttons) above the shared pages is still there; Notes, Calendar, Archive and Mindmap are the existing pages with their existing look.
