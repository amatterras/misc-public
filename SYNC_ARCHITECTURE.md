# Sync architecture

Status (2026-10-22):
- The PC hub, the sync protocol (v1) and the device-side sync engine are
  **implemented and tested on this PC**: in-process tests with a real hub on
  127.0.0.1 and several simulated devices.
- **Not yet tested:** real multi-device sync (a real iPhone/iPad, a second PC),
  Tailscale, and the hub running permanently in the background.
- The Windows app has **not** been paired with a hub on this PC yet.
- §1–§8 are the original proposal and the decisions. **§9–§15 describe what the
  code actually does**; where they differ, §9–§15 are correct.

## 1. Requirements recap
- Windows PC is the primary data host; iPhone and iPad also get full access.
- Every device edits offline and syncs automatically later.
- Same item edited on two devices → predictable result, never silent loss of text.
- One record per thing (canvas objects, notes, images, links, tasks, calendar
  entries); no duplicates after syncing.
- Attachments, deletions, backups, recovery and schema migrations must all sync safely.
- Secure access away from home; clear behaviour when the PC is off.
- Minimal running costs; nothing uploaded to a cloud service without your approval.

## 2. What works where

| Works entirely on one device (no network) | Needs another device to be reachable |
|---|---|
| All editing, capture, search, Calendar, Tasks | Exchanging changes between devices |
| Saving, crash-safe writes, `.bak` recovery | Downloading photos that were added elsewhere |
| Local backups and restore | Pairing a new device (one time) |
| Queuing changes made offline | Remote backup of a phone/tablet's changes |

Building and installing the iPhone/iPad app needs a **Mac with Xcode** and, for apps
that don't expire after 7 days, an **Apple Developer Program** membership
(US$99/year). This applies to every option below.

## 3. Options compared

Costs are approximate. Electricity depends on your tariff, so it is given in kWh.

| | A. PC hub + private network | B. A + always-on home mirror | C. A + encrypted iCloud mailbox | D. Rented server (VPS) | E. Hosted backend (Firebase/Supabase) |
|---|---|---|---|---|---|
| Primary copy | Your PC | Your PC | Your PC | Your PC + server | Provider's cloud |
| Sync away from home | Yes, via Tailscale | Yes, via Tailscale | Yes | Yes | Yes |
| Sync while PC is off | **No** — devices queue changes | **Yes**, through the mirror | **Yes**, through iCloud | Yes | Yes |
| Who can read your data | Only your devices | Only your devices | Only your devices (Apple stores encrypted blobs) | Only your devices if end-to-end encrypted | Provider |
| One-time cost | 0 | Raspberry Pi 5 + SSD ≈ €90–130 | 0 | 0 | 0 |
| Running cost | 0 (Tailscale Personal is free for 3 users / 100 devices) | ≈ 40–50 kWh/year | 0 if within free 5 GB iCloud, else iCloud+ ≈ €1/month | ≈ €4–6/month | Free tier, then usage-based |
| PC on 24/7? | Needed for sync anywhere, anytime: a desktop idling at 50–100 W uses ≈ 450–900 kWh/year | No | No | No | No |
| Maintenance | Low | Low–medium (one small box) | Low | Medium (updates, security) | Low, but vendor lock-in |
| Fits "no cloud without approval" | Yes | Yes | Only with your explicit opt-in | Only with opt-in | **No** (rejected) |

Two options considered and rejected:
- **LAN-only peer-to-peer.** It only syncs on the same Wi-Fi, so devices away from home never sync.
- **Plain shared folder (OneDrive/Dropbox) of the raw files.** It produces conflicting file copies, and iOS apps can't reliably sync third-party folders in the background.

## 4. Recommendation
**Option A now, designed so B or C can be added later without changing any screen.**

- The Windows app gets a small built-in **sync service** using Dart's own
  `dart:io` HTTP server, with no new dependencies. It listens **only** on the
  Tailscale and home-network interfaces: no port forwarding, nothing exposed to
  the internet.
- **Tailscale** links your PC, iPhone and iPad into a private, encrypted
  (WireGuard) network that works from anywhere. Data travels directly between your
  devices.
- Phones and tablets keep a **full local copy** and work offline. They sync when
  the app opens, when it closes, every few minutes while open, and opportunistically
  in the background (iOS decides when).
- If "PC off = no sync" becomes annoying, add **B**: a Raspberry Pi running the same
  sync service as an always-on mirror. It costs a few kWh instead of keeping the PC
  on, and still involves no cloud. **C** is the zero-hardware alternative, but it
  stores encrypted data at Apple, so it would only be enabled if you explicitly approve it.

What happens when the PC is switched off (with A only): nothing breaks. Every device
keeps working and queues its changes. As soon as the PC is on, with THEapp running
and reachable, devices sync automatically. Windows **sleep** also stops the service, so
for remote access the PC must stay awake or be woken. Wake-on-LAN over the internet
is unreliable, which is the main reason to add B later.

## 5. How sync would work (original proposal)

> **Superseded in places by the implementation (§9–§15):**
> - Conflicts are resolved per whole record. Lists such as tags or habit
>   check-offs are **not** combined; the losing version is kept as a conflict
>   copy instead.
> - Canvas stacking order travels with the canvas's title/folder record; there
>   are no per-item order keys.
> - After a restore, the restored records are *re-offered* (see §11) rather than
>   given new revisions.
> - Tombstones are not pruned yet.

### Records and identity
- Every record already has a stable unique id. Canvas objects become sync records
  keyed `canvasId/itemId`, so two devices editing different notes on the same
  canvas never conflict.
- Every change gets a **revision stamp** from a hybrid logical clock (§7). Stamps
  are device-unique, always increase on a device even if its clock is wrong,
  and sort the same way everywhere.
- Images and links are `Asset` records stored once and referenced by id, so they
  never duplicate. The same URL is reused locally. On merge, identical URLs from two
  devices are deduplicated and their references are redirected to the surviving asset.

### Protocol (state-based, small)
1. **Push:** the device sends every record whose revision is newer than its last
   successful push, along with the revision it was based on.
2. **Hub merges** each record (rules below) and gives the result a hub sequence number.
3. **Pull:** the device asks "everything after sequence N" and applies it.
4. If a sync is interrupted, it is simply retried. Every step is idempotent, so a
   repeated sync changes nothing.

### Conflict rules (when both sides changed since the common base)

| Data | Rule |
|---|---|
| Simple fields (title, colour, position, size, dates, priority, done) | Newest revision wins, per field where practical |
| Long text (note body, canvas note text, calendar notes) | Newest wins, **and the other version is kept as a "conflict copy" in the note's history**, flagged in the UI. Text is never silently lost |
| Sets and lists (tags, attachments, habit check-offs, "other" dates, reading log) | Merged: additions from both sides are kept; removals apply only to items the other side didn't re-add |
| Edit vs delete | If the edit is newer than the deletion, the item is kept (no data loss); otherwise it stays deleted, and remains in backups |
| Calendar "5 active" limit | After a merge the category may show 6/5. The app **warns and asks you to archive one** rather than archiving anything by itself |
| Canvas stacking order | Gets a sortable position key per item, so concurrent reordering merges cleanly |

### Attachments
- Synced separately from records: metadata first, then file bytes, resumable.
- Identified by content hash (SHA-256, computed at sync time), so the same photo
  sent twice is stored once. iPhone/iPad download thumbnails eagerly and full
  images on demand, with an optional "Wi-Fi only" setting.
- Never deleted while any record references them. Unreferenced files are removed
  only after every paired device has seen the deletion, plus a grace period.

### Deletions
Deletions are tombstones with stamps (already stored). They are pruned only after
every paired device has synced past them, plus 90 days.

### Backups and recovery
- The PC hub keeps the daily automatic backups it already makes, and gains a
  backup of everything received from phones.
- A restore is treated as **a new edit**: restored records get fresh stamps and
  spread to the other devices. Otherwise newer edits elsewhere would immediately
  undo the restore.
- Each device can also restore locally from its own backups.

### Migrations
- The sync handshake exchanges data schema versions. A device on an older version
  is asked to update before syncing. Data is never downgraded.
- Newer data an older version can't read is preserved untouched. Canvases already
  do this (§7); records will get the same treatment before sync ships.

### Security
- Network: Tailscale (WireGuard keys per device). Optionally require sign-in with
  2-factor on the Tailscale account.
- App-level pairing on top: the PC shows a one-time code, and the phone receives a
  long random device token stored in the iOS Keychain (on Windows, protected with
  DPAPI). Each device can be revoked from the PC.
- The sync service only answers paired devices and only on private interfaces.
  Optional HTTPS via `tailscale cert`.
- At rest: Windows BitLocker and iOS Data Protection.
- AI or any cloud transfer stays opt-in, per action.

## 6. Phased plan
1. **Stabilise the local app** (next, as agreed).
2. Finish data-layer prep: record version history (for conflict copies), canvas
   z-order keys, unknown-field preservation for records, attachment hashes.
3. Sync engine as a pure Dart library with exhaustive tests. Two simulated devices
   plus a hub run in-process; no network needed to test conflicts.
4. PC sync service + pairing, used first between two Windows installs.
5. iPhone/iPad app (needs the Mac and Apple account) connecting via Tailscale.
6. Optional: Raspberry Pi mirror (B), or encrypted iCloud mailbox (C) if approved.

## 7. Preparation already done (backward compatible)
- **Device identity:** `sync\device.json`, a random id per installation. A data
  folder copied to another computer gets its own id.
- **Hybrid logical clock:** `lib/data/sync/sync_clock.dart`.
- **Record revisions:** every record collection now stores `revs` (id → stamp), bumped
  only when content really changes. Tombstones are stamps; old ISO dates are
  converted. Collection file schema is 1 → 2.
- **Canvas revisions:** per-item stamps (`itemRevs`), item tombstones, a stamp
  for title/folder changes (`metaRev`), and **preserved unknown items**. Canvas
  file schema is 2 → 3.
- **Canvas deletions:** recorded in `sync\canvas_tombstones.json`.
- The `sync` folder is included in backups. A full backup (`backups\…-pre-v3`) is
  taken automatically before the first upgrade.
- Verified on the real data folder: the canvas upgraded to schema 3 with both notes intact.

## 8. Decisions (agreed 2026-10-21)
1. **Option A first:** PC hub + Tailscale. The Raspberry Pi mirror (B) is "maybe later".
   Encrypted iCloud (C) is not planned.
2. **Text conflicts:** newest wins, and the other version is kept as a conflict copy.
3. **Calendar over the limit after a merge:** warn and ask; never auto-archive.
4. **Still open:** Mac access and the Apple Developer Program (needed only for the
   iPhone/iPad phase).

Next step agreed: stabilise the local app before implementing sync.

---

# Implemented behaviour (protocol v1)

## 9. Data flow and roles

```
 Windows app (device copy)        THEapp hub (authoritative copy)        iPhone / iPad (future)
 %APPDATA%\THEapp            <->  %APPDATA%\THEapp-hub              <->  their own local copy
 works fully offline              separate program: bin/thehub.dart      same sync engine (lib/sync)
```

- **Two folders, two writers, one authority.** The hub (`bin/thehub.dart`,
  pure Dart) is the only program that writes `%APPDATA%\THEapp-hub`, and its
  copy is the authoritative synced state. The Windows app only writes
  `%APPDATA%\THEapp`; it is one device among several and syncs with the hub
  exactly as the phones will.
- **The app never needs the hub.** Sync stays off until the app is paired. When
  the hub is unreachable, edits stay pending locally (nothing is lost) and go
  out on the next successful attempt.
- **What syncs** (protocol name → data):
  - `assets` (links and photos), `notes`, `folders`, `inbox`, `projects`, `tasks`
    (subtasks included)
  - `calendar_entries` (Reading, Habits, Events, Other), `calendar_days` (day
    notes and attachments)
  - `canvases` (title, folder and item order), `canvas_items` (one record per
    note, drawing, photo, link or note card; id `"<canvasId>/<itemId>"`)
  - `conflicts` (preserved losing versions)
- **What does not sync:** settings, window/canvas zoom position, the device
  identity, logs, and backups.
- **Identity and change tracking:**
  - Every record has a stable unique id.
  - Every version carries a revision stamp from a hybrid logical clock:
    `<16-digit UTC ms>-<4-digit counter>-<device id>` (`lib/sync/hlc.dart`).
    Stamps never go backwards on a device, are unique per device, and sort the
    same everywhere.
  - Deletions are tombstones with a stamp.
  - Timestamps inside records are stored in UTC.
- **One sync cycle** (`SyncEngine.syncOnce`, `lib/sync/sync_engine.dart`):
  1. Save the open canvas and all records to disk.
  2. Ask the hub for its id and newest change number. If the hub is different,
     or is behind where this device last read (it was restored), forget the
     sync bookkeeping and re-offer everything (§11).
  3. Fill in missing photo checksums.
  4. Once per session, check that the hub has every photo this device has, and
     upload any that are missing.
  5. **Push** every local version whose revision differs from the last revision
     this device knows the hub has ("base"), in batches of up to 200. Photo
     files are uploaded before their record. A record is marked as synced only
     after the hub confirms it was written to disk. A record over 1 MB is not
     sent; it is reported instead, so it can't block the rest.
  6. **Pull** everything after this device's cursor, in pages (default 200, max
     500). Each page is applied and saved; only then is the cursor saved. An
     interrupted sync therefore resumes without skipping anything.
  7. Download missing photo files, checked against their SHA-256.
- **When it runs (Windows app):** 3 seconds after start, every minute, and on
  Settings → Sync hub → **Sync now**. Opening a canvas waits until a running
  sync has finished writing.

## 10. Hub API (HTTP, protocol 1)

Every data endpoint requires both headers:
- `x-theapp-protocol: 1` (anything else → `426 protocol_mismatch`)
- `Authorization: Bearer <device token>` (missing or wrong → `401 unauthorized`)

Bodies are JSON, at most 8 MB.

| Method & path | Auth | Request | Response |
|---|---|---|---|
| `GET /v1/status` | none | — | `{service, hubId, protocol}` (no user data) |
| `POST /v1/register` | pairing code | `{pairingCode, deviceId, deviceName}` | `{token, protocol, lastSeq}` |
| `POST /v1/push` | device | `{changes: [Change, …]}` (at most 200) | `{results: [Result, …], lastSeq, hubId}` |
| `GET /v1/changes?since=N&limit=M` | device | — | `{changes: [Change with seq, …], next, hasMore, lastSeq, hubId}` |
| `HEAD /v1/attachments/<sha256>` | device | — | `200` if stored, `404` if not |
| `PUT /v1/attachments/<sha256>` | device | raw bytes; `Content-Length` required | `{ok: true}`; size and SHA-256 must match |
| `GET /v1/attachments/<sha256>` | device | — | raw bytes |
| `GET /v1/admin/status` | admin, this PC only | — | counts, devices, backups, listening addresses, memory |
| `POST /v1/admin/pair` | admin, this PC only | — | `{code, expiresInMinutes}` |
| `POST /v1/admin/revoke` | admin, this PC only | `{deviceId}` | `{revoked}` |
| `POST /v1/admin/backup` | admin, this PC only | — | `{backup, verified}` |
| `POST /v1/admin/compact` | admin, this PC only | — | stats (takes a backup first) |
| `POST /v1/admin/shutdown` | admin, this PC only | — | `{stopping: true}` |

**Payloads:**
- **Change:** `{collection, id, rev, deleted, data?, baseRev?}`. `data` is the
  record's JSON and is absent when `deleted`.
- **Result:** `{collection, id, rev, status, current?, conflictId?}`, where
  `status` is one of:
  - `applied`: stored.
  - `duplicate`: already had exactly this version.
  - `keptServer`: the hub kept another version; the device must take `current`.

**Limits:** 200 changes per push, 1 MB per record, 100 MB per attachment.

**Errors** are `{error, message}`. Messages never contain user content.

| Code | Status | Meaning |
|---|---|---|
| `unauthorized` | 401 | Missing, wrong or revoked token; or an admin call without the admin token, or not from this PC |
| `pairing_failed` | 401 | Wrong or expired pairing code |
| `rate_limited` | 429 | 5 wrong pairing codes from one address within 10 minutes |
| `protocol_mismatch` | 426 | Different protocol version: update the app |
| `bad_request`, `bad_change` | 400 | Malformed input. Also: unknown collection, invalid id or revision, or an edit claiming another device's revision |
| `too_many_changes`, `record_too_large` | 400 | Over the limits above |
| `bad_attachment` | 400 | Invalid attachment id (anything that isn't 64 lowercase hex characters) |
| `too_large` | 413 | Body or attachment over the limit |
| `integrity_failed` | 422 | Attachment size or SHA-256 doesn't match |
| `not_found` | 404 | No such endpoint or attachment |
| `internal` | 500 | Hub error (only the error *type* is logged) |

## 11. Conflicts, deletions, retries and recovery (as implemented)

**Hub rules for each pushed change** (`HubStore._push`):

| Situation | Result |
|---|---|
| Hub has no version, or its version equals the change's `baseRev` | **applied** |
| Hub already has exactly this revision | **duplicate** (nothing stored) |
| Hub's version is this device's own earlier edit (its reply was lost) and the change is newer | **applied**, no conflict copy |
| Both deleted | **keptServer** (stays deleted) |
| Deleted here, but the hub has a different (edited) version | **keptServer**: the edit stays, and a conflict record notes the deletion request. *A deletion never overwrites an edit.* |
| Edited here, but the hub has it deleted | **applied** (the edit wins), and a conflict record keeps the deletion |
| Both edited | The **higher revision wins**; the other version is kept in full as a conflict record (`otherData`) |

**Conflict records** (`conflicts`, made by the hub) sync to every device. In the
Windows app: Settings → Sync hub → **Review conflicts**:
- **Use this version** makes the preserved version current again (an ordinary
  edit, so it syncs).
- **Dismiss** deletes the conflict record.
- Conflicts are per whole record. Lists such as tags or check-offs are not
  combined.

**Retries and duplicates:**
- Every change has a natural operation id (`device|collection|id|rev`), and the
  hub records its answer.
- A repeated *edit* (one with a base) gets the earlier answer. If the record has
  moved on since, the answer is `keptServer` with the current version, so a
  device never believes an outdated version is in sync.
- Base-less offers (new records and re-offers) are always judged by the rules
  above.
- Re-sending, or receiving the same version twice, never creates a second record
  or a second version.

**Out-of-order arrival:**
- Changes are pulled in hub order (`seq`).
- A record that refers to one not yet received (for example a note's folder) is
  shown without it until it arrives.
- Canvas items that arrive before their canvas's title record create the canvas
  as "Synced canvas" until the title arrives.

**Local edits are protected while applying incoming changes:**
- A record with an unsent local change is never overwritten by an incoming
  version. It is sent instead, and the hub decides.
- On the open canvas, an item edited but not yet saved, or the note being typed
  in, is also protected.
- When the hub keeps its own version, the device takes it only if the record
  still has exactly the revision it sent. An edit made while the request was in
  flight is kept and sent next time.

**Re-offering** (after a hub restore, re-pairing, or restoring an app backup):
- The device forgets its sync bookkeeping and offers every record with no base
  revision.
- The hub judges these by the rules above:
  - Versions it already has → duplicate.
  - Versions it lost → filled back in, including versions made by other devices.
  - Older versions never overwrite newer ones; they are kept as conflict records.
  - Restored records the hub had deleted come back, with the deletion kept as a
    conflict record.

**Calendar limit after a merge:** a category may end up with more than 5 active
entries. The app shows a warning in that category, and editing those entries
still works. Nothing is archived automatically.

**Deleted canvases** go to the device's trash folder (`canvases\.trash`), never
erased.

**Tombstones** are kept indefinitely on the hub and on devices (no pruning
yet).

## 12. Photos and other attachments

- Each photo (and each link preview image) is identified by its SHA-256. The hub
  stores it once, at `attachments\<sha256>`, whichever device sent it.
- **Upload:** the hub writes to `attachments\.incoming\…` while hashing. The
  file is moved into place only if its size and SHA-256 match. An interrupted or
  corrupted upload never becomes a visible file. Uploading the same file again
  does nothing.
- **Download:** the device writes to `<name>.download`, checks size and SHA-256,
  then renames. A bad download never replaces anything.
- File names arriving from other devices must match a strict pattern (no
  folders, no `..`), so a file can only ever be written inside the app's
  attachments folder.
- The hub never deletes attachments. Devices never delete attachment files
  either.

## 13. Security boundaries

| Aspect | What the code does |
|---|---|
| Listening addresses | Always `127.0.0.1` (this PC). Optionally **one** extra address via `--private-host`, which must belong to this PC and be private (10/8, 172.16/12, 192.168/16, Tailscale 100.64/10, IPv6 fc00::/7). `0.0.0.0`, `::` and public addresses are refused. Firewall rules are not changed. |
| Device tokens | 256-bit random, shown once at pairing. The hub stores only their SHA-256 (`devices.json`) and compares in constant time. Revocable (`thehub revoke`). On the PC app, the token is stored in `sync\hub.token`, encrypted with Windows DPAPI. On iPhone/iPad it goes to the Keychain (this device only) and `hub.token` only names the Keychain entry; if the Keychain write fails, pairing fails rather than storing the token in plain text (iOS part not yet run on a device). |
| Pairing codes | 8 characters, single use, valid 10 minutes, made only through the admin endpoint. 5 wrong codes per address in 10 minutes → blocked. |
| Admin token | A new random token every time the hub starts, saved in `admin.token` encrypted with DPAPI (readable only by your Windows account). Admin endpoints also require the request to come from this PC. |
| Revisions | A device can only push *edits* (with a base) under its own device id. Base-less re-offers may carry other devices' revisions, so a restore can refill the hub; they follow the normal rules and never overwrite newer data. |
| Hub addresses on devices | The app accepts only `localhost`, private/Tailscale IP addresses or `*.ts.net` names. Traffic is plain HTTP, so encryption on the network relies on Tailscale (WireGuard). |
| Logs | `logs\hub.log` records only method, route, status, time, and the first 4 characters of the device id. No record content, URLs, tokens, codes or attachment ids. |

## 14. Backups and recovery

**Hub backups:**
- Stored in `%APPDATA%\THEapp-hub\backups\<UTC time>\`: `journal.jsonl`,
  `devices.json` and `manifest.json`.
- Taken once when the hub starts and every 24 h while it runs (keeps 10), and
  before every `compact`.
- The journal copy is taken between batches, so it is consistent.
- The manifest holds the journal's size and SHA-256 plus every attachment hash.
  A backup counts only once its manifest exists, and `verify` checks the
  checksum.
- Attachments are *listed*, not copied, because they are immutable. If the
  hub's attachments folder is lost, devices that still have the photos upload
  them again on their next session (§9 step 4).

**Restoring the hub** (never in place):
1. Stop the hub: `C:\src\flutter\bin\dart run bin/thehub.dart stop`
2. Restore into a **new, empty** folder:
   `C:\src\flutter\bin\dart run bin/thehub.dart restore-to "%APPDATA%\THEapp-hub\backups\<time>" "%APPDATA%\THEapp-hub-restored"`
   This refuses a folder that isn't empty or a backup that fails verification,
   and copies the listed photos from the live hub.
3. Rename `%APPDATA%\THEapp-hub` aside (keep it), then rename the restored folder
   to `%APPDATA%\THEapp-hub`.
4. Start the hub. The restored hub gets a **new hub id**, so every device
   re-offers its data (§11). Device tokens stay valid because `devices.json` is
   restored too.

**Damaged journal:**
- An unfinished write at the end (a crash or power cut) is cut off at start-up.
  The cut bytes are kept as `journal.jsonl.tail-<time>`; they were never
  acknowledged, so devices still hold those changes.
- Damage in the *middle* (a disk fault) makes the hub stop with an error and
  change nothing. Restore a backup instead.

**App backups:** see `ARCHITECTURE.md`. A restore keeps a "before-restore"
copy, and it now also clears the app's sync bookkeeping. If the app is paired,
the restored data is therefore re-offered rather than overwritten by the next
sync (§11).

## 15. Running the hub

Run every command from the project folder
`C:\Users\user\Documents\THEapp\theapp\flutter_application_1`:

| Action | Command |
|---|---|
| Start (this PC only; Ctrl+C stops it) | `C:\src\flutter\bin\dart run bin/thehub.dart serve` |
| Start, also on a Tailscale address of this PC (later) | `C:\src\flutter\bin\dart run bin/thehub.dart serve --private-host 100.x.y.z` |
| Status, memory, devices | `C:\src\flutter\bin\dart run bin/thehub.dart status` |
| Stop | `C:\src\flutter\bin\dart run bin/thehub.dart stop` |
| Pairing code for a device | `C:\src\flutter\bin\dart run bin/thehub.dart pair` |
| List / revoke devices | `… thehub.dart devices`  /  `… thehub.dart revoke <deviceId>` |
| Backup now / shrink journal | `… thehub.dart backup`  /  `… thehub.dart compact` |
| Optional start at sign-in (reversible) | `C:\src\flutter\bin\dart compile exe bin/thehub.dart -o build/hub/thehub.exe`, then `… thehub.dart startup enable` (undo: `startup disable`) |

**Pairing the Windows app** (not done yet): start the hub, run `pair`, then in
THEapp → Settings → Sync hub, enter `http://127.0.0.1:47710` and the code.

**Hub folder contents:** `journal.jsonl` (data), `devices.json`, `admin.token`,
`hub-id`, `hub.json` (only while running), `attachments\`, `backups\`,
`logs\hub.log`.

**Not verified yet:**
- the compiled `thehub.exe` and the start-at-sign-in shortcut
- `--private-host` with a real Tailscale address
- a real second device
- long-running memory use: one short run used about 100 MB, mostly the Dart
  runtime

## 16. Read-only mirror copy (`thehub mirror-*`) — experimental

A mirror is a **second, read-only copy** of the hub's history, kept in its own
folder (for example on another disk, or later on a Raspberry Pi). It is a
backup of the hub, not a second hub: devices never sync with it.

```
dart run bin/thehub.dart pair                                   # on the hub: get a code
dart run bin/thehub.dart mirror-pair   --hub http://127.0.0.1:47710 --code <code> --data D:\THEapp-mirror
dart run bin/thehub.dart mirror-run    --data D:\THEapp-mirror     # copy new changes + photos
dart run bin/thehub.dart mirror-status --data D:\THEapp-mirror
dart run bin/thehub.dart mirror-verify --data D:\THEapp-mirror     # opens the copy like a hub would
dart run bin/thehub.dart restore-from-mirror D:\THEapp-mirror <empty folder>
```

- `--data` is **required** and must not be a hub folder (one holding `hub-id`,
  `devices.json` or `admin.token`). The first version defaulted to the live hub
  folder and appended to the running hub's journal (fixed in the October 2026
  audit).
- The mirror pairs like a device (its own token, stored encrypted in
  `mirror.token`), then pulls `/v1/changes` page by page and writes the hub's own
  journal format, so `mirror-verify` and a restore open it with the normal hub
  code. Gaps in change numbers are normal (edits replace older versions).
- Photos referenced by any asset (`fileSha256`, `previewSha256`) are downloaded
  and checked by SHA-256.
- If the hub was replaced or restored from an older backup (different hub id,
  or its history is shorter than the copy), `mirror-run` **stops** and changes
  nothing. `--reseed` moves the old copy aside to `previous-<time>` (never
  deletes it) and starts again.
- `restore-from-mirror` refuses a non-empty target and an incomplete or
  damaged copy. The restored hub gets a **new hub id**, so every device must
  pair again. Nothing ever copies mirror data into the live hub
  automatically: there is one writable hub, so no split-brain.

**Failures and recovery** (each covered by `test/hub_mirror_test.dart`):

| Situation | What happens |
|---|---|
| Hub off / network down | `networkError`; position kept; next run continues |
| Crash or power cut while writing | the unfinished batch is cut off at the start of the next run (bytes kept as `journal.jsonl.tail-<time>`), so damage never sits mid-journal |
| Disk full / folder not writable | `storageError`; a failed append is cut back; the position does not move, so nothing is skipped |
| Interrupted photo download | written to a temporary file and checked by SHA-256 before it gets its real name; retried next run |
| Damaged photo copy (bit rot) | `mirror-verify` reports it; `mirror-run --repair` moves it to `damaged\` and downloads it again |
| Hub replaced or restored | stops (see above) |

**Health:** `mirror-status` prints `ok`, `ok, but N attachment(s) missing`,
`failing: <reason>` (last run failed) or `stale` (no good run for 48 hours),
plus the last error. `mirror.json` holds the same fields for scripts.

**Storage:** each photo is stored once, named by its SHA-256 (no duplicates).
The journal holds every version the hub still has, like the hub's own.

**Security:** the mirror has its own device token (revocable with
`thehub revoke`); on Windows it is DPAPI-encrypted, on Linux/macOS the file is
readable by its owner only (`chmod 600`). It only needs to reach the hub over
the Tailscale address (`serve --private-host`), which is encrypted by
WireGuard; neither side listens on public addresses.

**Raspberry Pi (optional, not done):** no Pi was available, so everything
above was tested with a second folder on this PC (simulated, not on a Pi).
On a Pi it would need: a free 64-bit OS, the free Flutter/Dart SDK (the hub
code lives in this Flutter project), Tailscale's free personal plan, and a
timer such as `crontab -e` →
`*/15 * * * * cd ~/theapp && dart run bin/thehub.dart mirror-run --data ~/THEapp-mirror`.
None of this has been tried. The mirror stays off until someone runs
`mirror-pair`.
