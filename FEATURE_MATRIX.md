# THEapp feature matrix

Source of requirements: the original project brief (2026-10-21, quoted in
section numbers below) and `MASTER_SPEC.md`. Code existing is never enough:
"Verified" needs a passing test or a recorded real-binary check.

Status: VERIFIED = implemented and verified · UNVERIFIED = implemented but
not verified · PARTIAL · MISSING · BLOCKED · EXCLUDED.
Platform: W = Windows, i = iPhone/iPad. Priority: P1 (core) … P3 (later).

## 1. Design and navigation
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| Dark, minimal design; collapsible right sidebar | P1 | W | VERIFIED | `lib/app/shell.dart`, `sidebar.dart`; `widget_test` "every page opens from the sidebar"; `spec_coverage_test` sidebar persistence | click-through on real binary not automated |
| Navigation (2026-10-23): sidebar has exactly Mind map, Notes, Calendar, Archive; Home opens from the THEapp/sun button; Tasks is a collapsible ~3/5 column inside Calendar (replaces the calendar below 900 px); 5 most recent notes under Notes; last page restored at start | P1 | W,i | VERIFIED (widget tests) | `sidebar.dart` `appDestinations`, `calendar_page.dart`; `widget_test`, `layout_test` (8 sizes incl. phone/iPad) | real-binary and iPad click-through |
| Home: today's tasks, priorities, upcoming deadlines, quick capture, recent/favorite notes | P1 | W | VERIFIED (screenshot of real binary on test data + widget tests) | `lib/features/home/home_page.dart` | |
| Canonical global, Archive/Links, Calendar and ink palettes; backed-up legacy color migration | P1 | W,i | PARTIAL | `canonical_color_migration_test`, `phase3_test` (selected-tag highlight callback); see `MASTER_SPEC.md` | Lasso tags (dots + minimap glow) implemented in Phase 3; project custom colors await an approved palette |

## 2. Canvas (highest priority)
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| Infinite, zoomable, pannable workspace | P1 | W | VERIFIED | `canvas_features_test` "world is effectively unbounded", `canvas_edge_test` viewport | |
| Create/edit text anywhere; move; resize | P1 | W | VERIFIED | `canvas_controller_test`, `interaction_test`, `canvas_edge_test` | |
| Mouse selection, panning, zooming, freehand drawing | P1 | W | VERIFIED | `canvas_controller_test`, `interaction_test` | |
| Separate Move/Select and Write/Draw modes | P1 | W | VERIFIED | `interaction_test` "drawing, moving and erasing do not interfere" | |
| Undo/redo | P1 | W | VERIFIED | `interaction_test`, `canvas_edge_test` | |
| Images | P1 | W | VERIFIED | `interaction_test` photos survive restarts | |
| PDFs ("where practical") | P2 | W | PARTIAL: PDF cards on the canvas and in notes, stored/synced like photos, open in the default viewer — VERIFIED (`documents_test`, `sync_engine_test` PDF arrives); pages are not drawn inside THEapp | in-app rendering needs a plugin (Developer Mode off) |
| Saved links and web previews ("where practical") | P2 | W | VERIFIED (title preview) | `canvas_features_test`, `workspace_test` link preview parsing | |
| Mind maps / connections between notes on the canvas | P1 | W | VERIFIED | `ConnectorItem` (references, not copies), Connect tool (C); `canvas_connector_test` (create/undo, refusals, follows moves, delete cascade, copy remap, persistence, hidden when an end is missing) | real-binary click-through |
| Persistence of positions, sizes, text, drawings | P1 | W | VERIFIED | `canvas_controller_test` JSON round trip; real binary restart check | |
| Nested folders, tags, favorites shared across Canvas and Notes | P1 | W | VERIFIED | `workspace_test` nested folders; canvases have `folderId` | |
| Input architecture for touch/Pencil (pen, highlighter, eraser, lasso, palm rejection) | P2 | i | UNVERIFIED | `audit_regressions_test` (simulated touch/stylus) | needs iPad + Pencil |

## 3. Notes and organization
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| Editable notes; nested folders; tags; favorites; linked notes | P1 | W | VERIFIED | `workspace_test` "notes, tags, favourites and links persist", folders test | |
| Search across the app (PDF text is not searched, and says so), incl. note-page text, Archive board, link tags, projects; a link result opens its card in Archive | P1 | W | VERIFIED | `phase5_test`, `spec_coverage_test`, `interaction_test` Ctrl+K | |
| Quick capture; Send-to requests are idempotent (no duplicate after a crash) | P1 | W | VERIFIED | `phase5_test`, `interaction_test`, `widget_test` Quick Add | |
| Images and URLs in notes | P1 | W | VERIFIED | `workspace_test`, capture tests | |
| PDFs in notes ("where practical") | P2 | W,i | PARTIAL: import into a note or as a note, write on pages, export annotated copy (iOS, PDFKit; Swift unverified); Windows: attach + open | `phase2_test` (coordinates, pages, bridge simulated) | iPad run |
| Canvas objects reference notes, no duplicates | P1 | W | VERIFIED | `NoteCardItem.noteId`; `interaction_test` filing reuses records | |

## 4. Calendar (Calendar + Tracker merged)
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| One page; sections Reading, Habits, Events, Other; no Projects | P1 | W | VERIFIED | `widget_test` (no "Projects"), `calendar_page.dart` | |
| User-chosen range up to 38 days | P1 | W | VERIFIED | `spec_coverage_test` 38-day limit | |
| Large squares, zoom and pan, weekday top-right, date top-left, labels bottom-left | P1 | W | VERIFIED | `spec_coverage_test` cell positions; `interaction_test` wheel zoom | |
| Days hold notes, images, links | P1 | W | VERIFIED | `workspace_test` day notes and attachments | |
| Sections and grid share records; no duplicates | P1 | W | VERIFIED | `workspace_test` grid and category views same record | |
| Max 5 active per category; archive/restore | P1 | W | VERIFIED | `workspace_test`, `widget_test` sixth refused | |
| Over-limit after sync → warning, never auto-archive | P1 | W | VERIFIED | `widget_test` over-limit warning | |
| Name, description, color, dates, optional times/duration, notes, attachments | P1 | W | VERIFIED (data) | `calendar_models.dart`, `workspace_test` | |
| Four canonical Calendar category colors | P1 | W | VERIFIED for category mapping, migration test | `CalendarCategoryColors`; `canonical_color_migration_test` | Manual swatch/contrast check on Windows |
| Reading: books, progress, activity, notes, highlights | P1 | W | VERIFIED (data) | `workspace_test` reading logs | |
| Habits: one record, many dated occurrences, check-offs | P1 | W | VERIFIED | `workspace_test` habit occurrences | |
| Events: single/multi-day, optional times | P1 | W | VERIFIED | `workspace_test` drag keeps length | |
| Category navigation and quick add | P1 | W | VERIFIED | `widget_test` (category tab, sixth entry refused), `interaction_test` (Quick Add task on Calendar) | |
| Category and colour filters on the grid | P1 | W | UNVERIFIED | `calendar_page.dart` (`_shown`, `_colors`) | no automated test yet; check by hand |

## 5. Tasks and study planning
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| Tasks, projects, subtasks, deadlines, priorities, completion | P1 | W | VERIFIED | `spec_coverage_test`, `workspace_test` | |
| Reminders | P1 | W,i | VERIFIED in-app (notice + taskbar flash while running; missed ones at next start; follow recurring tasks). iOS notifications while closed: IMPLEMENTED BUT UNVERIFIED (Dart tested with simulated channel; Swift uncompiled) | `Task.remindBefore`, `reminders_test`, `ipad_touch_test` | no Windows notification while THEapp is closed (needs a background process); iOS needs a Mac build |
| Recurring tasks | P1 | W | VERIFIED | `workspace_test` recurring task moves | |
| Subjects, revision tasks, exam dates, preparation materials (same task system) | P1 | W | VERIFIED (data) | `spec_coverage_test` exams/subtasks | |
| Deadlines on Calendar as the original task record | P1 | W | VERIFIED | `workspace_test`, `interaction_test` | |
| Focus timer | P1 | W | VERIFIED | `spec_coverage_test` focus timer | |
| Version history (Milestone 5) | P2 | W | VERIFIED for notes (kept on each device, incl. text replaced by sync; restore; deleted notes) | `version_history_test` | not synced between devices (hub collection list); canvases use undo + backups |

## 6. Storage, sync, privacy
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| Local save and restore | P1 | W | VERIFIED | many tests; real binary restart | |
| Automatic backups, recovery | P1 | W | VERIFIED | `workspace_test`, `json_file_store_test`, real-binary recovery | |
| Safe attachment storage | P1 | W | VERIFIED | content-addressed, SHA-256 checks (`hub_test`, sync tests) | |
| PC hub, offline editing, automatic sync, conflicts (local network) | P1 | W | VERIFIED | `sync_engine_test`, `sync_risks_test`, 11 cross-process checks | |
| Sync across different networks (remote) | P1 | W,i | BLOCKED (no second device that runs THEapp; only an iPad, no iOS build). Done so far: test hub reachable and access-controlled through the PC's Tailscale address (11/11 `remote_check` on this PC; an iPad in the tailnet reached it, but on the same home network); never run across networks; THEapp sync from another device not run | `SYNC_ARCHITECTURE.md` §17; `tool/remote_check.dart`; `remote_readiness_test` | a second device that runs THEapp (second Windows PC/laptop, or a Mac-built iOS app), signed in to the same tailnet, on another network; Windows Firewall approval (Private only) |
| Device revocation and re-pairing | P1 | W | VERIFIED | `remote_sync_test`: revoked token refused (push/pull/attachments); device stops retrying, keeps edits, sends them after pairing again | |
| Encrypted transport | P1 | W,i | PARTIAL | Tailscale (WireGuard) by design, untested here; home-network addresses unencrypted — warning before pairing (`remote_sync_test`) | Tailscale |
| Test copies can't reach real hubs | P1 | W | VERIFIED | test mode pairs only with 127.0.0.1:47799 (`test_environment_test`) | |
| Security of tokens (DPAPI / Keychain) | P1 | W,i | VERIFIED (W) / IMPLEMENTED BUT UNVERIFIED (i: Keychain, this device only; removed on Disconnect) | `secret_store.dart`, `ios_bridge_test`, `ios_readiness_test` | iOS device |
| Read-only mirror (Pi optional) | P3 | W | VERIFIED with local folders | `hub_mirror_test` | no Pi |
| AI: none automatic | — | — | EXCLUDED until approved | — | |

## 7. iPhone/iPad
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| iOS build (compile) | P2 | i | VERIFIED (2026-10-23): Codemagic cloud build of `371c6ca`, Release, no code signing; Swift and Dart compiled without errors; `Runner.app` 18.6 MB, `THEapp-unsigned.ipa` 7.52 MB | `codemagic.yaml`, `ios/BUILD_WITHOUT_MAC.md` | — |
| iOS install and run | P2 | i | NOT VERIFIED: not yet signed or installed | `ios/BUILD_WITHOUT_MAC.md` | Sideloadly + free Apple ID on Windows; the iPad |
| iOS data folder (`Library/Application Support/THEapp`) | P1 | i | IMPLEMENTED BUT UNVERIFIED | `json_file_store.dart` `defaultDataDirectory` | iOS device |
| iOS device identity after a restored backup (Keychain-bound id; restored copy gets a new id and asks to pair again) | P1 | i | IMPLEMENTED BUT UNVERIFIED (Dart logic tested with a simulated Keychain) | `ios_readiness_test` | iOS device |
| iOS pairing: no 127.0.0.1 default, Tailscale address hint, clear refusal of loopback, key-store failure reported | P1 | i | IMPLEMENTED BUT UNVERIFIED (tested on Windows with simulated channel) | `ios_readiness_test` | iOS device + second network |
| Sync when the app returns to the front | P1 | W,i | VERIFIED (W, in tests) / UNVERIFIED (i) | `ios_readiness_test` | iOS device |
| `theapp://capture` links (Shortcut) | P2 | i | IMPLEMENTED BUT UNVERIFIED (Dart tested with simulated channel; Swift uncompiled) | `ios_bridge_test` | Mac |
| Photo / PDF pickers (copies removed after import) | P2 | i | IMPLEMENTED BUT UNVERIFIED (Dart tested; Swift uncompiled) | `ios_bridge_test`, `ios_readiness_test` | Mac |
| Share-menu link capture | P2 | i | PARTIAL (Dart side tested with simulated channel, shared text capped; Swift uncompiled; extension target not in the Xcode project) | `ios_bridge_test`, `ios_readiness_test` | Mac; Share Extension needs paid account (App Groups) |
| Apple Pencil (pressure, low-latency live layer, prediction, squeeze to erase, hold to straighten) | P2 | i | IMPLEMENTED BUT UNVERIFIED (logic tested; feel needs a device) | `phase2_test` | iPad + Pencil (Pro for squeeze) |
| Notes as full pages with lazy handwriting pages | P1 | W,i | VERIFIED (logic, widget tests) | `phase2_test`, `widget_test`, `version_history_test` | |
| Links library: board of link cards (preview, title, tags), Pencil ink on the board, filter by tag | P1 | W,i | VERIFIED (logic, widget tests incl. phone width); iPad not run | `phase3_test` | |
| Link tags Resource/Projects/Other/Shopping/Second-brain with canonical colors, synced and selected-tag minimap glow | P1 | W,i | PARTIAL: tag-color persistence and selection highlighting tested; minimap visual check pending | `phase3_test` | manual minimap check |
| Share a link into Links (Quick Add, paste, `theapp://capture?to=links` Shortcut) | P1 | W,i | VERIFIED on Windows; iOS Shortcut path UNVERIFIED | `phase3_test`, `widget_test` | iPad |
| Home-screen widgets: today + tomorrow tasks and events, +N more, deep links, light/dark | P2 | i | IMPLEMENTED BUT UNVERIFIED (snapshot and deep links tested; Swift cloud-compiled only; App Group with free signing unknown) | `phase3_test` | iPad; App Group via sideloader |
| Touch-only use (no mouse/keyboard): every menu reachable by press and hold, canvas trash in the title menu, 44 px resize target, double-tap tolerance, touch wording | P1 | i | VERIFIED in simulated touch tests / NOT VERIFIED on an iPad | `ipad_touch_test` | iPad |
| Dart ↔ Swift channel contract | P1 | i | VERIFIED by source check (every Dart call has a Swift case and back); Swift not compiled | `ipad_touch_test` | Mac |
| iOS sync compatibility (same Dart engine and protocol v1 as Windows) | P1 | i | IMPLEMENTED BUT UNVERIFIED on iOS | `sync_engine_test`, `ios_readiness_test` | Mac build + device |

## Motivation and manual verification
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| 600 greetings in six local-time pools; 60-second window; refresh on resume/timezone/date changes | P1 | W,i | VERIFIED by deterministic tests; no real-device test | `motivation_test`, `widget_test`; scheduling rules in `MASTER_SPEC.md` | Windows/iOS manual clock-change checks |
| 1,000 quotes rotate hourly using local time and appear in main bars | P1 | W,i | VERIFIED by injected-clock and widget tests | `motivation_test`, `widget_test` | physical-device check |
| Canonical color migration and the four independent semantic palettes | P1 | W,i | VERIFIED by synthetic tests and analyzer | `canonical_color_migration_test`; `MASTER_SPEC.md` | project colors pending palette decision |
| Windows manual checks for colors, greeting/quote behavior, restart and sync | P1 | W | NOT RUN | perform only with a disposable profile/data directory | no manual run recorded |

## Five-phase roadmap (implemented 2026-10-23 by Claude, Phases 1–4)
"VERIFIED" = automated tests on Windows with synthetic data in temp
folders. Nothing below was clicked through in the real app or run on an
iPad (see the manual checklist in `MANUAL_CHECKLIST.md`).

### Phase 1 — foundations (`test/roadmap_phase1_test.dart`, 8 tests)
| Requirement | Status | Evidence | Gap |
|---|---|---|---|
| Exactly 3 notebook templates (standard grid, larger grid, split 2/5 grid + 3/5 dots) with previews | VERIFIED | `data/models/paper.dart`, `notes/paper_dialog.dart`, `paper_painter.dart` | visual look not checked by eye |
| Template settings: spacing, line/dot colour + opacity, page colour; split sides independent | VERIFIED | same; colours are existing design tokens only | |
| Paper kept through save, reload, delete/restore | VERIFIED | `Note.paper`, `NoteVersion.paper` | |
| Windows/iPhone: tap types, Draw must be chosen; iPad: choose Type or Draw | VERIFIED (rule) | `notebookStartsWithPen` | real iPad not run |
| Reusable floating windows (drag, resize, stay inside, remembered per device) | VERIFIED | `app/floating_windows.dart`, `widgets/floating_layer.dart` | |
| Always on top (Windows; iPhone/iPad explained as unsupported) | IMPLEMENTED, setting VERIFIED; real window NOT VERIFIED | `setMainWindowTopmost` (SetWindowPos) | check by hand |
| Greeting 600/6 pools, 60 s upper-left window; quotes in bars | VERIFIED (earlier) | `motivation_test` | |
| Per-device layout preferences | VERIFIED by design | settings are not synced (`syncCollections`) | |
| Conflict review UI, item-level tag/PDF-page merges | VERIFIED (earlier) | `sync_risks_test`, Settings → Sync conflicts | |

### Phase 2 — planning (`test/roadmap_phase2_test.dart`, 14 tests)
| Requirement | Status | Evidence | Gap |
|---|---|---|---|
| Task views: list, Kanban board, sortable/filterable table, Gantt (dates only) | VERIFIED | `tasks/task_views.dart` | |
| Labels, custom properties, start dates, Kanban status — one record in all views | VERIFIED | `Task` fields (written only when used) | |
| Dependencies with gentle warnings, loops refused | VERIFIED | `Workspace.openPrerequisites/canDependOn` | |
| Recurring: skip or move one occurrence without changing the series | VERIFIED | `Task.skippedOccurrence/movedOccurrence`, `seriesDate` | editing other fields of one occurrence: not supported |
| Bulk date shift keeping intervals (selection, whole project) | VERIFIED | `shiftTasks`, `shiftProject` | |
| Multi-select + bulk complete/shift/label/priority/project/delete | VERIFIED for tasks | bulk bar | PARTIAL: not across notes/resources |
| Smart views: overdue, no date, high priority, waiting, study topics, labels; notes "not in a project" | VERIFIED | `SmartList`, `UnlinkedNotes` | |
| Completion messages: understated / funny / silent | VERIFIED | `completion_messages.dart` | |
| Calendar month, week, day, agenda, timeline + 38-day range | VERIFIED | `calendar/calendar_views.dart` | |
| Category and colour filters | VERIFIED | `itemsOn` filter test | |
| Date format and week start (per device) | VERIFIED | `widgets/date_prefs.dart` | |
| Freeform drawing on the calendar, saved per date | VERIFIED | `calendar_ink.dart` (doc `calendar-ink`) | Pencil feel on iPad not run |
| Drag a task onto a day to schedule it | VERIFIED (logic) | `moveDayItem(from: null)` | drag by hand not run |
| Recurring workflow templates | MISSING | — | scope to confirm |

### Phase 3 — connections (`test/roadmap_phase3_test.dart`, 17 tests)
| Requirement | Status | Evidence | Gap |
|---|---|---|---|
| Object and group locking | VERIFIED | marks in item extra fields (synced with the item) | |
| Lasso/tag labels: 5 chosen colours, dots top-left/top-right, minimap glow | VERIFIED (logic) | `CanvasTagColors`, `_paintMarks`, `MinimapPainter` | look not checked by eye |
| Recolour selected ink and text (opacity kept) | VERIFIED | `recolorSelection` | |
| Rotate | PARTIAL | ink rotates 90°; text/images/cards do not rotate | |
| Group / ungroup | VERIFIED | | |
| Shape recognition (line, triangle, rectangle, ellipse; off by default) | VERIFIED | `ink/shape_recognition.dart` | |
| Reference overlays (behind the ink, not selectable) | VERIFIED | `makeSelectionReference` | PDF pages as canvas content need a renderer plugin (BLOCKED) |
| Links between mindmaps that open the target | VERIFIED | `app/canvas_ops.dart` (`theapp://canvas/<id>`) | |
| Reusable components (saved copies, inserted as a group) | VERIFIED | doc `canvas-components` | |
| Named version snapshots + restore (undoable) | VERIFIED | store `canvas_snapshots` | kept on this device only, not synced |
| Copy / move a selection to a note or another mindmap | VERIFIED | `copyToNote`, `copyToCanvas` | |
| Right-click canvas menu (+ "More" button for touch) | IMPLEMENTED | `canvas_menu.dart` | not clicked through |
| Bidirectional links note ↔ task ↔ project ↔ mindmap card | VERIFIED | `Note.projectIds`, `Task.noteIds`, `note_connections.dart` | |
| Mention detection offers a link (never silent) | VERIFIED | `mentionedNotes`, `linkMention` | |
| Side-by-side version comparison | VERIFIED | `note_diff.dart` | |
| Text-conversion bar: Task / Subtask / Project / Note, preview, duplicate check | VERIFIED | `notes/conversion.dart` | |
| Command palette (Ctrl+Shift+P) | VERIFIED | `palette/command_palette.dart` | |
| App switcher, can float | VERIFIED | `palette/app_switcher.dart` | not on phone width (bottom tabs instead) |
| Customizable start page (choose, order; per device) | VERIFIED | `homeSections` | |
| Activity timeline | VERIFIED | `home/activity.dart` | |
| Archive: projects on resources, project filter, video links marked | VERIFIED (model) | `Asset.projectIds`, `isVideo` | Archive folders: MISSING |
| The three Graveyard areas | BLOCKED | no Graveyard exists in the code or earlier docs | please say where they were |

### Phase 4 — advanced (`test/roadmap_phase4_test.dart`, 12 tests)
| Requirement | Status | Evidence | Gap |
|---|---|---|---|
| AI off by default; master switch; per-source permissions; context limit | VERIFIED | `ai/ai_service.dart` (`AiSettings`) | |
| Nothing sent without Send; window shows exactly what is sent | VERIFIED | `ai/ai_session.dart` (`preview` = sent text) | |
| Floating, draggable, resizable AI window opens when content is sent | IMPLEMENTED | `ai/ai_window.dart` | not clicked through |
| Lasso/mindmap selection sent as a picture | VERIFIED (render) | `canvas/canvas_export.dart` | real model not run |
| Explain, summarize, outline, quiz, flashcards, brainstorm, follow-ups, sources [n] | IMPLEMENTED (tested with a fake model) | `AiTool` | answer quality depends on the model |
| Proposed tasks / mindmap / links applied only after approval | VERIFIED | `applyTasks`, `applyMindmap`, `applyLinks` | |
| Personal ChatGPT account | BLOCKED | a ChatGPT subscription has no API access; options: free local Ollama, or a paid API key | your decision |
| Local model (Ollama) | IMPLEMENTED, tested against a fake server | `OllamaClient` | Ollama not installed here |
| Semantic search (local model only) | IMPLEMENTED, fake-tested | `similarity.dart` `SemanticIndex` | |
| Duplicate detection | VERIFIED (similar wording, offline) | `similarNotes` | by-meaning duplicates: not done |
| Imports: Obsidian, Notion (Markdown), Apple Notes (HTML/TXT), Markdown folders; folders, tags, links, images; re-import skips | VERIFIED | `import/note_import.dart` | Notion CSV databases not imported (reported); Apple Notes has no direct export on Windows |
| Drag-and-drop from File Explorer | IMPLEMENTED, Dart side VERIFIED, C++ compiles | `windows/runner/flutter_window.cpp` (WM_DROPFILES), `capture/file_drop.dart` | real drag NOT VERIFIED |
| Exports: mindmap picture/web page, note Markdown/page pictures/web page; sources unchanged | VERIFIED | `export/exports.dart` | PDF page content not drawn in page pictures (reported) |
| Branded read-only web sharing with access, expiry, revocation | BLOCKED | needs hosting; THEapp makes the read-only page as a file | hosting decision (free: Tailscale Funnel from the hub, or a static host) |
| Universal clipboard between devices | IMPLEMENTED, logic VERIFIED | `AppState.checkClipboard`, collection `clipboard` | no second device; hub must run this version; iOS only sends with a button (paste permission) |
| iOS share-sheet capture | UNCHANGED | Shortcut fallback (`ios/README_IOS.md`) | Share Extension needs paid Apple account |
| External calendar sync | NOT STARTED (assessment only) | — | provider choice; the 5-active-entries rule conflicts with importing many events |

## Explicitly excluded (never implement)
Separate Tracker page · Projects category in Calendar · time blocking ·
productivity statistics / scoring / chart dashboards · extensive theme
customization · two-way Apple Calendar sync · conventional full-year calendar
replacing the 38-day view · duplicate records across views · unapproved
features · automatic AI processing · more than three notebook templates.

## Cross-cutting acceptance checks (2026-10-22)
| Check | Target | Measured / evidence | Status |
|---|---|---|---|
| Full suite (2026-10-23, after Phases 1–4) | all pass | 413 passed, 3 skipped (Windows-native opt-in), 0 failed; `flutter analyze` clean; Windows Release build OK | VERIFIED |
| Load 2,000 notes + 1,000 tasks + 200 entries | < 3 s | 100 ms (`performance_test`) | VERIFIED |
| Search the same workspace | < 0.5 s | 19 ms | VERIFIED |
| Canvas 3,500 items (500 connections) save + reload | < 2 s | 47 ms, 568 KB | VERIFIED |
| Recovery rehearsal (backup → notes + tasks lost/damaged → restore → Release binary starts) | data back, before-restore backup kept | passed on test data | VERIFIED |
| Security: hub address rules, loopback/private binding, tokens encrypted, logs without content | as specified | `remote_readiness_test`, `hub_test`, code review | VERIFIED (Windows) |
| Accessibility: tooltips on icon buttons, keyboard shortcuts, layouts at 8 sizes incl. phone/iPad | no overflow | `layout_test` (8 sizes, task panel open) | VERIFIED (layout); screen-reader use NOT VERIFIED |
| Real-binary click-through | — | posted input is ignored by Flutter; foreground input is forbidden | NOT VERIFIED |

## Phase 5 audit (2026-10-23, Claude, fresh pass) — `test/roadmap_audit_test.dart` (9 tests)
Fixed (each with a regression test):
1. A tag/lock/group change on a mindmap item could be overwritten by a sync arriving before the ~0.6 s save (`applyRemote` now treats it as unsaved).
2. "Select all" picked reference overlays, so Delete removed them; now skipped.
3. Text formatting changed locked text; now refused.
4. "Move to a note / mindmap" with locked items copied them but left the originals (silent duplicate); locked items now stay and are not copied.
5. Named mindmap versions were not in backups; `canvas_snapshots` added to the backup folders.
6. Search by meaning sent all notes to whatever AI address was set; now only to this PC (127.0.0.1/localhost), with a warning in Settings for other addresses.
7. Imports could attach files from outside the chosen folder via `../` embeds; now refused.
8. With an older hub, one clipboard record made the hub refuse the whole upload (all sync stopped); clipboard records now go last and alone, and a refusal is reported without stopping other sync.
9. A mindmap link found by search tried to open `theapp://…` in the system; it now opens the mindmap.

Verified by two-device tests through a real local hub: new task fields (labels, properties, status, moved occurrence), note paper and projects, link projects, canvas item tags/locks; clipboard only while on.

Known limits (not fixed): older THEapp builds on other devices list "Calendar drawings" and "Components" as mindmaps — update every device; clipboard text is kept in backups; real-app click-through and iPad still not tested (see MANUAL_CHECKLIST.md).

Result after the audit: `flutter analyze` clean; 422 passed, 3 skipped, 0 failed; Windows Release build OK.
