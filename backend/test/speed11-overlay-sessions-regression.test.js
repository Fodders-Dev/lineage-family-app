// Регресс SPEED-11 (найден агентом SPEED-12): _writableCirclesViewForTree делал
// {...db} на замороженном общем снимке — spread вызывает бросающий геттер
// sessions → GET gatherings/polls/stories падали 500, когда viewer ≠ author
// в федеративном дереве. Хелперы взяты из speed12-shared-snapshot-more.test.js.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {createApp} = require("../src/app");
const {FileStore} = require("../src/store");
const {RealtimeHub} = require("../src/realtime-hub");
const {PushGateway} = require("../src/push-gateway");

async function startTestServer() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-speed12-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();
  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store});

  // useSemyaModel читается один раз внутри createApp — включаем ДО
  // вызова, восстанавливаем сразу после (см. speed9-b-single-read.test.js).
  const prevFlag = process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  process.env.RODNYA_FEDERATED_SEMYI_ENABLED = "true";
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
  if (prevFlag === undefined) {
    delete process.env.RODNYA_FEDERATED_SEMYI_ENABLED;
  } else {
    process.env.RODNYA_FEDERATED_SEMYI_ENABLED = prevFlag;
  }

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

async function shutdown({server, tempDir}) {
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
}

async function makeUser(baseUrl, email) {
  const res = await fetch(`${baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      email,
      password: "Test-Password-123!",
      consentDocVersion: "test-consent-v1",
      displayName: email.split("@")[0],
    }),
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  return {userId: body.user.id, token: body.accessToken};
}

function authedGet(baseUrl, url, token) {
  return fetch(`${baseUrl}${url}`, {headers: {Authorization: `Bearer ${token}`}});
}

// Федеративная фикстура: дерево + семья + один person + один пост —
// достаточно для всех восьми маршрутов SPEED-12 (posts/search/graph/
// attributes/identity-suggestions используют то же дерево; onboarding-
// state/browse-token treeId-агностичны, но используют owner/tree тоже).

test(
  "РЕГРЕСС (был живой на main): GET /v1/gatherings|polls|stories не падают, когда viewer ≠ author",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await makeUser(ctx.baseUrl, "circlesbug-owner@example.com");
      const viewer = await makeUser(ctx.baseUrl, "circlesbug-viewer@example.com");
      const tree = await ctx.store.createTree({
        creatorId: owner.userId,
        name: "Дерево для регресса кругов",
        description: "",
        isPrivate: true,
        kind: "family",
      });
      const semya = await ctx.store.createSemya({
        ownerId: owner.userId,
        name: "Семья регресса",
        treeId: tree.id,
      });
      // viewer должен быть членом СЕМЬИ (не только tree.memberIds) —
      // федеративный requireTreeAccess гейтит через findMembership.
      await ctx.store.addMembership({
        semyaId: semya.id,
        userId: viewer.userId,
        role: "viewer",
        invitedByUserId: owner.userId,
      });

      await ctx.store.createGathering({
        treeId: tree.id,
        authorId: owner.userId,
        authorName: "Владелец",
        title: "Событие",
        startAt: "2026-07-01T15:00:00.000Z",
      });
      await ctx.store.createPoll({
        treeId: tree.id,
        authorId: owner.userId,
        authorName: "Владелец",
        question: "Вопрос?",
        options: ["Да", "Нет"],
      });
      await ctx.store.createStory({
        treeId: tree.id,
        authorId: owner.userId,
        authorName: "Владелец",
        type: "text",
        text: "Текст истории",
      });

      for (const url of [
        `/v1/gatherings?treeId=${tree.id}`,
        `/v1/polls?treeId=${tree.id}`,
        `/v1/stories?treeId=${tree.id}`,
      ]) {
        // eslint-disable-next-line no-await-in-loop
        const res = await authedGet(ctx.baseUrl, url, viewer.token);
        assert.equal(res.status, 200, `${url} не должен падать 500`);
      }
    } finally {
      await shutdown(ctx);
    }
  },
);
