# misc. — security audit, threat model and status

Date: 2026-11-04. Scope: this repository (Windows app, Windows hub, iOS runner,
widget and share extension). Method: reading the code and the tests, plus new
tests (`test/security_zero_friction_test.dart`). **This is not an independent
audit, nothing here was run on an iPhone or iPad, and misc. is not "secure" or
"OWASP-certified" because of it.** OWASP MASVS/MASTG were used as a checklist
of topics only.

Legend: **Implemented** (in code) · **Tested** (automated test on Windows) ·
**Unverified on device** (Swift/iOS or real network, never run) · **Not
implemented**.

## 1. Valuable assets

Notes, tasks, calendar, mindmaps and handwriting; imported photos and PDFs; the
Archive; the workspace encryption key; per-device hub tokens and the hub admin
token; AI provider keys; backups and exported `.theappbackup` files; the hub's
copy of the data.

## 2. Attackers considered

1. Someone with the disk or a copy of a backup (lost laptop, stolen iPad, cloud
   copy). 2. Another device on the home Wi-Fi or tailnet. 3. A malicious link or
   file that reaches misc. through Share, the clipboard or a pasted URL. 4. A
   revoked or lost device. 5. Malware running as the same user (out of scope:
   nothing here defends against it).

## 3. What already protects the data (verified by reading the code)

| Area | What exists | State |
|---|---|---|
| Data at rest | AES-256-GCM per file, per-file HKDF key and random nonce (`storage_encryption.dart`, pointycastle). The workspace key is random, kept only in Windows DPAPI or the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`), never beside the data. No password or recovery code exists, so a lost key means lost data and the app says so. | Implemented, Tested (Windows), Unverified on device |
| Secrets | Device tokens, the hub admin token and the key go through DPAPI / Keychain (`secret_store.dart`). The hub stores only SHA-256 hashes of device tokens. | Implemented, Tested |
| iOS files | `NSFileProtectionComplete` on private files and as the default entitlement. | Implemented, Unverified on device |
| Sync | End-to-end encrypted records (`e2ee.dart`), per-device keys and endorsements, the hub refuses plain data once it has switched. | Implemented, Tested |
| Pairing | One-time code, valid 10 minutes, single use; 5 wrong codes per address in 10 minutes then 429. | Implemented, Tested |
| Revocation | A removed device is refused at once and the workspace key is rotated for the others; the removed device keeps its local copy. | Implemented, Tested |
| Hub network | Binds loopback by default; extra addresses only private/Tailscale ranges, never `0.0.0.0` or public; plain HTTP only on loopback/Tailscale, HTTPS (certificate pinned per hub) elsewhere; admin endpoints need the separate admin token. | Implemented, Tested |
| Offline | Local saving never waits for the hub; the scheduler backs off and retries; unsent changes stay queued; "unauthorized" stops sync without touching local data. | Implemented, Tested |
| Backups | Checksummed manifests, atomic rename, safety copy before restore, staged restore with rollback, never prunes the last good one; encrypted because they are byte copies of encrypted files. | Implemented, Tested |
| Logs | `sanitizeLog` removes tokens, keys, bearer headers and private URL paths at the one place all logging passes. | Implemented, Tested |
| Dependencies | Only `crypto`, `pointycastle`, `ffi` (+ Flutter). No analytics. | Verified |
| App lock | None is armed (the code exists but is not wired; the app opens straight to the work). | Tested |

## 4. Findings

### Verified weaknesses (fixed in this change)

| # | Severity | Finding | Fix |
|---|---|---|---|
| V1 | **Medium** | Link previews fetched any pasted/shared URL, including `http://192.168.x.x`, `127.0.0.1`, link-local (`169.254.169.254`) and Tailscale addresses, and followed up to 5 redirects blindly. A hostile link could make the device send GET requests into the user's own networks (router admin pages, NAS, other services). | `url_guard.dart`: only public http(s) hosts without credentials; every address a name resolves to must be public; redirects are followed by hand and each hop is checked, max 5. Tested with real local servers. |
| V2 | **Low–Medium** | Imported images/PDFs were accepted by file extension only, with no size limit. A program or HTML file renamed `.png`/`.pdf` was stored and later handed to system viewers. | `import_guard.dart`: signature check (png, jpg, gif, webp, bmp, pdf), size limits (64 MB images, 256 MB PDFs), empty files refused; downloaded preview images are checked too. A refused file is skipped and logged without its name. Tested. |
| V3 | **Low** | The status of local protection, sync authorization and backups was spread over several settings sections with no single, honest summary. | New Settings → Security & Privacy page (below). |

### Open items (not fixed here)

| # | Severity | Finding | Why it is open / next step |
|---|---|---|---|
| O1 | **Medium** | Device tokens never expire and are not renewed automatically. Revocation exists, and tokens are 256-bit and stored hashed, so the practical risk is a stolen device that nobody removes. | A renewal endpoint changes the sync protocol and every paired device; needs its own design and a version bump. Not done. |
| O2 | **Low–Medium** | The hub's certificate is self-signed and pinned per device; there is no renewal or rotation path. When the certificate changes, devices must pair again. | Pinning without a rotation plan is what the specification warns against. Proper fix: certificates from Tailscale (`tailscale cert`) with automatic renewal. Not implemented. Plain HTTP over Tailscale (WireGuard) is the default path and does not use it. |
| O3 | **Low** | Rate limiting covers pairing only. Authenticated endpoints have none (the token is 256-bit, so guessing is not practical). | Add a per-device limiter if the hub is ever exposed beyond Tailscale. |
| O4 | **Low** | `NSFileProtectionComplete` makes private files unreadable while the iPad is locked. The app has no background modes, so nothing breaks today, and writes that arrive while locked wait (`FileProtection.whenUnlocked`). If background sync is added, use `CompleteUntilFirstUserAuthentication` for the data folder. The Keychain key is already `AfterFirstUnlock`. | Left as is. Unverified on device. |
| O5 | **Low** | Link-preview name checks resolve the host once and the HTTP client resolves it again (DNS rebinding window). | Stated in `url_guard.dart`. Pinning the connection to the vetted IP needs a custom socket factory. |
| O6 | **Low** | The log, user-asked exports, the widget snapshot and short-lived decrypted viewer copies are not encrypted (documented in `storage_encryption.dart`). | Accepted and documented. |
| O7 | Info | Windows: no firewall rule is created. The hub listens on loopback unless a private/Tailscale address is configured, so no unnecessary port is open. | Fine as is. |

### Theoretical risks (no verified exploit)

Malware as the same Windows user can read decrypted memory and call DPAPI; the
hub is a single point of availability for sync (not for editing); a Tailscale
ACL that is too wide is a configuration risk outside this repository.

## 5. Requirements that are not implemented

Stated plainly, because the specification asks for them:

* **iCloud backup / iCloud availability and quota detection**: not implemented.
  It needs CloudKit or iCloud Drive entitlements and Swift that cannot be
  built or tested here. The Security & Privacy page says so. Use Export all
  data and save the file to iCloud Drive.
* **Automatic backup to the Windows hub as a separate destination**: not
  implemented. While paired, the hub already keeps its own synced copy.
* **Automatic credential renewal** (O1) and **automatic certificate renewal**
  (O2).
* **Tailscale ACLs, grants and key expiry**: configured in the Tailscale admin
  console, not in this repository. Recommendation: tag the hub PC
  (`tag:misc-hub`), allow only your own devices to reach TCP 47710 on it; keep
  key expiry on for phones and tablets; a hub PC that is always on may use a
  tagged node (tagged nodes do not expire by default) because it is a server,
  not a person's device. Do not disable expiry for personal devices.
* **Encrypting backups before they leave the device with a separate key**:
  backups are already ciphertext when encryption is on; a separate backup key
  is not added (it would only add a second key to lose).
* **Background integrity verification on a schedule**: the Security & Privacy
  page checks the newest backup on request; no timer does it.
* **Notifications**: only one event is announced (a device that lost
  authorization), once per day (`AttentionGate`). Persistent backup failures
  show on the status page but do not raise a toast yet.
* **Windows Hello / Face ID**: deliberately not used.

## 6. The Security & Privacy page

Four areas, each with a status word and a short explanation: Local protection,
Hub synchronization, Backups, Device authorization. Labels: Protected, Backing
up, Sync paused, Backup needs attention, Device authorization expired (plus
Needs attention for a local-protection problem and Not in use). The headline is
never "Protected" while an area has a problem. No keys, addresses or scores are
shown. Device types are not available from the hub (it records a name and
read-only or not), so they are not shown.

## 7. Unavoidable user actions

* First pairing of a device (a code made on the PC), by design.
* Pairing again after a device is removed or the hub is reset.
* Restoring a backup (it can replace newer data, so it always asks).
* If the encryption key is lost with every trusted copy, the data cannot be
  recovered; this is stated, not hidden.
