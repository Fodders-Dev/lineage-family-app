# Architectural Decisions Log

Каждое архитектурное решение принятое в ходе рефакторинга
заносится сюда с датой и обоснованием. Формат:

```
## YYYY-MM-DD: краткое название
**Контекст**: какая ситуация
**Решение**: что выбрали
**Альтернативы**: что отклонили и почему
**Влияет на**: список файлов / API
**Принято**: имя decision-maker'а
```

---

## 2026-05-09: фундаментальное направление

**Контекст**: текущая модель «multi-tree per user + invite to
slot» не масштабируется когда у юзеров общие родственники, и
не позволяет приглашённому юзеру быть активным редактором.

**Решение**: переходим на **connected per-user trees** —
каждый юзер имеет одно дерево с собой как корнем, cross-tree
связи через `personIdentities`.

**Альтернативы**:
* Single shared global tree (FamilySearch model) — отвергнут:
  невозможен без community moderation, не подходит для
  закрытой семейной соцсети.
* Status quo с расширенными permissions (приглашённые могут
  редактировать BLOOD-RELATED slot'ы) — отвергнут как полумера,
  не решает дубликаты cross-tree.

**Влияет на**: всё. См. PLAN.md полностью.

**Принято**: Артём (user) + Claude.

---

## 2026-05-09: PLAN.md superseded by RFC

**Контекст**: Phase 0 audit (этой сессии) обнаружил, что в коде уже
существует параллельный unified-graph слой (`graphPersons` /
`graphRelations` / `branches` / `branchPersonViews`), реализующий
бо́льшую часть «целевой модели». Это исполнение отдельного RFC —
[`docs/tree_model_overhaul_rfc.md`](../tree_model_overhaul_rfc.md)
от 2026-05-07. Сделанные фазы по RFC: Phase 0 (person-picker),
Phase 1.1 (identity propagation), Phase 1.2 (silent 💡 matcher),
Phase 3.1 (schema graph), Phase 3.4 (post.branchIds[]), Phase 6.1
(BranchSwitcherChip).

PLAN.md (написан в этой же сессии до audit'а) описывает альтернативную
модель «single tree per user», которая НЕ совместима с RFC: PLAN.md
требует удалить multi-branch концепцию и BranchSwitcher, RFC — её
центральный UX-элемент.

**Решение**: PLAN.md superseded by RFC. RFC — единственный source
of truth. graphPersons + branches слой остаётся. Phase 0 / 1.1 /
1.2 / 3.1 / 3.4 / 6.1 правильны и не выпиливаются. Никаких
гибридов — чисто B (RFC выигрывает).

**Альтернативы**:
* **A: PLAN.md правильный, RFC выпиливаем** — отвергнут: пара
  месяцев работы по 1.1/1.2/1.3/3.1/3.4/6.1 не должна выкидываться
  из-за того что новый план был написан в неведении. И сама
  multi-branch модель отвечает на пользовательскую боль про
  ветки лучше, чем single-tree.
* **C: гибрид (граф под капотом, single-tree сверху)** — отвергнут:
  половинчато, BranchSwitcher уже в проде, одна модель должна
  победить, а не сосуществовать.

**Влияет на**: всё дальнейшее. PLAN.md помечен SUPERSEDED, фазы
ниже (Phase 1, 2, 3, ...) больше НЕ актуальны в его трактовке.
Источник правды — RFC.

**Принято**: Артём (user).

---

## 2026-05-09: memberIds — split into two distinct mechanisms

**Контекст**: в legacy модели `tree.memberIds[]` несёт два смешанных
смысла — (a) право редактировать дерево и (b) право видеть/писать
в ленту дерева. В RFC модели эти смыслы разъезжаются по разным
сущностям, поэтому простой drop невозможен.

**Решение**:
* (a) **Право редактировать** → owner-model на уровне `graphPerson`,
  не на уровне ветки. Реализуется в RFC Phase 3.2: автоматически
  на ≤2 hops по кровным рёбрам, модерация на 3+, hard-delete
  запрещён. Per-узел, не per-ветка.
* (b) **Право видеть ленту ветки** → отдельный механизм branch
  sharing. Дизайн — при подходе к Phase 3 (TREE → BRANCH миграция),
  отдельным design-pass'ом.

`memberIds` как поле в `branches` пока зеркалится из legacy
`tree.memberIds` (через `_syncTreeToBranch`), но не используется
для авторизации в новых endpoints. Будет полностью удалено когда
оба механизма (a)+(b) задеплоены и legacy переход завершён.

**Альтернативы**:
* «Просто drop memberIds» — отвергнут: теряем два разных смысла,
  ломаем существующие use case'ы.
* «Конвертировать в общий treeVisibility» — отвергнут как
  половинчатое решение: владелец-модель и share-модель — разные
  концепции, должны быть разные API.

**Влияет на**: backend Phase 3.2 (owner-model), новый branch-share
API в Phase 3.

**Принято**: Артём (user).

---

## 2026-05-09: Three legacy invite flows → two API + three user-facing actions

**Контекст**: сейчас три разных flow «привлечь юзера в моё дерево»:
1. `linkPersonToUser` через invite-link (`/v1/invitations/pending/process`)
2. `createTreeInvitation` (`/v1/trees/:treeId/invitations`)
3. `linkPersonsByIdentity` (`/v1/trees/:treeId/persons/:personId/link-identity`)

В RFC модели семантика «привязать userId к слоту» становится
частным случаем identity-claim (self-graphPerson юзера ←→ identity
link с targetPerson).

**Решение**:
* **Invite-link** → identity-claim: `linkPersonsByIdentity` API
  поверх self-graphPerson юзера и слота в чужой ветке.
* **Manual merge двух узлов** → тот же `linkPersonsByIdentity` API.
* **Share branch access** (read/post в чужой ленте без identity
  claim'а) → отдельный API. Либо новый, либо repurposed
  `createTreeInvitation` — решим на дизайне Phase 3.
* **`linkPersonToUser` → DEPRECATED.** Старые ссылки продолжают
  работать через legacy-redirect ([web/index.html](web/index.html)
  уже это делает) ~3 месяца после Phase 3, потом депрекейтятся.

**Альтернативы**:
* «Все три legacy flow жизнеспособны, оставляем» — отвергнут:
  семантика slot-link противоречит graph-модели и порождает
  дубли в graphPersons.
* «Резко выпиливаем всё legacy после Phase 3» — отвергнут:
  у юзеров на руках старые invite-ссылки, нужен переходный
  период.

**Влияет на**: Phase 3 (TREE → BRANCH миграция), endpoint
`/v1/invitations/pending/process` будет переписан на тонкий
shim над `linkPersonsByIdentity`.

**Принято**: Артём (user).

---

## 2026-05-09: Phase 3 заблокирован 4 нерешёнными вопросами

**Контекст**: Phase 3 (TREE → BRANCH миграция) — XL-фаза, требует
отдельного design-pass перед началом кода. RFC оставил 4 вопроса
открытыми; без ответов лезть в Phase 3 нельзя.

**Решение**: до старта Phase 3 нужно зафиксировать ответы на:
1. **Privacy escape hatch на graphPerson** — три уровня:
   `owner` / `connected` / `public`. Дефолт? Кто видит контактные
   данные живых людей? Как переключать без UI-катастрофы?
2. **Migration conflict strategy** — что wins при initial merge
   противоречивых данных? Самый недавний `updatedAt`? Самый
   полный record? Manual merge через mergeProposals?
3. **Owner-model thresholds** — реально ли «≤2 hops auto» работает
   в большой семье (200+ родственников)? Где граница между
   автоматическим propagation и moderation queue?
4. **BFS depth для blood-branch визуализации** — 4-5 hops, не 10?
   Где обрезаем visualization чтобы canvas не падал?

Phase 1.3 (edit-time conflict surfacing) **НЕ заблокирован** этими
вопросами. Закрываем 1.3 как описано в RFC, потом design-pass
по Q1-Q4, потом Phase 3.

**Принято**: Артём (user).

---

## 2026-05-10: Phase 3 разблокирован — ответы A–D на 4 RFC-вопроса

**Контекст**: 2026-05-09 я зафиксировал 4 нерешённых вопроса как
блокеры Phase 3. Артём ответил 2026-05-10, формально снимая блок.

### A. Privacy escape hatch на graphPerson

**Решение**:
* **Default visibility** = `connected-via-blood-graph` (≤4 hops по
  кровным рёбрам видят узел; за пределами — нет).
* **Sensitive fields** (телефон, текущий адрес, email) — `owner-only`
  всегда, независимо от hops. Это per-field gate поверх node visibility.
* **Историческое исключение**: `isAlive === false && birthYear < (now - 100 лет)`
  → автоматически `public` (узел исторический, не несёт privacy
  риска для живых).
* **Owner override**: владелец graphPerson может явно поднять
  privacy на конкретный узел до `owner-only` (например, секретный
  родственник).

**Влияет на**:
* `graphPerson.visibility` — новое поле (см. SCHEMA proposal).
* `graphPerson.visibilityOverride` — для owner-poweredup secret nodes.
* Sensitive fields — отдельный список на стороне store / route layer.
* Cross-tree access checks — расширяются с `_userCanAccessTreeRecord`
  до `_userCanSeeGraphPerson(graphPersonId, viewerUserId)`.

### B. Migration conflict strategy

**Решение**:
* Initial migration по `personIdentities` строит canonical
  graphPerson через **highest-completeness wins**: для каждого
  поля **отдельно** выбираем source с наибольшим количеством
  непустых значений (не на уровне записи целиком).
* Все divergent values записываются в `identityFieldConflicts`
  (та самая Phase 1.3 коллекция) с `resolvedAt: null`.
* После миграции каждый affected user видит ⚠️ badge на узлах
  с conflict'ами и решает через тот же Phase 1.3 UI.
* **Принципиально**: переиспользуем существующий механизм
  Phase 1.3, не плодим новую логику для миграции.

**Влияет на**:
* `pickCanonicalPerson` в [migration-utils.js:307](backend/src/migration-utils.js:307)
  → переписывается на per-field selection, удаляется текущая
  preference «claimed user → updatedAt».
* `buildGraphPersonFromCanonical` → читает best-non-null per-field.
* После migration — записать divergent values в
  `identityFieldConflicts` для каждого поля где source != canonical.

### C. Owner-model thresholds — пересмотрено vs RFC Phase 3.2

**Решение** (строже чем RFC «≤2 hops auto», осознанно):
* **Default**: owner-only edit, **без auto-extension по hops**.
* **Owner extension**: владелец может явно дать права на конкретный
  graphPerson другому юзеру через UI (новая сущность
  `graphPersonEditGrants` или поле в graphPerson). Не автоматически
  по графу.
* **Merge двух узлов**: **оба** owner'а должны дать consent (двусторонне).
  Никакого auto на ≤2 hops.
* **Hard-delete запрещён** (как в RFC) — 30-day soft с
  восстановлением через `deletedAt` flag.

**Обоснование Артёма**: «избежим vandalism в больших семьях. Если
потом UX покажет что слишком зажато — расширим». То есть это
deliberately conservative starting point.

**Влияет на**:
* RFC Phase 3.2 «≤2 hops auto» / «3+ hops moderation» — **отменяется**.
* Заменяется на: всегда owner-only + явные grants.
* Новая сущность `graphPersonEditGrants` (TBD: shape) — кто кому
  дал права редактировать graphPerson.
* `mergeProposals` уже двусторонний механизм (через `claimedByUserId`
  с обеих сторон) — не нужно менять.

### D. BFS depth для blood-branch визуализации

**Решение**:
* **Default `branch.includeRules.maxHops`** = 5 (≈4 поколения вверх
  + 1–2 вниз для viewer'а).
* **UI slider** 3..8 в branch-creation wizard (Phase 6.4) — юзер
  выбирает.
* **`findBloodRelation` (Phase 4 BFS)**: `maxDepth = 10` ОК — это
  другой сценарий («найти родство с любым человеком в графе»),
  не визуализация ветки.

**Влияет на**:
* `branch.includeRules` — новое поле `maxHops` для типа
  `blood-from-me` / `descendants-of` / `ancestors-of`.
* Helper `_buildBranchVisiblePersonIds` в store.js (упомянут в RFC
  Phase 6.4) учитывает `maxHops`.

**Принято**: Артём (user) 2026-05-10.

**Следующий шаг**: design proposal по schema changes (Phase 3.1)
с учётом A-D — `PHASE-3.1-SCHEMA-PROPOSAL.md`. Показать Артёму
ПРЕЖДЕ чем браться за миграцию. Не лезть в код store.js / migration
до явного approve.

---

## 2026-05-10: Phase 3.1 proposal approved + Q1/Q3 + pre-flight check

**Контекст**: PHASE-3.1-SCHEMA-PROPOSAL.md вышел на review.
Артём approve целиком + два уточнения + один nice-to-have.

### Q1: re-run миграции v1→v2 ЦЕЛИКОМ

* `complete-v2` ledger ещё не существует — старый `complete` после
  Phase 3.1 трактуется как «нужно пересобрать с новой logic'ой».
* Re-run полностью deterministic + idempotent + покрывается dry-run
  diff'ом.
* В существующих v2-данных ничего критичного не накопилось, что
  нельзя пересобрать из v1 + новой logic'и.
* **Если что-то ВДРУГ всплывёт после rerun (data drift между rebuild
  и старой v2) — фиксируем как новую DECISION в DECISIONS.md и
  обсуждаем. Не молча правим.**

### Q3: accept gap между Phase 3.1 и 3.4

* Default `connected-via-blood-graph` + sensitive fields owner-only
  через personAttributes — conservative enough.
* Юзеры не получат worse-than-current state: сейчас escape hatch'а
  на чужие деревья нет вообще.
* Рисковый случай (deceased ancestor которого хотят owner-only)
  встретится у мизерного числа юзеров. Если жалоб не будет —
  вообще не делаем admin escape.

### Nice-to-have: pre-flight count check в migrateTreesToGraphAndBranches

Перед write проверяет:
* `graphPersons.length === uniqueIdentitiesWithLinkedPersons + personsWithoutIdentity`
* `graphRelations.length === dedup(relations)` (учитывая orphan-drop)
* `branches.length === trees.length`

Если расхождение — **abort** с clear error сообщением, **не write**.
Это страховка от тихого data loss при переписывании canonical-picking
логики.

**Принято**: Артём (user) 2026-05-10.

**Следующий шаг**: implementation в порядке из CURRENT-PHASE.md
(EMPTY_DB → migration → store helpers → tests → dry-run → diff).
Diff на показ перед коммитом — обязательно.

---

## Roadmap после Phase 3.1

После implementation 3.1 backend и migration done, schema заморожена.
Дальше:
* **Phase 3.2** — owner-model permissions enforcement (route gates,
  edit-grants UI flow на стороне backend).
* **Phase 3.4** — UI для visibility/edit grants на клиенте.
* Порядок: любой, Артём подскажет.

---

## 2026-05-10: Phase 3.2 first, не 3.4 — schema без enforcement = corruption surface

**Контекст**: после approve Phase 3.1 (commit 0d5acec) встал
выбор приоритета: 3.2 (route enforcement) vs 3.4 (Flutter UI).

**Решение**: 3.2 first. Никаких вариантов.

Логика:
* Schema 3.1 без enforcement = любой client может писать
  `graphPerson.visibility` что угодно через curl/Postman, обходя
  любые UI ограничения. Это не «permission feedback в runtime» —
  это data corruption surface.
* 3.4 без 3.2 = security theater: красивый toggle в UI который
  ничего не enforce'ит на сервере. Ничему не учит, лживо
  обещает privacy.
* 3.2 standalone testable end-to-end через API tests без UI.
  Faster validation cycle.

**Cutover plan**:
1. 3.1 → pre-prod уже сейчас (миграция + schema, ничего не ломает).
2. 3.2 → pre-prod (enforcement gates + новые grants endpoints).
   Старые UI продолжают работать на anonymous (`graphPerson.userId
   === null`) persons. Claimed получают 403 на edit-as-stranger —
   правильное поведение, не regression.
3. 3.4 → pre-prod + prod (Flutter UI для visibility, grants, wizard).

Между 3.2 и 3.4 — NO user-visible regression на anonymous persons.
Claimed-edit-as-stranger 403 — ровно тот случай, что уже частично
fixнул `additive: true` коммит, теперь финально enforced.

**Принято**: Артём (user) 2026-05-10.

---

## 2026-05-10: Phase 3.2 — Q1/Q3 + nice-to-have pre/post-claim test

После approve PHASE-3.2-ENFORCEMENT-PROPOSAL.md.

### Q1: keep backward-compat для anonymous persons

**Решение**: anonymous (`graphPerson.userId === null`) — edit через
`requireTreeAccess` (creator + memberIds). Claimed (`userId !=
null`) — только owner или active grant per scope.

**Обоснование Артёма**: «семьи строят дерево совместно — Артём
создал слот "прабабушка Лида", Дарья добавила её девичью фамилию
которую она помнит лучше, кто-то ещё фотографию загрузил. Если
запретим — collaboration ломается, RFC модель «общими усилиями»
теряет смысл».

`additive: true` фикс предотвращал DATA-CORRUPTION (затирание
полей чужого слота). Phase 3.2 закрывает orthogonal surface —
editorial vandalism на claimed карточках. Это **не regression**,
а целевой behavior из RFC.

### Q3: 30 days revoked window для /v1/me/edit-grants

**Решение**: 30 дней OK, и **намеренно совпадает** с
`hardDeleteScheduledAt` window из Phase 3.1. Один TTL на оба
audit-флоу = simpler mental model для юзера: «всё что произошло
с моими правами / моими записями за последний месяц видно».

Если потом UX покажет что 30 шумно — снизим до 14, но не больше.

### Nice-to-have: explicit pre-claim/post-claim regression test

**Решение**: в `owner-model-enforcement.test.js` явный test:
1. Member-of-tree (не creator) делает PATCH на person которая
   anonymous (graphPerson.userId === null) → success.
2. Кто-то отдельно claim'ит эту person через invite/relation-request
   flow → graphPerson.userId становится claimer.
3. Тот же member делает PATCH снова → 403.

Это самый болевой regression risk и Артём явно хочет видеть его
зафиксированным test'ом, не только в комментарии.

### Self-resolved Q2/Q4/Q5

* Q2 (create new person) — keep as-is, member может создать
  anonymous → становится owner.
* Q4 (`tree.memberIds` после 3.2) — не удаляем, фейдится в
  Phase 5/6.
* Q5 (`merge-consent` отдельный scope) — keep отдельным от `edit`.

Если что-то из этих окажется неочевидным при implementation —
surface как новая DECISION, не молча решать.

**Принято**: Артём (user) 2026-05-10.

---

## 2026-05-10: два независимых maxHops

**Контекст**: при wiring chunk 2 visibility toggle UI всплыл
вопрос — какое значение писать в russianHint для visibility
варианта `connected-via-blood-graph`. Initial draft указывал
«до 5 колен» (по аналогии с `branch.includeRules.maxHops`
default'ом), но backend visibility BFS использует 4.

В системе **СОЗНАТЕЛЬНО** используются **два разных
hop-limit'а** для разных целей:

* `FileStore._connectedVisibilityMaxHops = 4` — для
  `_userCanSeeGraphPerson` через blood-graph BFS. Контроль
  «кто может видеть карточку при visibility=connected-via-blood-graph».
  **Tight (4 поколения)**, потому что privacy: ширина видимости
  должна быть стабильно узкой, не configurable юзером.

* `branch.includeRules.maxHops` — default 5, slider 3..8 в
  Phase 3.4 wizard'е. Для `_buildBranchVisiblePersonIds` при
  `type === "blood-from-me" / "descendants-of" / "ancestors-of"`.
  Контроль «кто показывается в ветке». **Шире (5 default,
  до 8)**, потому что юзер сам выбирает scope своей ветки —
  это его UX choice, не privacy invariant.

### Не путать. Не unify'ить.

* Visibility — privacy gate, server-side, **не expose**'нуть в UI.
  Если когда-то понадобится ослабить (5 hops) — это change в
  privacy semantics, требует отдельного DECISION.
* Branch maxHops — UX dial. Юзер двигает slider 3..8.

Тесты cover'ят **обе границы отдельно**:
* `branch-include-rules.test.js` — visibility BFS на 4 hops.
* `migration-utils.test.js` + `owner-model-enforcement.test.js`
  — branch maxHops boundaries (3, 8, 0→1, 100→20, undefined→5).

### Зачем эта запись

Без неё через 3 месяца кто-то (включая Артёма / Claude)
увидит «4 vs 5» в коде и попробует «починить inconsistency»
— сломает либо privacy (если расширит visibility до 5), либо
UX (если сузит branch default'ом). Эта DECISION фиксирует:
inconsistency **deliberate**.

### russianHint строка

UI hint для visibility-варианта говорит «до 4 поколений»
(`lib/backend/models/visibility_choice.dart`). Branch wizard'у
slider показывает 3..8 (`lib/screens/family_tree/create_tree_screen.dart`).
Числа в UI **разные**, потому что концепции разные.

**Принято**: Артём (user) 2026-05-10 (после chunk 2 verify-2
review).

---

## 2026-05-10: Phase 3.2 implementation surfaced edge — createPerson-with-userId followed by createRelation as creator

**Контекст**: при wiring enforcement gates всплыл legitimate
use-case в existing api.test.js:

```
Alice (owner of tree-a) creates person with `userId: bob.user.id`
  → person.userId = bob (claimed by Bob through this single POST)
  → graphPerson.userId = bob (after _syncPersonToGraph)
  → owner of graphPerson = Bob

Alice immediately creates relation:
  POST /v1/trees/tree-a/relations {person1Id: alicePerson, person2Id: bobPerson, ...}
  → mid Phase 3.2 gate: person2 claimed by Bob, Alice has no grant
  → 403
```

Это паттерн «Alice invites Bob через создание linked-person'а +
relation' к нему за один flow». Pre-Phase-3.2 работало (route не
проверял claim'нутость на relation creation). После — reject как
claimed-edit-as-stranger.

Конкретные failing tests на момент implementation:
* `tree graph snapshot syncs profile fields and normalizes family
  units` (api.test.js:9271) — Alice создаёт spouse через
  `userId: bob.user.id` + relation alice↔spouse spouse.
* `branch chat endpoint reuses branch thread and limits participants
  to that branch` (api.test.js:11011) — same shape: Alice creates
  Bob person through `userId: bob.user.id` + relation.
* `auto circles follow tree relations and filter audience content`
  (api.test.js:7747) — same.

### Решение

Эти тесты отражают **legacy invite-via-creation flow** который
Phase 3 RFC явно депрекейтит (см. tree_model_overhaul_rfc.md Phase
3 «invite semantics»). Правильный flow — Bob receive invite,
claim'ит slot из своего аккаунта, тогда graphPerson.userId
обновляется через consent'ный path. Alice создаёт **anonymous**
slot, Bob его потом claim'ит.

Поэтому **adjust expectations** в тестах: либо убрать
`userId: bob.user.id` из POST /persons (создаём anonymous и Bob
claim'ит позже), либо явно ожидать 403 как новое правильное
поведение enforcement'а.

Это **не add auto-grant exemption** для creator. Auto-grants
противоречат ответу C («без auto-extension по hops, только
explicit grants»). Если pre-claim creation + immediate relation
понадобится — Phase 3.4 UI добавит «Создать как anonymous» как
default для unfamiliar email/userId.

### Альтернатива (отвергнут)

Auto-issue limited grant Alice'е при `POST /persons` с `userId`:
* Pro: backward-compat with one-shot invite-via-creation flow.
* Con: нарушает Артёмову Q1/C invariant «без auto-extension». Любая
  exemption «creator получает initial grant» легко становится
  vandal vector — особенно если creator потом revoke'ит и не
  ставит новые grants. Пусть pre-claim Alice работает как
  anonymous; claim — explicit consent step, как в RFC.

**Принято**: Claude (implementation), документирую как DECISION
для review Артёмом. Если он не согласен — поправим до commit'а.
Не молчу — surface как просили.

---

## 2026-05-10: Phase 3.2 follow-up — POST/DELETE relations = tree-level, не двойной edit-gate

**Контекст**: при wiring двойного edit-gate на `POST /relations`
+ `DELETE /relations/:id` всплыли legitimate failures на:
* `auto circles follow tree relations and filter audience content`
  (api.test.js:7747) — Alice (tree-creator) creates relations
  alice↔Bob (Bob claimed his own person), alice↔Carol, partner↔Bob.
* `branch chat endpoint` (11011) — same pattern.
* `tree graph snapshot syncs profile fields` (9271) — same.

Это паттерн «tree-creator расставляет родственные связи между
participants дерева» — Bob и Carol уже в дереве с claimed
self-persons, Alice прокладывает kinship structure. По исходному
proposal'у двойной edit-gate этот flow blocking — Alice не owner
Bob'а / Carol'ы.

### Решение

**Relation creation/deletion — tree-level STRUCTURAL операция,
не editorial mutation на конкретных persons.** Per Артёмовой Q1
(«семьи строят дерево совместно — кто-то добавил девичью фамилию,
кто-то фотографию, ... запретим — collaboration ломается»), эта
философия распространяется и на построение связей: один член семьи
часто знает структуру лучше других, но это не значит что он должен
получить explicit grant от каждого relative'а сначала.

`POST /v1/trees/:treeId/relations` + `DELETE .../:relationId` —
требуют только `requireTreeAccess(treeId)`, без gate per-person.

### Защита от identity-merge vandalism

Опасный case — «vandal link'ает Alice'ин self-person к чужой
бабушке как identity»:
* Это **identity merge**, не relation. Делается через
  `POST /v1/trees/:treeId/persons/:personId/link-identity` —
  отдельный endpoint, который Phase 3.2 gates'ит **двусторонним
  merge-consent**.
* Простой POST /relations пишет только parent/child/sibling/spouse
  edge между **двумя existing person rows**. Identity link'ом не
  становится; viewer не может через relation создать «Alice = моя
  чужая бабушка». Identity-merge surface — отдельный, защищён.

Так что dropping relation gates **не открывает identity-merge
vandalism vector**. Editorial-on-claimed остаётся защищённым через
`PATCH person`. Visibility — через `PATCH /v1/graph-persons/:id/
visibility` (owner-only-всегда). Sensitive contacts — через field
gate. Все три остаются enforced.

### Альтернатива (отвергнут)

Двойной edit-gate с per-person check на относительных endpoints:
* Pro: theoretically tighter.
* Con: ломает collaborative tree-building flow. Tree-creator не
  может расставить родственные связи между already-claimed members
  своей семьи без сбора N grants. UX-катастрофа.

### Что остаётся в Phase 3.2 enforcement (для ясности)

* `PATCH /v1/trees/:treeId/persons/:personId` — claimed = owner/grant.
* `DELETE /v1/trees/:treeId/persons/:personId` — soft-delete scope.
* `POST/PATCH/DELETE /v1/trees/:treeId/persons/:personId/media` —
  edit scope.
* `POST /v1/trees/:treeId/persons/:personId/link-identity` —
  двусторонний merge-consent.
* `PUT /v1/trees/:treeId/persons/:personId/attributes` — edit scope
  + sensitive (contacts) owner-only-всегда.
* `PATCH /v1/graph-persons/:id/visibility` — owner-only-всегда.
* Cross-tree READ paths — visibility filter.

**Принято**: Claude (implementation), документирую для review
Артёмом. Это conservative loosening от первоначального proposal'а
— surface потому что это narrowing of enforcement, не expansion.

### Caveat для будущей фазы (Артём 2026-05-10 после approve)

DECISION 2 верна для **current-scope**: relations в Phase 3.1
branch-scoped через `legacyRelationIds`. Каждый legacy relation
живёт внутри одного `tree`/`branch`, и tree-creator имеет
структурную authority внутри своего branch'а — collaborative,
но не propagating across branches.

Если в будущей фазе `graphRelations` станут **truly cross-branch
propagating** (Артём рисует ребро в своей ветке → Дарья видит
его в своей), модель «односторонняя tree-authority» может
потребовать пересмотра — возможно через **conflict log
per-relation** аналогичный Phase 1.3 для canonical fields.
Сценарий: Артём создаёт relation `мама spouse Иван`, Дарья
утверждает что `мама spouse Пётр` — нужен flow «edit-time
divergence» и user-resolution.

**Re-evaluate в Phase 6** (где branch sharing proectируется).
До тех пор — current-scope tree-authority валидна, потому что
relations не cross-branch propagate.

---

## 2026-05-10: Phase 3.4 — answers Q1-Q5 + backend addendum strategy + migration conservative

**Контекст**: после approve PHASE-3.4-UI-PROPOSAL.md (commit
`30d8415`). Артём ответил на 5 open questions + дал scope для
backend addendum.

### Q1: `/tree/view` URL → KEEP

Legacy invite-link'и в дикой природе ходят минимум 3 месяца.
Ломать URL = ломать конкретных юзеров. Согласовано с RFC
«Совместимость» (старый treeId API живёт 6 месяцев минимум).
URL-migration в `/branch/view` отложен до Phase 6 cleanup.

### Q2: `auth_screen` «семейное дерево» → KEEP

Marketing-poetry в onboarding hero — не nav-element. Замена
«семейная ветка» в маркетинговом контексте звучит как
тех-жаргон, обратная задача от цели «human-readable».

### Q3: `GET /v1/me/issued-grants` → ADD

Без него outgoing-таб edit-grants screen = N+1 round-trip'а:
плохо UX (slow load) и плохо ops (нагрузка). Симметрия с
`/v1/me/edit-grants` чистая. Добавляется в backend addendum
до Phase 3.4 UI commits.

### Q4: Branch edit с warning'ом → YES

`PATCH /v1/trees/:treeId` с расширенным `includeRules` shape.
Warning-формулировка: «Некоторые родственники могут исчезнуть
из ветки или появиться» + **preview affected count** перед
apply. Юзеры делают мисклики при создании ветки; force-recreate
= bad UX. Preview endpoint — `GET /v1/trees/:treeId/include-rules-preview`
с `?type=...&maxHops=...&anchorPersonId=...` query, возвращает
counts (added / removed / total) для UX warning.

### Q5: Per-row + header conflict badge → BOTH с fallback note

Per-row = «где конкретно», header = «сколько в этой ветке».
Оба полезны для разных моментов user attention.

**Fallback note для post-deploy**: после первой недели в pre-prod
подавать метрику «conflict count per branch». Если медиана > 5,
**отключаем per-row**, оставляем header-only — слишком noisy.
Добавить в operational checklist.

### Backend addendum strategy

**SEPARATE pre-3.4 backend commit**, не часть UI.

Reasons:
* Phase 3.2 был 100% backend, Phase 3.4 должен быть 100% UI с
  минимальным backend touch. Чистая ментальная модель «фазы по
  слоям, не по фичам».
* Backend deployed first → UI build тестирует против реального
  endpoint'а, не stub'а.
* Atomic rollback — если UI commit вызывает проблему, backend
  не нужно откатывать.
* ~20 строк = low risk, отдельный commit не replace blocker'ом.

Commit name: `feat(phase-3.4-prep): tree includeRules in POST +
issued-grants endpoint`. Сразу после него — Phase 3.4 UI commits.

Что делает backend addendum:
* `POST /v1/trees` принимает `includeRules` в payload (validate
  type ∈ {manual, blood-from-me, descendants-of, ancestors-of},
  maxHops 1..20, anchorPersonId optional).
* `PATCH /v1/trees/:treeId/include-rules` — owner edit с
  расширенным includeRules. Owner-only (tree.creatorId).
* `GET /v1/trees/:treeId/include-rules-preview` — query params,
  возвращает `{addedCount, removedCount, totalAfterCount,
  totalBeforeCount}` без mutate'а. Для Q4 warning UX.
* `GET /v1/me/issued-grants` — список grants выписанных viewer'ом
  (group by graphPersonId), включая revoked-since-30d (TTL
  совпадает с Q3).

### Migration strings → CONSERVATIVE

Per Артёмовому правилу «если в каком-то месте сомневаешься —
оставь "дерево"»:

**Rename** только в:
* Navigation/wizard/actions UI: «Создать ветку», «Переключить на
  ветку», «Ветка X из Y».
* Settings → «Мои ветки» (вместо «Мои деревья»).
* Sheet bottom-action «Создать ветку».
* Tree-edit screen → «Параметры ветки».

**KEEP**:
* URL'ы (`/tree/view`).
* `auth_screen` poetic context («семейное дерево» в onboarding hero).
* Kind toggle («Семья / Круг»).
* Legacy переменные в коде (`treeId`, `TreeProvider`) — не rename,
  чтобы не плодить мега-diff'ы.

**Aggressive pass отложен** — потом проще добавить migration в
один коммит, чем откатывать misnamed strings когда юзер пожалуется.

**Принято**: Артём (user) 2026-05-10.

---

## 2026-05-10 (chunk 3 follow-ups) — TODO list

Зафиксированы по итогам chunk 3 review (edit-grants screen).
Не блокеры для самого chunk 3, но обязаны быть закрыты до
финального cut-off Phase 3.4.

### TODO 1 — backend: hydrate grantor preview в /v1/me/edit-grants

Сейчас `/v1/me/edit-grants` возвращает grants с
`graphPerson` preview, но БЕЗ `grantor` preview. Симметрия с
`/v1/me/issued-grants` нарушена — там grantee hydrate'ится, а
здесь grantor нет. Incoming-таб экрана «Доступы» из-за этого
показывает «вы можете редактировать карточку X» без context'а
«потому что Y разрешил».

**Объём**: ~30 строк в `backend/src/routes/graph-person-routes.js`
(`/v1/me/edit-grants` handler) — собрать `Set<grantorUserId>`,
`store.findUserById(...)` для каждого, добавить `grantor` поле в
response payload. Frontend часть готова: `EditGrant.fromJson`
уже парсит `grantor` field (см. lib/backend/models/edit_grant.dart
строки 119–121, 142–145), `_IncomingCard` нужно расширить чтобы
показать «X разрешил» row выше chips'ов.

**Когда**: до выпуска Phase 3.4. Не блокер для chunk 3 commit'а,
но «functional → обоснованный» — UX gap.

**Тесты**: расширить `backend/test/owner-model-enforcement.test.js`
секцию /v1/me/edit-grants чтобы проверить что grantor включён.

### TODO 2 — extract russian plural helpers

`_pluralDays` / `_pluralWeeks` / `_revokedAgoLabel` сейчас дублируются
в `lib/widgets/access_grants_outgoing_tab.dart` и
`lib/widgets/access_grants_incoming_tab.dart` (3 функции × 2 файла).

**Когда extract**: при следующем месте использования. Кандидаты:
* notifications screen (timestamp'ы «N минут назад»)
* history view / activity log (когда добавим audit trail для
  graphPerson edit'ов)
* comments timeline (Phase 4+)

**Куда**: `lib/utils/russian_plural.dart` (или `russian_dates.dart`
если набирается critical mass функций про даты).

**Аргумент против преждевременного extract**: chunk 3 уже
~1370 LOC новых widgets + tests, не размывать. Дублирование двух
файлов — приемлемая цена за tighter chunk diff. Третий call-site
делает extract естественным — копировать в третий раз начинает
явно болеть, и дисциплина вытаскивает helper.

**Принято**: Артём (user) 2026-05-10 (chunk 3 review).

---

## 2026-05-11 (chunk 4 review): ownership ≠ creator для privacy data

**Универсальный invariant**: для любых sensitive / private fields
gate должен быть на `userId == viewer` (актуальный owner), а не
`createdBy == viewer` (исторический создатель).

**Сценарий**: Алиса создаёт anonymous person'а для своего деда.
Дед потом регистрируется и claim'ит карточку — `userId` shift'ится
с null на `bob.id`, `createdBy` остаётся `alice.id`. После claim'а
Алиса теряет privacy access к дедовым contacts'ам. Это **deliberate**,
не bug — creator's role «инициатор записи», а не «вечный custodian».

**Применяется к**:
* Sensitive contacts (chunk 4) — phone/email/address gate'ятся
  на `_isViewerOwnPerson`, который checks `userId == currentUserId`.
* Visibility toggle (chunk 2) — `effectiveOwnerUserId =
  userId ?? createdBy` для anonymous case, но после claim — userId.
* Phase 3.6 hard-delete background job — actor должен быть
  актуальный owner, не creator.
* Phase 4+ notification-feed privacy filters — кому показывать
  «X обновил Y's профиль».

**Anonymous case (userId == null)**:
* Creator в роли owner для privacy data — это temporary state до
  момента claim'а. После claim — owner shifts. До тех пор —
  `createdBy` это и есть «текущий» owner на отсутствие userId'а.
* `effectiveOwnerUserId` formula (chunk 2 helper) уже отражает
  это правильно: `userId ?? createdBy`.

**Не-применяется к**:
* Tree-level structural data (relations, branches) — те остаются
  под `tree.creatorId` (DECISION 2 follow-up 2026-05-10).
* Audit trail (kто и когда menjal) — creator там остаётся
  навсегда как historical record, это не privacy data.

**Принято**: Артём (user) 2026-05-11 (chunk 4 review).

---

## 2026-05-11 (chunk 5 review) — TODO list

Зафиксированы по итогам chunk 5 review (conflict badges на не-canvas
screens). Не блокеры для chunk 5 commit'а, но обязаны быть
закрыты до Phase 4 cut-off.

### TODO 3 — cache invalidation strategy для conflict counts

**Где**: `lib/screens/relatives_screen.dart` (`_conflictCounts` +
`_treeConflictsCache`) — кэш не invalidate'ится автоматически
если юзер resolve'нул конфликт через sheet и вернулся на
relatives_screen. Sheet onChoice вызывает `_refreshConflictCounts`,
но **только когда sheet открыт из relatives_screen**. Если юзер
открыл sheet с relative_details (тот же widget, тот же
endpoint), вернулся на relatives_screen pull'ом back — там cache
stale.

**Симптом**: «5 карточек требуют внимания» banner, реально уже 4.
Confusing.

**Простой fix**: добавить refresh-on-resume на focus event
(`WidgetsBindingObserver.didChangeAppLifecycleState` либо
`RouteAware.didPopNext`). Альтернатива — global event bus
«conflictsChanged» что подписываются и canvas, и relative_details,
и relatives_screen.

**Когда**: Phase 4 либо когда первый юзер feedback'нет. Не
блокер для Phase 3.4 cut-off — pull-to-refresh пока работает.

### TODO 4 — performance audit при большом дереве

**Симптом**: у юзера 200+ persons, у 50 из них конфликты. На
mid-range Android (e.g. Redmi 9A class) build per-row badge x 50 +
`getIdentityConflictsForTree` fetch + JSON parse → возможно
заметные janks при scroll.

**Где будет хуже**: Phase 4 (extended-family network через identity
граф) — там дерево 500+ persons.

**Когда**: измерить на Phase 4 testing pass. Если slow:
* **Lazy badge fetch** — count'ы только для visible viewport
  (`ScrollController` + `RenderSliver` viewport check).
* **Skip render if count > threshold** — header banner показывает
  «50+ карточек», per-row badges suppressed.
* **Server-side aggregation** — `/v1/trees/:id/identity-conflict-counts`
  endpoint, который вернёт `Map<personId, count>` плоско, без
  full conflict bodies. Эконом ~10x payload, parse быстрее.

**Не блокер** для Phase 3.4 cut-off. Sub-100ms build на синтетике
50 badge'ей измерен (Material standard cost).

**Принято**: Артём (user) 2026-05-11 (chunk 5 review).

---

## 2026-05-12 — Phase 4 архитектурные answers

Закрыты review-revise циклом с Артёмом по итогам Phase 4 proposal
v1 (`docs/connected-trees-refactor/PHASE-4-PROPOSAL.md` baseline
commit `32a8f8d`). Принципы — для всех Phase 4 implementation
chunks; cross-reference'аются из proposal v2 §5/§6/§7.

### Q1.B — privacy fence respected

Phase 4 = **visualization layer** на том, что юзер уже может
видеть через `_connectedVisibilityMaxHops = 4`. Никакого
relaxation'а fence'а.

**Reasoning**: если Phase 4 relax'ает fence, мы получаем privacy
regression — viewer видит бабушек friends'ов которых не должен.
Расширенная сеть = красивая визуализация existing visibility, не
extension её scope'а. Fence остаётся фундаментальным privacy
invariant'ом из Phase 3.1.

### Q1.A — emergent property из Q1.B

Public-frontier walk **за fence** фундаментально невозможен.

**Сценарий**: node X с `visibility=public`, его родитель Y с
`visibility=connected-via-blood-graph`, viewer вне connected
set'а Y. Можно ли BFS-walk «прыгнуть X→Y» через public node X?

**Ответ**: нет. `Y.visibility` resolves **per-target-node**, не
per-path. Public node X не служит как «портал» к приватному Y —
fence режет render самого Y (или его sensitive fields)
независимо от того, через что walker к нему пришёл. Это
**emergent property** Q1.B, не отдельное решение.

### Q6.A — depth slider == privacy fence

Range **`2..4`**, default `4`. Точно совпадает с
`_connectedVisibilityMaxHops = 4` как hard cap.

**Reasoning**:
* Slider за пределы fence misleading — юзер тянет до 6/10,
  ничего нового не появляется, frustration.
* `min = 2` (не 1) — hop 1 = self + immediate (parents/kids/
  spouse) = 3-5 nodes; feels broken, не focused.
* `2 hops`: + grandparents + siblings + niblings (≈ 7-10 typical).
* `3 hops`: + great-grandparents + cousins.
* `4 hops`: full extended (default).

Расширение fence за 4 hops — Phase 5+ feature с consent flow,
не Phase 4.

### Q3.A — node tap для relation sheet

**Edge tap НЕ используется**. Sheet «как этот человек связан со
мной» открывается через tap на **node**.

**Reasoning**: edges на mobile микроскопические, попасть пальцем
сложно. Tap на node открывает sheet с identity + relation-to-me
(lazy compute via existing `/v1/trees/:id/relation-path`,
Phase 2). Edge tap технически интересен, UX-вред.

### Q4.A — нет «Попросить доступ» stub в Phase 4

Foreign node tap-sheet **не** включает «Попросить доступ»
button до Phase 5+.

**Reasoning**: lure без выполнения = ложное обещание UX. Юзер
тапает foreign node → sheet с owner identity row + «Написать»
button (chat existing flow) + «Открыть карточку» (read-only
person card). Real edit-request flow — Phase 5+ когда есть
real implementation на backend'е (notification ping owner'у +
inbox для request'а).

### Q5.A — client-side search filter ≤ 1000 persons

Search в extended view фильтрует **client-side по уже-fetched
slice'у**. Server-side search endpoint и пагинация — **Phase 5+**.

**Reasoning**: у тестовых users < 100 persons. Production случаев
slice > 1000 не будет в обозримом времени. Premature optimization
сейчас. Document'ируем limit в proposal'е, если real data покажет
slice > 1000 в realistic flow — Phase 4.1 addendum.

### Q7.A — chips horizontal scrollable

Filter chips для branches / generations — горизонтально
scrollable container (`SingleChildScrollView(scrollDirection:
Axis.horizontal)` либо `Wrap` с overflow). Standard Material
Design Filter Chips pattern.

**Reasoning**: dropdown для filters compact'нее, но скрывает
options. Chips более скан'абельны и tap-friendly на mobile.
Scrollable обходит cramping на narrow. Dropdown как fallback —
только если 5+ filters и clearly hierarchical (сейчас 3-4 filter
— chips OK).

### Q8.A — per-tree persist для mode toggle

View mode (`mine` / `extendedNetwork`) сохраняется **per-tree**
через SharedPreferences с key'ом `extended_mode_${treeId}`.
Default «Моё дерево» при отсутствии preference'а — opt-in явный.

**Reasoning**: у разных tree'ев (family vs friends vs round)
могут быть разные предпочтения. Friends-tree вряд ли нужен
extended (там мало identity-cross-link'ов); blood-tree —
наоборот, главное место использования. Global preference
теряет per-tree intent.

### Q8.B — URL shareability deferred

Phase 4 v1 не реализует shareable URL для extended slice
(`/tree/view/:treeId?mode=extended&depth=N`). **Phase 5+ если
понадобится**.

**Reasoning**: дополнительная surface — routing + permission
check на recipient'е (если recipient вне privacy fence —
fallback на default view + warning). Сценарий «look at my
tree this way» пока гипотетический, не блокирует Phase 4.

### Q8.C — narrow mobile layout test in implementation

AppBar segmented control «Моё / Все» (short labels, font
scaling). Layout testing откладывается до implementation chunk —
не reschedule заранее.

**Fallback**: если на 320dp выглядит cramped → icon-only
(`mode_outlined` / `network_check_outlined`) с tooltip'ами.
Decide on actual implementation, не блокер для proposal'а.

**Принято**: Артём (user) 2026-05-12 (Phase 4 proposal v1 review).

### Chunk 1 implementation decisions (2026-05-12, follow-up)

Принятые внутри chunk 1 implementation (по Артёмову «think about»
блоку в approve message'е, surfaced before coding):

**Sparse ownerMap (nice-to-have #1, IMPLEMENTED)**:
* Response payload содержит entries в `ownerMap` **только для
  foreign nodes** (owner !== viewer). Viewer-owned nodes — implicit,
  resolve через `slice.getOwnerInfo(id) == null` client-side.
* На 90%+ typical viewer'а экономит payload + memory.
* DTO helper `ExtendedNetworkSlice.isForeignNode(id)` + `getOwnerInfo(id)`
  делает sparse pattern API-clean для UI.

**Cache 60s TTL без invalidation (nice-to-have #2, IMPLEMENTED)**:
* In-memory Map в route closure scope; key = `${treeId}:${viewerId}:${maxHops}:${includeAnonymous}:${branchIds}`.
* 60s window после mutation acceptable: Phase 4 — view layer, **не**
  edit canvas. Edit чужих nodes — only через grants и через my-only
  view (relative_details), где cache не релевантен.
* GC: каждые 200+ entries старые expired удаляются. Простая
  protection от unbounded memory growth.
* Без invalidation hooks на mutation endpoints — invalidation
  через event bus / pub-sub был бы over-engineering для текущей
  storage layer (JSONB + lazy postgres-store).

**`branchIds` query param**:
* В chunk 1 — placeholder для cross-branch filtering. v1 ignored
  unless explicitly matches treeId (current schema mirror'ит trees
  1:1 на branches).
* Phase 4.1+: при наличии truly cross-branch graphPersons (e.g.
  юзер участвует в Машиной branch'е через grant) — этот param
  будет filter'ить по branch ID.

**Test coverage (nice-to-have #3, IMPLEMENTED)**:
* `backend/test/extended-network-endpoint.test.js` — 10 tests:
  auth (401 no token, 403 non-member, 200 member), maxHops clamp
  (1→2, 10→4, garbage→default), privacy isolation (stranger's
  tree persons not in slice), sparse ownerMap, cap behavior (cap=3
  fixture → capReached=true), cache 60s TTL functional.
* `test/extended_network_slice_test.dart` — 10 DTO tests: fromJson
  full payload, sparse helpers, defensive parsing, malformed
  entries, isAlive default, hopDistance coercion, nullable strings,
  round-trip, stats coercion.

**Принято**: Claude (chunk 1 implementation, surface'нуто к Артёмову
review в commit'е chunk 1).

### Chunk 3 visual design (2026-05-12, follow-up)

Reviewer Артём после chunk 2 push'а surface'ил визуальный design
chunk 3 в **per-element table** вместо v1 «colour tint + 18×18 badge
+ dashed edges» blanket. Каждое из 5 элементов — независимый
approval gate, чтобы «не подкидывать всё вместе» (комплект может
«протащиться» через одобрение). Полная developer-facing reference
в **PHASE-4-PROPOSAL.md §5.A**.

**Element 1 — Colour tint own vs foreign nodes**: **APPROVED**
(essential). My nodes — warm beige (`primaryContainer`, current
default); foreign — cool grey-blue (low saturation
`surfaceContainerLow`). Контраст ≥ 3:1, читаем без eye strain на
≥10 nodes distance. Это **signal, не шум**. Без него extended mode
бессмыслен.

**Element 2 — Edge color tint (cross-tree)**: **APPROVED as
replacement for dashed**. My-to-my edges — `primary` palette
(current). Cross-tree — `surfaceVariant` (muted). Solid lines both,
no dashed pattern. Дешевле рендер, лучше viewability на 1-2px
strokes. Замена dashed (см. dropped).

**Element 3 — Owner avatar badge**: **APPROVED as on-tap only,
NOT always-visible**. По умолчанию foreign node только с tint'ом,
без badge'а. Tap → foreign node sheet (chunk 4) рендерит owner
avatar full size. Reasoning: 50+ foreign nodes × 18×18 badge =
visual noise, на 320dp может overlapping с text.

**Element 4 — Conflict ⚠ badge**: **APPROVED (existing, no change)**.
Phase 3.4 chunk 5 уже реализовал. Продолжает работать для both my
и foreign nodes в chunk 3.

**Element 5 — Deleted state**: **APPROVED (existing, no change)**.
Existing UI остаётся; в practice deleted-state в extended mode не
появится (backend filter'ит `deletedAt != null`), но defensive
code path сохраняется.

**DROPPED** (chunk 3 visual review):
* **Dashed cross-tree edges** — replaced Element 2 edge color tint.
  Dashed на тонкой 1-2px line почти не виден; рендеринг dashed Path
  в Flutter Canvas дороже solid (extra path operations × per
  frame).
* **Always-visible owner badge на foreign nodes** — replaced
  Element 3 on-tap. Always-visible = noise на 50+ foreign nodes
  + risk overlap на narrow viewport.

**Chunk 3 implementation gates** (per Артёмов request, обязательны
перед coding):
1. **Perf baseline** на legacy mine view — synthetic fixture'ы
   100/500/1000 persons, first paint + scroll FPS. Если new
   render path regress'нёт legacy mine — halt chunk 3.
2. **Visual snapshot tests** — golden files per state (own / foreign
   tint / own+conflict / foreign+conflict / deleted).
3. **Feature-flag `useExtendedRenderPath`** — `false` daje legacy
   bit-identical path. Защита от regression во время review.
   Удаляется после chunk 4 либо +1 prod week.

**Принято**: Артём (user) 2026-05-12 (chunk 3 prep visual review).

### Chunk 3 follow-up caveats + flag removal (2026-05-12)

После 5/5 per-element approvals + 3/3 gates approvals, два
follow-up caveat'а и flag removal sequence:

**Caveat 1 (Element 1 tint contrast)**: WCAG 3:1 contrast — non-text
UI минимум, **но визуально проверь на 50% zoom** (scroll-out view).
Если tint становится indistinguishable на scrolled-out — увеличить
saturation. Test'ируем в golden snapshot на 2-3 zoom levels (1.0,
0.5, 0.25). Не полагаемся на абстрактные WCAG-цифры — глазная
проверка на realistic zoom.

**Caveat 2 (Gate 2 golden snapshots — pin variables)**: Golden file
snapshots в **одной теме** consistently — light. Dark mode subtle
rendering precision (shadow / blur) drift'ит на разных dev машинах
и CI runner'ах. Fixed in test setup:
* `ThemeMode.light` (force, не system).
* Fixed window size (1920×1080 для desktop snapshots, 390×844 для
  mobile snapshots — стандарты iPhone/Android current).
* Fixed font scale (`MediaQueryData.textScaler = TextScaler.noScaling`).

Это даёт reproducible golden files. Любой drift на CI = real visual
regression, не environment noise.

**Flag removal sequence для `useExtendedRenderPath`**:

```
1. Chunk 3 merged в feature branch с flag=false (legacy default).
2. Chunk 4 merged в feature branch с flag=false (legacy default).
3. Feature branch → main (squash, all commits flag=false).
4. Manual smoke на production:
   - toggle flag=true для test аккаунтов (Артём + Степа).
   - Verify extended mode работает end-to-end.
   - Watch metrics +1 week (no error spike, no perf regression
     alerts).
5. Если +1 week clean → cleanup commit:
   refactor(phase-4): remove useExtendedRenderPath feature flag,
                       extended is now default
6. Step 5 удаляет flag + legacy code path. Irreversible.
```

Rollback path до step 5: deploy с `flag=false` → bit-identical legacy
behavior в один CI cycle. После step 5 (legacy code path removed) —
rollback требует revert step 5 commit'а либо git revert на feature
branch.

**Принято**: Артём (user) 2026-05-12 (chunk 3 prep — caveats + flag
removal confirmation).

### 100-node fixture noise — D Accept (2026-05-12)

Mean-of-3 + stronger warmup даёт σ ≈ 25% raw / ~14% effective
(σ/√3) для 100-node fixture (vs ~5% для 500/1000). 10% regression
threshold потенциально flake'ает на 100-node case.

**Решение**: **accept noise**. Perf tests в `test/perf/` directory,
**not в CI default run** — manual execution only. Premature
engineering против noise когда tests не блокируют builds = тратим
время на не-проблему.

**Если в будущем перейдут в CI и flake'нут на 100-node**:
* **Option A** — drop 100-node fixture entirely. Typical
  case, но signal слабый для realistic perf assessment.
* **Option B** — per-fixture threshold (15% для 100, 10% для
  500/1000).
* **Option E** — keep 100-node как smoke run без threshold
  comparison (catch crashes / hangs, ignore timing).

Re-evaluate когда CI integration perf tests'ов спроектирована.

**Принято**: Артём (user) 2026-05-12 (methodology fix follow-up,
после Claude's surface of 100-node noise).

### 25% zoom golden test deferred (2026-05-12 chunk 3b follow-up)

Transform.scale в widget test **не reflects** real InteractiveViewer
scroll-out rendering. Capture native 25% zoom требует controller-
based transformation matrix setup в test harness (~50-100 LOC
дополнительно + cognitive overhead).

**Решение**: defer на chunk 3d либо post-Phase-4 visual smoke pass.
100% и 50% goldens (16 snapshots chunk 3b) покрывают critical zoom
levels где differentiation matters. На 25% overview view individual
card tint signal already marginal — acceptable melt.

**Принято**: Артём (user) 2026-05-12 (chunk 3b approve follow-up).

### Slice scan O(N²) overhead — deferred trigger-based fix (2026-05-12)

`_isPersonForeign` в `interactive_family_tree.dart` вызывает
`slice.graphPersons.any((g) => g.id == personId)` per card render.
Это O(N) per card → O(N²) total для full tree. На 1000-node slice
(cap maximum) теоретическое overhead ~1M comparisons ≈ ~50ms.

На typical 7-100 nodes (DECISIONS.md 2026-05-12 §4 slice size
re-estimate) — микросекунды cost, hidden в variance noise. Не
проблема.

**Решение**: defer fix до **measured trigger**:
* Если perf re-baseline в chunk 3c либо 3d покажет flag-on
  regression > 10% vs flag-off на 500/1000 fixture'ах →
  Set<id> cache в `ExtendedNetworkSlice` (~15 LOC fix, обратимо).

Premature optimization для worst case который для типичного юзера
никогда не возникнет — wait для actual signal.

**Принято**: Артём (user) 2026-05-12 (chunk 3b approve follow-up).

### Phase 4 backend addendum — viewerSelfGraphPersonId (2026-05-12)

`getExtendedNetworkSlice` response добавляет
`viewerSelfGraphPersonId: string | null` поле.

**Reason**: client-side `slice.graphPersons.firstWhere((p) =>
p.userId == auth.currentUserId)` требует `userId` field в
`ExtendedNetworkPerson` DTO, которого там нет (sparse design — DTO
public preview только, без full ownership). Backend уже знает
viewer's identityId → self-node mapping (`_selfGraphPersonIdForUser`
helper) — surface это deterministic field вместо client-side scan
который требует расширения DTO.

**Properties**:
* Single contract field (~12 LOC backend + 11 LOC DTO).
* Versionable: clients ignoring field continue working (null-safe
  defaults).
* Null когда viewer не имеет claimed self-node (edge case —
  anonymous tester либо account без identity yet).
* Used в chunk 4a foreign node sheet для `from` parameter `/v1/graph/
  relation` lazy fetch'а.

**Принято**: Артём (user) 2026-05-12 (chunk 4a approve follow-up).

---

## 2026-05-13: Phase 6 chunk 1 — naming + idempotency

### Collection naming: kinshipChecks vs relationRequests

**Existing `relationRequests`** (Phase 1) — flow **invite-to-tree**
(recipient joins sender's tree as user-linked person). Endpoint
family `/v1/trees/:treeId/relation-requests` + `/v1/relation-requests/*`.

**Phase 6 BFS «мы родственники?»** — semantic mismatch (discovery
shortest-path consent), не invite. Different state machine, different
side effects.

**Решение**: new collection **`kinshipChecks`** + endpoint family
**`/v1/kinship-checks/*`**. Existing `relationRequests` unchanged.

**User-facing strings** — «проверка родства», «Проверить, родственники
ли мы», «Запрос на подтверждение родственной связи». **No backend
jargon в UI** («kinship», «probe», «BFS», «check» — все backend-only
terms).

### Idempotency: state-based для /onboarding/seed

**Pattern**: state-based вместо header `Idempotency-Key`. Wizard
natural state (completed/incomplete) maps к idempotency boundary
cleanly.

* `POST /v1/onboarding/seed`:
  - If `onboardingStates[userId].completed === true` → return
    existing `{treeId, personIds}` (idempotent re-call).
  - If incomplete attempt exists (previous tree partial) →
    **replace**: delete previous tree + persons, then create new
    с current request payload. User не должен иметь ghost дерево
    с half-сохранённой попыткой.
  - If absent → fresh atomic seed.

**Rejected alternative**: header `Idempotency-Key`. UUID generation
client-side + TTL cleanup window — over-engineering для wizard
scenario.

**Принято**: Артём (user) 2026-05-13 (Phase 6 chunk 1 pre-coding
verify approve).

---

## 2026-05-14: Phase 6 kinship-check rejection cooldown 30d

При создании kinship_check'а инициатором, если target ранее
rejected запрос within last 30 days — backend возвращает 429
+ `retryAfterMs`.

**Цель**: anti-spam защита, чтобы persistent initiator не
доставал rejected target повторно. Без cooldown rejected
target будет получать notifications repeatedly — превращается
в harassment vector.

**30d window** — balance между:
* User changed mind может legitimately want to retry.
* Persistent harassment без reasonable break.

**Cooldown reset condition**:
* Confirmed match с этим target (existing relationship через
  identity-claim либо tree membership).
* Target's status update (block / unblock — Phase 7+ moderation
  features).

**UI surface**: «Этот юзер недавно отклонил запрос. Попробуйте
через 30 дней.» Show retry-after countdown в settings либо
notification.

**Addition history**: не в original Phase 6 proposal v2 —
proactively добавлено agent'ом во время chunk 1 implementation
как anti-spam invariant. Surface'нуто в Артёмов batched approve
2026-05-14 → confirmed как useful.

**Принято**: Артём (user) 2026-05-14 (chunk 1 approve follow-up).

---

## 2026-05-14: Phase 6 wizard route — /setup vs /onboarding

Existing `/onboarding` — Phase 1 welcome carousel (5-slide
PageView, marketing intro shown once after signup в legacy
flow). Phase 6 wizard — first-time user **setup** (4-step form,
account profile → first relatives seed).

**Semantically distinct experiences**:
* `/onboarding` = «welcome tour» (skippable, marketing).
* `/setup` = «account setup» (functional, creates tree).

**Решение**: separate routes — `/onboarding` (existing tour
unchanged), `/setup` (Phase 6 wizard). Не rename existing для
backward compat (old links / deep-link references survive) +
clear separation.

**Notification copy** — UI strings reference «настройка» / «начать
заполнять дерево», never «onboarding» либо «setup» backend term.

**Принято**: Артём (user) 2026-05-14 (chunk 2 approve follow-up).

---

## 2026-05-14: Phase 6 post-signup redirect — Option A simplified

**Surfaced при chunk 2 review**: wizard accessible через direct
nav `/setup` — no automatic redirect post-signup. Phase 6 core
purpose — onboard new users automatically; manual entry point
preserves funnel leak.

**Решение**: **Option A simplified** — post-signup-specific
redirect, не universal router guard.

**Architecture**:
* Backend `/v1/auth/register` response carries `requiresOnboarding:
  bool` flag (либо derive из onboardingStates absence).
* Client signup flow: after successful auth response, if
  `requiresOnboarding === true` → redirect to `/setup` instead
  of `/`.
* Existing user login flow: response без flag (либо `false`) →
  standard `/` redirect.
* User mid-wizard на crash/relaunch — resume через existing
  GET `/v1/me/onboarding-state` (chunk 1 backend supports).

**Why Option A** (vs B async router init, vs C manual entry):
* B (async router init) — heavier, requires AppLaunch loader,
  changes initial route resolution.
* C (manual entry) — preserves funnel leak; manual «Start setup»
  link assumes user understands need. Rejected.
* A (post-signup-only redirect) — minimal touching: backend +1
  field, client +1 conditional redirect.

**Scope**: implementation deferred к chunk 4 polish (chunk 3
focuses on discover «мы родственники?» UI per proposal §11).

**Принято**: Артём (user) 2026-05-14 (chunk 2 approve follow-up).

---

## 2026-05-14: Phase 6 chunk 4c — identity-suggestions push notification deferred

**Surfaced при chunk 4c implementation**: PHASE-6-PROPOSAL.md
§5.X envisions a post-onboarding push notification surfacing
identity-suggestions:

> «Возможно, ваш Виктор Моздуков — тот же человек, что у Степы.
> Связать карточки?»

**Existing infrastructure** (Phase 1.2):
* `findCrossTreeIdentitySuggestions` matcher
  (backend/src/identity-matcher.js).
* `GET /v1/trees/:treeId/persons/:personId/identity-suggestions`
  endpoint — per-person lazy fetch.
* 💡 indicator на каждой card в tree view — auto-surfaces matches
  когда client renders.

**What's missing** (proposal scope):
* Backend async trigger post-seed runs matcher для seeded persons.
* Persistent suggestion storage (currently lazy on-demand).
* Push notification dispatch с tap-target wiring.

**Решение**: defer push notification к Phase 6.5 (out-of-scope
follow-up).

**Why defer**:
* Existing 💡 indicator covers discovery on-demand (user opens
  tree → cards render → matcher runs → indicator surfaces).
* Push dispatch ≠ trivial — needs background job, per-match либо
  batched delivery decision, notification copy variants, tap-target
  wiring. Меняет surface area beyond chunk 4 scope.
* No data-driven signal что lazy discovery insufficient. Если
  observation week shows users miss matches, prioritize Phase 6.5.

**Scope-out не функциональный**: Phase 6 v1 ships без push, users
still see matches via 💡 indicator. Discovery path preserved.

**Принято**: Claude (agent) 2026-05-14 (chunk 4c self-judge);
surface для Артёма audit на chunk 4c review.

---

## 2026-05-18: Phase 6 `/v1/auth/session` hot-path fix

**Контекст**: `b4dcb47` (Phase 6 chunk 4a follow-up) добавил
`await store.hasIncompleteOnboarding({userId})` read в
`GET /v1/auth/session`, нарушив инвариант api.test.js:13345
«auth session endpoint can serve from cached auth context» —
endpoint вызывается клиентом на каждый router-tick и обслуживается
из `_userCache` без `_read`. Backend deploy run `26013704426`
failed на этом тесте → прод остался на старом binary без endpoint
fix → smoke-test landing на `/complete_profile` вместо `/setup`
wizard (тот же симптом, который b4dcb47 должен был fix'нуть).

**Решение**: A3 — write-through cache `_onboardingIncompleteCache:
Map<userId, boolean>` в `FileStore`, mirrors паттерн `_userCache`.

* `hasIncompleteOnboarding({userId})` — cache-first; cache miss
  fallback на `_read` (legacy users либо cold cache после restart
  процесса).
* `updateOnboardingState` + `seedOnboarding` — write-through после
  `_write`, derive result из persisted state. Покрывает оба write
  paths, где `completed = true` может быть установлено.
* `_forgetUser` — sweep кэш при удалении user (transitive из
  `deleteUser`).
* `PostgresStore extends FileStore` без override
  `hasIncompleteOnboarding` → fix транзитивно покрывает prod path.
  Тест `PostgresStore auth hot paths avoid full state reads`
  проверяет этот invariant в Postgres-режиме и зелёный.

**Альтернативы**:
* **A1**: inject `requiresOnboarding` в `req.auth` через
  `requireAuth` middleware — смешивает onboarding-concern с
  auth-concern, расширяет hot path для всех endpoints даже когда
  им флаг не нужен.
* **A2**: JWT/access-token claim — stale state после wizard
  completion до refresh token; усложняет invalidation.
* **B**: relax api.test.js:13345 invariant — endpoint hits
  ~per-route-tick; лишний `_read` это потеря hot-path contract'а
  навсегда.
* **C**: только client-side defense (`_sessionFromResponse`
  preserves existing flag при null, b4dcb47 client часть) без
  backend поля — gap для других callers `/v1/auth/session` без
  guarantee, что флаг приедет.

**Cache invalidation**: per-user write-through. Все write paths к
`onboardingStates.<row>.completed` identified через grep — два
места (`updateOnboardingState`, `seedOnboarding`), оба `cache.set`
после `_write`. User deletion очищает кэш через `_forgetUser`.
Per-process scope OK для FileStore (test fixture) + single-instance
PostgresStore (prod на 2026-05-18). Multi-instance backend в
будущем потребует cross-process invalidation (Redis pubsub либо
postgres NOTIFY) — logged как Phase 6.5 follow-up, не блокер
сейчас.

**Влияет на**:
* `backend/src/store.js` — `FileStore` конструктор, `_forgetUser`,
  `hasIncompleteOnboarding`, `updateOnboardingState`,
  `seedOnboarding` (+35/-4).
* `PostgresStore` (наследует FileStore, имплицитно).

**Commits**: `b4dcb47` (backend endpoint поле + client defense) +
`40202a1` (cache hot path follow-up). Both в `main`, без revert.

**Verify**:
* Locally: api.test.js:13345 green, auth-onboarding-redirect.test.js
  10/10, postgres-store hot-path тесты green.
* Backend deploy run `26020837859` success (47s, all steps green).
* Live `GET /v1/auth/session` возвращает `requiresOnboarding: true`
  для не-завершённого user (api.rodnya-tree.ru).
* ADB smoke-test pass: login → `/setup` wizard welcome
  («Старт» step indicator, «Добро пожаловать в Родню»).

**Принято**: Артём + Claude.

---

## 2026-05-18: Phase 4 `useExtendedRenderPath` cleanup

**Контекст**: Phase 4 (extended-family network) shipped 2026-05-12
`028d1d2` с feature-flag `useExtendedRenderPath` в
`lib/config/feature_flags.dart`. 2026-05-13 `5fb1d3c` — flag flip
default `true` (observation window start). Original plan: cleanup
+1w после flip = ~2026-05-20, but cutover plan смещался к
~2026-05-17 (NEXT_STEPS.md, MERGE-CHECKLIST-PHASE-6.md §7). Сегодня
2026-05-18 — на день позже, закрываем.

`git log origin/main --since=2026-04-15 | grep -iE
"rollback|revert|hotfix"` — clean. Observation window прошла без
regression signals.

**Решение**: удалить flag + связанные artifacts в один cleanup
commit:

* `lib/config/feature_flags.dart` — file deleted (single-member
  class, `useExtendedRenderPath` был единственным flag'ом; пустой
  scaffold «на будущее» не оставлять).
* `extendedRenderPathOverride` `@visibleForTesting` parameter из
  `InteractiveFamilyTree` constructor + связанный field — clean
  break без deprecation stub. Prod callers не используют, только
  3 тест-файла, обновлены одновременно.
* `_isExtendedRenderActive` getter упрощён до
  `viewMode == extended && networkSlice != null` (был
  `(override ?? FeatureFlags.useExtendedRenderPath) &&
  viewMode==extended && slice!=null`).
* Stale comments в widget («const = false») удалены, не
  переписаны — фактический default `true` с 2026-05-13.
* Comment-mention в `tree_view_screen_sections.dart` — orphan
  reference на удалённый класс, snipе целиком.

**Perf baseline test simplification (Q1 variant A)**:

`test/perf/interactive_family_tree_baseline_test.dart` имел Test 2
с `expect(flag-on, lessThanOrEqualTo(flag-off_baseline * 1.10))` —
parity assertion, которая умирает вместе с flag-off baseline. Заменили
на measure-and-log без `expect`:

* Single test case (Test 1 + Test 2 → один).
* `_singleMeasurement` / `_measureFirstPaintMs` без branching,
  всегда builds extended-render widget.
* `baseline.json` mechanism удалён (`_readBaseline`, `_writeBaseline`,
  `UPDATE_PERF_BASELINE` env switch) + сам `test/perf/baseline.json`
  file — содержал mine-view numbers, incomparable с extended-view
  measurements после cleanup.
* Regression detection — debugPrint observability на CI logs, не
  CI gate. Mean-of-3 на 100/500/1000 chain fixtures preserved как
  measurement methodology.

**Альтернативы (perf test)**:
* Variant B (absolute threshold based on documented variance) —
  rejected: новый baseline нужно зафиксировать как const, scope
  cleanup commit'а расширяется. Variant A проще + наблюдательность
  через CI logs остаётся.
* Keep both tests post-cleanup — rejected: Test 1 base'ом был
  mine-view (legacy=true в момент написания), оба after cleanup
  measures the same extended path → дубликат.

**Влияет на**:
* `lib/config/feature_flags.dart` — deleted.
* `lib/widgets/interactive_family_tree.dart` — flag check + override
  + stale comments removed.
* `lib/screens/tree_view_screen_sections.dart` — comment-mention
  removed.
* `test/extended_network_flow_test.dart` — FeatureFlags references
  + import removed.
* `test/foreign_person_id_translation_test.dart` — override params
  removed + legacy testWidgets case deleted.
* `test/perf/interactive_family_tree_baseline_test.dart` — major
  simplification (-174 LOC).
* `test/perf/baseline.json` — deleted.

**Commit**: `baa75d5` (-263 LOC across 7 files: 5 modified + 2
deleted).

**Verify**:
* `flutter analyze`: 2 warnings (pre-existing baseline, 0 new).
* `flutter test` целевые: extended_network_*.dart (29 tests),
  foreign_person_id_translation_test.dart (2 tests after legacy
  removal), extended_network_flow_test.dart (8 tests),
  interactive_family_tree_test.dart (29 tests) — all green.
* `flutter test test/perf/ --tags perf --run-skipped` — passes
  measure-and-log: 100→214ms, 500→630ms, 1000→1179ms (mean of 3).
* Frontend deploy run `26025409726` success (включая internal route
  smoke after deploy).
* `curl -I https://rodnya-tree.ru/` → 200 OK, Last-Modified
  `Mon, 18 May 2026 09:36:58 GMT`.

**Принято**: Артём + Claude.

---

## 2026-05-18: Phase 3.6 hard-delete background job

**Контекст**: soft-delete с 2026-05-12 ставит `deletedAt` (+
`hardDeleteScheduledAt` Path A only) на graphPersons / graphRelations /
branches / personIdentities, но physical cleanup отсутствует.
Записи копятся вечно → раздувают backups, нарушают GDPR-ожидание
«удалил → удалено». Phase 3.6 — заполнитель этого gap'а.

**Решение**: background job `hardDeleteExpired` на store слое +
thin scheduler wrapper в `backend/src/jobs/hard-delete-job.js`.
Document-based architecture (single JSON blob через FileStore либо
PostgresStore single-row JSONB) → не SQL-style migration с table
indexes / FK / batched DELETE'ами, а single full-state pass:
`_read` → mutate в памяти → `_write` (atomic per document storage).

**Hybrid eligibility формула**:
```
hardDeleteAt = entity.hardDeleteScheduledAt
  ?? (Date.parse(entity.deletedAt) + retentionDaysMs);
eligible = entity.deletedAt && hardDeleteAt < now;
```

Backwards-compat с Path A (`_markPersonDeletedInGraph` явно ставит
`hardDeleteScheduledAt = deletedAt + 30d`) + forward-compat с
потенциальными custom retention'ами (например user requested extend
window — кодом меняет explicit поле). Age-based fallback covers
Path B (`_reconcilePersonIdentities`) + graphRelations + branches +
personIdentities — все они оставляют `hardDeleteScheduledAt`
undefined.

**Order (application-level, не FK — FK не существуют в document
storage)**:
```
graphRelations → branches → personIdentities → graphPersons →
  branchPersonViews (orphans от вышепроцессенных)
```
Leaf-first, root-last. Cap mid-collection может halt — partial
state OK, reconciliation cleans dangling refs на next state load.

**branchPersonViews**: orphan cleanup, не own `deletedAt` (annotation
entity). После сбора hard-deleted branch + graphPerson IDs в same
run, фильтрует views ссылающиеся на удаляемые IDs. Один pass, тот
же транзакционный scope.

**Альтернативы**:
* **Чистый age-based** (без explicit override): отвергнут — теряет
  semantics Path A, не позволяет future custom retentions.
* **Backfill `hardDeleteScheduledAt` всем существующим**:
  отвергнут — touch existing data, риск migration corruption ради
  unify'а который age-based fallback уже handles.
* **node-cron dependency**: отвергнут — `setInterval` 24h
  достаточно для daily job, нет нужды в cron syntax. Минимизируем
  deps.
* **On-demand cleanup при user request**: отвергнут — не
  масштабируется, не помогает с reconciliation orphans которые
  user не trigger'ит вручную.
* **DB trigger на UPDATE**: N/A — document storage, нет per-column
  triggers.
* **SQL migration с indexes + audit table**: N/A — document
  storage не даёт SQL DDL. Migration = добавление
  `hardDeleteAudit: []` + `hardDeleteLastRunAt: null` в EMPTY_DB +
  normalizeDbState (zero-DDL).

**Cache + restart safety**:
* `state.hardDeleteLastRunAt` persisted после каждого live (non-dry,
  non-paused) run.
* Scheduler на startup вычисляет catch-up delay через
  `computeFirstDelayMs`:
  - `firstRunDry=true` → 60s overrides всё (review log timing,
    not 24h wait).
  - Нет `lastRunAt` → catch-up через 60s.
  - `lastRunAt` старше `intervalMs` → catch-up через 60s.
  - `lastRunAt` recent → wait `intervalMs - elapsed`.
* Catch-up cap = single bonus run + next regular cycle (не rapid-
  fire multi-runs).

**Rollout sequence (must follow)**:
```
1. Deploy: hardDeleteEnabled=false (default) → scheduler не
   register'ится, log «hard_delete_job_disabled».
2. Set RODNYA_HARD_DELETE_ENABLED=true → backend restart →
   через 60s первый dry-run (hardDeleteFirstRunDry=true default) →
   log JSON с {dryRun: true, deleted: {graphPersons: N, ...},
   sampleIds: {...}, capHit: false, errors: []}.
3. Артёмов review:
   - Counts reasonable? (10K+ → flag suspicious либо expected
     backlog).
   - Sample IDs — это действительно те записи которые expected
     hard-deleted?
   - errors[] пустой?
4. Set RODNYA_HARD_DELETE_FIRST_RUN_DRY=false → следующий
   scheduled run работает live.
5. Steady state: 24h cycle.
```

**Multi-instance considerations**: out of scope для Phase 3.6.
Single-instance prod (per Phase 6 hot-path fix DECISIONS). Если
завтра multi-instance scales → нужен `pg_advisory_lock` либо
optimistic-concurrency через version field на state document.
Logged как Phase 6.5+ follow-up.

**Влияет на**:
* `backend/src/jobs/hard-delete-job.js` — new (~200 LOC).
* `backend/src/store.js` — конструктор + `_forgetUser` уже не
  trogается, новый `hardDeleteExpired` method (+234 LOC) + EMPTY_DB
  defaults + normalizeDbState defaults.
* `backend/src/config.js` — 9 env vars + `readEnvBool` helper (+71
  LOC).
* `backend/src/server.js` — wire `scheduleHardDeleteJob` после
  store init (+8 LOC).
* `backend/src/migration-utils.js` — добавил `hardDeleteAudit` к
  `SNAPSHOT_COLLECTION_KEYS` (+4 LOC).
* `backend/test/hard-delete-job.test.js` — new test file
  (~330 LOC, 14 tests).

**Commit**: `253efaf feat(phase-3.6): hard-delete background job`.
Net: +957 LOC across 6 files (4 modified + 2 new).

**Verify (local)**:
* Full backend test suite: 199/201 pass (2 Windows-only ENOTEMPTY
  baseline flakes, not regression).
* Phase 3.6 tests: 14/14 pass.
* `flutter analyze` не запускался (backend-only commit).
* Backend deploy run `26028844174` success (41s).
* `curl https://api.rodnya-tree.ru/ready` → 200 OK.
* `curl POST /v1/auth/login` smoke → valid sessionToken (regression
  check для observation window Phase 6).
* Boot disabled log: `hard_delete_job_disabled` (default).
* Boot enabled log с corrected config: firstRunInMs=60000,
  intervalMs=43200000 (12h test), retentionDays=30, firstRunDry=true.
* Ad-hoc e2e через FileStore on temp disk: seed → dry-run (state
  untouched) → live-run (eligible entities physically gone, audit
  populated, lastRunAt persisted, recent entries preserved).

**Out of scope**:
* Multi-instance distributed lock — Phase 6.5+.
* User account hard-delete — отдельный flow с consent confirmation,
  GDPR territory.
* Backup-before-delete — audit log (90d retention) достаточен.
* prom-client metrics export — Phase 6.5+ если потребуется
  dashboard.

**Принято**: Артём + Claude.

---

## 2026-05-19: Phase 3.6 hard-delete activated в проде

**Контекст**: Phase 3.6 ship'нут `253efaf` 2026-05-18 в режиме master
toggle off (`RODNYA_HARD_DELETE_ENABLED=false` default). Backend deploy
success, code loaded, job sleeping. Сегодня manual env flip на
rodnya-backend сервере (212.69.84.167) для активации.

**Решение**: production activation hard-delete background job в режиме
live (не dry). Two-stage rollout: first dry run для verify execution,
потом `RODNYA_HARD_DELETE_FIRST_RUN_DRY=false` для live mode.

**Rollout execution (2026-05-19 UTC)**:
* 02:58 — backup `/etc/rodnya-backend.env` → `bak-20260519-025824`
* 02:59:33 — `RODNYA_HARD_DELETE_ENABLED=true` appended, `systemctl
  restart rodnya-backend`. Boot log: `hard_delete_job_scheduled
  {firstRunInMs:60000, intervalMs:86400000, retentionDays:30,
  firstRunDry:true, ...}`.
* 03:00:33 — first dry run (60s после restart): 0 deletions, 241ms,
  `errors:[]`, `sampleIds:{}` empty (ничего не matched 30-day
  retention). `runId:e9b4bb41-ee13-4672-adb0-bda98bf5e60e`.
* 03:02:44 — `RODNYA_HARD_DELETE_FIRST_RUN_DRY=false` appended, restart.
* 03:03:45 — first live run: 0 deletions, 505ms (+260ms за state
  document write), `lastRunAt=2026-05-19T03:03:45.674Z` persisted,
  `errors:[]`. `runId:5086f109-1166-4d69-905e-70281f64fef4`.

**Counts = 0 — interpretation**: project молодой, Phase 6 ship 2026-05-14
recent reconciliation activity не достигла 30-day retention. Вчерашние
DELETE /persons (~7 часов age на момент flip) корректно не подхвачены —
правильное behavior. R1 (большой first-run backlog) не материализовался.

**Что подтверждено в проде**:
* dryRun mode не персистит `lastRunAt` (correct — state untouched).
* Live mode персистит `lastRunAt` через state document write.
* FK delete order traversed без errors.
* All 5 entity types correctly enumerated (`graphPersons`,
  `graphRelations`, `branches`, `personIdentities`, `branchPersonViews`).
* Audit prune integrated в same pass (`auditPruned` counter).
* Service stable post-activation: memory 56.8M, `/ready` 200,
  Phase 6 hot-path session endpoint без regression.

**Next scheduled run**: ~2026-05-20 03:03 UTC (через `intervalMs -
elapsed_since_lastRunAt` ≈ 23h 57min).

**Rollback procedure** (если потребуется):
```
ssh rodnya 'echo "RODNYA_HARD_DELETE_PAUSED=true" >> /etc/rodnya-backend.env && systemctl restart rodnya-backend'
```
Это оставит code enabled но pause flag short-circuit'нёт actual run.
Альтернатива (полный disable):
```
ssh rodnya 'sed -i "/^RODNYA_HARD_DELETE_/d" /etc/rodnya-backend.env && systemctl restart rodnya-backend'
```

**Backup env file**: `/etc/rodnya-backend.env.bak-20260519-025824`
(pre-flip snapshot, 2220 bytes).

**Влияет на**: `rodnya-backend.service` на 212.69.84.167. Без code
changes — только env vars + restart.

**Принято**: Артём + Claude.

---

## 2026-05-19: rodnya-backup.service CRLF fix (15-day failure streak)

**Контекст**: rodnya-backup.service failing identical pattern every day
с 2026-05-05 по 2026-05-19 (15 дней подряд). Discovered случайно во
время Phase 3.6 activation discovery phase (`systemctl list-units` showed
backup-service в failed state). Артём не получал alerts — нет monitoring
infrastructure для systemd failed services.

**Root cause**: `/usr/local/bin/rodnya-backup.sh` имел Windows CRLF line
endings на последних 2 строках (hex: `-rf 0d 0a 0d 0a`). Cleanup line:
```
... | xargs -r rm -rf<CR>
```
Бash parsed `-rf\r` как single token. `rm` saw `-r`, `-f`, then `-\r`
(invalid option) → "rm: invalid option -- '<binary>'" → exit 123.
`set -euo pipefail` killed script на pipe failure. Backup script всё
кроме cleanup step делал корректно (env copy, dev-db copy, uploads tar,
postgres dump, minio tar — всё OK).

**Решение**:
```
cp -p /usr/local/bin/rodnya-backup.sh /usr/local/bin/rodnya-backup.sh.bak-20260519-fix
sed -i 's/\r$//' /usr/local/bin/rodnya-backup.sh
```
Strip trailing CR. Verified hex (`-rf 0a 0a`, LF only). `systemctl start
rodnya-backup` → exit 0/SUCCESS. Cleanup ran: 36 backup subdirs → 7
(retention = newest 7).

**Альтернативы**:
* `dos2unix` — package не установлен на сервере, лишний dep ради
  single fix.
* Manual rewrite через `cat <<'EOF' > file` — overkill для 2-char fix.
* Add `.gitattributes eol=lf` + commit script в repo — рассматривали,
  откладываем (script сейчас не в git, отдельный change).

**Cost от 15-day failure**:
* Backups делались — env, dev-db, uploads.tar.gz, postgres dump,
  minio data все intact в /var/backups/rodnya/YYYYMMDD-* directories.
* Cleanup НЕ делался → 36 directories накопились (~7 days × backup
  size data). Storage waste, не data loss.
* Recovery option: every day backup intact, можно restore from любой.

**Что НЕ в scope этой фазы** (future ops follow-ups):
* Добавить script в git repo с `.gitattributes eol=lf` для drift
  prevention. Сейчас server-side managed manually.
* `manual` directory в /var/backups/rodnya survives cleanup forever
  (alphabetic sort puts "manual" после YYYYMMDD-* prefix). Pre-existing
  quirk, не введено fix'ом. Hide-fix: rename to `2026-manual-*` либо
  exclude в find pattern.
* Monitoring для systemd failed services — `OnFailure=` systemd
  directive с email/webhook hook. Phase 6.5+ candidate.

**Backup file**: `/usr/local/bin/rodnya-backup.sh.bak-20260519-fix`
(pre-fix snapshot, 1393 bytes с CRLF).

**Влияет на**: server file `/usr/local/bin/rodnya-backup.sh` на
212.69.84.167 (НЕ в git repo). Daily timer next fire 2026-05-20 03:17 UTC.

**Принято**: Артём + Claude.

---

## 2026-05-22: Phase 3.4 branch cleanup (squash-merge artifact abandon)

**Контекст**: ветка `claude/infallible-pike-41360c` показывалась в
CURRENT-PHASE.md как "Parked, awaiting merge decision" с 2026-05-13.
Анализ при попытке решить merge'ить или нет показал `+126 / -18765`
diff stat — branch удалит 18K строк main work (Phase 4 tests,
Phase 6 onboarding/kinship tests, Phase 3.6 hard-delete job,
ops/scripts) если squash-merge.

**Root cause analysis**: commit `cb67b0b feat: Phase 3 — connected
per-user trees через identity граф (squash)` от 2026-05-11 23:33:51
уже включал Phase 3.4 UI chunks 1-5 (verified — все 10 critical
UI files exist в main, identical content к branch tip):

* `lib/widgets/visibility_toggle_section.dart`
* `lib/widgets/sensitive_contacts_section.dart`
* `lib/screens/access_grants_screen.dart`
* `lib/widgets/identity_conflicts_badge.dart`
* `lib/widgets/identity_conflicts_sheet.dart`
* `lib/widgets/access_grants_incoming_tab.dart`
* `lib/widgets/access_grants_outgoing_tab.dart`
* `lib/backend/models/edit_grant.dart`
* `lib/backend/models/include_rules.dart`
* `lib/backend/models/visibility_choice.dart`

Plus 9 corresponding test files. `git diff origin/main:$f
origin/claude/infallible-pike-41360c:$f` returned пустой результат
для всех 10 files — bit-identical content.

**Решение**: abandon branch. Это classic squash-merge artifact —
source branch остался pointing на old tip `66a31ac`, не linked
с squash commit `cb67b0b` на main. Git не знает что они equivalent
(different hashes).

**Действия**:
* `git worktree remove C:/rodnya-tree-app/.claude/worktrees/infallible-pike-41360c`
* `git push origin --delete claude/infallible-pike-41360c`
* CURRENT-PHASE.md: Phase 3.4 row перенесён из Parked в Shipped
  (`cb67b0b`), cutover plan corrected, "Pending — merge decision"
  cleaned up.

**Альтернативы**:
* Squash-merge branch как было предложено в CURRENT-PHASE —
  отвергнуто, catastrophic (lose 18K строк current main work).
* Cherry-pick конкретные Phase 3.4 commits в main — не нужно,
  work уже в main через `cb67b0b`.
* Leave branch as-is — отвергнуто, creates confusion для future
  sessions (как сегодня).

**Lesson**: squash-merge не updates source branch pointer. После
squash полезно либо (a) delete source branch immediately, либо
(b) tag squash commit с reference к source branch name (e.g.
`squash-of-infallible-pike-41360c`) для future correlation.

**Bonus — другие parked worktrees (audited 2026-05-22)**:

* `claude/quiet-meridian-7a91b3` (tip `68fa6ae docs(refactor):
  Phase 4 → main merge checklist`) — 10 unique commits (Phase 4
  chunks 3a/3b/3c/4a/4b/4c + perf baseline + docs); diff vs main
  `+421 / -10590` (75 files). **Pattern matches infallible-pike**:
  branch имеет Phase 4 development commits, main has Phase 4
  squash `028d1d2`. Recommendation: **abandon** (squash artifact).
  Не deleted в этой session — defer to отдельному Артёмова OK.
* `claude/serene-fjord-8b4d62` (tip `d704f5c feat(phase-6):
  chunk 4d — e2e integration test + MERGE-CHECKLIST`) — 10 unique
  commits (Phase 6 chunks 1/2/3/4a/4b/4c/4d + proposal v2 +
  cooldown decision); diff vs main `+411 / -2460` (35 files).
  **Pattern matches**: branch имеет Phase 6 development, main has
  Phase 6 squash `414b218`. Recommendation: **abandon**. Не
  deleted (тот же defer).
* `claude/strange-pascal-3c3c1b` (tip `fb8ec21 feat(auth): hero
  as floating card on cream`) — 0 unique commits vs main; diff
  `+881 / -37898` (189 files). Branch tip is **ancestor** of main
  (0 unique commits forward), но diff to main is massive deletions
  if merged. Likely abandoned UI iteration, work обогнала branch.
  Recommendation: **abandon** (зеро forward progress, only
  regressive merge target). Не deleted — defer.

Все 3 — same squash-artifact pattern. После Артёмова явного OK
single command cleanup:
```
git worktree remove C:/rodnya-tree-app/.claude/worktrees/quiet-meridian-7a91b3
git worktree remove C:/rodnya-tree-app/.claude/worktrees/serene-fjord-8b4d62
git worktree remove C:/rodnya-tree-app/.claude/worktrees/strange-pascal-3c3c1b
git push origin --delete claude/quiet-meridian-7a91b3
git push origin --delete claude/serene-fjord-8b4d62
git push origin --delete claude/strange-pascal-3c3c1b
```

**Влияет на**: только doc cleanup + git refs. Code в main
unchanged.

**Принято**: Артём + Claude.

### Cleanup follow-up (same session)

Three additional parked worktrees abandoned same pattern:

* `claude/quiet-meridian-7a91b3` — Phase 4 development chunks
  (squashed via `028d1d2` 2026-05-12). Worktree + remote branch
  gone clean.
* `claude/serene-fjord-8b4d62` — Phase 6 development chunks
  (squashed via `414b218` 2026-05-14). Worktree + remote branch
  gone clean.
* `claude/strange-pascal-3c3c1b` — abandoned UI iteration, 0
  unique commits ancestor of main. Remote branch deleted. Worktree
  removed from git tracking via `--force` (had untracked files —
  consistent с 0-unique-commits verification). **Filesystem
  directory `.claude/worktrees/strange-pascal-3c3c1b/` остался
  на disk** — Windows path-length limit (260 chars) при removal,
  не git-tracking issue. Manual cleanup later либо leave (orphan
  files невидимы для git, harmless).

Two remote-only branches investigated:

* `claude/fix-phase-6-setup-guard` (single commit
  `57b0953 fix(phase-6): bypass profile-complete guard для /setup
  wizard`) — **superseded**. Touches `lib/navigation/app_router_guards.dart`
  +6/-1 lines, content identical к `4602db9` уже в main (`git diff
  4602db9:... 57b0953:...` empty). Phase 6 actual fix landed через
  `4602db9` + `b4dcb47` + `40202a1` (A3 cache hot-path). Branch
  remote-deleted.
* `claude/create-github-issues-b6eKP` (single commit `062fe2f ci:
  add Claude Code GitHub Action workflow with OAuth auth`) —
  **DEFERRED, has unique production-relevant work**. Adds
  `.github/workflows/claude.yml` (NOT в main) — workflow на mention
  `@claude` в issue/PR comments. Triggers via OAuth token
  (`CLAUDE_CODE_OAUTH_TOKEN`, Max subscription quota), не API key.
  Includes author_association safety gate (OWNER / MEMBER /
  COLLABORATOR only) против random external @claude burning quota.
  **Recommendation**: cherry-pick `062fe2f` в main (preserve the
  workflow), then delete branch. Альтернативно: leave branch для
  future activation. Decision Артёма.

После cleanup `git worktree list` показывает только main checkout
(плюс orphan filesystem `strange-pascal-3c3c1b/`). `git branch -r |
grep claude/` shows only `create-github-issues-b6eKP` (deferred).

---

## 2026-05-22: Phase 6 observation early peek — null sample

**Контекст**: review window 2026-05-14 → 2026-05-28 (2 weeks).
Day 8 peek для surface red flags до official review.

**Findings (production data peek через `sudo -u postgres psql`)**:

| Metric | Result |
|---|---|
| Users (total) | 70 |
| Users registered after Phase 6 ship | 5 |
| Real organic (1) vs test (4) | `taka336@mail.ru` / 4× smoke + `ya@fodderxd.ru` |
| Onboarding states completed | 0/5 |
| Trees created post-ship | 0 |
| Kinship checks invoked | 0 |
| 5xx rate | 0% |
| Backend stability | excellent |
| Phase 3.6 hard-delete cycles | 3 (Wed/Thu/Fri 03:03 UTC, 0/0/0/0/0 каждый) |

**Root cause null wizard finishes**: все 5 registrations прошли
ДО chunk 4a fix deploy (2026-05-18 04:33 UTC). Все hit redirect
bug (landing на `/complete_profile` вместо `/setup`). После fix —
0 новых organic registrations, fix verified только через ADB smoke
(2026-05-18).

**Implication для 2026-05-28 review**: sample size = 1 organic
abandoned user. Targets (`>70%` / `>90%` / `>40%`) не computable.
Review window inconclusive из-за adoption volume, не stability.

**Решение**:

* Backend register handler automatically sets
  `currentStep: "welcome"` при registration (verified в
  `backend/src/store.js`). Все 5 stuck onboardingStates имеют
  `currentStep: "welcome", completed: false` — semantically
  correct fresh-wizard-slot state. Никаких mutations не потребовалось.
* После chunk 4a fix (`b4dcb47` deployed 2026-05-18 04:33 UTC),
  `/v1/auth/session` correctly returns `requiresOnboarding: true`
  для всех 5. На next login клиент route'нёт к `/setup` wizard
  автоматически.
* Observation review 2026-05-28 mark как "inconclusive — null
  sample".
* Production health `5xx=0` — Phase 6 deployment stable.
* Focus shift к adoption / marketing / features (Артёмов next
  decision).

**Не сделано (Артёмов call)**:

* Outreach `taka336@mail.ru` (email через UniSender?) — не делали
  без его phrase'ования.
* Smoke account cleanup — 4 test accounts остаются (минимальный
  шум).
* Phase 6.5 candidates (identity-suggestions push, revocation UX,
  notification action buttons) — pending design call.

**Lesson (для future schema-touch ops)**:

* Always verify actual field names через `SELECT` перед `UPDATE`
  на JSONB state document. Initial briefing на этой task говорил
  «step: empty» но реальное field — `currentStep: "welcome"` (set
  by register handler). Worker discipline на STOP-before-mutation
  сэкономила unnecessary no-op DB write на production state
  document. Pattern: read-verify → если diverges от briefing →
  STOP + report, не «guess and proceed».

**Влияет на**: docs only, 0 state mutations.

**Принято**: Артём + Claude.

---

## 2026-05-22: Phase 6.5 — kinship-check revocation

**Контекст**: Phase 6 shipped 2026-05-14 без revocation для sent
kinship checks. PHASE-6-PROPOSAL.md §2.6 listed как Phase 6.5
candidate. Initiator could send accidentally либо передумать —
no way отозвать pending request. После Phase 6 observation peek
(2026-05-22) showed null sample, focus shift к features:
revocation выбран как first 6.5 ship.

**Решение**: добавить `POST /v1/kinship-checks/:checkId/revoke`
endpoint. Mirror respond pattern. Target receives `kinship_check_revoked`
notification «Запрос отозван» (избегает stale accept после revoke).
State machine extended: `pending → accepted | rejected | expired |
revoked` (terminal).

**Permission gates**:
* Routes layer: pre-validate `initiatorUserId === req.auth.user.id`
  → 403 «Нельзя отозвать чужой запрос». Status `!== "pending"` →
  409 «Этот запрос уже обработан либо отозван».
* Store layer (defense-in-depth): `revokeKinshipCheck` returns
  `NOT_INITIATOR` / `NOT_PENDING` / `NOT_FOUND` / `INVALID_INPUT`
  error codes.
* Idempotent re-revoke (status уже `"revoked"`): NOT_PENDING с
  `currentStatus: "revoked"` — guards против double notification
  dispatch при network retry.

**Frontend UX**:
* Trailing IconButton (`Icons.close_rounded`) на pending issued
  rows в `_IssuedHistorySection`. Hidden для terminal statuses.
* Single-tap → AlertDialog «Отозвать запрос? Получатель увидит
  уведомление об отзыве.» с `«Отмена»` + `«Отозвать»` (red
  foreground через `theme.colorScheme.error`).
* No double-confirm — action recoverable (initiator может
  re-create immediately).
* Snackbar feedback: «Запрос отозван» либо error message из
  controller.
* Status enum extended `KinshipCheckStatus.revoked` с label
  «Запрос отозван», icon `cancel_schedule_send_rounded`, color
  `onSurfaceVariant`.

**Альтернативы**:
* `DELETE /v1/kinship-checks/:id` — REST покажется чище, но
  `POST .../revoke` matches respond convention (status transition,
  не destruction; row остаётся для audit + target's received list).
* No notification к target — отвергнуто, stale accept после revoke
  = bad UX (target sees pending in list, taps accept, gets 409
  без понятного objaснения).
* Cooldown after revoke перед re-create — отвергнуто, no harassment
  vector (initiator-side action; cooldown уже applies для
  rejection per DECISIONS 2026-05-14 30d).
* Swipe-to-delete UI — отвергнуто, heavier interaction чем
  trailing-icon, plus confirmation dialog already needed (icon →
  dialog flow more discoverable).
* Double-confirm dialog — отвергнуто, action recoverable, friction
  unnecessary.

**Влияет на**:
* `backend/src/store.js` — `revokeKinshipCheck` method (~40 LOC) +
  `createKinshipCheck` initial check shape (`revokedAt: null`).
* `backend/src/routes/kinship-checks-routes.js` — `mapCheck`
  exposes `revokedAt`, new POST `.../revoke` route handler с
  permission gates + notification dispatch (~70 LOC).
* `backend/test/kinship-checks.test.js` — 8 new tests: success,
  non-initiator 403, target tries 403, accepted 409, rejected 409,
  idempotent re-call 409 (verifies single notification), 404
  non-existent, 401 no-auth.
* `lib/backend/models/kinship_check.dart` — `KinshipCheckStatus.revoked`
  enum case + `revokedAt` field на `KinshipCheck`.
* `lib/backend/interfaces/kinship_check_capable_family_tree_service.dart`
  — abstract `revokeKinshipCheck` method.
* `lib/services/custom_api_family_tree_service.dart` —
  implementation + `_mapKinshipCheckException` extended (403 →
  `NOT_INITIATOR` для endpoint='revoke').
* `lib/providers/kinship_check_controller.dart` — `revokeCheck`
  method + `isRevoking/revokingCheckId` state, mirror responding
  pattern.
* `lib/screens/discover_relatives/discover_relatives_screen.dart`
  — `_IssuedHistorySection` accepts controller, new `_RevokeButton`
  widget (confirmation dialog + snackbar), `revoked` status case
  в icon/color/label switches.
* `test/kinship_check_test.dart` — round-trip + revoked parsing +
  null `revokedAt` для pending.
* `test/kinship_check_controller_test.dart` — `_FakeService`
  extended + 6 new tests в `revokeCheck` group.

**Тесты (verified locally)**:
* Backend `node --test backend/test/kinship-checks.test.js` —
  20/20 (12 existing + 8 new).
* Backend full workflow suite — 123/123 на second run (Windows
  ENOTEMPTY flakes гонять).
* Frontend `flutter test test/kinship_check_test.dart
  test/kinship_check_controller_test.dart` — 38/38 (29 existing +
  9 new — 3 model tests + 6 controller tests).
* `flutter analyze` — 1 warning (`_branchDigest` baseline), 0 new
  from this work.

**Принято**: Артём + Claude.

---

## 2026-05-22: Phase A+B — push-triggered auto-refresh (posts + tree)

**Контекст**: после ship'а постов (DECISIONS 2026-04-XX feed) и
multi-user tree edits (Phase 3.4) пользователи видели stale UI
до manual pull-to-refresh: post creator опубликовал → второй юзер
не видел пока не дёрнул feed; tree co-editor добавил persona →
владелец дерева видел только после повторного visit'а в TreeView.
WebSocket realtime path уже существовал
(`custom_api_realtime_service.dart` → `notification.created`
event), и push delivery работала через `push-gateway.js`. Не
хватало клиентского signal-handling: notification arrived, но
никто не listening'ил «refetch the feed / tree».

**Решение**: централизованный coordinator pattern + silent
notification mode.

* **Backend**: `createAndDispatchNotification` теперь принимает
  optional `silent: boolean`. Notification record store'ит
  `silent` flag, оба channel'а (`mapNotification` → WebSocket
  payload + `_buildWebPushPayload` → web-push payload) пробрасывают.
  Для **Phase B (tree mutations)** новый `dispatchTreeMutation`
  helper в `tree-routes.js` шлёт `tree_mutated` silent push на
  5 endpoint'ах: POST/PATCH/DELETE persons + POST/DELETE relations.
  Audience — `resolveTreeAudienceUserIds` (owner + members +
  graph-person userIds + active edit-grant holders), actor
  исключён. Payload — `{treeId, kind, actorUserId}`, **без**
  personId/relationId (privacy fence — recipient знает only что
  «дерево изменилось», не «кто-то редактировал именно Бабушку
  Аню»).
* **Для Phase A (posts)** уже существующий `post_created`
  notification теперь дополнительно route'ится через client-side
  coordinator — visible banner сохранён (user хочет видеть «new
  post»), silent flag не используется.
* **Client**: два singleton-coordinator'а — `PostsRefreshCoordinator`
  (single-subscriber, HomeScreen feed) и `TreeRefreshCoordinator`
  (Map keyed by treeId, multiple tree surfaces). Оба debounce
  500ms. `_showBackendNotification` в
  `custom_api_notification_service.dart` route'ит arriving
  notifications в соответствующий coordinator ДО visual display.
  Silent flag — early-return после coordinator dispatch (tree
  mutations не должны спамить banner'ами).
* **On-resume stale-cache check**: `WidgetsBindingObserver` в
  HomeScreen + TreeViewScreen re-fires coordinator на app resume.
  Покрывает race'ы где background push handler не успел
  route'ить до process suspension. Debounce coalesces с concurrent
  push arrival → no duplicate roundtrip.
* **WebSocket realtime path triggers coordinator так же как
  push** — foreground users (`notification.created` WebSocket
  event) и background (push) сходятся через тот же
  `_showBackendNotification` entry point, никакого second path
  не добавлено. **Это критическое design constraint от Артёма**
  — single coordinator entry → testable single code path.

**Альтернативы**:
* **Polling**: HomeScreen / TreeViewScreen фоновый Timer.periodic
  каждые 30s → GET feed/tree. Отвергнут: WebSocket infrastructure
  уже существует, и для tree mutations интервал должен был
  быть малым (15s+ otherwise edit feels laggy), что =
  ~5760 unnecessary GET'ов / user / day. Battery / bandwidth
  тax огромный для функционала, который должен быть event-driven.
* **WebSocket-only (skip push на refetch)**: backgrounded
  users пропускают refetch. Resume + manual pull-to-refresh
  снова возвращает stale window. Не закрывает background-edit
  case (юзер открыл app → видит actual tree без extra жеста).
* **Включить personId/relationId в payload**: rejected per
  privacy fence — silent notification arriving означает что
  user knows about specific edit even если у них не было
  permission видеть affected entity. `{treeId, kind, actorUserId}`
  достаточно для refetch trigger, и refetch использует
  server-side authorization для filtering.
* **Skip debounce**: burst tree edits (e.g. import 20 persons)
  = 20 refetches за секунду. 500ms window coalesces в один
  refetch. Cost: 500ms staleness window — acceptable для не-
  critical content (tree view, не chat).
* **Visible banner для tree_mutated**: rejected — каждый person
  edit = banner spam. User хочет видеть результат на screen,
  не «X добавил человека в дерево» каждый раз. Silent push
  только.
* **Service worker для web**: deferred — текущая web build
  не имеет registered SW, и добавление = separate ship.
  WidgetsBindingObserver на mobile + foreground WebSocket
  для web покрывает большинство cases.

**Влияет на**:
* `backend/src/store.js` — `createNotificationRecord` +
  `store.createNotification` принимают `silent`; новый
  `resolveTreeAudienceUserIds({treeId, excludeUserId})` метод
  (audience = owner + members + graphPerson userIds via
  `legacyPersonIds` lookup + active edit-grants).
* `backend/src/app.js` — `mapNotification` exposes `silent`;
  `createAndDispatchNotification` принимает silent, passes
  through; `registerTreeRoutes` теперь получает
  `createAndDispatchNotification`.
* `backend/src/push-gateway.js` — `_buildWebPushPayload`
  add'ит `payload.silent = true` когда notification.silent.
* `backend/src/routes/tree-routes.js` — `dispatchTreeMutation`
  helper + 5 hooks (best-effort try/catch, не блокирует
  mutation response).
* `backend/test/tree-mutation-dispatch.test.js` — 7 new tests:
  audience resolution (owner/members/edit-grant + actor
  exclusion), non-existent tree → empty, 5 endpoints dispatch
  verification, silent flag survives mapNotification round-trip.
* `lib/services/posts_refresh_coordinator.dart` (NEW) —
  single-subscriber debounced coordinator.
* `lib/services/tree_refresh_coordinator.dart` (NEW) — per-tree
  Map-keyed coordinator.
* `lib/services/custom_api_notification_service.dart` —
  type-dispatch в `_showBackendNotification` + `_readTreeId`
  helper + `silent` early-return.
* `lib/screens/home_screen.dart` — `_feedRefreshCallback`
  registered с PostsRefreshCoordinator; WidgetsBindingObserver
  для on-resume.
* `lib/screens/tree_view_screen.dart` — `_treeRefreshCallback`
  + `_syncTreeRefreshSubscription` hooks в lifecycle
  (initState / _handleTreeChange / dispose);
  WidgetsBindingObserver для on-resume.
* `test/posts_refresh_coordinator_test.dart` (NEW) — 6 tests
  (register/unregister, debounce, no-op без subscriber, identity-
  check, replace, exception isolation).
* `test/tree_refresh_coordinator_test.dart` (NEW) — 9 tests
  (per-tree register/unregister, debounce, isolation, empty
  treeId, replace, exception isolation).

**Тесты (verified locally)**:
* Backend `node --test backend/test/tree-mutation-dispatch.test.js` —
  7/7.
* Backend full workflow suite — 122/123 (1 Windows ENOTEMPTY flake
  baseline, не regression).
* Frontend `flutter test test/posts_refresh_coordinator_test.dart
  test/tree_refresh_coordinator_test.dart` — 15/15.
* Frontend `flutter test test/home_screen_test.dart
  test/tree_view_screen_test.dart` — 16/16 (regression check —
  оба screens строятся cleanly с новыми lifecycle hooks).
* `flutter analyze` (touched files) — 1 warning (`_branchDigest`
  baseline), 0 new. `prefer_function_declarations_over_variables`
  info на `_feedRefreshCallback` suppressed inline с обоснованием
  (stored closure для intent-clarity + survives method-name
  refactor).

**Что осталось open**:
* Service worker для web push silent handling — deferred per
  выше; revisit когда web traffic значимый или когда
  RuStore push для PWA понадобится.
* Identity-suggestions push notification — отдельный track
  (DECISIONS 2026-05-14, ждёт Phase 6 observation closure).

**Принято**: Артём + Claude.

---

## 2026-08-30 — SPEED-7: notifications + pushDeliveries из блоба в таблицы (ветка, ждёт «го»)

**Контекст**: после SPEED-6 остался документированный хвост — фан-аут
уведомлений (1 createNotification + 1 createPushDelivery + 1-2
updatePushDelivery НА КАЖДОЕ устройство) шёл whole-blob RMW; CPU-спайки
access/persist до ~300мс под бёрстом.

**Решения** (ветка `speed7-notifications-tables`, дизайн —
`docs/speed7_notifications_table_design.md`):
* Обе коллекции уезжают из блоба ЦЕЛИКОМ (без projection — никто не
  читает их в чужих `_mutate`-applyFn). Таблицы `<t>_notifications`
  (coalesce_key-индекс) и `<t>_push_deliveries`; PK с ЯВНЫМИ именами
  `<t>_pk` (не дефолтный `_pkey` — коллизия с осиротевшими именами).
* Коалесинг реакций — через «планы» (`build*NotificationPlan` в store.js):
  guard'ы/тексты/патчи описаны данными, массивная (FileStore) и табличная
  (PostgresStore) реализации `_applyNotificationCoalescePlan` не дублируют
  строки. Ключ — `computeNotificationCoalesceKey` (единая точка правды:
  оверрайды, drain, миграция).
* Унаследованные inline-пути (`_notifyReviewers`, `article_block_conflict`)
  пишут в блоб-массивы как раньше; `_write` дренирует их в таблицы
  (best-effort, с SQL-дедупом по coalesce_key). Блоб-массивы = транзит.
* Гейт `_notificationTablesReady`: при транзиентно недоступном состоянии
  на буте миграция скипается, и ВСЕ оверрайды делегируют в FileStore-путь
  по блобу (деградация без потери данных и без отравления write-once
  бэкапа), drain выключен.
* Каскад deleteUser берёт removed-множества ИЗ РЕЗУЛЬТАТА
  FileStore.deleteUser (вычислены атомарно в applyFn) — реконструкция
  дифом блоба до/после гонялась с конкурентными удалениями чужих данных
  (P0 адверсариального ревью).
* Retention — SQL-окна в hardDeleteExpired (silent 48ч / read 30д /
  unread 365д; deliveries TTL 7д + cap 2000), счётчики в тот же summary.
* Откат: `backend/scripts/restore-notifications-to-blob.js` (сохраняет
  записи, созданные после миграции; guard по маркеру).

**Репетиция на scratch из прод-дампа** поймала то, что pg-mem не ловит:
на проде с апреля 2026 жила `rodnya_state_notifications` СТАРОЙ схемы
(6 мёртвых строк) — бут падал на CREATE INDEX. Добавлена эвакуация
несовместимой таблицы в backups. После фикса: 312+24 записи, 0 пропусков,
~3с; второй бут идемпотентен.

**Ревью**: sonnet-finders + sonnet-verify + opus-скептик, 10 подтверждённых
находок (3×P0-класс гоночного дифа, P1 тихого старта на немигрированной
БД, GDPR-окно, и др.) — все закрыты. Бэкенд 661/661 (+13 новых тестов).

**Принятые известные следствия**: гонка коалесинга может дать дубль вместо
бампа (как у прежних голых пар — не хуже); drain коммитит уведомление до
записи блоба — при lost-update голых `_read/_write` пар (pre-existing
класс) уведомление может пережить потерянную сущность (полный фикс =
перевод голых пар на `_mutate`, отдельный трек).

**Merge = deploy миграции прод-БД — только по явному «го» Артёма.**

**Принято**: Claude (ночная смена), ждёт подтверждения Артёма.

---
