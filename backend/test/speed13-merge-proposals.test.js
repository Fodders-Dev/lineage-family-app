// SPEED-13 (docs/speed_measurement.md, раздел «SPEED-13»): GET
// /v1/merge-proposals/pending без материализации на чтении и без
// двойного хэширования.
//
// Контекст: SPEED-10/12 профилировали listPendingMergeProposalsForUser
// и нашли, что ~47% self-time — это ДВОЙНОЙ hashSnapshot (before/after
// stableSerialize+sha256 ВСЕЙ базы persons+personIdentities) внутри
// backfillPersonIdentities, вызываемого БЕЗУСЛОВНО на каждый GET через
// _reconcilePersonIdentities — хотя на проде (steady state) у всех
// persons уже есть identityId и хэш ничего не находит. SPEED-12 не
// перевёл этот маршрут на readSharedSnapshot(), потому что
// _ensureCrossTreeMergeProposals/_markStaleMergeProposals безусловно
// МУТИРУЮТ db (push/присвоение полей) — на замороженном снимке push()
// бросил бы TypeError, присвоение поля молча no-op'алось бы (store.js
// без "use strict") — оба исхода хуже текущего поведения.
//
// Фикс (store.js): 1) dbHasPersonsWithoutIdentity(db) — тот же приём,
// что treeHasPersonsWithoutIdentity (SPEED-8c), но глобальный (merge-
// proposals кросс-древесные) — backfill вызывается ТОЛЬКО если гейт
// говорит, что он нужен, и ТОЛЬКО внутри _mutate (реальная запись);
// 2) _ensureCrossTreeMergeProposals/_markStaleMergeProposals получили
// dryRun — вычисляют, изменился бы результат, НЕ трогая переданный db
// (тот же контрольный поток, без побочных эффектов — одной реализации,
// разойтись нечему); 3) listPendingMergeProposalsForUser сначала читает
// readSharedSnapshot() (0 clone на попадании кэша PostgresStore), при
// чистом гейте — dryRun по снимку, и материализует (_mutate) ТОЛЬКО
// если dryRun нашёл реальные изменения (новое предложение / выросший
// score / протухшая пара).
//
// Этот файл доказывает четыре сценария на HTTP-уровне (createApp +
// FileStore, метод как в speed9-b-single-read.test.js/
// speed12-shared-snapshot-more.test.js) плюс идентичность на
// store-уровне относительно «старого» безусловного прогона (метод как
// в speed10-identity.test.js «SPEED-10 D»):
//   A. Нет кандидатов — пустой ответ, 0 записей блоба.
//   B. Новые кандидаты — материализация РОВНО одной записью; повторный
//      GET без изменений — 0 записей, ответ байт-в-байт тот же.
//   C. Устаревшая пара (кандидат удалён) — переход pending → stale
//      РОВНО одной записью, предложение пропадает из pending.
//   D. Замороженный readSharedSnapshot() не мутируется — ни когда
//      dry-run находит изменения (материализация идёт по СВОЕМУ
//      независимому _mutate()-чтению, не по переданному объекту), ни
//      в steady state (dry-run без изменений вообще не пишет).
//   E. Идентичность: оптимизированный путь (снимок + dryRun + условная
//      материализация) даёт ТОТ ЖЕ ответ, что «по-старому» — свежий
//      _read(), безусловный (без dryRun) прогон обеих функций,
//      безусловный _write() — тот же метод сравнения, что SPEED-10 D.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

// ── HTTP harness (speed9-b-single-read.test.js / speed12-shared-snapshot-more.test.js) ──

async function startTestServer() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed13-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store});
  const app = createApp({
    store,
    config: {
      corsOrigin: "*",
      dataPath,
      mediaRootPath: path.join(tempDir, "uploads"),
    },
    realtimeHub,
    pushGateway,
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, "127.0.0.1", () => resolve(instance));
  });
  realtimeHub.attach(server);
  return {
    baseUrl: `http://127.0.0.1:${server.address().port}`,
    server,
    store,
    tempDir,
  };
}

async function stopTestServer(ctx) {
  await new Promise((resolve, reject) => {
    ctx.server.close((error) => (error ? reject(error) : resolve()));
  });
  await fs.rm(ctx.tempDir, {recursive: true, force: true}).catch(() => {});
}

async function registerUser(ctx, email) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      email,
      password: "Test-Password-123!",
      consentDocVersion: "test-consent-v1",
      displayName: email.split("@")[0],
    }),
  });
  assert.equal(response.status, 201);
  const body = await response.json();
  return {userId: body.user.id, token: body.accessToken};
}

async function createTree(ctx, token, name = "Тестовое дерево") {
  const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({name, description: "", isPrivate: true}),
  });
  assert.equal(response.status, 201);
  return (await response.json()).tree;
}

async function createPerson(ctx, token, treeId, body) {
  const response = await fetch(`${ctx.baseUrl}/v1/trees/${treeId}/persons`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  assert.equal(response.status, 201);
  return (await response.json()).person;
}

async function deletePerson(ctx, token, treeId, personId) {
  const response = await fetch(
    `${ctx.baseUrl}/v1/trees/${treeId}/persons/${personId}`,
    {method: "DELETE", headers: {authorization: `Bearer ${token}`}},
  );
  return response;
}

// readSharedSnapshot() (SPEED-11) отдаёт "sessions" как enumerable
// throw-геттер (fail-loud контракт) — обычный structuredClone()/deepEqual
// читает ЗНАЧЕНИЕ каждого enumerable-свойства и упал бы на этом геттере.
// Сравнивать снимки нужно БЕЗ чтения этого поля вовсе.
function structuredCloneWithoutSessions(snapshot) {
  const plain = {};
  for (const key of Object.keys(snapshot)) {
    if (key === "sessions") continue;
    plain[key] = snapshot[key];
  }
  return structuredClone(plain);
}

async function getPending(ctx, token) {
  const response = await fetch(`${ctx.baseUrl}/v1/merge-proposals/pending`, {
    headers: {authorization: `Bearer ${token}`},
  });
  return {status: response.status, body: await response.json()};
}

function spyWrites(store) {
  let count = 0;
  const original = store._write.bind(store);
  store._write = async (data) => {
    count += 1;
    return original(data);
  };
  return {
    count: () => count,
    reset: () => {
      count = 0;
    },
  };
}

// ── A: нет кандидатов ─────────────────────────────────────────────────

test("SPEED-13 A: нет кандидатов — пустой ответ, блоб не пишется вовсе", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "a-owner@test.app");
    const tree = await createTree(ctx, owner.token);
    await createPerson(ctx, owner.token, tree.id, {
      firstName: "Соло",
      lastName: "Одинцов",
      gender: "male",
    });

    const writes = spyWrites(ctx.store);
    const {status, body} = await getPending(ctx, owner.token);
    assert.equal(status, 200);
    assert.deepEqual(body.proposals, []);
    assert.equal(writes.count(), 0, "нет кандидатов — гейт чист, dry-run не нашёл изменений, блоб не пишется");
  } finally {
    await stopTestServer(ctx);
  }
});

// ── B: новые кандидаты — материализация РОВНО одной записью ────────────

test("SPEED-13 B: новые кандидаты материализуются РОВНО одной записью; повторный GET не пишет и не меняет ответ", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "b-owner@test.app");
    const treeA = await createTree(ctx, owner.token, "Дерево А");
    const treeB = await createTree(ctx, owner.token, "Дерево Б");
    await createPerson(ctx, owner.token, treeA.id, {
      firstName: "Иван",
      lastName: "Иванов",
      gender: "male",
      birthDate: "1980-01-01",
    });
    await createPerson(ctx, owner.token, treeB.id, {
      firstName: "Иван",
      lastName: "Иванов",
      gender: "male",
      birthDate: "1980-01-01",
    });

    const writes = spyWrites(ctx.store);
    const first = await getPending(ctx, owner.token);
    assert.equal(first.status, 200);
    assert.equal(first.body.proposals.length, 1, "кросс-дерево совпадение должно предложить слияние");
    assert.equal(writes.count(), 1, "материализация новой пары — ровно одна запись блоба");

    writes.reset();
    const second = await getPending(ctx, owner.token);
    assert.equal(second.status, 200);
    assert.deepEqual(second.body, first.body, "повторный GET без изменений — байт-в-байт тот же ответ");
    assert.equal(
      writes.count(),
      0,
      "SPEED-13: повторный GET — 0 записей (dry-run по снимку не нашёл изменений, было: писал/хэшировал безусловно)",
    );
  } finally {
    await stopTestServer(ctx);
  }
});

// ── C: устаревшая пара (кандидат удалён) → stale РОВНО одной записью ──

test("SPEED-13 C: удаление одной из карточек делает пару неактуальной — переход в stale РОВНО одной записью, пропадает из pending", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "c-owner@test.app");
    const treeA = await createTree(ctx, owner.token, "Дерево А");
    const treeB = await createTree(ctx, owner.token, "Дерево Б");
    const personA = await createPerson(ctx, owner.token, treeA.id, {
      firstName: "Пётр",
      lastName: "Петров",
      gender: "male",
      birthDate: "1975-05-05",
    });
    const personB = await createPerson(ctx, owner.token, treeB.id, {
      firstName: "Пётр",
      lastName: "Петров",
      gender: "male",
      birthDate: "1975-05-05",
    });

    const created = await getPending(ctx, owner.token);
    assert.equal(created.body.proposals.length, 1, "предпосылка: пара должна была предложиться");

    const deleteResponse = await deletePerson(ctx, owner.token, treeB.id, personB.id);
    assert.equal(deleteResponse.status, 204, "владелец дерева должен уметь удалить анонимную карточку");
    assert.equal(personA.id !== personB.id, true);

    const writes = spyWrites(ctx.store);
    const after = await getPending(ctx, owner.token);
    assert.equal(after.status, 200);
    assert.deepEqual(
      after.body.proposals,
      [],
      "кандидат удалён — предложение больше не actionable, пропадает из pending",
    );
    assert.equal(writes.count(), 1, "переход pending → stale — ровно одна запись блоба");

    writes.reset();
    const again = await getPending(ctx, owner.token);
    assert.deepEqual(again.body, after.body);
    assert.equal(writes.count(), 0, "предложение уже stale — повторный GET снова 0 записей");
  } finally {
    await stopTestServer(ctx);
  }
});

// ── D: замороженный снимок не мутируется ────────────────────────────────

test("SPEED-13 D: readSharedSnapshot() не мутируется — ни когда dry-run находит изменения (материализация идёт по своему _mutate-чтению), ни в steady state", async () => {
  const ctx = await startTestServer();
  try {
    const owner = await registerUser(ctx, "d-owner@test.app");
    const treeA = await createTree(ctx, owner.token, "Дерево А");
    const treeB = await createTree(ctx, owner.token, "Дерево Б");
    await createPerson(ctx, owner.token, treeA.id, {
      firstName: "Анна",
      lastName: "Сидорова",
      gender: "female",
      birthDate: "1990-02-02",
    });
    await createPerson(ctx, owner.token, treeB.id, {
      firstName: "Анна",
      lastName: "Сидорова",
      gender: "female",
      birthDate: "1990-02-02",
    });

    // Снимок ДО первого вызова — ничего ещё не материализовано; dry-run
    // обязан найти НОВОЕ совпадение и уйти в _mutate (свой независимый
    // fresh _read()) — переданный сюда объект-снимок не должен от
    // этого измениться (иначе следующий читатель снимка того же
    // процесса увидел бы "протёкшую" мутацию с чужого запроса).
    const snapshotBefore = await ctx.store.readSharedSnapshot();
    assert.ok(Object.isFrozen(snapshotBefore), "readSharedSnapshot() обязан отдавать заморозку");
    const frozenClone = structuredCloneWithoutSessions(snapshotBefore);

    const first = await ctx.store.listPendingMergeProposalsForUser(
      owner.userId,
      {limit: 50},
      snapshotBefore,
    );
    assert.equal(first.length, 1, "материализация должна была произойти");
    assert.ok(Object.isFrozen(snapshotBefore), "снимок остаётся заморожен после вызова");
    assert.deepEqual(
      structuredCloneWithoutSessions(snapshotBefore),
      frozenClone,
      "переданный снимок не должен был измениться — материализация читает СВЕЖЕЕ состояние сама, а не поверх этого объекта",
    );

    // Второй прогон: снимок уже отражает материализованное состояние —
    // dry-run должен решить «изменений нет» и вовсе не трогать снимок.
    const snapshotAfter = await ctx.store.readSharedSnapshot();
    const steadyClone = structuredCloneWithoutSessions(snapshotAfter);
    const second = await ctx.store.listPendingMergeProposalsForUser(
      owner.userId,
      {limit: 50},
      snapshotAfter,
    );
    assert.deepEqual(second, first, "steady state — тот же ответ");
    assert.deepEqual(
      structuredCloneWithoutSessions(snapshotAfter),
      steadyClone,
      "steady-state dry-run не мутирует снимок",
    );
  } finally {
    await stopTestServer(ctx);
  }
});

// ── E: идентичность относительно «старого» безусловного прогона ────────

async function seededStore(prefix) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), `rodnya-${prefix}-`));
  const dataPath = path.join(tempDir, "dev-db.json");
  const bootstrap = new FileStore(dataPath);
  await bootstrap.initialize();

  const db = JSON.parse(await fs.readFile(dataPath, "utf8"));
  db.users = [{id: "user-a", email: "a@rodnya.app", profile: {displayName: "Артём"}}];
  db.trees = [
    {id: "tree-a", name: "Семья А", creatorId: "user-a", memberIds: ["user-a"], members: ["user-a"]},
    {id: "tree-b", name: "Семья Б", creatorId: "user-a", memberIds: ["user-a"], members: ["user-a"]},
  ];
  await fs.writeFile(dataPath, JSON.stringify(db, null, 2));
  return {store: new FileStore(dataPath), tempDir};
}

async function makePerson(store, treeId, personData) {
  const person = await store.createPerson({treeId, creatorId: "user-a", personData, userId: null});
  return person.id;
}

test("SPEED-13 E: оптимизированный путь (снимок+dryRun+условная материализация) даёт ТОТ ЖЕ ответ, что старый безусловный прогон", async () => {
  const candidate = {
    firstName: "Мария",
    lastName: "Кузнецова",
    gender: "female",
    birthDate: "1985-07-07",
  };

  const {store: optimized} = await seededStore("speed13e-opt");
  await makePerson(optimized, "tree-a", candidate);
  await makePerson(optimized, "tree-b", candidate);
  const optimizedResult = await optimized.listPendingMergeProposalsForUser("user-a");

  const {store: naive} = await seededStore("speed13e-naive");
  await makePerson(naive, "tree-a", candidate);
  await makePerson(naive, "tree-b", candidate);

  // «По-старому»: свежий _read(), безусловный (dryRun по умолчанию
  // false) прогон обеих функций, безусловный _write() — буквально код
  // store.js ДО SPEED-13 (эти же функции остаются полноценно рабочими
  // в недвижном режиме — именно на этом основан данный тест).
  const naiveDb = await naive._read();
  naive._ensureCrossTreeMergeProposals(naiveDb, "user-a", {limit: 50});
  naive._markStaleMergeProposals(naiveDb);
  await naive._write(naiveDb);
  const naiveResult = naiveDb.mergeProposals
    .filter(
      (proposal) =>
        proposal.status === "pending" &&
        proposal.reviewerUserIds.includes("user-a") &&
        naive._mergeProposalStillActionable(naiveDb, proposal),
    )
    .map((proposal) => naive._mergeProposalView(naiveDb, proposal, "user-a"));

  assert.equal(optimizedResult.length, 1, "кросс-дерево совпадение должно предложить слияние");
  assert.deepEqual(
    optimizedResult.map((p) => ({...p, id: undefined, createdAt: undefined})),
    naiveResult.map((p) => ({...p, id: undefined, createdAt: undefined})),
    "SPEED-13 не должен менять итоговую форму/оценку предложения относительно старого безусловного прогона",
  );
});

test("SPEED-13 E: пусто (нет persons) — оба пути дают []", async () => {
  const {store: optimized} = await seededStore("speed13e-empty-opt");
  const result = await optimized.listPendingMergeProposalsForUser("user-a");
  assert.deepEqual(result, []);
});
