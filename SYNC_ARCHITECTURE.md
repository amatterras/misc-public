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
- **When it runs** (`lib/sync/sync_scheduler.dart`, since 2026-10-24):
  - **About 0.3 s after a local edit.** Edits made close together travel together.
  - **At once when the hub reports another device's change.** The app keeps one long-poll open: `GET /v1/wait?since=<cursor>`. The hub answers as soon as it has stored something newer, or after 25 s as a heartbeat, and the app then pulls.
  - **A request made while a sync is running** is remembered and runs right after it; it is never dropped.
  - **Every minute** as a safety net, and on **Sync now**.
  - **When the hub is unreachable:** the long-poll retries after 1, 2, 4 … up to 30 s. A successful sync ends the wait early and catches up.
  - **A hub without `/v1/wait`** (older version, 404) is simply polled.
  - **iPhone/iPad:** the long-poll stops in the background and restarts on resume.
  - Measured on this PC (`test/live_sync_test.dart`, real hub on 127.0.0.1): PC → iPad in 70–360 ms; catch-up after a hub restart in 0.5–2.1 s.
  - Opening a canvas waits until a running sync has finished writing.
- **Status shown** (Settings → Sync), always the current truth:
  - "Changes waiting to sync…" while a local edit has not gone through a successful sync.
  - "Hub not reachable — your changes are saved here…" while offline.
  - "Synced · live" when connected live.
  - The last result (conflicts, problems) otherwise.
- **The change envelope** is the existing `SyncChange`:
  - entity id = `collection/id`;
  - operation id = `device|collection|id|rev`, idempotent on the hub;
  - revision = hybrid logical clock, which also carries the origin device and time;
  - operation = create/update (`data`) or delete (`deleted`). A move is an update of a parent/folder field.
  - Hub order = `seq`.
  - The acknowledgement is the per-change `PushResult`.
  - Nothing was added to the envelope: no migration was needed.

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
| `GET /v1/wait?since=N&timeout=S` | device | — | `{lastSeq, hubId}` as soon as `lastSeq > N`, or after S (1–25) seconds; no record data. Old hubs: 404 → clients poll |
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

**Pairing the Windows app** (done on 2026-10-22 for this PC's app): start the
hub, run `pair`, then in THEapp → Settings → Sync hub, enter
`http://127.0.0.1:47710` and the code. For testing, use the separate test hub
and test app from `tool\testenv.ps1` (port 47799), never this one.

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
| Two runs at once (e.g. a timer overlapping a slow run) | `mirror.lock`: the second run reports `busy` and changes nothing; a lock older than 2 hours (crashed run) is taken over |

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

## 17. Sync across different networks (remote) — status and design

**Status (2026-10-22): works through this PC's Tailscale address; NOT yet
verified across networks.** Tailscale is installed and signed in on the PC
(one device in the tailnet; the Tailscale network is classed Private). The
TEST hub listened on `127.0.0.1:47799` and the PC's Tailscale address only,
and `tool/remote_check.dart` passed 11/11 checks through that address (see
below) — all on this PC, so no data has crossed between networks yet. That
needs a second device signed in to the same tailnet on another network.
There is no cloud server. The Windows PC remains the only writable hub.

### Capability audit
| Capability | Status | Evidence |
|---|---|---|
| Sync on this PC (127.0.0.1), offline queue, retries, idempotency, conflicts, deletions, attachments | IMPLEMENTED AND VERIFIED | `sync_engine_test`, `sync_risks_test`, cross-process two-client runs on the disposable hub |
| Hub listening on a private/Tailscale address (`serve --private-host`) | IMPLEMENTED AND VERIFIED (on this PC) | test hub bound to the PC's Tailscale address and loopback only (`netstat`, hub status); `remote_check`: tokens required, wrong tokens refused, admin refused from the Tailscale side even with the admin token, real hub port 47710 not reachable there, disposable device paired/sent/received/revoked through it |
| Access from another device in the tailnet | VERIFIED (same home network) | 2026-10-22: an iPad in the tailnet opened the test hub's status page through `100.64.12.34:47799` (hub log shows the request; correct hub id reported by the user) and could not reach port 47710 (real hub). Tailscale showed the path as *direct via 192.168.1.x*, i.e. the iPad was on the same home network — so this is NOT a cross-network result. No firewall rule was added. |
| Access from a different network | NOT VERIFIED | iPad status-page attempts all went over the home network |
| THEapp sync between two devices on different networks | BLOCKED | needs a second device that runs THEapp (a second Windows PC/laptop, or an iOS build made on a Mac); the user has only an iPad and there is no iOS build (recorded 2026-10-22) |
| Devices accepting Tailscale addresses (`100.64/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`) | IMPLEMENTED AND VERIFIED (address rules) | `remote_readiness_test` |
| Authentication and pairing | IMPLEMENTED AND VERIFIED | `hub_test`, `hub_auth_test` |
| Revocation (`thehub revoke`) | IMPLEMENTED AND VERIFIED | revoked tokens refused for push, pull and attachments; the device stops automatic sync, says to pair again, keeps unsent edits and sends them after pairing again (`remote_sync_test`) |
| Encrypted transport | PARTIAL | Tailscale (WireGuard) encrypts; plain home-network addresses are NOT encrypted — the app now warns before pairing with one (`remote_sync_test`) |
| Test copies reaching a real hub | PREVENTED | test data mode pairs only with 127.0.0.1:47799 (`test_environment_test`) |
| Sync between different networks | BLOCKED | Tailscale is set up on the PC and the iPad, but a real sync test needs a second device that runs THEapp (only an iPad is available; no iOS build) |
| PC off | by design: no sync | devices keep working and queue changes |

### Architecture choice
- **Chosen: private Windows hub reached over Tailscale.** $0, nothing public,
  no new server to run. Consequence: **the PC must be on, awake, signed in
  (or the hub started at sign-in) and online** for devices to sync; while it
  is off, each device keeps working and catches up later.
- **Not chosen: an independent server** (VPS or always-on box acting as the
  writable hub). It could sync while the PC is off, but costs money or needs
  a machine running at home 24/7, adds maintenance and security work, and
  would change which copy is authoritative — a design change that needs the
  user's approval. The optional Raspberry Pi stays a read-only mirror.

| Question | Answer (as implemented) |
|---|---|
| Authoritative data | The Windows hub (`%APPDATA%\THEapp-hub`). Devices hold full offline copies. |
| PC off or unreachable | Devices keep working offline; changes stay queued on disk (verified across app restarts) and are sent when the hub is reachable again. Nothing syncs device-to-device in between. |
| Reachability from another network | A private **Tailscale** network: the PC and the iPhone/iPad join the same tailnet; the hub listens on the PC's Tailscale address (`serve --private-host 100.x.y.z`). No router port is opened, nothing is public. |
| Transport security | WireGuard encryption between devices (Tailscale). The hub itself speaks plain HTTP on that private link. A plain home-network address (e.g. `192.168.x.x`) is **not** encrypted; the pairing screen warns about it and the log records which kind of address was paired. |
| Authentication / revocation | Per-device 256-bit tokens from one-time pairing codes; `thehub revoke <id>`; tokens stored with DPAPI (Windows) / Keychain (iOS). |
| Offline, retries, idempotency, conflicts, deletions, attachments | Same protocol as on one PC (§10–§12); verified by automated and cross-process tests. |
| Backups / recovery | Hub backups (§14) and the optional read-only mirror (§16). |
| Allowed addresses | Devices accept only this PC, private ranges, `100.64.0.0/10` and `*.ts.net`; the hub refuses `0.0.0.0`, `::` and public addresses (`test/remote_readiness_test.dart`, `hub_test`). |
| Recurring cost | $0 on Tailscale's free Personal plan today. A free plan can change; it is not assumed permanent. |

**What blocks it:** installing Tailscale on the PC and the iPhone/iPad and
signing in is a user action (and an account decision) that was not
authorized; the iOS app itself also needs a Mac to build. Until then, sync
works on this PC and on the home network.

**Least-cost alternatives if Tailscale stops being free:** (1) home-network
only sync (works today, $0, only at home); (2) a self-hosted WireGuard
endpoint on the home router or a Raspberry Pi ($0 software, needs one router
port forwarded — a network-security change that needs explicit approval);
(3) a paid relay/VPS (rejected under the zero-cost rule).

**Steps for the user when ready (each is the user's own decision):**
1. Create a free Tailscale account and install Tailscale on the PC; sign in.
2. Install Tailscale on the iPhone/iPad (App Store, free) with the same
   account. (The iOS app itself still needs a Mac to build.)
3. Note the PC's Tailscale address (`100.x.y.z`, shown in the Tailscale app).
4. Stop the hub and start it again with
   `dart run bin/thehub.dart serve --private-host 100.x.y.z`. Windows may ask
   whether to allow the hub on the network — allow it for **private
   networks only**.
5. Run `dart run bin/thehub.dart pair` and pair the device with
   `http://100.x.y.z:47710` (no warning should appear for this address).
6. First check: make a note on one device, wait a minute, see it on the other.

## 18. Sync switch, read-only mirrors and the attack tests (2026-10-24)

- **Sync on/off (Windows app, Settings → Sync → "Sync between devices"):**
  - Off saves the setting and stops this app's sync.
  - It also pauses the hub on this PC (`POST /v1/admin/pause {paused}`, this PC only, admin token). The pause is kept in the hub folder (`paused` file) and survives restarts.
  - While paused, every device's sync request gets `503 sync_paused`. Devices keep their changes queued; nothing is reset or marked as synced. Their `/v1/wait` is held, so they show "paused" and notice the resume immediately.
  - On restarts the connections, reconciles at once, and both sides catch up. Measured: 44–187 ms from resume to delivery.
  - Read-only mirrors keep reading while paused, so backups continue.
- **Read-only devices:**
  - Mirrors register with `readOnly: true`.
  - Devices whose id starts with `mirror` are treated as read-only, including ones paired before this flag existed.
  - The hub refuses pushes and attachment uploads from them with `403 read_only`.
- **Attack tests** (`test/sync_attack_test.dart`, `test/live_sync_test.dart`): real hub, real engines, separate data folders, plus a fault-injecting proxy. This is a simulation on one PC, not physical devices. They cover:
  - simultaneous edits;
  - different items;
  - offline add/update/delete on both sides;
  - a push stored by the hub whose reply is lost, followed by a hub restart;
  - an upload cut half way (never stored; the retry arrives intact);
  - out-of-order and repeated delivery;
  - an old client coming back after deletions;
  - a device clock 2 h behind;
  - 12 reconnect cycles;
  - a mirror trying to write;
  - pause and resume;
  - a third device receiving photo bytes.

  Every case converges: all devices agree and nothing more is pushed. No defect was found in the record rules. Two scheduler defects were found and fixed:
  - a held wait did not end on resume (delivery hung);
  - delivery after resume took 3–4 s.

## 19. External calendar synchronization (2026-10-24)

This is provider synchronization from the app client, separate from the
Windows-authoritative workspace hub in the preceding sections.

- Google Calendar uses incremental `syncToken` pagination with the same query
  parameters for initial and incremental requests; expired tokens trigger a full
  fetch. Outlook uses Microsoft Graph calendar-view delta links and restarts a full
  window fetch after an expired delta link.
- Provider-created events are materialized as read-only `ExternalEvent` records.
  THEapp Reminder/Event entries optionally export to a chosen provider calendar and
  update/delete through persistent `CalendarLink` records. Provider changes to a
  linked local entry are applied when the remote `updated` timestamp is at least as
  new as the local record; older remote edits lose and are reported. Imported events
  have no local editable copy, so editing them remains a provider-side action.
- A timed entry with no positive duration is retained locally and skipped during
  export; the prior remote link is protected from accidental deletion. A user must
  supply its duration before a valid provider end time can be sent.
- Create operations are retry-safe: Google uses a deterministic event id and
  private THEapp key. Outlook uses Graph `transactionId`. For either provider with
  a stable create identity, the local pending link is flushed before the POST and
  completed after the provider returns its id. Google recovery validates the
  private operation key after a 409 response.
- Accounts refresh on app startup, resume, explicit Sync now, and every five
  minutes while the app is active. Unexpected scheduled-run errors leave a user
  status and a stack-only local diagnostic; provider response bodies and tokens are
  not written to that diagnostic.
- Automated tests use local HTTP servers and a deterministic in-memory provider.
  They cover query construction, Google lost-response recovery, Outlook transaction
  ids, local/remote edits, conflict ordering, deletion, multi-day events, restart
  retry, and missing duration. These tests do not establish live provider
  authorization or actual account behavior. The end-to-end tests run from
  `test/platform_features_test.dart` (`P3 calendar sync`).

## 20. Hub run by THEapp, 10-second backup and sync, disconnect fixes (2026-10-24)

**Why the hub "disconnected" (root causes found on the PC)**
1. The hub only ran when started by hand (`thehub serve` in a console). Nothing started it again after the window closed. The leftover `hub.json` pointed at a dead process (pid 12664, last request 2026-10-22 04:54). No sign-in shortcut existed.
2. Without `--private-host`, the hub listens on 127.0.0.1 only, so the iPad can never reach it. The address also had to exist at start.
3. The hub's listeners had no error handler. In a standalone Dart process, an unhandled listener error ends the whole process. The PC's Wi-Fi adapter was dropping and reconnecting repeatedly around that time (Intel `Netwtw10` events). Whether that killed the hub could not be proven from the logs, but the gap is closed either way.
4. The PC app did not log sync failures (`SyncFailure` was skipped), so the outage left no trace.

**What changed**
- **Hub inside THEapp on Windows** (`lib/hub/hub_host.dart`).
  - The hub runs in its own isolate while THEapp is open. This happens only if `%APPDATA%\THEapp-hub` exists and the app is not in test-data mode.
  - If a hub already answers on the port (e.g. `thehub serve`), THEapp uses it and starts none. Binding the port is the cross-process lock.
  - It listens on 127.0.0.1 and on this PC's Tailscale address (100.64.0.0/10), detected automatically.
- **Health check every 10 s.**
  - Follows a new or changed Tailscale address, and reopens a listener lost to a network change (127.0.0.1 untouched).
  - Makes a real HTTP request on each address.
  - After 3 failed checks on 127.0.0.1, the isolate closes its listeners and starts the server again in place (same data, same port).
  - A new isolate is started only if the old one ended after closing its sockets.
  - Limitation: in this Dart VM, a *killed* isolate keeps its listening port until the process ends. So the hub isolate runs in a guarded zone that never lets errors end it. If it ever freezes completely, the status says to reopen THEapp.
- **Listeners** (`HubServer._serve`) log errors and closures instead of ending the process. `setPrivateHost` re-binds at runtime.
- **`thehub serve --private-host auto`**: same Tailscale detection, plus a 10-second listener check. The sign-in shortcut uses it.
- **10-second work** (`lib/app/maintenance.dart`), Windows only. One scheduler is started once at the end of start-up; it keeps running while the window is minimised and stops on close. Each tick runs four jobs; each job runs at most once at a time, and a tick missed during a run is run once afterwards.
  1. Hub check.
  2. Sync (`syncNow`): counts as done only if a cycle really completed.
  3. App backup (`BackupService.liveSnapshot`), only after a change:
     - records are copied into a hidden `.partial-…` folder and compared with the live files, then renamed;
     - a failure leaves earlier backups untouched;
     - leftovers are removed at start;
     - its own rolling set of 12, never pushing out daily, weekly, manual or pre-upgrade backups;
     - sync and this backup share a lock, so they never touch the data at once.
  4. Hub backup (`HubBackups.createLive`), only after `lastSeq` changed:
     - journal and devices first, manifest last;
     - checked;
     - kept in `backups/live`, 12 at a time;
     - included in the 7-day calendar purge.
- **Status** in Settings → Sync shows:
  - hub state and addresses;
  - last real sync and backups;
  - what runs now;
  - each job's last error, retried every 10 s.
- **Log**: each sync connection change is logged once (unreachable / connected again).

**Tests**
- `hub_host_test` (7): one hub only; uncaught errors; in-place restart; isolate end; port held; live hub backups; listener re-bind.
- `maintenance_test` (9): starts once; 10-second cadence on a fake clock; no overlap; truthful outcomes; clean stop; lock; checked, interrupted and bounded backups.
- `app_hub_sync_test` (1, end to end): outage reported as failed, never "synced"; recovery and catch-up without duplicates; navigation adds no scheduler; clean shutdown.
- `hub_stability_test`: opt-in long run.

## 21. Storage modes and switching (2026-10-25)

The PC hub stays the authoritative writable hub in PC-hub mode; nothing in
§9–§20 changed. Added on top (details in [STORAGE_MODES.md](STORAGE_MODES.md)
and [DATA_MIGRATIONS.md](DATA_MIGRATIONS.md)):

- One `StorageProvider` abstraction for local only / PC hub / hosted
  (`lib/sync/storage_modes.dart`). The hosted service (`HostedHub`) runs the
  same `HubStore` rules as the PC hub.
- Pairing and hosted sign-in now go through the copy-and-verify switch:
  verified backup → copy from a temporary restore (live data untouched) →
  read back and compare every record version and attachment checksum →
  user confirms → activate. Cancel changes nothing; remote data is never
  deleted.
- Fixed: ISO-date tombstones from schema-1 files were never converted to
  stamps and made the hub refuse the push batch ("Invalid revision").
- Fixed: canvases created without revision stamps (new or welcome canvases
  never edited) did not sync; `canvas-revisions-v1` stamps existing ones and
  new canvases are stamped when created.
- Deletions received from another device are kept locally in "recently
  deleted" (30 days); a restore is a new edit that wins over the deletion
  on every device without bringing back anything else.

---

# End-to-end encryption and secure transport (§16, protocol 1, added 2026-10-28)

## 16.1 Transport rules (enforced before anything is sent)
- **Plain `http://` is only used for this PC (127.0.0.1, `localhost`) and for Tailscale** (100.64.0.0/10, `fd7a:115c:a1e0::/48`, and `*.ts.net` names that resolve into those ranges; WireGuard encrypts that network).
- **Every other network address needs `https://`**: a home network (192.168.x.x, 10.x.x.x, 172.16-31.x.x) or a hosted service. `SyncClient` refuses a plain-http address with `insecure_transport` *in its constructor*, so no pairing code, device token or record is ever sent, and there is no silent fallback to http.
- **Certificates are validated.** HTTPS uses the system trust store. A hub with its own certificate (home network) is reached only by **pinning**: the pairing code carries the first 16 hex digits of the certificate's SHA-256 (`<26 characters>.<fingerprint prefix>`); the app connects once, sends nothing, checks the certificate matches the prefix, and pins the full fingerprint. Any other untrusted certificate is refused (`certificate_rejected`, not retryable). `badCertificateCallback` accepts only the pinned certificate for that host and port.
- **The hub** listens plainly only on 127.0.0.1 and Tailscale. A home-network address needs `thehub serve --private-host <ip> --tls-cert cert.pem --tls-key key.pem`; without them the hub refuses to listen there. (Making the certificate is up to the user: `mkcert`, `tailscale cert`, or `openssl`. THEapp does not generate one.)

## 16.2 What the hub can and cannot see
- Records and attachments are **sealed on the device** (AES-256-GCM, a per-message key from HKDF, a random nonce; `lib/sync/e2ee.dart`) with one random 256-bit **workspace key** shared by the user's devices. The hub (and anyone with its disk, backups or database) holds ciphertext only.
- Each sealed record is bound to its place: collection, id and revision are authenticated, so a hub that moves a ciphertext to another record is detected (`e2ee_unreadable`) rather than believed.
- **Visible to the hub, because it needs it:** the collection name, the record id (random), the revision stamp (device id and time), the deleted flag, the ciphertext size, attachment ids (SHA-256 of the *sealed* bytes) and sizes, and for share links the expiry and revoked flags. Titles, text, URLs, file names, tags and every other field are inside the ciphertext. The size of a record or file is visible.
- **Conflicts** are still resolved by the hub from revisions alone; the loser is kept as a conflict record whose preserved version is sealed too and is opened on the device.
- **Attachments** are sealed in full; the id the hub stores them under is the SHA-256 of the sealed bytes (so it cannot confirm that a known file is present). The sealed copy's id travels inside the sealed asset record (`fileBlob` / `previewBlob`).

## 16.3 The workspace key and pairing
- The key lives only in OS-protected storage (Windows DPAPI, the iOS Keychain; `lib/sync/sync_key_store.dart`), never in a backup, and a platform without that storage does not sync at all.
- **Pairing a new device** uses a longer code made on a device that has the key: 26 characters (130 random bits). The hub is given only `registerCode` (a one-way function of the code) and the workspace key *wrapped* under another one-way function of it (AES-GCM). The code never leaves the two devices; the hub cannot unwrap the key, and a hub that substitutes its own wrapped key fails the GCM check. Endpoints: `POST /v1/admin/pair` with `{registerCode, wrappedKey}` (this PC), `POST /v1/pairing` and `POST /v1/pairing/redeem` (signed-in devices, for hosted accounts). `POST /v1/register` returns `wrappedKey`.
- An **ordinary short code** (`thehub pair`) carries no key. After the hub is switched to encrypted-only such a device can only read: this is how a Raspberry Pi mirror stays a read-only copy of ciphertext.
- Key transfer is the only way to open data on a second device. There is **no recovery**: if every device loses the key, the hub's data cannot be read.

## 16.4 Share links
- A share snapshot (title and text) is sealed on the device with a fresh key that is **only in the link's `#fragment`** (`https://hub/s/<token>#k=<key>`). Browsers never send the fragment, so the key is not in requests, hub logs, analytics or referrers (`Referrer-Policy: no-referrer`). The hub stores and serves the ciphertext in a page whose small inline script (pinned by a CSP hash) opens it with WebCrypto.
- Expiry, revocation, read-only access and the identical "not available" answer for unknown, revoked and expired links are unchanged; a revoked link keeps no ciphertext. WebCrypto needs a secure context, so a link opened over plain http (e.g. Tailscale without a certificate) shows "open this link over HTTPS".
- Only notes, links, calendar entries, canvases and thought experiments can be shared; the private vault is not shareable.
- Links made before this change have no key in their address and cannot be sealed for the same URL: during the upgrade they are retired (revoked). Make a new link.

## 16.5 Upgrading a hub that holds plain data (once, by the first updated device)
1. The device asks the hub (`GET /v1/e2ee`) whether it requires encryption and how many plain records it holds.
2. If it holds any, the device **re-offers every record sealed**. A sealed copy replaces the hub's plain copy of the same revision.
3. The hub is asked again and must report **0 plain records**; the device reads **every record back**, opens it and compares it with its own copy.
4. Only then `POST /v1/e2ee/commit`: the hub refuses (`plaintext_remaining`, nothing changed) if any plain record is left; otherwise it switches to encrypted-only (plain pushes and uploads are refused with `plaintext_rejected`), rewrites its journal without superseded versions, **deletes its plain attachment files**, makes a new backup of ciphertext and **removes every older backup**.
- If a record cannot be migrated the upgrade stops, is reported in the sync status, and no end-to-end claim is made; the next sync tries again.
- **Not controllable:** copies outside the hub's own folders (a Raspberry Pi mirror's earlier copy, disk snapshots, file-system journals, the device's own older backups) are not touched; erasing them is not guaranteed.
- Order matters with several devices: update one device (the PC) first; other devices must be paired again with a new code to get the key. Until then they fail with `e2ee_unreadable` / `plaintext_rejected` instead of using or exposing data.

---

# Devices, key changes and deleting for good (§17, added 2026-10-28)

## 17.1 Devices
- **Settings → Sync → Devices** lists every paired device: name, "this device", **can read and write** or **read-only** (a mirror), whether it was removed, and when it was **last seen** (updated at most once a minute). `GET /v1/devices`.
- **Removing a device is done by the hub**, not by the screen. `POST /v1/devices/revoke` (a writable device) marks it removed; from its very next request every endpoint answers `unauthorized`, and any long-poll it was holding ends at once (a removal wakes the hub's waiters and each wait re-checks the device before answering). The PC's admin `revoke` does the same.
- **Roles cannot be changed by any request.** A read-only device cannot remove devices, change keys, commit, or offer pairings (`read_only`, 403); nothing makes a read-only device writable.

## 17.2 A new workspace key when a device is removed
- Every device has a P-256 key pair; the private half is in OS-protected storage, the public half is on the hub with an **endorsement**: an HMAC under the first workspace key over the device id and public key. Only a holder of the workspace key can make one, so the hub cannot add a device of its own.
- After a removal the removing device makes the **next key epoch** and wraps it separately for each endorsed, non-removed, non-read-only device (including itself): ECDH with a fresh key, HKDF, AES-256-GCM. Each wrapped key also carries an HMAC under the first workspace key, so a device accepts a new key only from a holder of the old one, never from the hub. Nobody types anything. `POST /v1/keys`, `GET /v1/keys?since=N`.
- From then on records and attachments are sealed under the new epoch (`k` in the sealed record; the epoch is part of what is authenticated). The hub refuses records sealed under an older epoch (`stale_key`, 409, retryable) so a device that missed the change cannot write something the removed device could read. Devices fetch the key at the start of each sync. Older records stay readable with the older keys, which every device keeps.
- **Limits:** the removed device keeps what it already downloaded and the old keys, so it can still read records it has (and older ones it could fetch before removal). Devices that never published a public key (an old app) are named after the change and must be paired again. Existing records are not re-sealed under the new key.

## 17.3 Deleting for good (permanent purge)
- An ordinary deletion is unchanged: undoable from "recently deleted", and an old copy can still bring the record back. **Delete for good** (Settings → Storage → Recently deleted) is different: the record leaves active storage and "recently deleted" (and, for a note, its saved versions); links that shared it are revoked and blanked; attachment files nothing else uses are deleted; every copy in the app's backups and saved copies is removed (with a tombstone in its place; manifests rewritten, retention untouched); the previous-version copies (`.bak`) of the live files are refreshed.
- A permanent **purge mark** (`purges/<collection>.<id>`, sealed like any record) syncs to every device and the hub. The hub **refuses any later write of that record from any device, whatever its revision**, refuses to undo the mark, adds its own tombstone, rewrites its journal without the record's old versions, removes them from every hub backup, and removes the sealed attachment copies the record alone used. Another device that still has the record loses it when the mark arrives; a restored backup or an old copy cannot bring it back because the mark and the hub's lock outlive them.
- **What this is not:** forensic erasure. Disks, wear levelling, journaling and the operating system may keep traces; a copy the user exported or made outside THEapp, a link someone already read, and a device that is switched off are out of reach until it syncs. AI chats that quoted the item are not edited. The words in the app say so.

---

# Reliability pass (2026-11-05)

## 22.1 Hub start at sign-in: checked, was NOT working (fixed in 23.3)
Inspected on this PC (nothing was rebooted, so a start after a reboot was not
tested): the Startup folder holds only `desktop.ini`; no `HKCU\...\Run` entry,
no scheduled task and no `build\hub\thehub.exe` exist; `thehub startup enable`
refuses to run without that exe, and §15 asks the user to compile it by hand
first. So after a reboot nothing starts the hub until THEapp itself is opened
(§20: the hub then runs inside THEapp). While THEapp is closed the iPad cannot
sync. Not changed in this pass (out of scope); open item.

## 22.2 iPad / device disconnection (done)
- `SyncScheduler.onBlocked`: a 401 from the live wait or from a cycle stops
  the scheduler and tells the app once (before, only a cycle did; the app
  kept saying "Synced" and nothing retried on an iPad).
- `SyncConnection.blocked`: a refusal that waiting does not fix (for example a
  version mismatch) is shown as such, never as "… · live"; a later success
  clears it.
- `start()` forgets old failures (the first retry after the app returns to
  the front is immediate, not up to 30 s later).
- "Pairing required" is no longer final: coming back to the front, "Sync now"
  and Settings → Sync → "Check again" look once more; a hub that accepts the
  device again (for example the right hub after a wrong one answered on the
  same address) clears it. A really removed device stays "pairing required".
- Tests: `test/sync_recovery_test.dart`.

## 22.3 Conflicts (done)
- A notice on every page while conflicts wait; one message when new ones
  arrive; Settings → Sync keeps the button.
- The review window shows the current and the other version side by side;
  opening it changes nothing. "Keep current" and "Use other" both settle the
  conflict and keep both versions inside it; "Undo" (under Settled) takes a
  settling back; settled conflicts are pruned after 90 days, open ones never.
- Mindmap/notebook item conflicts can now be restored (before: dismiss only).
  `CanvasController.restoreItem` / `removeItemById` stamp a new revision, so
  the choice syncs like any edit. Conflicts on a canvas's title / item order
  / PDF pages (`canvases`) are shown and can be kept, not restored (pages are
  merged automatically already).
- Tests: `test/conflict_resolution_test.dart`.

## 22.4 Cost of a sync cycle (measured) and the proposal (implemented in 23.2)
`tool/sync_bench_test.dart` (run: `flutter test tool/sync_bench_test.dart`;
real hub on 127.0.0.1, one device, data at rest not encrypted, so real times
are higher). Medians of 5 cycles in which nothing changed:

| Data | Idle cycle | of which `localVersions()` | Cycle after 1 item changed |
|---|---|---|---|
| 100 items (5 notes) | 46 ms | 19 ms | 108 ms |
| 2.5k items, 2.6 MB | 111 ms | 91 ms | 310 ms |
| 10k items, 10.5 MB | 419 ms | 417 ms | 737 ms |
| 2.5k items, 39 MB on disk | 368 ms | 379 ms | 406 ms |
| 10k items, 157 MB on disk | 1601 ms | 1307 ms | 1377 ms |

First full sync: 0.4 s / 2.4 s / 13 s / 4 s / 15 s. The cost of "nothing
changed" grows linearly with the total size of all canvas files, because every
cycle reads and parses every canvas (`SyncEngine.localVersions`, which also
keeps every item's data in memory) just to learn their revisions. The PC runs
a cycle every 10 s and after every edit.

Proposal: a **revision manifest** (cache, never the source of truth).
1. `sync/canvas_manifest.json` (stored like the other sync files, so at-rest
   encryption applies): per canvas id → `{metaRev, itemRevs, tombstones,
   file size, file mtime}`. No item data.
2. Written by `canvases.save` / `delete` with the file, so it follows every
   write the app makes (edits, remote changes applied by sync, migrations).
3. A cycle `stat`s each canvas file (no read). A file whose size/mtime differ
   from the manifest, or a new/missing file (restore, import, another
   process), is re-read and its entry refreshed. A missing or damaged
   manifest is rebuilt by the full scan that exists today. Pending = revisions
   differ from `state.base`, exactly as now; only canvases with something
   pending are loaded for their data.
4. Updates: the save writes new revisions into the entry. Deletions:
   item tombstones are in the entry; a deleted canvas drops it (and the stat
   pass notices a missing file). Offline edits: nothing is queued separately,
   pending is derived from revisions as before, so a lost manifest loses no
   edit. Conflicts: unchanged, since the hub decides from revisions and the
   incoming-change check (`isPending`) still reads the live revisions of the
   canvases that actually receive changes.
5. Safety net: a full re-verification (manifest vs full scan) at start, after
   any restore/import/migration and once a day, logged if it ever differs;
   the full scan stays the fallback and the one-time end-to-end upgrade keeps
   using it.
6. Proof required before shipping: a property test that after random
   sequences of edits, deletions, remote applications, offline periods,
   restores and externally replaced files the manifest-based pending set
   equals the full-scan pending set.
Smaller, independent step: the 10-second tick runs a full cycle even when the
live connection already reports changes; skipping it when nothing is pending
and the hub's change number has not moved would remove the idle cost on the PC.

## 22.5 A saved mindmap edit did not ask for a sync (fixed in 23.1)
`AppState._saveCanvas` (mindmaps) does not tell the scheduler (note pages and
the Archive board do, in `saveDocument`). Measured: after a mindmap edit was
saved, the device did not show "changes waiting" and the hub had not received
the item 3 s later. Mindmap edits therefore wait for a timer: up to 10 s on
the PC, up to 60 s on an iPad (no 10-second job there). A one-line change
(`_editedLocally()` after the save) with a regression test would fix it.

## 23. Second reliability pass (2026-11-05): fixes, tests, measurements

### 23.1 A saved mindmap edit asks for a sync
`AppState._saveCanvas` now calls `_editedLocally()`. Measured: save -> hub 355 ms
on the iPad configuration (before: waited for a timer, up to 60 s). The
scheduler's 300 ms pause batches rapid saves (30 saves, a handful of cycles).

### 23.2 Incremental change detection (the manifest)
`lib/sync/canvas_manifest.dart`. A cache of each canvas's revisions plus a
fingerprint (size and modification time of the file and its previous copy);
never the source of truth. An entry is believed only while the fingerprint
matches AND nothing wrote the file through `JsonFileStore` since (write
listener); a missing, damaged, foreign, stale or older manifest only means
"read that canvas again". It is verified against every file when new and once
a day. Writes are atomic (the store's temp file + rename). `SyncEngine.pendingVersions`
reads only canvases with something pending; `pendingVersionsFullScan` is the
reference it must equal: `test/canvas_manifest_test.dart` runs 12 random
sequences x 70 steps of every kind of change and compares after each step.
A canvas file that cannot be read no longer fails every sync (skipped and logged).

Benchmark (`flutter test tool/sync_bench_test.dart`, this PC, data not encrypted):

| Data | Idle cycle before -> after | 1 item changed before -> after |
|---|---|---|
| 100 items | 46 -> 29 ms | 108 -> 110 ms |
| 2.5k items, 2.6 MB | 111 -> 29 ms | 310 -> 87 ms |
| 10k items, 10.5 MB | 419 -> 86 ms | 737 -> 172 ms |
| 2.5k items, 39 MB on disk | 368 -> 32 ms | 406 -> 84 ms |
| 10k items, 157 MB on disk | 1601 -> 72 ms | 1377 -> 160 ms |

### 23.3 Hub at Windows sign-in
`lib/hub/hub_startup.dart`, `thehub startup enable|disable|status`, `thehub serve
--background yes`. `enable` builds `thehub.exe` itself (the documented manual
compile failed on a fresh checkout: the output folder did not exist), registers
a Startup-folder shortcut (idempotent, updates a moved or damaged one, handles
spaces and apostrophes, leaves nothing on failure), and the hub then runs
without a window, independently of THEapp (THEapp's own host recognises it as
external). `status` shows what is registered, whether its program exists,
whether a hub answers, and the log. Tests: `test/hub_startup_test.dart` (16),
including the real compiled program started the way a sign-in starts it, killed
and started again. NOT verified: that Windows runs the shortcut at the next
sign-in (needs a sign-out/reboot). It is not registered on this PC by the change.

### 23.4 Connection state
- Unexpected errors and refusals that waiting does not fix are `blocked`, never
  "live"; while blocked every request except "Sync now" is throttled (15 s,
  doubling to about 8 min), including the Windows 10-second job.
- A stopped scheduler (app in the background) says sync is not running, not "Synced".
- A cycle with problems says "Some changes could not sync: ...", not "Synced (...)".
- Scenario lab `test/support/sync_rig.dart` + `test/sync_scenarios_test.dart`
  (19 scenarios): real hub, production AppState devices (PC or iPad
  configuration), controllable networks; every step of the old manual checklist.

### 23.5 Conflicts
Settling records its intent (both versions inside the conflict record) and saves
it BEFORE touching the record; `recoverInterrupted` finishes an unfinished one at
start-up. Malformed conflict records are listed and kept. A settled conflict
cannot be settled again. `test/conflict_robustness_test.dart` (14).

### 23.6 Other fixes from the audit
- The hub compacts its journal itself (after a backup, when it is at least 16 MB
  and over 3x what a compaction would keep); before, it only ever grew.
- Stale partial downloads (7 days) and stray staged uploads (1 day) are swept.
- Pairing-code expiry and the wrong-code throttle share one replaceable clock
  (tested without waiting).

### 23.7 Not verifiable here
Real iPhone/iPad behaviour (suspension by iOS, the Share Extension on a device),
Windows running the sign-in shortcut after a reboot, Tailscale across networks,
real-service AI answers. The iOS build is checked in Codemagic (compiles, App
Group entitlement in all three targets); it is not run on a device.
