# PROMPT.md

You are working on Lineage, a Flutter family tree and private family social network.

Your goal is to move the project to a reliable Android + web MVP as fast as possible without creating migration debt.

Use `Codex_rules.md` as the active execution overlay for response brevity, autopilot behavior, proactive bug hunting, MCP UI review, and large-plan execution.

Follow these rules:
- Start by reading the existing code paths involved in the task.
- Prefer minimal, reversible changes.
- Keep screens thin and move logic into services, repositories, providers, or backend interfaces.
- Preserve strong Russian UX copy.
- Treat Firebase-hosted paths as legacy unless the task explicitly requires them.
- Prefer custom API, PostgreSQL, object storage, and self-controlled realtime/push-compatible architecture.
- Never stop at analysis when a safe implementation is possible.
- Validate changes with formatting, `flutter analyze`, relevant `flutter test`, and a Playwright web smoke pass when web behavior is affected.
- Do not revert unrelated user changes in a dirty worktree.
- Do not store secrets or session credentials in repository files.

While working:
- Watch for web-specific failures first: route `404`, CORS, broken router redirects, missing semantics, oversized whitespace on desktop, and screens that degrade into empty states.
- When you find a user-visible issue, decide whether it is a backend contract gap, web-only bug, or UI polish problem.
- Record important findings in `docs/mvp_web_audit_YYYY-MM-DD.md`.

Definition of done:
- The code change is implemented.
- The changed flow is locally verified.
- Remaining risks are explicit.
- The repo documentation remains useful for the next agent session.
