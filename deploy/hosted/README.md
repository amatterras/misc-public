# THEapp hosted sync (optional)

The same sync hub as the self-hosted one, serving many accounts, each in its
own folder (`/data/users/<accountId>`) with its own store, devices and daily
backups. Nothing is deployed by default: this folder is how to deploy it.

## Run locally (to try it)
```
dart run bin/thehub.dart hosted-invite --data ./hosted-data
dart run bin/thehub.dart hosted-serve --data ./hosted-data --port 8080
```
The app only accepts `https://` service addresses; for a local trial put a
TLS proxy in front (e.g. Caddy with `tls internal`) or use the self-hosted hub.

## Deploy (needs your own server, domain and Docker)
1. Point a DNS name (e.g. `sync.example.com`) at the server; open ports 80/443.
2. `cp deploy/hosted/.env.example deploy/hosted/.env` and set `DOMAIN`, `ACME_EMAIL`.
3. `cd deploy/hosted && docker compose up -d --build`
4. Make an invite: `docker compose exec hub thehub hosted-invite --data /data`
5. In THEapp → Settings → Sync → "Or use a hosted sync service": the address
   `https://<DOMAIN>`, email, password (≥ 12 characters) and the invite code.
   Other devices sign in with the same email and password (no invite).

## Security model
- TLS by Caddy; the hub container is not published, only Caddy reaches it.
- Accounts: email + Argon2id password hash; single-use invite codes (only
  their SHA-256 is stored); login and sign-up rate limits per IP and email.
- Each device gets its own token `<accountId>.<token>`, checked by that
  account's own device list; revoke devices from the hub API
  (`/v1/account/revoke`) — a settings button is not built yet.
- An account can only reach its own folder; account ids in requests are
  never trusted on their own. Admin endpoints and public share pages are
  disabled in hosted mode.
- Deleting an account (`/v1/account/delete` with its password) removes its
  data and backups.

## Backups / restore
Daily backups per account under each account folder (`backups/`, same
format as the self-hosted hub; `thehub restore-to` works on them). Also back
up the Docker volume `hub-data` off the server.

## Not done (needs your decision/accounts)
- An actual server, domain and TLS certificate (nothing is running).
- Storage quotas per account and e-mail verification / password reset.
