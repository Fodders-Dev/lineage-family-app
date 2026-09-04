// SPEED-8c: сверка кругов (default + авто) на путях чтения.
//
// Инварианты:
// • Ленты (posts/stories/gatherings/polls) НЕ сверяют круги всех деревьев
//   и НЕ пишут блоб: видимость поста лениво сверяет круги ТОЛЬКО его
//   дерева, в памяти. До фикса каждое GET /posts гоняло
//   ensureCirclesForAllTrees по 25 деревьям прода (77% CPU запроса) и
//   писало блоб из читающего пути в обход _mutate.
// • Хранимое состояние кругов по-прежнему чинят listCircles/findCircle и
//   мутации графа.
// • Бэкфилл идентичностей по ВСЕЙ базе (двойной sha256 всех persons)
//   зовётся из сверки авто-кругов только когда у людей этого дерева
//   реально нет identityId — легаси-данные обслуживаются, устоявшиеся
//   не хэшируются.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {FileStore} = require("../src/store");

async function seededStore() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-circles-"));
  const dataPath = path.join(tempDir, "dev-db.json");

  const bootstrap = new FileStore(dataPath);
  await bootstrap.initialize();

  const db = JSON.parse(await fs.readFile(dataPath, "utf8"));
  db.users = [
    {id: "user-a", email: "a@rodnya.app", profile: {displayName: "Артём"}},
    {id: "user-b", email: "b@rodnya.app", profile: {displayName: "Борис"}},
    {id: "user-c", email: "c@rodnya.app", profile: {displayName: "Вера"}},
  ];
  db.trees = [
    {
      id: "tree-a",
      name: "Семья А",
      creatorId: "user-a",
      memberIds: ["user-a", "user-b", "user-c"],
      members: ["user-a", "user-b", "user-c"],
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

async function makePerson(store, treeId, name, {userId = null} = {}) {
  const person = await store.createPerson({
    treeId,
    creatorId: "user-a",
    personData: {firstName: name, lastName: "Тест", gender: "male"},
    userId,
  });
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

async function readRawDb(dataPath) {
  return JSON.parse(await fs.readFile(dataPath, "utf8"));
}

async function writeRawDb(dataPath, db) {
  await fs.writeFile(dataPath, JSON.stringify(db, null, 2));
}

// Дерево А: дед → отец → сын; user-b привязан к деду (НЕ потомок отца),
// user-c — к сыну (потомок). Возвращает id людей и авто-круг «Ветка: Отец».
async function seedBranch(store) {
  const grandpaId = await makePerson(store, "tree-a", "Дед", {userId: "user-b"});
  const fatherId = await makePerson(store, "tree-a", "Отец");
  const sonId = await makePerson(store, "tree-a", "Сын", {userId: "user-c"});
  await linkParentChild(store, "tree-a", grandpaId, fatherId);
  await linkParentChild(store, "tree-a", fatherId, sonId);

  const circles = await store.listCircles("tree-a");
  const branchCircle = circles.find(
    (circle) =>
      circle.kind === "descendants_of" && circle.anchorPersonId === fatherId,
  );
  assert.ok(branchCircle, "авто-круг «Ветка: Отец» должен существовать");
  assert.equal(branchCircle.memberCount, 2);
  return {grandpaId, fatherId, sonId, branchCircle};
}

test("ленты не сверяют круги всех деревьев и не пишут блоб", async () => {
  const {store, dataPath} = await seededStore();
  const {branchCircle} = await seedBranch(store);
  await store.createPost({
    treeId: "tree-a",
    authorId: "user-a",
    authorName: "Артём",
    content: "Только ветке отца",
    circleId: branchCircle.id,
  });

  // Дрейф: у дерева Б в хранилище нет ни одного круга (как у дерева,
  // созданного до появления кругов).
  const drifted = await readRawDb(dataPath);
  assert.ok(
    drifted.circles.some((circle) => circle.treeId === "tree-b"),
    "фикстура: у дерева Б должны были быть default-круги",
  );
  drifted.circles = drifted.circles.filter((circle) => circle.treeId !== "tree-b");
  await writeRawDb(dataPath, drifted);

  const before = await fs.readFile(dataPath, "utf8");
  const statBefore = await fs.stat(dataPath);

  const posts = await store.listPosts({treeId: "tree-a", viewerUserId: "user-c"});
  assert.equal(posts.length, 1);
  await store.listStories({treeId: "tree-a", viewerUserId: "user-c"});
  await store.listGatherings({treeId: "tree-a", viewerUserId: "user-c"});
  await store.listPolls({treeId: "tree-a", viewerUserId: "user-c"});

  const after = await fs.readFile(dataPath, "utf8");
  const statAfter = await fs.stat(dataPath);
  assert.equal(after, before, "чтение ленты не должно переписывать блоб");
  assert.equal(statAfter.mtimeMs, statBefore.mtimeMs);
  assert.equal(
    (await readRawDb(dataPath)).circles.some((circle) => circle.treeId === "tree-b"),
    false,
    "лента дерева А не должна чинить круги дерева Б",
  );

  // А вот эндпоинт кругов дерева Б — чинит и сохраняет.
  const treeBCircles = await store.listCircles("tree-b");
  assert.deepEqual(
    treeBCircles.map((circle) => circle.kind).sort(),
    ["all_tree", "favorites"],
  );
  assert.ok(
    (await readRawDb(dataPath)).circles.some((circle) => circle.treeId === "tree-b"),
  );
});

test("видимость поста по авто-кругу работает и без сохранённых кругов", async () => {
  const {store, dataPath} = await seededStore();
  const {branchCircle} = await seedBranch(store);
  await store.createPost({
    treeId: "tree-a",
    authorId: "user-a",
    authorName: "Артём",
    content: "Только ветке отца",
    circleId: branchCircle.id,
  });

  const visibleTo = async (viewerUserId) =>
    (await store.listPosts({treeId: "tree-a", viewerUserId})).length;

  assert.equal(await visibleTo("user-c"), 1, "потомок видит пост ветки");
  assert.equal(await visibleTo("user-b"), 0, "дед — не потомок отца");

  // Дрейф: авто-круги дерева А пропали из хранилища (например, мутация
  // графа прошла путём без сверки). Видимость обязана остаться той же —
  // сверка нужного дерева происходит лениво, в памяти запроса.
  const drifted = await readRawDb(dataPath);
  drifted.circles = drifted.circles.filter(
    (circle) => !(circle.treeId === "tree-a" && circle.kind === "descendants_of"),
  );
  drifted.circleMembers = drifted.circleMembers.filter(
    (entry) => entry.circleId !== branchCircle.id,
  );
  await writeRawDb(dataPath, drifted);

  assert.equal(await visibleTo("user-c"), 1);
  assert.equal(await visibleTo("user-b"), 0);
  assert.equal(
    (await readRawDb(dataPath)).circles.some(
      (circle) => circle.id === branchCircle.id,
    ),
    false,
    "лента не сохраняет пересчитанные круги",
  );
});

test("сверка авто-кругов бэкфиллит идентичности легаси-людей без identityId", async () => {
  const {store, dataPath} = await seededStore();
  const {fatherId, branchCircle} = await seedBranch(store);

  // Легаси-данные: у людей нет identityId и коллекции идентичностей нет
  // вовсе (так выглядел блоб до Phase 1). Круги тоже убираем — членство
  // должно быть собрано заново через бэкфилл.
  const legacy = await readRawDb(dataPath);
  for (const person of legacy.persons) {
    delete person.identityId;
  }
  delete legacy.personIdentities;
  legacy.circles = legacy.circles.filter((circle) => circle.treeId !== "tree-a");
  legacy.circleMembers = legacy.circleMembers.filter(
    (entry) => entry.treeId !== "tree-a",
  );
  await writeRawDb(dataPath, legacy);

  // Без initialize(): бут-бэкфилл не вмешивается, работает только гард
  // внутри ensureAutoCirclesForTree.
  const coldStore = new FileStore(dataPath);
  const circles = await coldStore.listCircles("tree-a");
  const restored = circles.find((circle) => circle.id === branchCircle.id);
  assert.ok(restored, "авто-круг ветки должен быть пересобран");
  assert.equal(restored.memberCount, 2);

  const persisted = await readRawDb(dataPath);
  const persons = persisted.persons.filter((person) => person.treeId === "tree-a");
  assert.equal(persons.length, 3);
  assert.ok(
    persons.every((person) => typeof person.identityId === "string" && person.identityId),
    "бэкфилл должен выдать identityId каждому человеку дерева",
  );
  const members = persisted.circleMembers.filter(
    (entry) => entry.circleId === branchCircle.id,
  );
  const fatherIdentityId = persons.find((person) => person.id === fatherId).identityId;
  assert.ok(members.some((entry) => entry.identityId === fatherIdentityId));
});
