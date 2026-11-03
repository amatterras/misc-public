# Data model, migrations and data safety (as implemented)

This describes what the code does on 2026-10-25. Where another document
disagrees, the code and this file are correct. Storage modes (local / PC hub
/ hosted) are in [STORAGE_MODES.md](STORAGE_MODES.md); the sync protocol is
in [SYNC_ARCHITECTURE.md](SYNC_ARCHITECTURE.md).

## 1. How data is stored

There is **no database**. Every device has a data folder (Windows
`%APPDATA%\THEapp`, iPhone/iPad `Library/Application Support/THEapp`) of
JSON files written by `JsonFileStore` (`lib/data/storage/json_file_store.dart`):
write to `<file>.tmp`, keep the previous version as `<file>.bak`, rename into
place. A damaged file is renamed `*.corrupt-<time>` (never overwritten) and the
`.bak` is used. There is no transaction across files.

| Folder | Holds | In backups | Syncs |
|---|---|---|---|
| `data/<collection>.json` | one file per record collection (`RecordCollection`): `schema`, `records`, `revs` (id → revision stamp), `tombstones` (id → deletion stamp), `recentlyDeleted` (local undo copies, §5) | yes | collections listed in `Workspace.syncCollections` |
| `canvases/<id>.json` | one file per mindmap / notebook / Archive board / calendar ink: items, positions, colours, strokes, `itemRevs`, item `tombstones`, `metaRev` | yes | yes (`canvases`, `canvas_items`) |
| `attachments/` | photo, PDF and link-preview bytes, named by file name; the asset record holds `fileSha256`/`fileSize` | full backups only (weekly + every pre-upgrade/pre-switch backup) | bytes by SHA-256 |
| `settings/app.json` | app settings (pen width, dot opacity, date order, …) | yes | no |
| `sync/` | `device.json` (device id), `hub.json` (provider address), `client_state.json` (sync bookkeeping), `canvas_tombstones.json`, `hub.token` (device key, DPAPI/Keychain) | yes, **except key files** | no |
| `migrations/state.json` | finished migration steps, the open checkpoint, the last failure | yes | no |
| `retention/` | ledger of expired calendar entries (7-day purge) | yes | via `calendar_entry_expirations` |
| `canvas_snapshots/` | named mindmap versions | yes | no |
| `ai/`, `calendar/` | API keys and OAuth tokens (DPAPI/Keychain) | **never** | no |
| `backups/<time>-<reason>/` | backups (§4) | — | no |

### Entities and their references

| Entity | Collection / file | References (ids) |
|---|---|---|
| Note | `notes` | `folderId` → `folders`; `assetIds` → `assets`; handwriting = canvas with the note's id |
| Note version history | `note_versions` (local) | `noteId` |
| Folder | `folders` | `parentId` → `folders` |
| Drawing / stroke / mindmap item | `canvases/<id>.json` items | image/link item `assetId` → `assets`; note card `noteId` → `notes`; connector `from`/`to` → items on the same canvas; page background `assetId` |
| Archive resource (link / photo / PDF) | `assets` | `folderId` → `archive_folders`; `linkTags` (`tag:<id>` → `custom_tags`, or fixed category ids); `projectIds`; `url` is the original source URL, stored exactly as captured |
| Tag (Archive + Mindmap) | `custom_tags` | colour = ARGB chosen by the user |
| Calendar entry (Reading, Habit, Event, Other) | `calendar_entries` | `assetIds`; habits: `weekdays`, `startDate`/`endDate`, optional `startMinutes`, completion history `checkoffs` (day keys); Reading: `readingLog` (day → pages), legacy `author`/`highlights`, `legacyReading` (§3) |
| Calendar day note | `calendar_days` (id = day key) | `assetIds` |
| Google/Outlook link | `calendar_links` | `entryId` → `calendar_entries` |
| Task / project | `tasks`, `projects` | `parentId`, `projectId`, `noteIds`, `assetIds` |
| Colours | stroke/text colours inside canvas items (ARGB, alpha kept); tag colours in `custom_tags`; calendar colours derive from the category | — |
| Theme | **there is no light/dark setting**: the app has one dark theme (`lib/app/theme.dart`) | — |

Local only (never sync): `note_versions`, `ai_conversations`,
`browser_bookmarks`, `browser_history`, `browser_permissions`, settings,
`clipboard` (unless clipboard sharing is on).

## 2. Version map

| Layer | Version | Introduced | Upgrade path |
|---|---|---|---|
| Record file schema (`RecordCollection.schemaVersion`) | 1 → **2** | 2026-10-21 | adds `revs`; ISO-date tombstones become stamps (fixed 2026-10-25, see below). Runs at load; saved after a verified `pre-v3` backup |
| Canvas file schema (`CanvasDocument.schemaVersion`) | 2 → **3** | 2026-10-21 | per-item stamps, item tombstones, `metaRev`, unknown items kept (`AppState.migrateCanvases`) |
| Data feature level (`AppState.dataFeatureLevel`) | **2** | Phases 2–3 | verified `pre-level2` backup, then canonical colour migration v1 |
| Canonical colour migration | **1** | 2026-10-23 | maps legacy ink colours to the shared palette; unknown colours kept |
| Versioned migrations (`MigrationRunner.registry`) | see §3 | 2026-10-25 | checkpointed runner |
| Sync protocol | **1** | 2026-10-22 | handshake header; a different version is refused (`426`) |
| Backup manifest format | **1** | 2026-10-25 | `manifest.json` in every new backup |

A newer record/canvas schema or feature level than this build knows opens
**read-only** (nothing is written). Unknown records, unknown fields and unknown
canvas items are kept and written back unchanged
(`lib/data/models/unknown_fields.dart`).

## 3. Versioned migrations (`lib/data/migrations/migration_runner.dart`)

Run at every start, after the schema/feature-level checks and before any
page opens.

1. **Checkpoint** in `migrations/state.json` naming the pending steps and the
   backup that holds the original data.
2. **Verified backup** (`pre-migration-<step>`, records + attachments):
   trusted only if its manifest checksums match **and** a copy of it opens as
   a workspace with the same record counts and every attachment
   (`verifyRestorable`, `lib/data/storage/backup_verifier.dart`). These
   backups are never pruned automatically.
3. **Steps** run. Each is idempotent: running it again changes nothing.
4. **Census**: every record id, canvas item id and attachment file before
   and after each step; any missing id stops the run ("would have lost N
   items").
5. The step is recorded as done; the checkpoint is cleared at the end.

**Interrupted** (crash, power cut): the checkpoint is still there at the
next start; the same original backup is reused (if its manifest still
verifies) and the steps run again — safe because they are idempotent.

**Failed**: nothing is deleted or re-created. The data folder becomes
read-only, the failure is recorded, and instead of the app a screen shows the
reason with **Retry the upgrade** and **Restore the backup** (which backs up
the current state first). There is no "reset" or "clear data" path.

| Step id | What it does | Data it adds | Never does |
|---|---|---|---|
| `reading-legacy-payload-v1` | For Reading entries with an author, highlights or a `quotes` field (from another version), copies them into `legacyReading: {version: 1, author, highlights, quotes?}` | `legacyReading` | remove or change `author`/`highlights`/`quotes`; touch the app-wide welcome quotes |
| `canvas-revisions-v1` | Gives canvas items and titles that have no revision stamp the stamp of the canvas's last edit (new and welcome canvases that were never edited did not sync) | `itemRevs`, `metaRev` | move, recolour or re-create items |
| `object-library-foundation-v1` | Initializes the object library schema with a verified pre-migration backup | none; new collections are created lazily | import, rewrite, or delete legacy Archive assets, folders, tags, or attachment bytes |
| `inbox-to-archive-v1` | Saves items still waiting in the removed Inbox (links, text, photos, files) as Archive objects, each marked with the Inbox item it came from; runs after a verified backup | Archive objects only; an item already moved, or already saved by its link, text or file, is not saved again | remove, change or hide any Inbox record (they stay on disk and sync), or move links that are not public web addresses |

### Migration path per entity for the next update

| Change in the next update | Existing data | How it is kept |
|---|---|---|
| Reading editor drops author / highlights / quotes | `author`, `highlights` fields; `quotes` (unknown field) | Kept in the record **and** in `legacyReading` (versioned); exported in backups; syncs as a normal field. The editor must not show them. |
| Dated daily Reading plans | `readingLog` (day → pages) and legacy book records remain unchanged; plan fields are optional additive JSON fields | Separate day pages use `<entryId>/<dayKey>` IDs, with date-only local fields; missing fields default safely. Removed dates are detached, never deleted. |
| Habit times | `startMinutes` (null = untimed) | Untimed habits stay untimed: `CalendarEntry.needsTimeConfiguration` is true until the user picks a time. No time is invented. |
| Occurrence-level checkboxes | `checkoffs` (set of day keys) | The completion history is the set of day keys; occurrence records must be keyed `<entryId>/<dayKey>` and derived from it, never replacing it until verified. Completions outside the current schedule are kept (integrity check reports them) |
| Extended Archive metadata | `assets` (url, title, tags, folder, preview, file hashes) | New fields are additive; unknown-field preservation keeps them on older devices; the original `url` is never rewritten |
| Colour/theme values | ARGB in items and tags; `themeMode` is an optional local setting | Defaults to dark; light/system changes semantic rendering only and never rewrite stored drawing colors. |

### Fixed while building this (2026-10-25)

- **ISO-date tombstones were never converted.** `SyncClock.parse` accepted
  "2026-08-30T09:00:00Z" as a stamp (it splits on "-" into numbers), so old
  (schema 1) deletion markers stayed ISO dates and the hub refused the push
  batch ("Invalid revision"). `parse` now requires the exact stamp form.
- **A duplicated record id was dropped on the next save.** The loader kept
  one copy; now the other is kept aside and written back unchanged, and the
  integrity check reports it.
- **Unstamped canvases did not sync** (see `canvas-revisions-v1`). New
  canvases are now stamped when created.
- **A failed migration could log record text.** The runner now logs only the
  error type and stack.

## 4. Backups (`lib/data/storage/backup_service.dart`)

- Written into `backups/.partial-<name>/` and renamed only when complete
  (an interrupted copy is never listed as a backup).
- Each backup has `manifest.json`: format, version, reason, schema versions,
  whether attachments are included, record counts per collection, and every
  file with its size and SHA-256. `"secretsIncluded": false`.
- **Key files are never copied**: `*.token`, `*.key`, `*.client`
  (device keys, AI keys, OAuth tokens). A restore keeps this device's own
  keys. Private-vault items stay encrypted in backups; the vault key is
  stored only wrapped by the vault password and by the recovery code
  (`vault_meta`), so opening a restored vault needs one of those two.
  Nothing else in a backup is encrypted by THEapp (at rest it relies on
  BitLocker / iOS Data Protection).
- **Restore** checks the manifest first and refuses a damaged backup;
  backs up the current state (`before-restore`); stages the copy; swaps the
  folders; only ever **adds** attachments; clears sync bookkeeping so a
  paired device re-offers the restored records instead of overwriting them.
- The 7-day calendar purge, which edits older backups, rewrites their
  manifest only if the backup verified before the purge.
- **Restore to another folder** (`restoreTo`) gives a working copy (tested:
  ids, relationships, attachment bytes, colours, settings).

Older backups (no manifest) can still be restored; they are reported as
"no manifest" by `checkManifest`.

## 5. Deletion, restore and sync (`RecordCollection`)

- **Delete** = tombstone with a new revision stamp (syncs), plus a local
  copy of the record's last content in `recentlyDeleted` (30 days, at most
  200 per collection; not synced). Deleting a record never deletes what it
  refers to (no cascade): a deleted note keeps its photos, folders and the
  mindmap cards that point to it.
- A deletion received from another device is also kept in that device's
  `recentlyDeleted`.
- **Restore** (`restoreDeleted`, Settings → Data safety → Recently deleted)
  puts the record back with a **new stamp, newer than its deletion**: the
  hub applies it as an edit and every device gets it. Only that record comes
  back; other deleted records stay deleted.
- Not kept for undo: expired calendar entries (7-day purge — their
  expiration record also blocks re-offers), pruned note versions, browser
  history, clipboard clips.
- **What can bring a deleted record back without a restore** (hub rules,
  unchanged): a device that never saw the deletion and *edits* the record
  (the edit wins; the deletion is kept as a conflict record), or re-offers
  it after a hub restore. This is deliberate: an edit is never lost to a
  deletion.

## 6. Integrity check (`lib/data/integrity/integrity_check.dart`)

Settings → Data safety → **Check data**. Read-only: it never writes, deletes
or "repairs". It reports, with a recovery hint each:

`duplicate_id` (records or canvas items) · `unreadable_records` ·
`missing_attachment` (record without bytes) · `unreferenced_attachment` ·
`missing_source_url` · `missing_reference` (folder, attachment, note, task,
project, Archive folder, page background) · `dangling_calendar_link` ·
`bad_habit_completion` / `habit_completion_outside_schedule` ·
`dangling_connection` · `migration_unfinished` · `migration_failed`.

The current model has no stored habit-occurrence records (occurrences are
computed from the schedule); "absent occurrence records" therefore means
completions that the schedule no longer produces, which are reported and
kept.

## 7. Logs

`logs/app.log` records operations, counts, ids and error types. Migration
failures log the error type and stack only; storage switches log counts.
Tests check that note bodies, URL queries, device keys and passwords do not
appear in the log (`test/data_safety_test.dart`,
`test/storage_modes_test.dart`).

## 8. Tests

| File | Covers |
|---|---|
| `test/support/pre_update_fixture.dart` | realistic pre-update workspace (linked notes/folders/tasks, photo + PDF bytes, Archive URL with query, Reading author/highlights/quotes, timed + untimed habits with history, tag and stroke colours, mindmap with card/photo/link/connection, Google link, schema-1 file, tombstones, settings) |
| `test/data_safety_test.dart` | migration without loss; second run changes nothing; interrupted run reuses the original backup; a lossy step is stopped and restored; failed start-up upgrade is read-only with restore; manifest/no keys/tamper/restore; restore into a separate working workspace; integrity on damaged data (no erasing); delete/restore across devices without resurrecting others; expired entries stay gone; log privacy |
