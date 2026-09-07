// Phase E4: «Опрос» (Poll) CRUD + voting route tests. Cloned from
// gathering-routes.test.js (real app.listen + fetch). Covers create→201,
// list/read, vote upsert (single-choice truncation), invalid option, and
// author-only delete.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-poll-rt-"));
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

async function shutdown({server, tempDir}) {
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(tempDir, {recursive: true, force: true});
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
  if (res.status !== 201) {
    throw new Error(`register failed status=${res.status}`);
  }
  const body = await res.json();
  return {userId: body.user.id, token: body.accessToken, email};
}

async function seedTree(store, baseUrl, ownerEmail) {
  const owner = await makeUser(baseUrl, ownerEmail);
  const tree = await store.createTree({
    creatorId: owner.userId,
    name: "Тест-дерево",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  return {owner, tree};
}

function createPoll(baseUrl, token, body) {
  return fetch(`${baseUrl}/v1/polls`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
}

function respond(baseUrl, token, pollId, body) {
  return fetch(`${baseUrl}/v1/polls/${pollId}/respond`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
}

test("POST /v1/polls creates a poll (201) with normalised options", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-create@example.com");
    const res = await createPoll(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      question: "Когда собираемся?",
      options: ["Суббота", "Воскресенье", ""], // empty dropped
    });
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.question, "Когда собираемся?");
    assert.equal(body.options.length, 2);
    assert.ok(body.options[0].id);
    assert.equal(body.options[0].text, "Суббота");
    assert.equal(body.allowMultiple, false);
    assert.deepEqual(body.responses, []);
  } finally {
    await shutdown(ctx);
  }
});

test("POST /v1/polls rejects fewer than two options (400)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-fewopts@example.com");
    const res = await createPoll(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      question: "Один вариант?",
      options: ["Да"],
    });
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/polls is gated by tree access (non-member → 403)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-vis-owner@example.com");
    await createPoll(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      question: "Опрос?",
      options: ["А", "Б"],
    });

    const ownerList = await fetch(
      `${ctx.baseUrl}/v1/polls?treeId=${tree.id}`,
      {headers: {Authorization: `Bearer ${owner.token}`}},
    );
    assert.equal(ownerList.status, 200);
    assert.equal((await ownerList.json()).length, 1);

    const stranger = await makeUser(ctx.baseUrl, "p-vis-stranger@example.com");
    const strangerList = await fetch(
      `${ctx.baseUrl}/v1/polls?treeId=${tree.id}`,
      {headers: {Authorization: `Bearer ${stranger.token}`}},
    );
    assert.equal(strangerList.status, 403);
  } finally {
    await shutdown(ctx);
  }
});

test("GET /v1/polls without treeId aggregates the feed «Все» tab (audience mode)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-aud-owner@example.com");
    await createPoll(ctx.baseUrl, owner.token, {
      treeId: tree.id,
      question: "Опрос в ленте?",
      options: ["Да", "Нет"],
    });

    // The «Все» tab sends NO treeId. Earlier this 400'd, so a poll never
    // showed under «Все» — it must now aggregate across accessible circles.
    const feed = await fetch(`${ctx.baseUrl}/v1/polls`, {
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(feed.status, 200);
    const polls = await feed.json();
    assert.equal(polls.length, 1);
    assert.equal(polls[0].question, "Опрос в ленте?");

    // Audience mode must NOT over-share: a stranger with no access to that
    // circle gets an empty feed (the accessibleTreeIds filter still scopes).
    const stranger =
        await makeUser(ctx.baseUrl, "p-aud-stranger@example.com");
    const strangerFeed = await fetch(`${ctx.baseUrl}/v1/polls`, {
      headers: {Authorization: `Bearer ${stranger.token}`},
    });
    assert.equal(strangerFeed.status, 200);
    assert.equal((await strangerFeed.json()).length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("POST respond upserts the vote; single-choice truncates to one", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-vote@example.com");
    const poll = await (
      await createPoll(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        question: "Что берём?",
        options: ["Мясо", "Рыба", "Овощи"],
      })
    ).json();
    const [a, b, c] = poll.options.map((o) => o.id);

    // Single-choice poll: voting for two options keeps only the first.
    const first = await respond(ctx.baseUrl, owner.token, poll.id, {
      optionIds: [a, b],
    });
    assert.equal(first.status, 200);
    let body = await first.json();
    assert.equal(body.responses.length, 1);
    assert.deepEqual(body.responses[0].optionIds, [a]);
    assert.equal(body.responses[0].userId, owner.userId);

    // Change of mind → same row updated, not duplicated.
    const second = await respond(ctx.baseUrl, owner.token, poll.id, {
      optionIds: [c],
    });
    body = await second.json();
    assert.equal(body.responses.length, 1);
    assert.deepEqual(body.responses[0].optionIds, [c]);
  } finally {
    await shutdown(ctx);
  }
});

test("POST respond keeps multiple choices when allowMultiple", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-multi@example.com");
    const poll = await (
      await createPoll(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        question: "Что берём?",
        options: ["Мясо", "Рыба", "Овощи"],
        allowMultiple: true,
      })
    ).json();
    const [a, b] = poll.options.map((o) => o.id);

    const res = await respond(ctx.baseUrl, owner.token, poll.id, {
      optionIds: [a, b],
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.responses.length, 1);
    assert.equal(body.responses[0].optionIds.length, 2);
  } finally {
    await shutdown(ctx);
  }
});

test("POST respond rejects an unknown option (400)", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-badopt@example.com");
    const poll = await (
      await createPoll(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        question: "Опрос?",
        options: ["А", "Б"],
      })
    ).json();

    const res = await respond(ctx.baseUrl, owner.token, poll.id, {
      optionIds: ["does-not-exist"],
    });
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("deletePoll only by author; author delete returns 204", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, tree} =
        await seedTree(ctx.store, ctx.baseUrl, "p-del-owner@example.com");
    const poll = await (
      await createPoll(ctx.baseUrl, owner.token, {
        treeId: tree.id,
        question: "Удаляемый опрос?",
        options: ["А", "Б"],
      })
    ).json();

    // Non-author cannot delete (store guard → false, route maps → 403).
    const stranger = await makeUser(ctx.baseUrl, "p-del-stranger@example.com");
    const refused = await ctx.store.deletePoll(poll.id, stranger.userId);
    assert.equal(refused, false);
    assert.ok(await ctx.store.findPoll(poll.id));

    // Author deletes via HTTP → 204, then it's gone.
    const delRes = await fetch(`${ctx.baseUrl}/v1/polls/${poll.id}`, {
      method: "DELETE",
      headers: {Authorization: `Bearer ${owner.token}`},
    });
    assert.equal(delRes.status, 204);
    assert.equal(await ctx.store.findPoll(poll.id), null);
  } finally {
    await shutdown(ctx);
  }
});
