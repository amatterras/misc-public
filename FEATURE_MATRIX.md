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
| Navigation Home/Canvas/Notes/Calendar/Tasks | P1 | W,i | VERIFIED | `widget_test`, `layout_test` (8 sizes incl. phone/iPad) | |
| Home: today's tasks, priorities, upcoming deadlines, quick capture, recent/favorite notes | P1 | W | VERIFIED (screenshot of real binary on test data + widget tests) | `lib/features/home/home_page.dart` | |

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
| Search across the app | P1 | W | VERIFIED | `spec_coverage_test` search; `interaction_test` Ctrl+K | |
| Quick capture | P1 | W | VERIFIED | `interaction_test`, `widget_test` Quick Add | |
| Images and URLs in notes | P1 | W | VERIFIED | `workspace_test`, capture tests | |
| PDFs in notes ("where practical") | P2 | W | PARTIAL (attach + open; no in-app pages) | `notes_page.dart` PDF button, `documents_test` | as canvas PDFs |
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
| Ten organizer colours (exact hex) | P1 | W | VERIFIED | `spec_coverage_test` exact hex values | |
| Reading: books, progress, activity, notes, highlights | P1 | W | VERIFIED (data) | `workspace_test` reading logs | |
| Habits: one record, many dated occurrences, check-offs | P1 | W | VERIFIED | `workspace_test` habit occurrences | |
| Events: single/multi-day, optional times | P1 | W | VERIFIED | `workspace_test` drag keeps length | |
| Category navigation and quick add | P1 | W | VERIFIED | `widget_test` (category tab, sixth entry refused), `interaction_test` (Quick Add task on Calendar) | |
| Category and colour filters on the grid | P1 | W | UNVERIFIED | `calendar_page.dart` (`_shown`, `_colors`) | no automated test yet; check by hand |

## 5. Tasks and study planning
| Requirement | Pri | Plat | Status | Evidence / references | Blocker |
|---|---|---|---|---|---|
| Tasks, projects, subtasks, deadlines, priorities, completion | P1 | W | VERIFIED | `spec_coverage_test`, `workspace_test` | |
| Reminders | P1 | W | VERIFIED in-app (notice + taskbar flash while running; missed ones at next start; follow recurring tasks) | `Task.remindBefore`, `reminders_test` | no Windows notification while THEapp is closed (needs a background process) |
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
| iOS build and run | P2 | i | BLOCKED | `ios/README_IOS.md` (Mac checklist) | needs macOS + Xcode; no Mac available (this PC is Windows only) |
| iOS data folder (`Library/Application Support/THEapp`) | P1 | i | IMPLEMENTED BUT UNVERIFIED | `json_file_store.dart` `defaultDataDirectory` | iOS device |
| iOS device identity after a restored backup (Keychain-bound id; restored copy gets a new id and asks to pair again) | P1 | i | IMPLEMENTED BUT UNVERIFIED (Dart logic tested with a simulated Keychain) | `ios_readiness_test` | iOS device |
| iOS pairing: no 127.0.0.1 default, Tailscale address hint, clear refusal of loopback, key-store failure reported | P1 | i | IMPLEMENTED BUT UNVERIFIED (tested on Windows with simulated channel) | `ios_readiness_test` | iOS device + second network |
| Sync when the app returns to the front | P1 | W,i | VERIFIED (W, in tests) / UNVERIFIED (i) | `ios_readiness_test` | iOS device |
| `theapp://capture` links (Shortcut) | P2 | i | IMPLEMENTED BUT UNVERIFIED (Dart tested with simulated channel; Swift uncompiled) | `ios_bridge_test` | Mac |
| Photo / PDF pickers (copies removed after import) | P2 | i | IMPLEMENTED BUT UNVERIFIED (Dart tested; Swift uncompiled) | `ios_bridge_test`, `ios_readiness_test` | Mac |
| Share-menu link capture | P2 | i | PARTIAL (Dart side tested with simulated channel, shared text capped; Swift uncompiled; extension target not in the Xcode project) | `ios_bridge_test`, `ios_readiness_test` | Mac; Share Extension needs paid account (App Groups) |
| Apple Pencil | P2 | i | UNVERIFIED | simulated tests | iPad + Pencil |

## Explicitly excluded (never implement)
Separate Tracker page · Projects category in Calendar · time blocking ·
productivity statistics / scoring / chart dashboards · extensive theme
customization · two-way Apple Calendar sync · conventional full-year calendar
replacing the 38-day view · duplicate records across views · unapproved
features · automatic AI processing.

## Not in the brief (deferred, not required)
Copying images out to other apps · drag-and-drop from Explorer.

## Cross-cutting acceptance checks (2026-10-22)
| Check | Target | Measured / evidence | Status |
|---|---|---|---|
| Load 2,000 notes + 1,000 tasks + 200 entries | < 3 s | 100 ms (`performance_test`) | VERIFIED |
| Search the same workspace | < 0.5 s | 19 ms | VERIFIED |
| Canvas 3,500 items (500 connections) save + reload | < 2 s | 47 ms, 568 KB | VERIFIED |
| Recovery rehearsal (backup → notes + tasks lost/damaged → restore → Release binary starts) | data back, before-restore backup kept | passed on test data | VERIFIED |
| Security: hub address rules, loopback/private binding, tokens encrypted, logs without content | as specified | `remote_readiness_test`, `hub_test`, code review | VERIFIED (Windows) |
| Accessibility: tooltips on icon buttons, keyboard shortcuts, layouts at 8 sizes incl. phone/iPad | no overflow | `layout_test` (8 sizes, task panel open) | VERIFIED (layout); screen-reader use NOT VERIFIED |
| Real-binary click-through | — | posted input is ignored by Flutter; foreground input is forbidden | NOT VERIFIED |
