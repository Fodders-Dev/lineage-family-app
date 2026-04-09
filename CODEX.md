# CODEX.md

## Purpose
This file is the Codex-specific operating guide for Lineage.
Use it together with `AGENTS.md`, not instead of it.

## Project stance
- Ship a stable Android + web MVP first.
- Treat Firebase-hosted paths as legacy unless they are still required by a specific migration task.
- Default backend direction is custom API + PostgreSQL + object storage + self-controlled realtime/push path.
- Preserve Russian UI quality when touching copy.

## Codebase map
- `lib/navigation/`: router and entry flow.
- `lib/screens/`: thin UI screens.
- `lib/services/`: concrete backend adapters and app services.
- `lib/backend/interfaces/`: abstraction layer that should stay stable during migrations.
- `lib/providers/`: app-level state, especially selected tree state.
- `docs/`: architecture notes, migration plans, audit documents.

## Working rules for Codex
- Inspect before editing; do not assume legacy docs are current.
- Prefer minimal patches over broad refactors.
- Keep business logic out of screens when changing behavior.
- Do not reintroduce Firebase-only assumptions into new code.
- Do not store real credentials in repo files. Use user-provided credentials only during the interactive session.
- Respect dirty worktrees. Never revert unrelated user changes.

## Reliable web workflow
1. Run `flutter pub get`.
2. If web needs validation, prefer `flutter build web --no-wasm-dry-run`.
3. Serve `build/web` locally via `python -m http.server 3000 --bind 127.0.0.1`.
4. Run Playwright MCP against the local build, not only against widget tests.
5. Capture concrete route failures, console errors, and UI regressions in a dated audit file under `docs/`.

## Known web reality as of 2026-04-09
- `flutter build web` was blocked by a missing `ChatPreview` import in `lib/screens/chat_screen.dart`; fixed.
- Home feed/profile `posts` flow is implemented in the repo custom backend, but production API still needs deployment.
- Some chat detail requests return `404`.
- Chat media on web breaks when uploads return `http://api.rodnya-tree.ru/media/...`; normalize to HTTPS on the client and keep backend deployment aligned so upload responses emit HTTPS directly.

## Expected completion checklist
- `dart format` on changed files.
- `flutter analyze`.
- relevant `flutter test`.
- if web-facing behavior changed, a short Playwright smoke pass.
- summarize changed files, what passed, what still blocks MVP.
