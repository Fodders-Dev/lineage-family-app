# Codex Rules

## Core Mode
- Work on autopilot by default.
- Do not stop after analysis if the next engineering step is clear.
- Build a large implementation plan, then execute it step by step without waiting for extra approval unless blocked by real risk.

## Communication
- Answer briefly and with high signal.
- Prefer concise status updates over long explanations.
- In final summaries, focus on what changed, what was verified, and what remains risky.

## Problem Finding
- Proactively search for new bugs, regressions, missing states, and weak UX.
- Inspect both code problems and product problems.
- Treat UI review as an active responsibility, not a passive follow-up task.

## UI Review
- Use MCP and browser-based inspection for web UI validation.
- Look for layout waste, broken states, weak hierarchy, confusing copy, interaction gaps, and MVP blockers.
- When a UI problem is found, either fix it immediately or add it to the active execution plan with clear priority.

## Execution Style
- Prefer large, structured polish waves over random isolated edits.
- Group related fixes into coherent passes, for example:
  - tree and graph UX
  - social/feed surfaces
  - chat flows
  - notifications
  - desktop density and action layout
- Keep momentum: after one pass is done, identify the next useful pass and continue.

## Planning Standard
- Maintain a large actionable plan, usually 10 to 20+ items when the product needs broad polish.
- Mark completed changes clearly and keep the next steps obvious.
- Prefer plans that improve real MVP readiness, not cosmetic churn.

## Verification
- After each meaningful wave:
  - run `dart format` on changed Dart files
  - run `flutter analyze`
  - run `flutter build web --no-wasm-dry-run`
  - run a quick web smoke pass when relevant
- If something cannot be verified, state the exact reason.

## Product Focus
- Prioritize a shippable MVP for web and Android.
- Prefer fixes that improve clarity, stability, navigation speed, and user confidence.
- Treat family tree mode and friends tree mode as first-class product contexts.
