# Deploy

> **Production front-end is Caddy** as of 2026-06-22.
> `caddy.service` binds `0.0.0.0:80/443` and routes Rodnya web traffic
> through `rodnya-web-static.service` on `127.0.0.1:8098`. nginx is
> installed but not active; [`deploy/nginx/rodnya.conf`](nginx/rodnya.conf)
> is kept as a tested fallback.

Rodnya web production is served by Caddy from `/var/www/rodnya-site`
via `rodnya-web-static.service`, while the API runs as
`rodnya-backend.service` from `/opt/rodnya/backend` behind
`api.rodnya-tree.ru`.

LiveKit pilot production runs on the same VM from `/opt/rodnya/livekit`
as a Docker stack managed by `rodnya-livekit.service`, with:

- `livekit.rodnya-tree.ru` proxied by Caddy to `127.0.0.1:7880`
- `turn.rodnya-tree.ru` used by LiveKit TURN/TLS

Current production nuance: on the shared VM, embedded TURN/UDP proved
unstable on this host. Until LiveKit moves to a dedicated IP/VM or an
L4 proxy, the same-VM pilot should stay on:

- `TURN/TLS` via `5349/tcp`
- `ICE/TCP` via `7881/tcp`
- direct media over `50000-60000/udp`

The current working VM config also pins LiveKit to the public `ens1` interface and a static node IP instead of STUN-based external-IP discovery.

## Web / Caddy front-end

`deploy/caddy/Caddyfile` is a full snapshot of the active
`/etc/caddy/Caddyfile` from the production host and is the canonical
front-end configuration for the current production host. Do not replace
it with a Rodnya-only snippet: the same file also carries shared host
routes such as RadioAtlas and the temporary `nip.io` smoke endpoint.

It captures:

- `/.well-known/assetlinks.json` served as `application/json` for
  Android Verified App Links (see
  [`docs/verified_app_links_deployment.md`](../docs/verified_app_links_deployment.md)).
- `/oauth/callback` routed to the static bridge HTML at
  `web/oauth/callback/index.html` so unverified-link installs still
  fall back to the legacy `rodnya://oauth/callback` custom scheme.
- `/invite` routed to the static invite interstitial at
  `web/invite/index.html` so in-app browsers can still offer
  "open in app" and web fallback.
- `/dl/*` served from `/opt/rodnya/static/dl` for direct APK downloads.
  The directory MUST be owned by `rodnya-deploy` (the OTA workflow `scp`s the
  APK there as that user; Caddy only needs world-read). After the 31.08.2026
  server move it came back as `rodnya:rodnya 755` and the first OTA failed with
  `scp: dest open: Permission denied` — fixed with
  `chown rodnya-deploy:rodnya-deploy /opt/rodnya/static/dl`.
- Cache-Control bands for SPA entry / runtime / long-cached assets
  before falling through to the Flutter SPA.

After changing `/etc/caddy/Caddyfile` on the host:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

After a manual production edit, copy `/etc/caddy/Caddyfile` back into
`deploy/caddy/Caddyfile` and commit it so the repo stays in sync with
the real front-end state. Temporary Caddyfile backups from the 2026-06-22
invite/App Links repair were moved out of `/tmp` to:

```text
/opt/rodnya/backups/caddy/20260622-codex-caddyfile-backups
```

## nginx fallback

`deploy/nginx/rodnya.conf` mirrors the public Rodnya surface for a
manual fallback if Caddy must be stopped and nginx brought back to
80/443. It references the current Caddy-managed certificate store so
`nginx -t` stays valid on the production VM.

After updating `rodnya.conf` or `connection-upgrade.conf`, push to the
host and run as root:

```
sudo deploy/nginx/install_nginx_config.sh
```

The installer is idempotent: it copies the conf to
`/etc/nginx/sites-available/rodnya`, removes any stale
`rodnya.conf.bak*` / `rodnya.conf.codex*` siblings that nginx has
been warning about, symlinks into `sites-enabled/`, then runs
`nginx -t` and `systemctl reload nginx` only after validation
succeeds. If nginx is not active, it validates and installs the fallback
config without trying to reload the inactive service. If validation
fails, it restores the previous config.

## Backend production flow

1. Pack a backend release tarball from local `backend/` without `node_modules`, `data/`, and local tests.
2. Upload the tarball to the server.
3. Activate it through `deploy/backend/activate_backend_release.sh`.

The backend activator:

- validates that the archive contains `package.json`, `package-lock.json`, and `src/server.js`;
- creates a timestamped backup in `/opt/rodnya/backups/<timestamp>-backend/`;
- stages the new release beside `/opt/rodnya/backend`;
- runs `npm ci --omit=dev` inside the staged release;
- atomically swaps the live backend directory;
- restarts `rodnya-backend.service`;
- checks `http://127.0.0.1:8080/ready`;
- automatically rolls back to the previous backend release if readiness fails.

Recommended ready/warnings check after every backend rollout:

```bash
node tool/backend_ready_alert.mjs --url https://api.rodnya-tree.ru/ready --fail-on-warnings
```

Recommended runtime/error aggregation check after every backend rollout:

```bash
node tool/backend_runtime_watch.mjs --api-url https://api.rodnya-tree.ru --fail-on-warnings
```

Optional alert hook:

- set `RODNYA_READY_ALERT_WEBHOOK_URL` to a chat/webhook endpoint;
- the tool will POST a JSON alert whenever `/ready` fails or warnings are treated as fatal.
- set `RODNYA_RUNTIME_ALERT_WEBHOOK_URL` when runtime warnings/errors should alert to a separate destination from `/ready`.

Backend runtime visibility after this pass:

- `/health` and `/ready` now expose `runtime`, `warnings`, and `x-rodnya-release`;
- `/v1/admin/runtime` mirrors the same operational payload for moderator/admin accounts;
- `runtime.recentErrors` is the single backend aggregation point for uncaught exceptions, rejected promises, and Express error-handler failures.

Install the activator once on the production server:

```bash
sudo install -m 0755 deploy/backend/activate_backend_release.sh /usr/local/bin/rodnya-activate-backend-release
```

### Manual backend deploy from Windows

Use the PowerShell helper from the repo root:

```powershell
pwsh -File deploy/backend/deploy_backend.ps1 `
  -ServerHost 212.69.84.167 `
  -User root `
  -IdentityFile "$HOME/.ssh/id_ed25519"
```

Notes:

- `ssh`, `scp`, `tar.exe`, `node`, and `npm` must be available locally.
- The default target is `/opt/rodnya/backend` with `rodnya-backend.service`.
- The helper runs `node --test backend/test/api.test.js` before packing unless `-SkipTests` is passed.
- If a non-root deploy user is used, it must be able to run `sudo -n /usr/local/bin/rodnya-activate-backend-release`.
- The backend release marker is written to `/opt/rodnya/backend/.last_release_id`.

### Backend rollback

Each backend deploy creates a tar backup, for example:

```bash
/opt/rodnya/backups/20260420-120000-backend/backend.tgz
```

To roll back manually:

```bash
mkdir -p /tmp/rodnya-backend-rollback
tar -xzf /opt/rodnya/backups/<timestamp>-backend/backend.tgz -C /tmp/rodnya-backend-rollback
tar -czf /tmp/rodnya-backend-rollback.tgz -C /tmp/rodnya-backend-rollback .
sudo /usr/local/bin/rodnya-activate-backend-release /tmp/rodnya-backend-rollback.tgz /opt/rodnya/backend rodnya-backend.service
```

### Backup and restore drill

Run this drill on a staging copy or maintenance window before changing the deploy process:

1. Confirm the latest backup exists in `/opt/rodnya/backups/<timestamp>-backend/`.
2. Restore that backup into a temporary directory and verify `package.json`, `package-lock.json`, and `src/server.js`.
3. Re-activate the restored archive with `rodnya-activate-backend-release`.
4. Check `systemctl status rodnya-backend.service`.
5. Check `curl -fsS https://api.rodnya-tree.ru/ready`.
6. Confirm the release marker changed back and `x-rodnya-release` matches the restored build.

For a lightweight automated precheck on the server:

```bash
bash deploy/backend/verify_backup_restore_drill.sh /opt/rodnya/backups /tmp/rodnya-backup-restore-drill
```

### Rollback checklist

Keep this order on every incident rollback:

1. Freeze new deploys.
2. Identify the last known-good backend backup timestamp.
3. Restore backend first and verify `/ready`.
4. Restore web only if the failure is also in `/var/www/rodnya-site`.
5. Re-run `tool/prod_route_smoke.mjs` with the disposable smoke account.
6. Record the failed release marker and the restored marker in the incident note.

## LiveKit production flow

LiveKit is deployed separately from the backend release so media-plane config and secrets stay outside `/opt/rodnya/backend`.

Repo assets for this live under `deploy/livekit/`.

Recommended server layout:

- `/opt/rodnya/livekit/docker-compose.yml`
- `/opt/rodnya/livekit/.env`
- `/opt/rodnya/livekit/livekit.yaml`
- `/etc/systemd/system/rodnya-livekit.service`

Windows deploy helper:

```powershell
pwsh -File deploy/livekit/deploy_livekit.ps1 `
  -ServerHost 212.69.84.167 `
  -User root `
  -LiveKitHost livekit.rodnya-tree.ru `
  -TurnHost turn.rodnya-tree.ru
```

The helper uploads `deploy/livekit/`, rewrites the Caddy blocks and backend env, renders `livekit.yaml`, restarts `rodnya-livekit.service`, and verifies `/ready`.

Required backend env additions in `/etc/rodnya-backend.env`:

```bash
RODNYA_LIVEKIT_URL=https://livekit.rodnya-tree.ru
RODNYA_LIVEKIT_API_KEY=<prod key>
RODNYA_LIVEKIT_API_SECRET=<prod secret>
RODNYA_LIVEKIT_WEBHOOK_KEY=<shared webhook secret>
```

The TURN hostname should also exist in Caddy so certificates are issued and renewed for:

- `turn.rodnya-tree.ru`

Minimum verification after rollout:

- `systemctl is-active rodnya-livekit.service`
- `docker ps` shows `rodnya-livekit` and `rodnya-livekit-redis`
- `https://api.rodnya-tree.ru/ready` returns `liveKitEnabled=true`
- `wss://livekit.rodnya-tree.ru` is reachable

## Current production flow

1. Build a full Flutter web bundle with `flutter build web --release`.
2. Sync shell assets that Flutter does not reliably copy into `build/web`:
   - `node tool/sync_web_shell_assets.js`
3. Upload a tarball to the server.
4. Activate it through `deploy/web/activate_web_release.sh`.

The activation step is intentionally shared between manual deploys and GitHub Actions so the server always follows the same path.

## Release checklist

Run this order on every production release:

1. `flutter analyze`
2. targeted `flutter test`
3. `flutter build web --release`
4. local smoke against `build/web`
5. production smoke through `tool/prod_route_smoke.mjs`
6. `/ready` and `/v1/admin/runtime` checks through
   `tool/backend_ready_alert.mjs` and `tool/backend_runtime_watch.mjs`

If any step fails, stop the rollout and keep the current live build.

## Clean release sync flow

When production already contains locally verified changes that have not been
landed cleanly in `main`, use this order instead of deploying from a dirty
worktree:

1. collect only release files into a clean clone or release branch
2. run `flutter analyze`, targeted `flutter test`, backend `node --test`, and
   `flutter build web --release`
3. run local smoke against `build/web`
4. push the clean commit to `main`
5. wait for `.github/workflows/flutter-web-deploy.yml` to finish green
6. deploy the backend from the same clean commit if backend files changed
7. verify the live route smoke, `/ready`, and `/v1/admin/runtime`
8. confirm `last_build_id.txt` and backend `x-rodnya-release` reference the same
   release wave

The web deploy workflow should stay scoped only to real app/web paths, while
`.github/workflows/production-watch.yml` remains the long-running readiness,
runtime, smoke, and backup-precheck contour.

## Server-side activation script

Install the activator once on the production server:

```bash
sudo install -m 0755 deploy/web/activate_web_release.sh /usr/local/bin/rodnya-activate-web-release
```

The script:

- validates that the uploaded archive is a Flutter web build;
- creates a timestamped backup in `/opt/rodnya/backups/<timestamp>-web/`;
- stages the new release in a sibling directory under `/var/www`;
- atomically swaps it into `/var/www/rodnya-site`;
- writes both `.last_build_id` and public `last_build_id.txt` when `BUILD_LABEL` is provided.

## Manual deploy from Windows

Use the PowerShell helper from the repo root:

```powershell
pwsh -File deploy/web/deploy_web.ps1 `
  -Host 212.69.84.167 `
  -User rodnya-deploy `
  -IdentityFile "$HOME/.ssh/id_ed25519"
```

Notes:

- `ssh`, `scp`, and `tar.exe` must be available locally.
- The server user must be able to run `sudo -n /usr/local/bin/rodnya-activate-web-release`.
- Recommended sudoers entry:
  `rodnya-deploy ALL=(root) NOPASSWD: /usr/local/bin/rodnya-activate-web-release`
- If the current working tree is dirty, the deploy marker will explicitly say so.
- By default the helper now runs `tool/prod_route_smoke.mjs` after activation and rolls back the web bundle automatically if that smoke fails.
- Full protected-route smoke needs a disposable production-ready account:
  - `-SmokeEmail`
  - `-SmokePassword`
  - optional `-SmokePartnerEmail`
  - optional `-SmokePartnerPassword`
  - optional auto-bootstrap through `RODNYA_SMOKE_AUTO_REGISTER=1` and `RODNYA_SMOKE_DISPLAY_NAME`
  - optional `-SmokeTreeName`
  - optional `-SmokeFixtureTreeId`
  - optional `-SmokeInviteUrl`
  - optional `-SmokeClaimUrl`
- Use `tool/prod_route_smoke.env.example` as the template for disposable smoke credentials and one-time invite/claim fixtures.
- If invite/claim URLs are not provided and the smoke account has a writable tree, `tool/prod_route_smoke.mjs` can auto-create a disposable offline relative fixture, use it for `relative-details`, and clean it up after the run unless `RODNYA_SMOKE_KEEP_FIXTURES=1`.

## GitHub Actions

`.github/workflows/flutter-web-deploy.yml` now uploads a tarball and activates it through the same server-side script.

It also runs the shared route smoke after deploy. To cover the full protected suite instead of only anonymous/login checks, configure these repository secrets:

- `RODNYA_SMOKE_EMAIL`
- `RODNYA_SMOKE_PASSWORD`
- `RODNYA_SMOKE_PARTNER_EMAIL`
- `RODNYA_SMOKE_PARTNER_PASSWORD`
- optional `RODNYA_SMOKE_FIXTURE_TREE_ID`
- optional `RODNYA_SMOKE_INVITE_URL`
- optional `RODNYA_SMOKE_CLAIM_URL`
- optional `RODNYA_SMOKE_TREE_NAME`
- optional `RODNYA_READY_ALERT_WEBHOOK_URL`
- optional `RODNYA_RUNTIME_ALERT_WEBHOOK_URL`
- optional `RODNYA_RUNTIME_EMAIL`
- optional `RODNYA_RUNTIME_PASSWORD`

`.github/workflows/production-watch.yml` turns those checks into a routine:

- scheduled `/ready` monitoring with optional webhook alerts;
- scheduled `/v1/admin/runtime` aggregation check for `warnings` and `runtime.recentErrors`;
- scheduled route smoke for anonymous + authenticated flows;
- remote backup archive extraction precheck over SSH when deploy secrets are available.

The smoke script now exposes two explicit suites:

- `anonymous`: `login`, `invite`, `claim`
- `authenticated`: `home`, `tree`, `relatives`, `relative-details`, `chats`, `chat-view`, `profile`, `settings`, `notifications`, `create-post`, `invite-flow-authenticated`, `claim-flow-authenticated`

Run only one suite when needed:

```bash
node tool/prod_route_smoke.mjs --suite anonymous
node tool/prod_route_smoke.mjs --suite authenticated
```

Important:

- GitHub deploys will only become reliable after `main` is cleanly web-buildable from a fresh checkout.
- Until then, the manual PowerShell deploy remains the safe fallback.

## Rollback

Each deploy creates a tar backup, for example:

```bash
/opt/rodnya/backups/20260411-231100-web/rodnya-site.tgz
```

To roll back:

```bash
mkdir -p /tmp/rodnya-rollback
tar -xzf /opt/rodnya/backups/<timestamp>-web/rodnya-site.tgz -C /tmp/rodnya-rollback
tar -czf /tmp/rodnya-rollback.tgz -C /tmp/rodnya-rollback .
sudo /usr/local/bin/rodnya-activate-web-release /tmp/rodnya-rollback.tgz /var/www/rodnya-site
```
