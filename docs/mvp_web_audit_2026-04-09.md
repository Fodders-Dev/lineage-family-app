# MVP web audit - 2026-04-09

Scope:
- local web build served from `build/web`
- login performed with a real account during the interactive session
- routes checked through Playwright MCP

## Critical blockers

### 1. Home feed is still broken on production API
- Route: `/#/`
- Current repo state: local custom backend now implements `/v1/posts`, likes and comments, and the web home feed renders correctly against that backend.
- Production gap: `GET https://api.rodnya-tree.ru/v1/posts?treeId=...` still returns `404 Route not found` until the backend deployment is updated.
- MVP impact: family social feed is implementation-ready in repo, but not yet restored on production web.

### 2. Profile posts are fixed in repo but not yet deployed
- Route: `/#/profile`
- Current state after client and backend work: profile no longer collapses, and authored posts work against the local custom backend.
- Production gap: `GET https://api.rodnya-tree.ru/v1/posts?authorId=...` still returns `404 Route not found` until deployment catches up.
- MVP impact: profile feed is ready in code, but still unavailable on production web.

### 3. Direct chat details endpoint mismatch
- Route reached from `/#/chats`
- Current state after client fix: direct chat view skips the non-essential details request and opens without that extra `404`.
- Backend note: the production API still appears inconsistent for some `GET /v1/chats/:chatId` requests.
- MVP impact: direct chat is more stable on web, but backend contract still needs cleanup for full parity.

### 4. Chat media uses unsafe media URLs on web
- Route: chat view
- Root cause: upload responses can return `http://api.rodnya-tree.ru/media/...`, and browsers fail on the redirect chain before reaching the working HTTPS media response.
- Confirmed behavior: direct `https://api.rodnya-tree.ru/media/...` responds with `Access-Control-Allow-Origin: *`, while the initial `http://...` redirect does not.
- Current state after client fix: existing chat attachments now normalize to HTTPS on read, so legacy photos render again in web chat; new uploads are normalized to HTTPS before the message is sent.
- Backend follow-up: deploy the backend patch so `/v1/media/upload` emits HTTPS media URLs directly behind the proxy.
- MVP impact: media rendering is recoverable on web, but production backend deployment is still required for a full fix.

## High-priority UX issues

### 5. Desktop layouts are materially improved, but tree view still sets the quality ceiling
- Routes: `/#/`, `/#/relatives`, `/#/chats`, `/#/profile`, `/#/notifications`, chat view
- Repo state: home now uses a denser desktop split, chats list has a structured desktop shell, profile header is card-based, relatives and notifications gained side panels, and chat view no longer stretches edge-to-edge on wide screens.
- Remaining issue: the overall desktop baseline is acceptable for MVP, but tree view still feels the least polished flagship screen.
- MVP impact: web is now substantially more desktop-usable, with tree view remaining the clearest presentation gap.

### 6. Tree view uses desktop width poorly
- Route: `/#/tree/view/:treeId`
- Symptom: tree is rendered in a very large canvas with substantial dead space and weak centering behavior.
- MVP impact: the flagship feature looks less polished than the underlying data quality deserves.

### 7. Notifications content quality is still too raw for MVP
- Route: `/#/notifications`
- Symptom: message notification list shows raw body fragments and repetitive entries without grouping.
- MVP impact: activity center looks noisy and hard to scan.

## Medium-priority issues

### 8. Create-post flow still lacks confidence cues
- Route: `/#/post/create`
- Symptom: screen now works against the local custom backend, but it still does not explain media limits, branch visibility consequences, or publish retry behavior clearly.
- MVP impact: content creation is functional, yet the UX still feels closer to an internal tool than a polished consumer MVP.

### 9. Production deployment gap remains the main MVP blocker
- Scope: production custom API
- Symptom: repo state is ahead of production for posts and canonical media URLs.
- MVP impact: the codebase is materially closer to MVP than the live environment; deployment is now the bottleneck.

## Positive observations
- Auth flow itself works on web with the current custom API session logic.
- Relatives list loads real data and reflects invite/chat affordances.
- Tree route redirect and tree rendering work after login.
- Notifications list loads real items and now sits inside a more desktop-appropriate shell.
- Web build is recoverable and now compiles with `flutter build web --no-wasm-dry-run`.
- Desktop layouts for home, chats, profile, relatives, notifications, and chat view are all denser than the initial audit baseline.

## Technical notes
- Web build had a compile blocker in `lib/screens/chat_screen.dart`: missing `ChatPreview` import.
- After fixing that import and cleaning generated Flutter state, the project builds successfully for web.
- Local custom backend now covers posts/feed/comment MVP flow and passes backend tests.
- Tree selection on web previously reused stale cached tree data across accounts; provider/cache logic now prefers fresh backend tree lists and replaces stale cached tree entries.
- Additional local custom-backend smoke passed on 2026-04-09: login, home feed, create-post, profile posts and empty notifications render correctly from the web build.

## Next repair order
1. Deploy backend changes for `/v1/posts` and HTTPS media URLs to production API.
2. Deploy backend changes for `/v1/posts` and canonical HTTPS media URLs to production API.
3. Polish notifications grouping and preview formatting.
4. Tighten tree view desktop composition and centering behavior.
5. Clean up the production `GET /v1/chats/:chatId` contract so group/branch/direct behave consistently.
