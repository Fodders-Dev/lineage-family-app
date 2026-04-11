# Lineage agent guide

## Mission
Ship a reliable Flutter MVP for Android and web as fast as possible. iOS later.

## Product
Lineage is a family tree + private family social network for relatives.
Short-term MVP:
- auth and onboarding
- family tree CRUD and viewing
- 1:1 text chat
- notifications
- basic media upload
- stable Android and web builds

Voice/video calls are phase 2 unless the task explicitly targets calls.

## Platform reality
The product must work for users in Russia.
Treat Firebase cloud and hosted Supabase as legacy dependencies to phase out if they create availability risk.

## Preferred backend direction
Prefer self-hostable or Russian-friendly infrastructure.
Default target direction:
- PostgreSQL
- object storage
- own auth or self-hosted auth
- own realtime/chat backend
- Android push path that does not depend only on FCM

Self-hosted Supabase is acceptable if it reduces migration time.
Avoid big-bang rewrites. First create abstractions and adapters, then migrate feature by feature.

## Engineering rules
- Be autonomous inside the task.
- Do not stop after analysis; implement, verify, and summarize.
- Do not ask follow-up questions unless truly blocked.
- Inspect the existing code before editing.
- Prefer minimal, reversible changes over wide refactors.
- Keep screens thin; move logic into services/repositories/providers.
- Do not introduce duplicate architecture.
- Preserve or improve Russian UI text quality when touching user-facing strings.

## Verification
Before finishing a task:
- run dart format on changed files
- run flutter analyze
- run relevant flutter tests
- if web UI changed, run a quick browser smoke test
- summarize changed files, what passed, and remaining risks

## Commands
- flutter pub get
- dart format .
- flutter analyze
- flutter test

## Browser testing
Use Playwright only for web smoke tests, not for Android-native flows.

## Codex notes
- Primary repo-level Codex instructions live in [CODEX.md](CODEX.md).
- Active autopilot behavior, response style, and execution rules live in [Codex_rules.md](Codex_rules.md).
- Keep an up-to-date web audit in [docs/mvp_web_audit_2026-04-09.md](docs/mvp_web_audit_2026-04-09.md) until the major MVP blockers are closed.
- Keep the working self-prompt in [PROMPT.md](PROMPT.md) and refine it when the project direction changes.

## Web startup
- Preferred local web validation path:
- `flutter pub get`
- `flutter build web`
- `python -m http.server 3000 --bind 127.0.0.1` from `build/web`
- Then run a Playwright MCP smoke pass against `http://127.0.0.1:3000/#/...`
- Use `flutter build web --no-wasm-dry-run` only as a compile check. In this repo it can leave a locally served `build/web` without the final asset manifests/icons needed for a real browser smoke pass.

## Current MVP web blockers
- Repo state: local custom backend now implements `/v1/posts`, likes and comments, but production API still needs deployment.
- Chat media on web was traced to `http://api.rodnya-tree.ru/media/...` URLs coming back from upload; client-side HTTPS normalization is in place, but the backend still needs deployment to emit HTTPS media URLs directly.
- Full details and screen-by-screen notes are in [docs/mvp_web_audit_2026-04-09.md](docs/mvp_web_audit_2026-04-09.md).
