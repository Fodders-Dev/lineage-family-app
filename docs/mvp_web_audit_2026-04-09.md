# MVP web audit - 2026-04-09

Scope:
- local web build served from `build/web`
- login performed with a real account during the interactive session
- routes checked through Playwright MCP

## Critical blockers

### 1. Home feed backend gap is closed on production
- Route: `/#/`
- Current production state after the 2026-04-10 deployment: `GET https://api.rodnya-tree.ru/v1/posts?treeId=...` returns `200`, and the backend feed contract is now available on the live API.
- MVP impact: the backend blocker is removed; remaining feed quality work is now mostly frontend UX and content-state handling.

### 2. Profile posts backend gap is closed on production
- Route: `/#/profile`
- Current production state after the 2026-04-10 deployment: `GET https://api.rodnya-tree.ru/v1/posts?authorId=...` returns `200`.
- MVP impact: authored posts are available in the live API; frontend presentation is now the main remaining concern.

### 3. Direct chat details endpoint mismatch
- Route reached from `/#/chats`
- Current state after client fix: direct chat view skips the non-essential details request and opens without that extra `404`.
- Backend note: the production API still appears inconsistent for some `GET /v1/chats/:chatId` requests.
- MVP impact: direct chat is more stable on web, but backend contract still needs cleanup for full parity.

### 4. Chat media now emits canonical HTTPS upload URLs
- Route: chat view
- Root cause: upload responses can return `http://api.rodnya-tree.ru/media/...`, and browsers fail on the redirect chain before reaching the working HTTPS media response.
- Current production state after the 2026-04-10 deployment: `/v1/media/upload` now responds with `https://api.rodnya-tree.ru/media/...` directly.
- Remaining note: old stored `http://...` URLs can still exist in historical data, but the web client already normalizes them on read.
- MVP impact: new media messages are no longer blocked by the old redirect/CORS chain.

## High-priority UX issues

### 5. Desktop layouts are materially improved, but tree view still sets the quality ceiling
- Routes: `/#/`, `/#/relatives`, `/#/chats`, `/#/profile`, `/#/notifications`, chat view
- Repo state: home now uses a denser desktop split, chats list has a structured desktop shell, profile header is card-based, relatives and notifications gained side panels, and chat view no longer stretches edge-to-edge on wide screens.
- Current repo state after the 2026-04-10 pass: tree view now uses a split desktop composition with a dedicated side control panel and bordered canvas area.
- Remaining issue: the overall desktop baseline is acceptable for MVP, but tree view still deserves one more visual pass if the goal is premium polish rather than MVP readiness.
- MVP impact: web is now substantially more desktop-usable, with tree view remaining the clearest presentation gap.

### 6. Tree view uses desktop width poorly
- Route: `/#/tree/view/:treeId`
- Symptom: tree is rendered in a very large canvas with substantial dead space and weak centering behavior.
- MVP impact: the flagship feature looks less polished than the underlying data quality deserves.

### 7. Notifications content quality is improved, but grouping can go further
- Route: `/#/notifications`
- Current repo state after the 2026-04-10 pass: repeated same-day notifications now collapse visually, preview text is normalized, and the desktop side panel shows a type summary.
- MVP impact: the screen is far more scannable for MVP, though a richer timeline or server-side grouping would still be a later polish step.

## Medium-priority issues

### 8. Create-post flow now has better confidence cues
- Route: `/#/post/create`
- Current repo state after the 2026-04-10 pass: the screen now explains image limits, branch visibility, publication mode, and retry expectations, and uses a more desktop-friendly two-column layout.
- MVP impact: content creation is meaningfully closer to MVP-ready.

### 9. Remaining MVP work is now mostly quality and operational hardening
- Scope: live web + API
- Symptom: the main deployment blockers are resolved, but the product still needs deeper route-by-route QA, stronger failure UX, and more operational monitoring.
- MVP impact: the app is substantially closer to a usable MVP than to a prototype, but it still needs disciplined smoke coverage before calling it finished.

## Positive observations
- Auth flow itself works on web with the current custom API session logic.
- Relatives list loads real data and reflects invite/chat affordances.
- Tree route redirect and tree rendering work after login.
- Notifications list loads real items and now sits inside a more desktop-appropriate shell.
- Web build is recoverable and now compiles with `flutter build web --no-wasm-dry-run`.
- Desktop layouts for home, chats, profile, relatives, notifications, and chat view are all denser than the initial audit baseline.
- Production deployment was updated on 2026-04-10 for both `api.rodnya-tree.ru` and `rodnya-tree.ru`.

## Technical notes
- Web build had a compile blocker in `lib/screens/chat_screen.dart`: missing `ChatPreview` import.
- After fixing that import and cleaning generated Flutter state, the project builds successfully for web.
- Local custom backend now covers posts/feed/comment MVP flow and passes backend tests.
- Tree selection on web previously reused stale cached tree data across accounts; provider/cache logic now prefers fresh backend tree lists and replaces stale cached tree entries.
- Additional local custom-backend smoke passed on 2026-04-09: login, home feed, create-post, profile posts and empty notifications render correctly from the web build.

## Next repair order
1. Run a fresh end-to-end browser smoke on the live site for login, feed, profile, create-post, chats, notifications, and tree view.
2. Verify photo send/receive in real browser UI after the media URL deployment.
3. Polish tree view visuals beyond MVP baseline if a more premium desktop feel is required.
4. Add more operational safeguards: deploy notes, rollback recipe, and basic health/error monitoring around the custom backend.
