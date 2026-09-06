// SPEED-10 (docs/speed_measurement.md): доказательство идентичности для
// оптимизаций горячих точек бёрста входа — все они АДДИТИВНЫ (новый
// опциональный параметр, память в пределах одного вызова), поэтому
// стратегия доказательства везде одна: индексированный/кэширующий путь
// должен давать РОВНО ТОТ ЖЕ результат, что и старый путь без индекса/
// кэша, на одном и том же db-снимке.
//
// Четыре раздела — по одной оптимизации на раздел:
//   A) buildCanonicalPersonView({usersById}) — listPersons резолвит
//      КАЖДОГО линкованного person'а через правильного user'а по карте,
//      не смешивает разных пользователей.
//   B) _buildPersonGraphIndex + _buildPersonViewFromGraph({index,
//      legacyPerson}) — индексированный путь (getTreeGraphSnapshot)
//      совпадает с одиночным (findPerson) person-в-person.
//   C) _createCircleVisibilityCache — listStories/listGatherings/listPolls
//      с кэшем дают ту же видимость, что и без него, включая несколько
//      деревьев в одном вызове (кэш не путает treeId).
//   D) normCache в _ensureCrossTreeMergeProposals/_markStaleMergeProposals/
//      _mergeProposalStillActionable — listPendingMergeProposalsForUser
//      с кэшем даёт тот же результат, что ручной прогон тех же трёх
//      методов БЕЗ кэша; плюс отдельная проверка, что «не менять
//      db, если пересчёт дал те же значения» действительно устраняет
//      лишний _write(), не трогая сам ответ.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {FileStore} = require("../src/store");

async function seededStore(prefix) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), `rodnya-${prefix}-`));
  const dataPath = path.join(tempDir, "dev-db.json");

  const bootstrap = new FileStore(dataPath);
  await bootstrap.initialize();

  const db = JSON.parse(await fs.readFile(dataPath, "utf8"));
  db.users = [
    {id: "user-a", email: "a@rodnya.app", profile: {displayName: "Артём", firstName: "Артём", lastName: "Тестов", photoUrl: "https://example.com/a.jpg", gender: "male"}},
    {id: "user-b", email: "b@rodnya.app", profile: {displayName: "Борис", firstName: "Борис", lastName: "Тестов", photoUrl: "https://example.com/b.jpg", gender: "male"}},
    {id: "user-c", email: "c@rodnya.app", profile: {displayName: "Вера", firstName: "Вера", lastName: "Тестова", photoUrl: "https://example.com/c.jpg", gender: "female"}},
    {id: "user-d", email: "d@rodnya.app", profile: {displayName: "Галина", firstName: "Галина", lastName: "Тестова"}},
  ];
  db.trees = [
    {
      id: "tree-a",
      name: "Семья А",
      creatorId: "user-a",
      memberIds: ["user-a", "user-b", "user-c", "user-d"],
      members: ["user-a", "user-b", "user-c", "user-d"],
    },
    {
      id: "tree-b",
      name: "Семья Б",
      creatorId: "user-a",
      memberIds: ["user-a"],
      members: ["user-a"],
    },
  ];
  await fs.writeFile(dataPath, JSON.stringify(db, null, 2));

  return {store: new FileStore(dataPath), dataPath};
}

async function makePerson(store, treeId, personData, {userId = null, creatorId = "user-a"} = {}) {
  const person = await store.createPerson({treeId, creatorId, personData, userId});
  return person.id;
}

async function linkParentChild(store, treeId, parentId, childId) {
  await store.upsertRelation({
    treeId,
    person1Id: parentId,
    person2Id: childId,
    relation1to2: "parent",
    relation2to1: "child",
  });
}

// Строит цепочку дед → отец → сын (как circles-reconcile.test.js), чтобы
// получить авто-круг «Ветка: Отец» — единственный НЕ all_tree сценарий,
// нужный обеим сторонам сравнения (с кэшем / без).
async function seedBranch(store, treeId, {grandpaUserId = null, sonUserId = null} = {}) {
  const grandpaId = await makePerson(store, treeId, {firstName: "Дед", lastName: "Ветвин", gender: "male"}, {userId: grandpaUserId});
  const fatherId = await makePerson(store, treeId, {firstName: "Отец", lastName: "Ветвин", gender: "male"});
  const sonId = await makePerson(store, treeId, {firstName: "Сын", lastName: "Ветвин", gender: "male"}, {userId: sonUserId});
  await linkParentChild(store, treeId, grandpaId, fatherId);
  await linkParentChild(store, treeId, fatherId, sonId);

  const circles = await store.listCircles(treeId);
  const branchCircle = circles.find(
    (circle) => circle.kind === "descendants_of" && circle.anchorPersonId === fatherId,
  );
  assert.ok(branchCircle, "авто-круг «Ветка: Отец» должен существовать (фикстура)");
  return {grandpaId, fatherId, sonId, branchCircle};
}

function withoutVolatileFields(person) {
  if (!person) return person;
  // getTreeGraphSnapshot/findPerson штампуют updatedAt=nowIso() при
  // резолве через связанного пользователя (applyCanonicalProfileToPerson
  // touchUpdatedAt=true по умолчанию) — известная нестабильность двух
  // подряд идущих вызовов без мутации между ними (см. docs/speed_measurement.md
  // SPEED-9 B, побочная находка). Сравниваем всё, КРОМЕ этого поля.
  const {updatedAt, ...rest} = person;
  return rest;
}

// ── A) buildCanonicalPersonView({usersById}) ────────────────────────────

test("SPEED-10 A: listPersons резолвит каждого person'а через СВОЕГО linked-user, не смешивает users по карте", async () => {
  const {store} = await seededStore("speed10a");
  const soloPersonId = await makePerson(store, "tree-a", {firstName: "Одиночка", lastName: "Безюзера", gender: "male"});
  const bId = await makePerson(store, "tree-a", {firstName: "Legacy-имя-B", lastName: "Legacy", gender: "male"}, {userId: "user-b"});
  const cId = await makePerson(store, "tree-a", {firstName: "Legacy-имя-C", lastName: "Legacy", gender: "female"}, {userId: "user-c"});

  const persons = await store.listPersons("tree-a");
  const byId = new Map(persons.map((p) => [p.id, p]));

  // Юзер B и юзер C резолвятся каждый в СВОЙ профиль (не переставлены,
  // не оба схлопнулись в один и тот же объект из карты).
  assert.equal(byId.get(bId).name, "Тестов Борис");
  assert.equal(byId.get(bId).photoUrl, "https://example.com/b.jpg");
  assert.equal(byId.get(bId).gender, "male");

  assert.equal(byId.get(cId).name, "Тестова Вера");
  assert.equal(byId.get(cId).photoUrl, "https://example.com/c.jpg");
  assert.equal(byId.get(cId).gender, "female");

  // Person без userId — карта usersById не участвует, legacy-имя остаётся.
  assert.equal(byId.get(soloPersonId).name, "Безюзера Одиночка");
  assert.equal(byId.get(soloPersonId).userId, null);

  assert.equal(persons.length, 3);
});

// ── B) _buildPersonGraphIndex + _buildPersonViewFromGraph({index}) ──────

test("SPEED-10 B: getTreeGraphSnapshot (индекс) и findPerson (без индекса) резолвят ОДНОГО И ТОГО ЖЕ person'а идентично", async () => {
  const {store} = await seededStore("speed10b");
  const {grandpaId, fatherId, sonId} = await seedBranch(store, "tree-a", {
    grandpaUserId: "user-b",
    sonUserId: "user-c",
  });
  // Четвёртый person без userId и без связей — чтобы в снимке был кто-то
  // вне цепочки деда/отца/сына (граничный случай индекса: person без
  // релевантных relations всё равно должен резолвиться).
  const loneId = await makePerson(store, "tree-a", {firstName: "Одиночка", lastName: "Вне-ветки", gender: "female"});

  const snapshot = await store.getTreeGraphSnapshot("tree-a", {viewerUserId: "user-c"});
  assert.ok(snapshot, "снимок дерева должен существовать");
  const byId = new Map(snapshot.people.map((p) => [p.id, p]));
  assert.equal(byId.size, 4);

  for (const personId of [grandpaId, fatherId, sonId, loneId]) {
    const fromSnapshot = withoutVolatileFields(byId.get(personId));
    const fromSingle = withoutVolatileFields(await store.findPerson("tree-a", personId));
    assert.deepEqual(
      fromSnapshot,
      fromSingle,
      `person ${personId}: индексированный путь должен совпадать с одиночным findPerson`,
    );
  }

  // Явная проверка, что userId-резолв не перепутан между дедом (user-b)
  // и сыном (user-c) — типичный баг конфлюэнса карт по неверному ключу.
  assert.equal(byId.get(grandpaId).photoUrl, "https://example.com/b.jpg");
  assert.equal(byId.get(sonId).photoUrl, "https://example.com/c.jpg");
});

// ── C) _createCircleVisibilityCache ──────────────────────────────────────

test("SPEED-10 C: listStories/listGatherings/listPolls с кэшем видимости дают тот же результат, что и раньше (авто-круг «Ветка»)", async () => {
  const {store} = await seededStore("speed10c");
  const {fatherId, branchCircle} = await seedBranch(store, "tree-a", {
    grandpaUserId: "user-b",
    sonUserId: "user-c",
  });

  // Три истории на дереве А: одна видна всем (all_tree — circleId не
  // задан), одна — только ветке отца (автор вне ветки), одна — тоже
  // ветке отца, но авторства САМОГО сына (проверяет одновременно и
  // ранний выход authorId===viewerUserId, и обычный путь через круг для
  // деда, который не автор и не в ветке).
  await store.createStory({treeId: "tree-a", authorId: "user-a", authorName: "Артём", type: "text", text: "Всем"});
  await store.createStory({treeId: "tree-a", authorId: "user-a", authorName: "Артём", type: "text", text: "Только ветке отца", circleId: branchCircle.id});
  await store.createStory({treeId: "tree-a", authorId: "user-c", authorName: "Вера", type: "text", text: "Тоже ветке отца, от сына", circleId: branchCircle.id});

  await store.createGathering({treeId: "tree-a", authorId: "user-a", authorName: "Артём", title: "Всем", startAt: new Date().toISOString()});
  await store.createGathering({treeId: "tree-a", authorId: "user-a", authorName: "Артём", title: "Ветке отца", startAt: new Date().toISOString(), circleId: branchCircle.id});

  await store.createPoll({treeId: "tree-a", authorId: "user-a", authorName: "Артём", question: "Всем?", options: ["Да", "Нет"]});
  await store.createPoll({treeId: "tree-a", authorId: "user-a", authorName: "Артём", question: "Ветке отца?", options: ["Да", "Нет"], circleId: branchCircle.id});

  // user-c — потомок отца (сын) → видит оба branch-круга; user-b — дед,
  // НЕ потомок отца и не автор → видит только «всем».
  const storiesForSon = await store.listStories({treeId: "tree-a", viewerUserId: "user-c"});
  const storiesForGrandpa = await store.listStories({treeId: "tree-a", viewerUserId: "user-b"});
  assert.equal(storiesForSon.length, 3, "сын видит: всем + оба branch-элемента (один свой)");
  assert.equal(storiesForGrandpa.length, 1, "дед видит только «всем» — не branch-круг ни в одном из двух");

  const gatheringsForSon = await store.listGatherings({treeId: "tree-a", viewerUserId: "user-c"});
  const gatheringsForGrandpa = await store.listGatherings({treeId: "tree-a", viewerUserId: "user-b"});
  assert.equal(gatheringsForSon.length, 2);
  assert.equal(gatheringsForGrandpa.length, 1);

  const pollsForSon = await store.listPolls({treeId: "tree-a", viewerUserId: "user-c"});
  const pollsForGrandpa = await store.listPolls({treeId: "tree-a", viewerUserId: "user-b"});
  assert.equal(pollsForSon.length, 2);
  assert.equal(pollsForGrandpa.length, 1);

  // fatherId существует и связан с обеими проверками выше — sanity, что
  // фикстура не сломалась молча.
  assert.ok(fatherId);
});

test("SPEED-10 C: кэш видимости не путает деревья при запросе без treeId (кросс-дерево лента)", async () => {
  const {store} = await seededStore("speed10c-cross");
  const {branchCircle} = await seedBranch(store, "tree-a", {sonUserId: "user-c"});
  // tree-b: пользователь user-a — единственный участник, «всем»-история.
  await store.createStory({treeId: "tree-a", authorId: "user-a", authorName: "Артём", type: "text", text: "Ветке отца в А", circleId: branchCircle.id});
  await store.createStory({treeId: "tree-b", authorId: "user-a", authorName: "Артём", type: "text", text: "Всем в Б"});

  // Один и тот же вызов (один и тот же circleCache внутри listStories)
  // видит ОБА дерева в одном проходе — кэш ключуется по treeId, поэтому
  // проверка ветки А не должна течь на дерево Б (у него нет такого круга
  // вовсе — id круга совпасть не может, но неверная мемоизация могла бы
  // вернуть stale allTreeCircle не того дерева, если бы кэш был ключом
  // без treeId).
  const authorId = "user-c"; // ранний выход не сработает — user-c не автор
  const stories = await store.listStories({authorId: "user-a", viewerUserId: authorId});
  const byTree = new Map(stories.map((s) => [s.treeId, s]));
  assert.equal(stories.length, 2, "видны обе истории (потомок ветки А + всем в Б)");
  assert.ok(byTree.has("tree-a"));
  assert.ok(byTree.has("tree-b"));
});

// ── D) normCache в merge-proposals ───────────────────────────────────────

async function seedMergeCandidates(store) {
  const p1 = await makePerson(store, "tree-a", {firstName: "Иван", lastName: "Иванов", gender: "male", birthDate: "1980-01-01"});
  const p2 = await makePerson(store, "tree-b", {firstName: "Иван", lastName: "Иванов", gender: "male", birthDate: "1980-01-01"});
  return {p1, p2};
}

test("SPEED-10 D: listPendingMergeProposalsForUser с normCache даёт тот же результат, что ручной прогон без кэша", async () => {
  const {store: storeWithCache} = await seededStore("speed10d-cached");
  await seedMergeCandidates(storeWithCache);
  const cachedResult = await storeWithCache.listPendingMergeProposalsForUser("user-a");
  assert.equal(cachedResult.length, 1, "кросс-дерево совпадение должно предложить слияние");

  // Независимая копия того же исходного состояния — прогоняем ВРУЧНУЮ
  // те же три метода БЕЗ normCache (как до SPEED-10), чтобы сравнить
  // итоговый список предложений один-в-один.
  const {store: storeNoCache} = await seededStore("speed10d-uncached");
  await seedMergeCandidates(storeNoCache);
  const db = await storeNoCache._read();
  storeNoCache._ensureCrossTreeMergeProposals(db, "user-a", {limit: 50});
  storeNoCache._markStaleMergeProposals(db);
  await storeNoCache._write(db);
  const manualResult = db.mergeProposals
    .filter(
      (proposal) =>
        proposal.status === "pending" &&
        proposal.reviewerUserIds.includes("user-a") &&
        storeNoCache._mergeProposalStillActionable(db, proposal),
    )
    .map((proposal) => storeNoCache._mergeProposalView(db, proposal, "user-a"));

  assert.deepEqual(
    cachedResult.map((p) => ({...p, id: undefined, createdAt: undefined})),
    manualResult.map((p) => ({...p, id: undefined, createdAt: undefined})),
    "normCache не должен менять итоговую форму/оценку предложения",
  );
});

test("SPEED-10 D: не-стюард ничего не видит независимо от кэша (реестр ревьюеров не затронут мемоизацией)", async () => {
  const {store} = await seededStore("speed10d-reviewer");
  await seedMergeCandidates(store);
  await store.listPendingMergeProposalsForUser("user-a");
  const forStranger = await store.listPendingMergeProposalsForUser("user-d");
  assert.equal(forStranger.length, 0);
});

test("SPEED-10 D: повторный вызов без изменений НЕ пишет блоб; реальное изменение — пишет и обновляет оценку", async () => {
  const {store} = await seededStore("speed10d-write");
  const {p1, p2} = await seedMergeCandidates(store);

  const first = await store.listPendingMergeProposalsForUser("user-a");
  assert.equal(first.length, 1);
  const firstScore = first[0].matchScore;

  // Спай поверх _write — считаем реальные записи блоба, начиная с этого
  // момента (сетап уже отписал своё).
  let writeCount = 0;
  const originalWrite = store._write.bind(store);
  store._write = async (data) => {
    writeCount += 1;
    return originalWrite(data);
  };

  const second = await store.listPendingMergeProposalsForUser("user-a");
  assert.deepEqual(second, first, "устойчивое состояние: ответ не меняется");
  assert.equal(
    writeCount,
    0,
    "SPEED-10: пересчёт дал ТЕ ЖЕ значения — блоб писать не нужно (было: писал безусловно)",
  );

  // Реальное изменение: обеим карточкам проставляем совпадающее место
  // рождения — matchScore и reasons обязаны легитимно вырасти, и это
  // ОБЯЗАНО вызвать запись (никакого «залипания» на первом расчёте).
  // updatePerson сам пишет блоб (не связано с merge-proposals) — считаем
  // писи ТОЛЬКО с этой точки, чтобы не путать его запись со «своей».
  await store.updatePerson("tree-a", p1, {birthPlace: "Москва"});
  await store.updatePerson("tree-b", p2, {birthPlace: "Москва"});
  writeCount = 0;

  const third = await store.listPendingMergeProposalsForUser("user-a");
  assert.equal(third.length, 1);
  assert.ok(
    third[0].matchScore > firstScore,
    `matchScore должен вырасти после совпавшего birthPlace (было ${firstScore}, стало ${third[0].matchScore})`,
  );
  assert.equal(
    writeCount,
    1,
    "легитимное изменение оценки обязано вызвать ровно один _write()",
  );
});
