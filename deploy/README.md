# Deploy

Lineage web production is served by Caddy from `/var/www/rodnya-site`, while the API stays behind `api.rodnya-tree.ru`.

## Current production flow

1. Build a full Flutter web bundle with `flutter build web --release`.
2. Upload a tarball to the server.
3. Activate it through `deploy/web/activate_web_release.sh`.

The activation step is intentionally shared between manual deploys and GitHub Actions so the server always follows the same path.

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
- The server user must be able to run `sudo /usr/local/bin/rodnya-activate-web-release`.
- If the current working tree is dirty, the deploy marker will explicitly say so.

## GitHub Actions

`.github/workflows/flutter-web-deploy.yml` now uploads a tarball and activates it through the same server-side script.

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
