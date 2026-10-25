# Storage modes: this device, PC hub, hosted service

Status 2026-10-25. What is implemented and tested, and what still needs your
own infrastructure, is in §6. Code: `lib/sync/storage_modes.dart`,
`lib/app/app_state.dart` (storage modes section),
`lib/features/settings/storage_section.dart`.

## 1. The three modes

```
                     ┌──────────── every mode ────────────┐
   edits ──► THIS DEVICE'S DATA FOLDER (durable working copy, offline-first)
                     └───────────────┬────────────────────┘
                                     │ sync engine (same code for B and C)
          ┌──────────────────────────┼───────────────────────────┐
   A  local only               B  PC hub                   C  hosted service
   nothing leaves         HubServer on the Windows PC     HostedHub (same hub
   the device             127.0.0.1 / Tailscale 100.x     code, one folder per
                          or *.ts.net, device token       account) behind Caddy
                          (pairing code)                  HTTPS, account + device
                                                          token, invite to sign up
```

| | A. This device only | B. This device + PC hub | C. This device + hosted service |
|---|---|---|---|
| Where data is | this device | this device + the PC hub folder (`%APPDATA%\THEapp-hub`) | this device + the service's account folder |
| Needs | nothing | the hub running on the PC (THEapp runs it on Windows when the hub folder exists); Tailscale for devices away from home | a server you deploy (Docker, domain, ports 80/443) |
| Other devices | do **not** receive changes; use backups / "Save a copy" | sync when the PC is on and reachable | sync whenever the service is up; no PC needed |
| Transport | — | Tailscale (WireGuard) or 127.0.0.1; a home-network address is plain HTTP (warned) | HTTPS (Caddy, Let's Encrypt); the app refuses `http://` and IP addresses |
| Credentials | — | per-device token, DPAPI (Windows) / Keychain (iOS) | per-device token after email + password (Argon2id on the server) |
| Default | **yes** (a new install is local) | after pairing | never by default: only after you enter an address, account and confirm |

One provider abstraction (`StorageProvider`: `LocalOnlyProvider`,
`PcHubProvider`, `HostedProvider`) and **one** set of business rules: the PC
hub and the hosted service run the same `HubStore` (revisions, tombstones,
conflict copies, idempotent operation ids, attachments by SHA-256), and
devices run the same `SyncEngine`.

## 2. Status shown (Settings → Storage)

- The mode in use is marked; the other two have **Switch…**.
- Local: "Stored on this device only. Nothing is uploaded, and your other
  devices do not receive these changes."
- PC hub / hosted: mode, `host:port` (never a path, query or key), the live
  status (`Changes waiting to sync…`, `Hub not reachable — … Will retry.`,
  `Sync is paused`, `Synced · live`, conflicts), and the time of the last
  **successful** sync. "Synced" is never shown while a local edit is pending
  or the hub is unreachable.
- Settings → Sync hub keeps the detailed view (hub on this PC, 10-second
  jobs, Sync now, conflicts review).

## 3. Switching (copy and verify, never silent)

Every change of mode, including the first pairing and the hosted sign-in,
goes through `StorageSwitch`:

1. **Details**: address and pairing code (PC hub) or email, password, invite
   (hosted). The address is validated for the mode.
2. **Connect**: the destination must answer as a THEapp hub with the same
   protocol; then pairing / sign-in. The device key stays in memory.
   The dialog says whether the destination **already holds data**: then
   both sides are merged (never replaced); differing versions are kept as
   conflicts.
3. **Copy and verify**: a full backup of this device (records + attachments)
   is made and verified; it is restored into a temporary folder and synced to
   the destination **from there**, so the live data is not touched (it
   shares the live clock, so no revision can collide). Then every record
   version is read back from the destination and compared, every attachment
   checksum is checked, and anything that cannot sync (e.g. an unstamped
   canvas) is reported. Any difference → nothing is switched.
4. **Confirm**: only now does the new provider become active (key stored
   in DPAPI/Keychain, address saved, old connection stopped). This device
   then offers everything once (the destination already has it) and follows
   the destination's change list.

**Cancel** at any step: this device and the active mode are unchanged; what
was already copied stays on the destination (THEapp never deletes remote
data). **Back to "this device only"**: one last bounded sync attempt (20 s),
then sync stops; nothing is deleted locally or remotely, and the app says if
some changes had not reached the remote.

## 4. Sync behaviour (all remote modes)

- Edits are saved locally first; the remote is never the only copy.
- Pending changes are durable (revision ≠ last acknowledged revision) and
  survive restarts; they go out exactly once (operation id
  `device|collection|id|rev`; a retried push answers `duplicate`).
- Conflicts: the higher revision wins and the other version is kept in full
  as a conflict record (Settings → Sync → Review conflicts); a deletion never
  overwrites an edit.
- Attachments: uploaded before their record, by SHA-256; the server writes to
  a temporary file and accepts it only if size and checksum match; downloads
  are verified the same way. Interrupted transfers are retried whole on the
  next cycle (not byte-resumed); a partial file never replaces anything.
- Reconnect: sync ~0.3 s after an edit; a long-poll (`/v1/wait`, 25 s
  heartbeat) for other devices' changes; while unreachable, retries back off
  1, 2, 4 … 30 s; a safety-net sync every minute; on Windows the 10-second
  maintenance tick also syncs and backs up (no overlapping runs; stops on
  close). A revoked device stops and asks to pair again (no endless retry).

## 5. Deploying the hosted service (option C)

Code: `lib/hub/hosted_hub.dart`, `bin/thehub.dart hosted-serve /
hosted-invite`, `deploy/hosted/` (Dockerfile, docker-compose with Caddy,
`.env.example`, README). Steps (needs your own server, domain and Docker):

1. Point a DNS name (e.g. `sync.example.com`) at the server; open 80/443.
2. `cp deploy/hosted/.env.example deploy/hosted/.env`; set `DOMAIN`,
   `ACME_EMAIL`.
3. `cd deploy/hosted && docker compose up -d --build`
4. Invite: `docker compose exec hub thehub hosted-invite --data /data`
5. THEapp → Settings → Storage → **This device + hosted service →
   Switch…**: `https://<DOMAIN>`, email, password (≥ 12 characters), invite
   code. Other devices sign in with the same email and password.

Prerequisites and cost: any small Linux VPS that runs Docker (the hub is
one Dart process; one short local run used ~100 MB RAM) plus a domain name.
Prices depend on the provider you choose; THEapp does not pick or pay for
one. Storage grows with your attachments. Backups: daily per account inside
the volume — also back up the Docker volume `hub-data` off the server.
No quotas, e-mail verification or password reset exist yet. Data at rest on
the server is **not** encrypted by THEapp (use disk encryption on the
server); vault items stay encrypted end to end.

## 6. What was tested (same PC) vs. what needs your infrastructure

| | Status | Evidence |
|---|---|---|
| Local only: create/edit/restart with attachments, no network use | TESTED | `storage_modes_test`: an `HttpOverrides` that fails on any connection |
| PC hub switch: copy + verify before switching; live data unchanged; activate; everything on the hub exactly once | TESTED (127.0.0.1) | `storage_modes_test` |
| Cancel at connect / after copy: nothing changes here; hub keeps its copy | TESTED | `storage_modes_test` |
| Destination with data: merged; conflicting edits keep both versions | TESTED | `storage_modes_test` |
| Hub unreachable: edits saved, never "Synced", status "not reachable", sent once after the hub returns | TESTED | `storage_modes_test`, plus existing `app_hub_sync_test`, `sync_attack_test`, `live_sync_test` |
| Hosted service: account + invite, two devices sync with **no PC hub**; conflicts; duplicate retry; leaving hosted keeps the remote copy; no password/key/content in the log | TESTED in-process on 127.0.0.1 **without TLS** | `storage_modes_test` (`HostedProvider.allowLoopbackForTests`) |
| Hosted service as a separate process (`thehub hosted-serve`, plain HTTP on 127.0.0.1:47811) | TESTED 2026-10-25: 11/11 checks (invite required and single-use, wrong password refused, two devices of one account exchange a record and an attachment by SHA-256, retried push recognised, admin/share off) | `tool/hosted_check.dart` |
| Docker image build, Caddy/Let's Encrypt TLS, a real domain | NOT TESTED — no Docker, server or domain here | — |
| Tailscale across different networks, a physical iPad/iPhone | NOT TESTED in this change (see SYNC_ARCHITECTURE.md §17) | — |
| Byte-range resume of a half-sent attachment | NOT IMPLEMENTED (a cut transfer is retried whole and verified) | `sync_attack_test` |
