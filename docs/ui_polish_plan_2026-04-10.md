# UI Polish Plan 2026-04-10

## Goal
Turn the current web MVP into a cleaner, denser, more controllable product surface without losing delivery speed.

## 10 large changes
1. Tree interaction polish
   Add free node dragging in edit mode while preserving visible relation lines and keeping the canvas readable.
2. Persistent tree composition
   Save manual node positions per tree so families can curate their own layout instead of fighting auto-layout every session.
3. Tree viewport ergonomics
   Improve centering, zoom affordances, reset controls, empty-space balance, and branch focus behavior on desktop web.
4. Tree editing clarity
   Make edit mode feel explicit: better cues for selected nodes, drag state, quick actions, and reset-layout affordances.
5. Friends tree product model
   Introduce a parallel graph mode for non-blood connections such as friends, close circles, classmates, colleagues, and chosen family.
6. Graph-mode switching
   Add navigation and entry points for switching between family tree and friends tree without mixing the two concepts in one confusing surface.
7. Friends graph semantics
   Reuse existing relation types such as `friend`, `colleague`, `partner`, and `other` where possible, and treat manual layout as the default for this mode.
8. Feed and social context polish
   Reflect whether the user is acting in a family context or a friends context in feed, profile, and notifications copy and entry points.
9. Screen density pass
   Continue tightening desktop composition for tree, relatives, notifications, chat, and profile so the app stops feeling like stretched mobile UI.
10. Verification and release hygiene
    Keep smoke coverage for web flows, update docs, and land each polish wave in clean commits.

## Friends tree direction
- Position it as a "chosen circle" graph, not a replacement for the family tree.
- It should support:
  - close friends
  - classmates
  - colleagues
  - mentors
  - godparents or symbolic family ties
- UX difference from family tree:
  - less hierarchy, more freeform network
  - manual arrangement is primary
  - no generation guides by default
  - relation chips should emphasize social meaning rather than lineage

## Execution order
1. Manual drag + persistence for family tree.
2. Tree viewport and edit-mode polish.
3. Data model groundwork for friends tree.
4. Navigation and graph-mode UI.
5. Social surfaces polish and verification.

## Progress
- Done: manual drag, persistent node layout, viewport controls, edit-mode cues.
- Done: `friends tree` model, create/select flows, route support, and differentiated tree canvas behavior.
- Done: social-surface context polish on home, post composer, tree selector, trees list, and profile so family vs friends mode is visible outside the tree editor.
- Next: continue desktop density polish for notifications, relatives, and chat, then run a production-targeted pass for the new friends-tree flows.

## 20-item execution wave
1. Add a graph-context banner to relatives.
2. Add relatives-side stat chips for people, chats, and pending requests.
3. Add a quick action in relatives side panel for search.
4. Add a quick action in relatives side panel for pending requests.
5. Add an actionable empty state in relatives for adding the first person.
6. Add a top notifications overview card before the list.
7. Make notifications copy adapt to family vs friends context.
8. Add a context chip inside the notifications desktop side panel.
9. Add a total unread summary line in notifications.
10. Add a "read all" action inside the notifications side panel.
11. Sort notification-type summary by volume, not by insertion order.
12. Add grouped-count badges to grouped notification cards.
13. Add chat-list header context under the app bar title.
14. Add chat-list overview chips for total chats, unread, and people search pool.
15. Make chat search placeholder adapt to family vs friends context.
16. Make chat-list empty state adapt to family vs friends context.
17. Make people search section label adapt to family vs friends context.
18. Make chat-composer search copy adapt to family vs friends context.
19. Make chat-composer group title hint adapt to family vs friends context.
20. Make chat screen show graph context and adapt empty/input/info copy to family vs friends context.

## Current status
- Implemented in this wave: 1-20.
- Next after this wave: denser desktop layouts for chat details and notifications, then a live manual drag smoke pass on an authenticated tree.
- Additional follow-up completed after the 20-item wave:
  - tree screen now has a hero banner and stronger quick actions to relatives, chats, and post creation
  - tree viewport controls are denser and more informative on desktop
  - chat info sheet now exposes more context and participation state
  - auth desktop layout was rebalanced locally so the hero no longer wastes as much vertical space, but production still needs deployment to reflect it
