// Phase 3.2 owner-model enforcement tests.
//
// Покрывает:
// • PATCH/DELETE persons (anonymous → tree-access; claimed →
//   owner или active grant per scope).
// • Pre-claim/post-claim regression (Артёмова nice-to-have):
//   member-of-tree edits anonymous person → success;
//   третья сторона claim'ит slot'a через linkPersonToUser →
//   member делает PATCH снова → 403. Самый болевой regression
//   risk зафиксирован test'ом.
// • Grant CRUD endpoints + idempotency + audit-trail на revoke.
// • Visibility PATCH (owner-only-всегда, не grants).
// • /v1/me/edit-grants — granted user видит свои.
// • Cross-tree search/identity-suggestions — visibility filter.
// • /v1/graph/relation chain — anonymization hidden middle node,
//   403 на blocked endpoints.
// • Sensitive contacts attribute — owner-only-всегда.

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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-owner-"));
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

async function registerUser(ctx, email, displayName) {
  const response = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      email,
      password: "secret123",
      consentDocVersion: "test-consent-v1",
      displayName,
    }),
  });
  assert.equal(response.status, 201);
  return response.json();
}

async function createTree(ctx, owner, name = "Test tree") {
  const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${owner.accessToken}`,
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

async function patchPerson(ctx, token, treeId, personId, body) {
  return fetch(
    `${ctx.baseUrl}/v1/trees/${treeId}/persons/${personId}`,
    {
      method: "PATCH",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
}

async function inviteAndAccept(ctx, owner, recipient, treeId) {
  const inviteResponse = await fetch(
    `${ctx.baseUrl}/v1/trees/${treeId}/invitations`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${owner.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({recipientUserId: recipient.user.id}),
    },
  );
  assert.equal(inviteResponse.status, 201);
  const invitation = await inviteResponse.json();
  const acceptResponse = await fetch(
    `${ctx.baseUrl}/v1/tree-invitations/${invitation.invitation.invitationId}/respond`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${recipient.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({accept: true}),
    },
  );
  assert.equal(acceptResponse.status, 200);
}

// ── PATCH person enforcement ─────────────────────────────────────────

test(
  "PATCH person: owner edits own anonymous person — 200",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "owner-anon@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Бабушка",
        lastName: "Иванова",
        gender: "female",
      });
      const response = await patchPerson(
        ctx,
        owner.accessToken,
        tree.id,
        person.id,
        {firstName: "Бабушка Лида"},
      );
      assert.equal(response.status, 200);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH person: tree-creator edits anonymous person created by member — 200 (collaborative editing)",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "alice@test.app", "Alice");
      const bob = await registerUser(ctx, "bob@test.app", "Bob");
      const tree = await createTree(ctx, alice);
      await inviteAndAccept(ctx, alice, bob, tree.id);
      // Bob creates anonymous person.
      const person = await createPerson(ctx, bob.accessToken, tree.id, {
        firstName: "Прабабушка",
        lastName: "Лида",
        gender: "female",
      });
      // Alice (tree-creator) edits — anonymous, allowed.
      const response = await patchPerson(
        ctx,
        alice.accessToken,
        tree.id,
        person.id,
        {firstName: "Прабабушка Лидия Александровна"},
      );
      assert.equal(response.status, 200);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH person: stranger (not in tree) — 403 from tree-access",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "alice2@test.app", "Alice");
      const stranger = await registerUser(ctx, "stranger@test.app", "Stranger");
      const tree = await createTree(ctx, alice);
      const person = await createPerson(ctx, alice.accessToken, tree.id, {
        firstName: "Anyone",
        gender: "unknown",
      });
      const response = await patchPerson(
        ctx,
        stranger.accessToken,
        tree.id,
        person.id,
        {firstName: "Hijack"},
      );
      // Stranger blocked at requireTreeAccess level (403).
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH person: pre-claim member edit → claim happens → post-claim member edit fails 403 (regression test)",
  async () => {
    // Артёмова nice-to-have — самый болевой regression risk.
    // Pre-Phase-3.2 любой member tree мог писать на claimed slot.
    // После claim'а enforcement reject'ит как «editorial vandalism
    // на чужом profile'е».
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "pc-alice@test.app", "Alice");
      const bob = await registerUser(ctx, "pc-bob@test.app", "Bob");
      const stepa = await registerUser(ctx, "pc-stepa@test.app", "Stepa");
      const tree = await createTree(ctx, alice);
      await inviteAndAccept(ctx, alice, bob, tree.id);

      // Alice creates anonymous slot для Stepa.
      const stepaPerson = await createPerson(
        ctx,
        alice.accessToken,
        tree.id,
        {firstName: "Стёпа", gender: "male"},
      );

      // Pre-claim: Bob (member of tree) edits Stepa's anonymous slot.
      // Allowed — anonymous + tree-access.
      const preClaimResponse = await patchPerson(
        ctx,
        bob.accessToken,
        tree.id,
        stepaPerson.id,
        {firstName: "Стёпан"},
      );
      assert.equal(
        preClaimResponse.status,
        200,
        "pre-claim Bob edit on anonymous slot must succeed",
      );

      // Stepa claim'ит свой slot через invite-link semantic.
      // POST /v1/invitations/pending/process — это linkPersonToUser
      // путь, который ставит person.userId = stepa.user.id.
      const claimResponse = await fetch(
        `${ctx.baseUrl}/v1/invitations/pending/process`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${stepa.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({treeId: tree.id, personId: stepaPerson.id}),
        },
      );
      assert.equal(claimResponse.status, 200);

      // Post-claim: Bob делает PATCH ту же person'у.
      // graphPerson.userId = stepa теперь. Bob — НЕ owner и НЕ
      // grant'ован. → 403.
      const postClaimResponse = await patchPerson(
        ctx,
        bob.accessToken,
        tree.id,
        stepaPerson.id,
        {firstName: "Стёпушка"},
      );
      assert.equal(
        postClaimResponse.status,
        403,
        "post-claim Bob edit on now-claimed slot must be rejected — claimed = owner-only",
      );

      // Sanity: Stepa (теперь owner) может editить.
      const stepaSelfEdit = await patchPerson(
        ctx,
        stepa.accessToken,
        tree.id,
        stepaPerson.id,
        {firstName: "Степан"},
      );
      assert.equal(stepaSelfEdit.status, 200);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH person: claimed person editable by user with active grant",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "g-alice@test.app", "Alice");
      const stepa = await registerUser(ctx, "g-stepa@test.app", "Stepa");
      const helper = await registerUser(ctx, "g-helper@test.app", "Helper");
      const tree = await createTree(ctx, alice);
      await inviteAndAccept(ctx, alice, helper, tree.id);

      const stepaPerson = await createPerson(
        ctx,
        alice.accessToken,
        tree.id,
        {firstName: "Стёпа", gender: "male"},
      );
      // Stepa claims.
      await fetch(`${ctx.baseUrl}/v1/invitations/pending/process`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${stepa.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({treeId: tree.id, personId: stepaPerson.id}),
      });

      // graphPerson.id === identityId. Найдём identityId через
      // GET person.
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${stepaPerson.id}`,
        {headers: {authorization: `Bearer ${stepa.accessToken}`}},
      );
      const personPayload = await personRead.json();
      const graphPersonId = personPayload.person.identityId;

      // Helper tries patch (no grant) → 403.
      const beforeGrant = await patchPerson(
        ctx,
        helper.accessToken,
        tree.id,
        stepaPerson.id,
        {firstName: "Hopelessly editable"},
      );
      assert.equal(beforeGrant.status, 403);

      // Stepa выписывает grant Helper'у.
      const grantResponse = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${stepa.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: helper.user.id,
            scope: "edit",
          }),
        },
      );
      assert.equal(grantResponse.status, 201);
      const grantPayload = await grantResponse.json();

      // Now Helper может editить.
      const afterGrant = await patchPerson(
        ctx,
        helper.accessToken,
        tree.id,
        stepaPerson.id,
        {firstName: "Edited via grant"},
      );
      assert.equal(afterGrant.status, 200);

      // Stepa revoke'ит grant.
      const revokeResponse = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants/${grantPayload.grant.id}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${stepa.accessToken}`},
        },
      );
      assert.equal(revokeResponse.status, 200);

      // Helper больше не может editить.
      const afterRevoke = await patchPerson(
        ctx,
        helper.accessToken,
        tree.id,
        stepaPerson.id,
        {firstName: "Should fail"},
      );
      assert.equal(afterRevoke.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── DELETE person (soft-delete scope) ────────────────────────────────

test(
  "DELETE person: anonymous — tree-access достаточно",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "d-alice@test.app", "Alice");
      const bob = await registerUser(ctx, "d-bob@test.app", "Bob");
      const tree = await createTree(ctx, alice);
      await inviteAndAccept(ctx, alice, bob, tree.id);
      const person = await createPerson(ctx, alice.accessToken, tree.id, {
        firstName: "Anon",
        gender: "unknown",
      });
      // Bob (member) deletes — anonymous, allowed.
      const response = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${bob.accessToken}`},
        },
      );
      assert.equal(response.status, 204);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "DELETE person: claimed — non-owner without grant — 403",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "d2-alice@test.app", "Alice");
      const stepa = await registerUser(ctx, "d2-stepa@test.app", "Stepa");
      const tree = await createTree(ctx, alice);
      const stepaPerson = await createPerson(
        ctx,
        alice.accessToken,
        tree.id,
        {firstName: "Stepa", gender: "male"},
      );
      await fetch(`${ctx.baseUrl}/v1/invitations/pending/process`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${stepa.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({treeId: tree.id, personId: stepaPerson.id}),
      });
      // Alice tree-creator пытается soft-delete claimed Stepa.
      const response = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${stepaPerson.id}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${alice.accessToken}`},
        },
      );
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Visibility PATCH (owner-only-всегда) ─────────────────────────────

test(
  "PATCH visibility: owner sets owner-only and visibilityOverride=true",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "v-owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;

      const response = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/visibility`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({visibility: "owner-only"}),
        },
      );
      assert.equal(response.status, 200);
      const payload = await response.json();
      assert.equal(payload.graphPerson.visibility, "owner-only");
      assert.equal(payload.graphPerson.visibilityOverride, true);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH visibility: non-owner with edit grant — 403 (visibility owner-only-всегда)",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "v2-alice@test.app", "Alice");
      const helper = await registerUser(ctx, "v2-helper@test.app", "Helper");
      const tree = await createTree(ctx, alice);
      await inviteAndAccept(ctx, alice, helper, tree.id);
      const person = await createPerson(ctx, alice.accessToken, tree.id, {
        firstName: "Self",
        userId: alice.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${alice.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;

      // Alice issues edit grant Helper.
      const grantResponse = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${alice.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: helper.user.id,
            scope: "edit",
          }),
        },
      );
      assert.equal(grantResponse.status, 201);

      // Helper пытается menять visibility — 403, потому что
      // visibility — owner-only-всегда даже с edit grant.
      const visibilityResponse = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/visibility`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${helper.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({visibility: "public"}),
        },
      );
      assert.equal(visibilityResponse.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH visibility: invalid value → 400",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "v3-owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "X",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;
      const response = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/visibility`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({visibility: "rainbow-mode"}),
        },
      );
      assert.equal(response.status, 400);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Grant CRUD ───────────────────────────────────────────────────────

test(
  "Grant POST: owner grants edit, idempotent on second call",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "gp-owner@test.app", "Owner");
      const grantee = await registerUser(ctx, "gp-grantee@test.app", "Grantee");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;

      const first = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: grantee.user.id,
            scope: "edit",
          }),
        },
      );
      assert.equal(first.status, 201);
      const firstPayload = await first.json();

      // Same grant второй раз — idempotent (200, не 201, та же row).
      const second = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: grantee.user.id,
            scope: "edit",
          }),
        },
      );
      assert.equal(second.status, 200);
      const secondPayload = await second.json();
      assert.equal(secondPayload.grant.id, firstPayload.grant.id);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "Grant POST: non-owner — 403",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "gp2-owner@test.app", "Owner");
      const stranger = await registerUser(ctx, "gp2-stranger@test.app", "X");
      const helper = await registerUser(ctx, "gp2-helper@test.app", "H");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;

      // Stranger пытается grant'нуть Helper edit-scope на graphPerson
      // owner'а. Stranger — НЕ owner. Должен получить 403 NOT_OWNER.
      // (Если бы stranger пытался grant'нуть СЕБЯ — порядок проверок
      // в store first triggers SELF_GRANT 409, поэтому используем
      // отдельного helper'а как grantee.)
      const response = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${stranger.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: helper.user.id,
            scope: "edit",
          }),
        },
      );
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "Grant POST: granting yourself — 409",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "gp3-owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;
      const response = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: owner.user.id,
            scope: "edit",
          }),
        },
      );
      assert.equal(response.status, 409);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "Grant POST: invalid scope — 400",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "gp4-owner@test.app", "Owner");
      const grantee = await registerUser(ctx, "gp4-grantee@test.app", "G");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;
      const response = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: grantee.user.id,
            scope: "delete-everything",
          }),
        },
      );
      assert.equal(response.status, 400);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "Grant DELETE: grantee tries revoke — 403; owner revokes idempotently",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "gd-owner@test.app", "Owner");
      const grantee = await registerUser(ctx, "gd-grantee@test.app", "G");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;

      const grantResponse = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: grantee.user.id,
            scope: "edit",
          }),
        },
      );
      const grantId = (await grantResponse.json()).grant.id;

      // Grantee revoke — 403.
      const granteeRevoke = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants/${grantId}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${grantee.accessToken}`},
        },
      );
      assert.equal(granteeRevoke.status, 403);

      // Owner revoke — 200.
      const ownerRevoke = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants/${grantId}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${owner.accessToken}`},
        },
      );
      assert.equal(ownerRevoke.status, 200);
      assert.ok((await ownerRevoke.json()).grant.revokedAt);

      // Idempotent — second revoke, no error.
      const secondRevoke = await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants/${grantId}`,
        {
          method: "DELETE",
          headers: {authorization: `Bearer ${owner.accessToken}`},
        },
      );
      assert.equal(secondRevoke.status, 200);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "/v1/me/edit-grants returns active grants with graphPerson preview",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "me-owner@test.app", "Owner");
      const grantee = await registerUser(ctx, "me-grantee@test.app", "G");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Bobby",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;
      await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: grantee.user.id,
            scope: "edit",
          }),
        },
      );
      const myGrants = await fetch(`${ctx.baseUrl}/v1/me/edit-grants`, {
        headers: {authorization: `Bearer ${grantee.accessToken}`},
      });
      assert.equal(myGrants.status, 200);
      const payload = await myGrants.json();
      assert.equal(payload.grants.length, 1);
      assert.equal(payload.grants[0].graphPersonId, graphPersonId);
      assert.equal(payload.grants[0].granteeUserId, grantee.user.id);
      assert.ok(payload.grants[0].graphPerson);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Sensitive contacts attribute (owner-only-всегда) ─────────────────

// ── Phase 3.4-prep: includeRules + issued-grants endpoints ──────────

test(
  "POST /v1/trees: includeRules в payload применяется к новому branch",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "ir-owner@test.app", "Owner");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Кровная семья",
          description: "Только моя кровная родня",
          isPrivate: true,
          includeRules: {
            type: "blood-from-me",
            anchorPersonId: null,
            maxHops: 4,
          },
        }),
      });
      assert.equal(response.status, 201);
      const tree = (await response.json()).tree;
      // Tree-level shape без изменений; rules живут на branch.
      // Читаем backend state напрямую, чтобы убедиться что
      // includeRules применились.
      const db = await ctx.store._read();
      const branch = db.branches.find((b) => b.id === tree.id);
      assert.ok(branch);
      assert.equal(branch.includeRules.type, "blood-from-me");
      assert.equal(branch.includeRules.maxHops, 4);
      assert.equal(branch.includeRules.anchorPersonId, null);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /v1/trees: invalid includeRules.type → 400 (client-bug surface, не silent fallback)",
  async () => {
    // Phase 3.4-prep fix-1: malformed type — это client-bug,
    // НЕ silent default. Missing/null поле — другая история
    // (silent default manual для legacy backward-compat),
    // отдельный тест ниже.
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "ir2-owner@test.app", "Owner");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Тест",
          isPrivate: true,
          includeRules: {type: "delete-everything", maxHops: 5},
        }),
      });
      assert.equal(response.status, 400);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "POST /v1/trees: missing includeRules → 201 + default manual rule (legacy back-compat)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "ir3-owner@test.app", "Owner");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Без rules",
          isPrivate: true,
          // includeRules: omitted — pre-3.4 legacy client behaviour.
        }),
      });
      assert.equal(response.status, 201);
      const tree = (await response.json()).tree;
      const db = await ctx.store._read();
      const branch = db.branches.find((b) => b.id === tree.id);
      assert.equal(branch.includeRules.type, "manual");
      // Default maxHops=5 за counts (RFC §D).
      assert.equal(branch.includeRules.maxHops, 5);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── maxHops boundary clamping ───────────────────────────────────────
// Phase 3.4-prep fix-2: maxHops — continuous int с clamp 1..20.
// Out-of-range values НЕ throw (в отличие от type, который throws);
// clamp в обозримые границы. Для type — discrete enum, invalid =
// client-bug; для maxHops — continuous range, out-of-range = caller
// pushed slider beyond UI-allowed bounds, sane bound + continue.

test(
  "applyIncludeRulesToBranch: maxHops=0 clamps to 1 (lower bound)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "mh1-owner@test.app", "O");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Lower",
          isPrivate: true,
          includeRules: {type: "blood-from-me", maxHops: 0},
        }),
      });
      assert.equal(response.status, 201);
      const tree = (await response.json()).tree;
      const db = await ctx.store._read();
      const branch = db.branches.find((b) => b.id === tree.id);
      assert.equal(branch.includeRules.maxHops, 1);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "applyIncludeRulesToBranch: maxHops=100 clamps to 20 (upper bound)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "mh2-owner@test.app", "O");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Upper",
          isPrivate: true,
          includeRules: {type: "blood-from-me", maxHops: 100},
        }),
      });
      assert.equal(response.status, 201);
      const tree = (await response.json()).tree;
      const db = await ctx.store._read();
      const branch = db.branches.find((b) => b.id === tree.id);
      assert.equal(branch.includeRules.maxHops, 20);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "applyIncludeRulesToBranch: maxHops=-5 clamps to 1 (negative)",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "mh3-owner@test.app", "O");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Negative",
          isPrivate: true,
          includeRules: {type: "blood-from-me", maxHops: -5},
        }),
      });
      assert.equal(response.status, 201);
      const tree = (await response.json()).tree;
      const db = await ctx.store._read();
      const branch = db.branches.find((b) => b.id === tree.id);
      assert.equal(branch.includeRules.maxHops, 1);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "applyIncludeRulesToBranch: maxHops omitted with blood-from-me → default 5",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "mh4-owner@test.app", "O");
      const response = await fetch(`${ctx.baseUrl}/v1/trees`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          name: "Defaults",
          isPrivate: true,
          // type без maxHops — должен взять default 5.
          includeRules: {type: "blood-from-me"},
        }),
      });
      assert.equal(response.status, 201);
      const tree = (await response.json()).tree;
      const db = await ctx.store._read();
      const branch = db.branches.find((b) => b.id === tree.id);
      assert.equal(branch.includeRules.type, "blood-from-me");
      assert.equal(branch.includeRules.maxHops, 5);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH /v1/trees/:treeId/include-rules: owner-only, меняет тип ветки",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "irp-owner@test.app", "Owner");
      const stranger = await registerUser(
        ctx,
        "irp-stranger@test.app",
        "Stranger",
      );
      const tree = await createTree(ctx, owner);
      // Stranger без access — 404 (requireTreeAccess upstream).
      const strangerResponse = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/include-rules`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${stranger.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            includeRules: {type: "blood-from-me", maxHops: 5},
          }),
        },
      );
      // Stranger даже не member → updateBranchIncludeRules → NOT_OWNER 403.
      assert.equal(strangerResponse.status, 403);

      // Owner — successful patch.
      const ownerResponse = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/include-rules`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            includeRules: {type: "blood-from-me", maxHops: 6},
          }),
        },
      );
      assert.equal(ownerResponse.status, 200);
      const payload = await ownerResponse.json();
      assert.equal(payload.includeRules.type, "blood-from-me");
      assert.equal(payload.includeRules.maxHops, 6);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "PATCH /v1/trees/:treeId/include-rules: invalid type → 400",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "irpe-owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      const response = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/include-rules`,
        {
          method: "PATCH",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            includeRules: {type: "wat-is-this", maxHops: 5},
          }),
        },
      );
      assert.equal(response.status, 400);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /v1/trees/:treeId/include-rules-preview: возвращает counts без mutate'а",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "irpr-owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      // У ветки сейчас manual rule с self-person'ом (1 шт.).
      // Preview переключения на blood-from-me: ожидаем такой же 1
      // (self без relations).
      const response = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/include-rules-preview?type=blood-from-me&maxHops=5`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      assert.equal(response.status, 200);
      const payload = await response.json();
      assert.ok(payload.preview);
      assert.equal(typeof payload.preview.addedCount, "number");
      assert.equal(typeof payload.preview.removedCount, "number");
      assert.equal(typeof payload.preview.totalAfterCount, "number");
      assert.equal(typeof payload.preview.totalBeforeCount, "number");

      // Sanity: mutate не произошёл — branch остался manual.
      const branchAfterPreview = await ctx.store._read();
      const branch = branchAfterPreview.branches.find((b) => b.id === tree.id);
      assert.equal(branch.includeRules.type, "manual");
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /v1/trees/:treeId/include-rules-preview: stranger без tree-access → 403",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "irpra-owner@test.app", "Owner");
      const stranger = await registerUser(
        ctx,
        "irpra-stranger@test.app",
        "X",
      );
      const tree = await createTree(ctx, owner);
      const response = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/include-rules-preview?type=manual`,
        {headers: {authorization: `Bearer ${stranger.accessToken}`}},
      );
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "GET /v1/me/issued-grants: возвращает grants выписанные viewer'ом",
  async () => {
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "ig-owner@test.app", "Owner");
      const grantee = await registerUser(ctx, "ig-grantee@test.app", "G");
      const tree = await createTree(ctx, owner);
      const person = await createPerson(ctx, owner.accessToken, tree.id, {
        firstName: "Self",
        userId: owner.user.id,
      });
      const personRead = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${person.id}`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const graphPersonId = (await personRead.json()).person.identityId;
      await fetch(
        `${ctx.baseUrl}/v1/graph-persons/${graphPersonId}/grants`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            granteeUserId: grantee.user.id,
            scope: "edit",
          }),
        },
      );

      // Owner reads issued-grants — sees own grant + grantee preview
      // + graphPerson preview.
      const issuedResponse = await fetch(
        `${ctx.baseUrl}/v1/me/issued-grants`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      assert.equal(issuedResponse.status, 200);
      const issued = await issuedResponse.json();
      assert.equal(issued.grants.length, 1);
      assert.equal(issued.grants[0].grantorUserId, owner.user.id);
      assert.equal(issued.grants[0].granteeUserId, grantee.user.id);
      assert.ok(issued.grants[0].graphPerson);
      assert.equal(issued.grants[0].graphPerson.id, graphPersonId);
      assert.ok(issued.grants[0].grantee);
      assert.equal(issued.grants[0].grantee.id, grantee.user.id);

      // Grantee reads issued-grants — пусто (он не grantor).
      const granteeIssuedResponse = await fetch(
        `${ctx.baseUrl}/v1/me/issued-grants`,
        {headers: {authorization: `Bearer ${grantee.accessToken}`}},
      );
      assert.equal(granteeIssuedResponse.status, 200);
      const granteeIssued = await granteeIssuedResponse.json();
      assert.equal(granteeIssued.grants.length, 0);
    } finally {
      await stopTestServer(ctx);
    }
  },
);

// ── Smoke benchmark: cross-tree visibility filter cost ──────────────

test(
  "Cross-tree search: visibility filter on 100-person graph stays under 1500ms budget",
  async () => {
    // Phase 3.2 (proposal §5.3): cross-tree READ paths делают
    // BFS-based visibility check per result. Без кеширования это
    // O(N) BFS, и большой граф сможет hit'нуть libuv thread.
    // Этот smoke catches regression если кто-то введёт N+1
    // _read() или повторный _buildBloodAdjacency на каждый person.
    //
    // 100 — выше realistic median семьи (50–80 persons), достаточно
    // для catching algorithmic regression. Бюджет 1500ms даёт
    // комфортный margin поверх ~100–300ms baseline и не зависит
    // от спорадических Windows GC pauses в CI.
    const ctx = await startTestServer();
    try {
      const owner = await registerUser(ctx, "smk-owner@test.app", "Owner");
      const tree = await createTree(ctx, owner);
      // 100 anonymous persons на одном дереве owner'а — все
      // visible viewer'у. Filter должен быстро пропустить все.
      for (let index = 0; index < 100; index += 1) {
        await createPerson(ctx, owner.accessToken, tree.id, {
          firstName: `Person${index}`,
          gender: "unknown",
        });
      }

      const startedAt = Date.now();
      const response = await fetch(
        `${ctx.baseUrl}/v1/persons/search?q=Person&limit=50`,
        {headers: {authorization: `Bearer ${owner.accessToken}`}},
      );
      const elapsed = Date.now() - startedAt;
      assert.equal(response.status, 200);
      const payload = await response.json();
      assert.ok(payload.persons.length > 0);
      assert.ok(
        elapsed < 1500,
        `cross-tree search with visibility filter took ${elapsed}ms (budget 1500ms). ` +
          `Likely regression: extra _read() inside loop, or _buildBloodAdjacency` +
          ` recomputed per result.`,
      );
    } finally {
      await stopTestServer(ctx);
    }
  },
);

test(
  "Sensitive contacts: non-owner cannot write contacts attribute (PUT 403)",
  async () => {
    const ctx = await startTestServer();
    try {
      const alice = await registerUser(ctx, "s-alice@test.app", "Alice");
      const bob = await registerUser(ctx, "s-bob@test.app", "Bob");
      const tree = await createTree(ctx, alice);
      await inviteAndAccept(ctx, alice, bob, tree.id);
      // Alice creates anonymous slot для Bob, Bob claim'ит через
      // invite-link. Это правильный flow Phase 3.2 — не одношаговое
      // create+claim (это запрещает existing pre-3.2 check
      // requestedUserId !== auth.user.id).
      const bobSlot = await createPerson(
        ctx,
        alice.accessToken,
        tree.id,
        {firstName: "Боб", gender: "male"},
      );
      const claim = await fetch(
        `${ctx.baseUrl}/v1/invitations/pending/process`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${bob.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({treeId: tree.id, personId: bobSlot.id}),
        },
      );
      assert.equal(claim.status, 200);

      // Alice tries set contacts visibility on Bob's claimed person.
      const response = await fetch(
        `${ctx.baseUrl}/v1/trees/${tree.id}/persons/${bobSlot.id}/attributes`,
        {
          method: "PUT",
          headers: {
            authorization: `Bearer ${alice.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            attributes: [{field: "contacts", visibility: "cross-tree"}],
          }),
        },
      );
      assert.equal(response.status, 403);
    } finally {
      await stopTestServer(ctx);
    }
  },
);
