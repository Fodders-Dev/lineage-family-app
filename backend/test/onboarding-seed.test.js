// Phase 6 chunk 1: onboarding endpoints tests.
//
// Covers (DECISIONS.md 2026-05-13 state-based idempotency):
// • POST /onboarding/seed — fresh + idempotent re-call + replace-
//   on-incomplete + atomic semantics.
// • GET/PATCH /me/onboarding-state — wizard progress.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-onb-"));
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
  await fs.rm(ctx.tempDir, {recursive: true, force: true});
}

async function registerUser(ctx, email) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({email, password: "secret123", consentDocVersion: "test-consent-v1", displayName: "Test"}),
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function seedOnboarding(ctx, token, payload) {
  return fetch(`${ctx.baseUrl}/v1/onboarding/seed`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

test("POST /onboarding/seed: no auth → 401", async () => {
  const ctx = await startTestServer();
  try {
    const response = await fetch(`${ctx.baseUrl}/v1/onboarding/seed`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({profile: {name: "X"}}),
    });
    assert.equal(response.status, 401);
  } finally {
    await stopTestServer(ctx);
  }
});

test("POST /onboarding/seed: missing profile → 400", async () => {
  const ctx = await startTestServer();
  try {
    const user = await registerUser(ctx, "u@test.app");
    const response = await seedOnboarding(ctx, user.accessToken, {
      relatives: [],
    });
    assert.equal(response.status, 400);
  } finally {
    await stopTestServer(ctx);
  }
});

test(
  "POST /onboarding/seed: fresh user → 201 + tree + persons + state.completed",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "fresh@test.app");
      const response = await seedOnboarding(ctx, user.accessToken, {
        profile: {name: "Иван Петров", gender: "male", birthDate: "1990-01-01"},
        relatives: [
          {name: "Мама Иванова", gender: "female", relationToMe: "mother"},
          {name: "Папа Иванов", gender: "male", relationToMe: "father"},
        ],
      });
      assert.equal(response.status, 201);
      const body = await response.json();
      assert.ok(body.treeId);
      assert.equal(body.personIds.length, 3); // self + 2 relatives
      assert.equal(body.idempotent, false);

      // Verify state.
      const stateResponse = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {headers: {authorization: `Bearer ${user.accessToken}`}},
      );
      const stateBody = await stateResponse.json();
      assert.equal(stateBody.state.completed, true);
      assert.equal(stateBody.state.currentStep, "done");
      assert.equal(stateBody.state.treeId, body.treeId);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /onboarding/seed: idempotent re-call → 200 + same tree (no duplicate)",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "idem@test.app");
      const r1 = await seedOnboarding(ctx, user.accessToken, {
        profile: {name: "Тест"},
        relatives: [{name: "Мама", relationToMe: "mother"}],
      });
      const b1 = await r1.json();
      assert.equal(r1.status, 201);

      const r2 = await seedOnboarding(ctx, user.accessToken, {
        profile: {name: "Тест"},
        relatives: [{name: "Мама", relationToMe: "mother"}],
      });
      assert.equal(r2.status, 200);
      const b2 = await r2.json();
      assert.equal(b2.idempotent, true);
      assert.equal(b2.treeId, b1.treeId);
      assert.deepEqual(b2.personIds, b1.personIds);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /onboarding/seed: incomplete previous attempt → replaced",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "replace@test.app");

      // Manually set incomplete state с fake treeId.
      const db = await ctx.store._read();
      const fakeTreeId = "incomplete-tree-uuid";
      db.trees.push({
        id: fakeTreeId,
        name: "Incomplete attempt",
        creatorId: user.user.id,
        memberIds: [user.user.id],
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      db.persons.push({
        id: "ghost-person",
        treeId: fakeTreeId,
        userId: user.user.id,
        name: "Ghost",
        createdAt: new Date().toISOString(),
      });
      // Phase 6 chunk 4a — register endpoint теперь создаёт initial
      // onboardingState record. Заменяем его в-place, не push'аем
      // duplicate (иначе seedOnboarding's find возвращает первый и
      // не replace'ит ghost tree).
      const existingStateIdx = db.onboardingStates.findIndex(
        (s) => s.userId === user.user.id,
      );
      const ghostState = {
        userId: user.user.id,
        completed: false,
        currentStep: "relatives",
        treeId: fakeTreeId,
        personIds: ["ghost-person"],
        updatedAt: new Date().toISOString(),
      };
      if (existingStateIdx >= 0) {
        db.onboardingStates[existingStateIdx] = ghostState;
      } else {
        db.onboardingStates.push(ghostState);
      }
      await ctx.store._write(db);

      // Seed с new payload — должен replace.
      const response = await seedOnboarding(ctx, user.accessToken, {
        profile: {name: "Иван"},
        relatives: [{name: "Сестра", relationToMe: "sibling"}],
      });
      assert.equal(response.status, 201);
      const body = await response.json();
      assert.notEqual(body.treeId, fakeTreeId, "должен быть new treeId");

      // Verify old tree удалён.
      const dbAfter = await ctx.store._read();
      const oldTree = dbAfter.trees.find((t) => t.id === fakeTreeId);
      assert.equal(oldTree, undefined, "ghost tree должно быть стёрто");
      const oldPerson = dbAfter.persons.find((p) => p.id === "ghost-person");
      assert.equal(oldPerson, undefined, "ghost person должен быть стёрт");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /onboarding/seed: relatives с relationToMe создаёт relations",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "rel@test.app");
      const response = await seedOnboarding(ctx, user.accessToken, {
        profile: {name: "Иван"},
        relatives: [
          {name: "Мама", relationToMe: "mother"},
          {name: "Брат", relationToMe: "sibling"},
        ],
      });
      const body = await response.json();
      const db = await ctx.store._read();
      const relations = db.relations.filter((r) => r.treeId === body.treeId);
      assert.equal(relations.length, 2);
      // Mom → me = parent/child.
      const motherRelation = relations.find(
        (r) => r.relation1to2 === "parent",
      );
      assert.ok(motherRelation);
      // Brother → me = sibling/sibling.
      const siblingRelation = relations.find(
        (r) => r.relation1to2 === "sibling" && r.relation2to1 === "sibling",
      );
      assert.ok(siblingRelation);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /me/onboarding-state: fresh user → completed=false, step=welcome",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "state@test.app");
      const response = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {headers: {authorization: `Bearer ${user.accessToken}`}},
      );
      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.state.completed, false);
      assert.equal(body.state.currentStep, "welcome");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH /me/onboarding-state: updates step",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "patch@test.app");
      const response = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${user.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({currentStep: "relatives"}),
        },
      );
      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.state.currentStep, "relatives");
      assert.equal(body.state.completed, false);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH /me/onboarding-state: invalid step → 400",
  async () => {
    const ctx = await startTestServer();
    try {
      const user = await registerUser(ctx, "patch-bad@test.app");
      const response = await fetch(
        `${ctx.baseUrl}/v1/me/onboarding-state`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${user.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({currentStep: "garbage"}),
        },
      );
      assert.equal(response.status, 400);
    } finally {
      await stopTestServer(ctx);
    }
  },
);
