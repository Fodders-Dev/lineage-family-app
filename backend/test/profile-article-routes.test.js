// Profile Phase 1 (2026-05-28): profileArticles HTTP + store tests.
//
// Per PROFILE-UX-REDESIGN-PROPOSAL (674c6ea). Covers article CRUD over
// HTTP, block validation, reorder, permission boundary, and (at the
// store layer, where two distinct authors are simplest to drive)
// multi-author attribution + last-write-wins conflict + history.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-art-rt-"));
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

async function seedTreeWithPerson(store, baseUrl, ownerEmail) {
  const owner = await makeUser(baseUrl, ownerEmail);
  const tree = await store.createTree({
    creatorId: owner.userId,
    name: "Тест",
    description: "",
    isPrivate: true,
    kind: "family",
  });
  const person = await store.createPerson({
    treeId: tree.id,
    creatorId: owner.userId,
    personData: {name: "Бабушка Лидия", gender: "female"},
  });
  return {owner, tree, person};
}

function authHeaders(token, json = false) {
  const h = {Authorization: `Bearer ${token}`};
  if (json) h["Content-Type"] = "application/json";
  return h;
}

test("article lifecycle: empty → append → edit → delete over HTTP", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "art-life@example.com",
    );
    const base = `${ctx.baseUrl}/v1/persons/${person.id}/article`;

    // GET empty article (synthesized, no blocks).
    let res = await fetch(base, {headers: authHeaders(owner.token)});
    assert.equal(res.status, 200);
    let body = await res.json();
    assert.equal(body.article.personId, person.id);
    assert.deepEqual(body.article.blocks, []);

    // POST a paragraph block.
    res = await fetch(`${base}/blocks`, {
      method: "POST",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({
        type: "paragraph",
        content: {spans: [{text: "Лидия родилась в 1949 году."}]},
      }),
    });
    assert.equal(res.status, 201);
    const {block} = await res.json();
    assert.equal(block.type, "paragraph");
    assert.equal(block.authorUserId, owner.userId);
    assert.equal(block.createdByUserId, owner.userId);

    // GET now shows the block.
    res = await fetch(base, {headers: authHeaders(owner.token)});
    body = await res.json();
    assert.equal(body.article.blocks.length, 1);
    assert.equal(body.article.blocks[0].id, block.id);

    // PATCH edits content.
    res = await fetch(`${base}/blocks/${block.id}`, {
      method: "PATCH",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({
        content: {spans: [{text: "Лидия родилась 12 февраля 1949 года."}]},
      }),
    });
    assert.equal(res.status, 200);
    const patched = await res.json();
    assert.equal(patched.conflict, false);
    assert.equal(patched.block.content.spans[0].text.includes("12 февраля"), true);

    // DELETE removes it.
    res = await fetch(`${base}/blocks/${block.id}`, {
      method: "DELETE",
      headers: authHeaders(owner.token),
    });
    assert.equal(res.status, 200);

    res = await fetch(base, {headers: authHeaders(owner.token)});
    body = await res.json();
    assert.equal(body.article.blocks.length, 0);
  } finally {
    await shutdown(ctx);
  }
});

test("block validation: photo without url + unknown type → 400", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "art-valid@example.com",
    );
    const blocksUrl = `${ctx.baseUrl}/v1/persons/${person.id}/article/blocks`;

    let res = await fetch(blocksUrl, {
      method: "POST",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({type: "photo", content: {caption: "нет url"}}),
    });
    assert.equal(res.status, 400);

    res = await fetch(blocksUrl, {
      method: "POST",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({type: "banana", content: {}}),
    });
    assert.equal(res.status, 400);
  } finally {
    await shutdown(ctx);
  }
});

test("reorder blocks via PUT .../blocks/order", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "art-order@example.com",
    );
    const base = `${ctx.baseUrl}/v1/persons/${person.id}/article`;

    const ids = [];
    for (const text of ["один", "два", "три"]) {
      const res = await fetch(`${base}/blocks`, {
        method: "POST",
        headers: authHeaders(owner.token, true),
        body: JSON.stringify({type: "paragraph", content: {spans: [{text}]}}),
      });
      ids.push((await res.json()).block.id);
    }

    const reversed = [...ids].reverse();
    let res = await fetch(`${base}/blocks/order`, {
      method: "PUT",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({order: reversed}),
    });
    assert.equal(res.status, 200);

    res = await fetch(base, {headers: authHeaders(owner.token)});
    const body = await res.json();
    assert.deepEqual(
      body.article.blocks.map((b) => b.id),
      reversed,
    );
  } finally {
    await shutdown(ctx);
  }
});

test("permission: non-member denied read + write", async () => {
  const ctx = await startTestServer();
  try {
    const {person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "art-owner2@example.com",
    );
    const stranger = await makeUser(ctx.baseUrl, "art-stranger@example.com");
    const base = `${ctx.baseUrl}/v1/persons/${person.id}/article`;

    // Read denied.
    let res = await fetch(base, {headers: authHeaders(stranger.token)});
    assert.ok(
      res.status === 403 || res.status === 404,
      `expected denied, got ${res.status}`,
    );

    // Write denied.
    res = await fetch(`${base}/blocks`, {
      method: "POST",
      headers: authHeaders(stranger.token, true),
      body: JSON.stringify({type: "paragraph", content: {spans: [{text: "x"}]}}),
    });
    assert.ok(
      res.status === 403 || res.status === 404,
      `expected denied, got ${res.status}`,
    );
  } finally {
    await shutdown(ctx);
  }
});

test("multi-author: last-write-wins conflict flips authorUserId + notifies prior author", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "art-ma-owner@example.com",
    );
    const coauthor = await makeUser(ctx.baseUrl, "art-ma-co@example.com");

    // Author A appends a block (store layer — two distinct authors are
    // simplest to drive directly; HTTP permission covered above).
    const block = await ctx.store.appendArticleBlock({
      personId: person.id,
      type: "paragraph",
      content: {spans: [{text: "Версия A"}]},
      actorUserId: owner.userId,
    });
    assert.equal(block.authorUserId, owner.userId);

    // Author B edits with a STALE baseUpdatedAt → conflict (LWW applies).
    const result = await ctx.store.updateArticleBlock({
      personId: person.id,
      blockId: block.id,
      content: {spans: [{text: "Версия B"}]},
      actorUserId: coauthor.userId,
      baseUpdatedAt: "2000-01-01T00:00:00.000Z",
    });
    assert.equal(result.conflict, true);
    assert.equal(result.block.authorUserId, coauthor.userId);
    assert.equal(result.block.content.spans[0].text, "Версия B");

    // Prior author A notified.
    const db = await ctx.store._read();
    const note = (db.notifications || []).find(
      (n) =>
        n.userId === owner.userId && n.type === "article_block_conflict",
    );
    assert.ok(note, "prior author should receive a conflict notification");

    // Audit `before` snapshot preserved (history reuses treeChangeRecords).
    const updateRecord = (db.treeChangeRecords || []).find(
      (r) => r.type === "article.block-updated" && r.personId === person.id,
    );
    assert.ok(updateRecord, "update should be audit-logged");
    assert.equal(updateRecord.details.before.spans[0].text, "Версия A");
  } finally {
    await shutdown(ctx);
  }
});

test("history returns article.* records newest-first", async () => {
  const ctx = await startTestServer();
  try {
    const {owner, person} = await seedTreeWithPerson(
      ctx.store,
      ctx.baseUrl,
      "art-hist@example.com",
    );
    const base = `${ctx.baseUrl}/v1/persons/${person.id}/article`;

    const res = await fetch(`${base}/blocks`, {
      method: "POST",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({type: "header", content: {text: "Детство", level: 2}}),
    });
    const {block} = await res.json();
    await fetch(`${base}/blocks/${block.id}`, {
      method: "PATCH",
      headers: authHeaders(owner.token, true),
      body: JSON.stringify({content: {text: "Ранние годы", level: 2}}),
    });

    const histRes = await fetch(`${base}/history`, {
      headers: authHeaders(owner.token),
    });
    assert.equal(histRes.status, 200);
    const {history} = await histRes.json();
    assert.ok(history.length >= 2);
    assert.ok(history.every((r) => r.type.startsWith("article.")));
    // Newest-first: the update comes after the add.
    assert.equal(history[0].type, "article.block-updated");
  } finally {
    await shutdown(ctx);
  }
});
