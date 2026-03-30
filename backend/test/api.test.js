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
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "lineage-backend-"));
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
    wsBaseUrl: `ws://127.0.0.1:${server.address().port}`,
    server,
    tempDir,
  };
}

async function stopTestServer(ctx) {
  await new Promise((resolve, reject) => {
    ctx.server.close((error) => (error ? reject(error) : resolve()));
  });
  await fs.rm(ctx.tempDir, {recursive: true, force: true});
}

test("auth + profile bootstrap flow works end-to-end", async () => {
  const ctx = await startTestServer();

  try {
    const registerResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "dev@lineage.app",
        password: "secret123",
        displayName: "Dev User",
      }),
    });
    assert.equal(registerResponse.status, 201);
    const registered = await registerResponse.json();
    assert.equal(registered.user.email, "dev@lineage.app");
    assert.equal(registered.profileStatus.isComplete, false);

    const token = registered.accessToken;
    assert.ok(token);

    const sessionResponse = await fetch(`${ctx.baseUrl}/v1/auth/session`, {
      headers: {authorization: `Bearer ${token}`},
    });
    assert.equal(sessionResponse.status, 200);
    const session = await sessionResponse.json();
    assert.equal(session.user.id, registered.user.id);

    const bootstrapResponse = await fetch(
      `${ctx.baseUrl}/v1/profile/me/bootstrap`,
      {
        method: "PUT",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          firstName: "Иван",
          lastName: "Иванов",
          middleName: "Иванович",
          username: "ivanov",
          phoneNumber: "+79990001122",
          countryCode: "+7",
          countryName: "Россия",
          city: "Москва",
          gender: "male",
        }),
      },
    );
    assert.equal(bootstrapResponse.status, 200);
    const bootstrap = await bootstrapResponse.json();
    assert.equal(bootstrap.profile.firstName, "Иван");
    assert.equal(bootstrap.profileStatus.isComplete, true);

    const searchResponse = await fetch(
      `${ctx.baseUrl}/v1/users/search?query=ivanov`,
      {
        headers: {authorization: `Bearer ${token}`},
      },
    );
    assert.equal(searchResponse.status, 200);
    const search = await searchResponse.json();
    assert.equal(search.users.length, 1);
    assert.equal(search.users[0].username, "ivanov");
  } finally {
    await stopTestServer(ctx);
  }
});

test("file store stays readable during queued writes", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "lineage-store-"));
  const dataPath = path.join(tempDir, "dev-db.json");
  const store = new FileStore(dataPath);
  await store.initialize();

  const largeBio = "x".repeat(256 * 1024);

  try {
    const operations = [];
    for (let index = 0; index < 12; index += 1) {
      operations.push(
        store._write({
          users: [],
          sessions: [],
          trees: [],
          persons: [
            {
              id: `person-${index}`,
              treeId: "tree-1",
              name: `Person ${index}`,
              bio: `${largeBio}-${index}`,
            },
          ],
          relations: [],
          messages: [],
          relationRequests: [],
          treeInvitations: [],
          notifications: [],
          pushDevices: [],
          pushDeliveries: [],
        }),
      );
      operations.push(store._read());
    }

    const results = await Promise.all(operations);
    const readSnapshots = results.filter((value) => value && value.persons);
    assert.ok(readSnapshots.length >= 12);
    assert.ok(
      readSnapshots.every(
        (snapshot) =>
          Array.isArray(snapshot.persons) && snapshot.persons.length <= 1,
      ),
    );
  } finally {
    await fs.rm(tempDir, {recursive: true, force: true});
  }
});

test("google auth endpoint is explicit stub in minimal backend", async () => {
  const ctx = await startTestServer();

  try {
    const response = await fetch(`${ctx.baseUrl}/v1/auth/google`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: "{}",
    });
    assert.equal(response.status, 501);
    const payload = await response.json();
    assert.match(payload.message, /Google sign-in/i);
  } finally {
    await stopTestServer(ctx);
  }
});

test("profile notes and media endpoints work for authenticated user", async () => {
  const ctx = await startTestServer();

  try {
    const registerResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "notes@lineage.app",
        password: "secret123",
        displayName: "Notes User",
      }),
    });
    assert.equal(registerResponse.status, 201);
    const registered = await registerResponse.json();
    const token = registered.accessToken;
    const userId = registered.user.id;

    const createNoteResponse = await fetch(
      `${ctx.baseUrl}/v1/users/${userId}/profile-notes`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          title: "Семейная история",
          content: "Первая заметка профиля",
        }),
      },
    );
    assert.equal(createNoteResponse.status, 201);
    const createdNotePayload = await createNoteResponse.json();
    assert.equal(createdNotePayload.note.title, "Семейная история");

    const noteId = createdNotePayload.note.id;
    assert.ok(noteId);

    const listNotesResponse = await fetch(
      `${ctx.baseUrl}/v1/users/${userId}/profile-notes`,
      {
        headers: {authorization: `Bearer ${token}`},
      },
    );
    assert.equal(listNotesResponse.status, 200);
    const listedNotes = await listNotesResponse.json();
    assert.equal(listedNotes.notes.length, 1);

    const updateNoteResponse = await fetch(
      `${ctx.baseUrl}/v1/users/${userId}/profile-notes/${noteId}`,
      {
        method: "PATCH",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          title: "Обновлённая история",
          content: "Исправленный текст заметки",
        }),
      },
    );
    assert.equal(updateNoteResponse.status, 200);
    const updatedNotePayload = await updateNoteResponse.json();
    assert.equal(updatedNotePayload.note.title, "Обновлённая история");

    const uploadResponse = await fetch(`${ctx.baseUrl}/v1/media/upload`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        bucket: "avatars",
        path: `${userId}/avatar.txt`,
        contentType: "text/plain",
        fileBase64: Buffer.from("avatar").toString("base64"),
      }),
    });
    assert.equal(uploadResponse.status, 201);
    const uploadedMedia = await uploadResponse.json();
    assert.match(uploadedMedia.url, /\/media\/avatars\//);

    const mediaResponse = await fetch(uploadedMedia.url);
    assert.equal(mediaResponse.status, 200);
    assert.equal(await mediaResponse.text(), "avatar");

    const deleteMediaResponse = await fetch(`${ctx.baseUrl}/v1/media`, {
      method: "DELETE",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({url: uploadedMedia.url}),
    });
    assert.equal(deleteMediaResponse.status, 204);

    const deleteNoteResponse = await fetch(
      `${ctx.baseUrl}/v1/users/${userId}/profile-notes/${noteId}`,
      {
        method: "DELETE",
        headers: {authorization: `Bearer ${token}`},
      },
    );
    assert.equal(deleteNoteResponse.status, 204);
  } finally {
    await stopTestServer(ctx);
  }
});

test("tree endpoints cover create tree, persons and relations", async () => {
  const ctx = await startTestServer();

  try {
    const registerResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "tree@lineage.app",
        password: "secret123",
        displayName: "Иван Иванов",
      }),
    });
    assert.equal(registerResponse.status, 201);
    const registered = await registerResponse.json();
    const token = registered.accessToken;
    const userId = registered.user.id;

    const createTreeResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        name: "Семья Ивановых",
        description: "Основное семейное дерево",
        isPrivate: true,
      }),
    });
    assert.equal(createTreeResponse.status, 201);
    const createdTreePayload = await createTreeResponse.json();
    assert.equal(createdTreePayload.tree.name, "Семья Ивановых");
    const treeId = createdTreePayload.tree.id;

    const listTreesResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      headers: {authorization: `Bearer ${token}`},
    });
    assert.equal(listTreesResponse.status, 200);
    const listedTreesPayload = await listTreesResponse.json();
    assert.equal(listedTreesPayload.trees.length, 1);
    assert.equal(listedTreesPayload.trees[0].memberIds[0], userId);

    const selectableTreesResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/selectable`,
      {
        headers: {authorization: `Bearer ${token}`},
      },
    );
    assert.equal(selectableTreesResponse.status, 200);
    const selectableTrees = await selectableTreesResponse.json();
    assert.equal(selectableTrees.trees.length, 1);

    const personsResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {
        headers: {authorization: `Bearer ${token}`},
      },
    );
    assert.equal(personsResponse.status, 200);
    const initialPersonsPayload = await personsResponse.json();
    assert.equal(initialPersonsPayload.persons.length, 1);
    assert.equal(initialPersonsPayload.persons[0].userId, userId);
    const creatorPersonId = initialPersonsPayload.persons[0].id;

    const createPersonResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          firstName: "Мария",
          lastName: "Иванова",
          gender: "female",
        }),
      },
    );
    assert.equal(createPersonResponse.status, 201);
    const createdPersonPayload = await createPersonResponse.json();
    assert.equal(createdPersonPayload.person.name, "Иванова Мария");
    const childPersonId = createdPersonPayload.person.id;

    const createRelationResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/relations`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          person1Id: creatorPersonId,
          person2Id: childPersonId,
          relation1to2: "parent",
          isConfirmed: true,
        }),
      },
    );
    assert.equal(createRelationResponse.status, 201);
    const createdRelationPayload = await createRelationResponse.json();
    assert.equal(createdRelationPayload.relation.relation1to2, "parent");
    assert.equal(createdRelationPayload.relation.relation2to1, "child");

    const listRelationsResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/relations`,
      {
        headers: {authorization: `Bearer ${token}`},
      },
    );
    assert.equal(listRelationsResponse.status, 200);
    const listedRelationsPayload = await listRelationsResponse.json();
    assert.equal(listedRelationsPayload.relations.length, 1);
  } finally {
    await stopTestServer(ctx);
  }
});

test("public tree endpoints expose read-only tree data without auth", async () => {
  const ctx = await startTestServer();

  try {
    const registerResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "public-tree@lineage.app",
        password: "secret123",
        displayName: "Публичный Автор",
      }),
    });
    assert.equal(registerResponse.status, 201);
    const registered = await registerResponse.json();
    const token = registered.accessToken;

    const createTreeResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        name: "Открытое дерево",
        description: "Дерево для публичного просмотра",
        isPrivate: false,
      }),
    });
    assert.equal(createTreeResponse.status, 201);
    const createdTreePayload = await createTreeResponse.json();
    const treeId = createdTreePayload.tree.id;

    const initialPersonsResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {headers: {authorization: `Bearer ${token}`}},
    );
    assert.equal(initialPersonsResponse.status, 200);
    const initialPersonsPayload = await initialPersonsResponse.json();
    const creatorPersonId = initialPersonsPayload.persons[0].id;

    const createPersonResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          firstName: "Анна",
          lastName: "Публичная",
          gender: "female",
        }),
      },
    );
    assert.equal(createPersonResponse.status, 201);
    const createdPersonPayload = await createPersonResponse.json();
    const secondPersonId = createdPersonPayload.person.id;

    const relationResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/relations`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          person1Id: creatorPersonId,
          person2Id: secondPersonId,
          relation1to2: "sibling",
          isConfirmed: true,
        }),
      },
    );
    assert.equal(relationResponse.status, 201);

    const previewResponse = await fetch(
      `${ctx.baseUrl}/v1/public/trees/${treeId}`,
    );
    assert.equal(previewResponse.status, 200);
    const previewPayload = await previewResponse.json();
    assert.equal(previewPayload.tree.name, "Открытое дерево");
    assert.equal(previewPayload.tree.isPrivate, false);
    assert.equal(previewPayload.stats.peopleCount, 2);
    assert.equal(previewPayload.stats.relationsCount, 1);

    const personsResponse = await fetch(
      `${ctx.baseUrl}/v1/public/trees/${treeId}/persons`,
    );
    assert.equal(personsResponse.status, 200);
    const personsPayload = await personsResponse.json();
    assert.equal(personsPayload.persons.length, 2);

    const relationsResponse = await fetch(
      `${ctx.baseUrl}/v1/public/trees/${treeId}/relations`,
    );
    assert.equal(relationsResponse.status, 200);
    const relationsPayload = await relationsResponse.json();
    assert.equal(relationsPayload.relations.length, 1);

    const privatePreviewResponse = await fetch(
      `${ctx.baseUrl}/v1/public/trees/missing-tree`,
    );
    assert.equal(privatePreviewResponse.status, 404);
  } finally {
    await stopTestServer(ctx);
  }
});

test("chat endpoints cover preview list, history, send and mark as read", async () => {
  const ctx = await startTestServer();

  try {
    const registerAliceResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "alice@lineage.app",
        password: "secret123",
        displayName: "Alice",
      }),
    });
    assert.equal(registerAliceResponse.status, 201);
    const alice = await registerAliceResponse.json();

    const registerBobResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "bob@lineage.app",
        password: "secret123",
        displayName: "Bob",
      }),
    });
    assert.equal(registerBobResponse.status, 201);
    const bob = await registerBobResponse.json();

    const createChatResponse = await fetch(`${ctx.baseUrl}/v1/chats/direct`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${alice.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({otherUserId: bob.user.id}),
    });
    assert.equal(createChatResponse.status, 200);
    const directChat = await createChatResponse.json();
    assert.ok(directChat.chatId);

    const sendMessageResponse = await fetch(
      `${ctx.baseUrl}/v1/chats/${directChat.chatId}/messages`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${alice.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({text: "Привет, Боб!"}),
      },
    );
    assert.equal(sendMessageResponse.status, 201);
    const sentMessagePayload = await sendMessageResponse.json();
    assert.equal(sentMessagePayload.message.text, "Привет, Боб!");

    const aliceChatsResponse = await fetch(`${ctx.baseUrl}/v1/chats`, {
      headers: {authorization: `Bearer ${alice.accessToken}`},
    });
    assert.equal(aliceChatsResponse.status, 200);
    const aliceChats = await aliceChatsResponse.json();
    assert.equal(aliceChats.chats.length, 1);
    assert.equal(aliceChats.chats[0].otherUserId, bob.user.id);
    assert.equal(aliceChats.chats[0].unreadCount, 0);

    const bobChatsResponse = await fetch(`${ctx.baseUrl}/v1/chats`, {
      headers: {authorization: `Bearer ${bob.accessToken}`},
    });
    assert.equal(bobChatsResponse.status, 200);
    const bobChats = await bobChatsResponse.json();
    assert.equal(bobChats.chats.length, 1);
    assert.equal(bobChats.chats[0].unreadCount, 1);

    const unreadResponse = await fetch(`${ctx.baseUrl}/v1/chats/unread-count`, {
      headers: {authorization: `Bearer ${bob.accessToken}`},
    });
    assert.equal(unreadResponse.status, 200);
    const unreadPayload = await unreadResponse.json();
    assert.equal(unreadPayload.totalUnread, 1);

    const historyResponse = await fetch(
      `${ctx.baseUrl}/v1/chats/${directChat.chatId}/messages`,
      {
        headers: {authorization: `Bearer ${bob.accessToken}`},
      },
    );
    assert.equal(historyResponse.status, 200);
    const historyPayload = await historyResponse.json();
    assert.equal(historyPayload.messages.length, 1);
    assert.equal(historyPayload.messages[0].senderId, alice.user.id);

    const markReadResponse = await fetch(
      `${ctx.baseUrl}/v1/chats/${directChat.chatId}/read`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${bob.accessToken}`,
          "content-type": "application/json",
        },
        body: "{}",
      },
    );
    assert.equal(markReadResponse.status, 200);

    const unreadAfterReadResponse = await fetch(
      `${ctx.baseUrl}/v1/chats/unread-count`,
      {
        headers: {authorization: `Bearer ${bob.accessToken}`},
      },
    );
    assert.equal(unreadAfterReadResponse.status, 200);
    const unreadAfterReadPayload = await unreadAfterReadResponse.json();
    assert.equal(unreadAfterReadPayload.totalUnread, 0);
  } finally {
    await stopTestServer(ctx);
  }
});

test("relation requests and invite processing work on custom backend", async () => {
  const ctx = await startTestServer();

  try {
    const registerOwnerResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "owner@lineage.app",
        password: "secret123",
        displayName: "Owner User",
      }),
    });
    assert.equal(registerOwnerResponse.status, 201);
    const owner = await registerOwnerResponse.json();

    const registerRecipientResponse = await fetch(
      `${ctx.baseUrl}/v1/auth/register`,
      {
        method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify({
          email: "recipient@lineage.app",
          password: "secret123",
          displayName: "Recipient User",
        }),
      },
    );
    assert.equal(registerRecipientResponse.status, 201);
    const recipient = await registerRecipientResponse.json();

    const createTreeResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${owner.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        name: "Дерево запросов",
        description: "Тест relation requests",
        isPrivate: true,
      }),
    });
    assert.equal(createTreeResponse.status, 201);
    const createdTree = await createTreeResponse.json();
    const treeId = createdTree.tree.id;

    const initialPersonsResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {
        headers: {authorization: `Bearer ${owner.accessToken}`},
      },
    );
    assert.equal(initialPersonsResponse.status, 200);
    const initialPersons = await initialPersonsResponse.json();
    const ownerPersonId = initialPersons.persons[0].id;

    const createOfflinePersonResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          firstName: "Offline",
          lastName: "Relative",
          gender: "female",
        }),
      },
    );
    assert.equal(createOfflinePersonResponse.status, 201);
    const offlinePersonPayload = await createOfflinePersonResponse.json();
    const offlinePersonId = offlinePersonPayload.person.id;

    const sendDirectRequestResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/relation-requests`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          recipientId: recipient.user.id,
          senderToRecipient: "sibling",
          message: "Подтверди родство",
        }),
      },
    );
    assert.equal(sendDirectRequestResponse.status, 201);
    const directRequestPayload = await sendDirectRequestResponse.json();

    const pendingResponse = await fetch(
      `${ctx.baseUrl}/v1/relation-requests/pending?treeId=${treeId}`,
      {
        headers: {authorization: `Bearer ${recipient.accessToken}`},
      },
    );
    assert.equal(pendingResponse.status, 200);
    const pendingPayload = await pendingResponse.json();
    assert.equal(pendingPayload.requests.length, 1);

    const acceptResponse = await fetch(
      `${ctx.baseUrl}/v1/relation-requests/${directRequestPayload.request.id}/respond`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${recipient.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({response: "accepted"}),
      },
    );
    assert.equal(acceptResponse.status, 200);
    const acceptedPayload = await acceptResponse.json();
    assert.equal(acceptedPayload.request.status, "accepted");
    assert.equal(acceptedPayload.relation.relation1to2, "sibling");

    const personsAfterAcceptResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/persons`,
      {
        headers: {authorization: `Bearer ${owner.accessToken}`},
      },
    );
    assert.equal(personsAfterAcceptResponse.status, 200);
    const personsAfterAccept = await personsAfterAcceptResponse.json();
    assert.equal(personsAfterAccept.persons.length, 3);
    assert.ok(
      personsAfterAccept.persons.some((person) => person.userId === recipient.user.id),
    );

    const relationsAfterAcceptResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/relations`,
      {
        headers: {authorization: `Bearer ${owner.accessToken}`},
      },
    );
    assert.equal(relationsAfterAcceptResponse.status, 200);
    const relationsAfterAccept = await relationsAfterAcceptResponse.json();
    assert.equal(relationsAfterAccept.relations.length, 1);
    assert.equal(relationsAfterAccept.relations[0].person1Id, ownerPersonId);

    const inviteProcessResponse = await fetch(
      `${ctx.baseUrl}/v1/invitations/pending/process`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${recipient.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          treeId,
          personId: offlinePersonId,
        }),
      },
    );
    assert.equal(inviteProcessResponse.status, 200);
    const inviteProcessPayload = await inviteProcessResponse.json();
    assert.equal(inviteProcessPayload.person.userId, recipient.user.id);
  } finally {
    await stopTestServer(ctx);
  }
});

test("tree invitations support pending list and accept flow", async () => {
  const ctx = await startTestServer();

  try {
    const ownerResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "tree-owner@lineage.app",
        password: "secret123",
        displayName: "Tree Owner",
      }),
    });
    assert.equal(ownerResponse.status, 201);
    const owner = await ownerResponse.json();

    const inviteeResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "tree-invitee@lineage.app",
        password: "secret123",
        displayName: "Tree Invitee",
      }),
    });
    assert.equal(inviteeResponse.status, 201);
    const invitee = await inviteeResponse.json();

    const createTreeResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${owner.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        name: "Приглашения в дерево",
        description: "Тест pending tree invites",
        isPrivate: true,
      }),
    });
    assert.equal(createTreeResponse.status, 201);
    const treePayload = await createTreeResponse.json();
    const treeId = treePayload.tree.id;

    const createInvitationResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/invitations`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${owner.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          recipientUserId: invitee.user.id,
          relationToTree: "родственник",
        }),
      },
    );
    assert.equal(createInvitationResponse.status, 201);
    const createdInvitation = await createInvitationResponse.json();
    assert.equal(createdInvitation.invitation.tree.id, treeId);

    const pendingInvitationsResponse = await fetch(
      `${ctx.baseUrl}/v1/tree-invitations/pending`,
      {
        headers: {authorization: `Bearer ${invitee.accessToken}`},
      },
    );
    assert.equal(pendingInvitationsResponse.status, 200);
    const pendingInvitations = await pendingInvitationsResponse.json();
    assert.equal(pendingInvitations.invitations.length, 1);
    assert.equal(pendingInvitations.invitations[0].tree.name, "Приглашения в дерево");

    const acceptInvitationResponse = await fetch(
      `${ctx.baseUrl}/v1/tree-invitations/${createdInvitation.invitation.invitationId}/respond`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${invitee.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({accept: true}),
      },
    );
    assert.equal(acceptInvitationResponse.status, 200);
    const acceptPayload = await acceptInvitationResponse.json();
    assert.equal(acceptPayload.accepted, true);

    const userTreesResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      headers: {authorization: `Bearer ${invitee.accessToken}`},
    });
    assert.equal(userTreesResponse.status, 200);
    const userTreesPayload = await userTreesResponse.json();
    assert.equal(userTreesPayload.trees.length, 1);
    assert.equal(userTreesPayload.trees[0].id, treeId);
  } finally {
    await stopTestServer(ctx);
  }
});

test("notification feed tracks unread events from chat, relation requests and tree invites", async () => {
  const ctx = await startTestServer();

  try {
    const aliceResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "notify-alice@lineage.app",
        password: "secret123",
        displayName: "Alice",
      }),
    });
    assert.equal(aliceResponse.status, 201);
    const alice = await aliceResponse.json();

    const bobResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "notify-bob@lineage.app",
        password: "secret123",
        displayName: "Bob",
      }),
    });
    assert.equal(bobResponse.status, 201);
    const bob = await bobResponse.json();

    const createTreeResponse = await fetch(`${ctx.baseUrl}/v1/trees`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${alice.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        name: "Уведомления",
        description: "Тест уведомлений",
        isPrivate: true,
      }),
    });
    assert.equal(createTreeResponse.status, 201);
    const treePayload = await createTreeResponse.json();
    const treeId = treePayload.tree.id;

    const relationRequestResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/relation-requests`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${alice.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          recipientId: bob.user.id,
          senderToRecipient: "sibling",
        }),
      },
    );
    assert.equal(relationRequestResponse.status, 201);

    const treeInvitationResponse = await fetch(
      `${ctx.baseUrl}/v1/trees/${treeId}/invitations`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${alice.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          recipientUserId: bob.user.id,
        }),
      },
    );
    assert.equal(treeInvitationResponse.status, 201);

    const directChatResponse = await fetch(`${ctx.baseUrl}/v1/chats/direct`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${alice.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({otherUserId: bob.user.id}),
    });
    assert.equal(directChatResponse.status, 200);
    const chatPayload = await directChatResponse.json();

    const sendMessageResponse = await fetch(
      `${ctx.baseUrl}/v1/chats/${chatPayload.chatId}/messages`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${alice.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({text: "Привет из уведомлений"}),
      },
    );
    assert.equal(sendMessageResponse.status, 201);

    const unreadCountResponse = await fetch(
      `${ctx.baseUrl}/v1/notifications/unread-count`,
      {
        headers: {authorization: `Bearer ${bob.accessToken}`},
      },
    );
    assert.equal(unreadCountResponse.status, 200);
    const unreadCount = await unreadCountResponse.json();
    assert.equal(unreadCount.totalUnread, 3);

    const notificationsResponse = await fetch(
      `${ctx.baseUrl}/v1/notifications?status=unread&limit=10`,
      {
        headers: {authorization: `Bearer ${bob.accessToken}`},
      },
    );
    assert.equal(notificationsResponse.status, 200);
    const notificationsPayload = await notificationsResponse.json();
    assert.equal(notificationsPayload.notifications.length, 3);
    assert.ok(
      notificationsPayload.notifications.some(
        (notification) => notification.type === "chat_message",
      ),
    );
    assert.ok(
      notificationsPayload.notifications.some(
        (notification) => notification.type === "relation_request",
      ),
    );
    assert.ok(
      notificationsPayload.notifications.some(
        (notification) => notification.type === "tree_invitation",
      ),
    );

    const readResponse = await fetch(
      `${ctx.baseUrl}/v1/notifications/${notificationsPayload.notifications[0].id}/read`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${bob.accessToken}`,
          "content-type": "application/json",
        },
        body: "{}",
      },
    );
    assert.equal(readResponse.status, 200);

    const unreadAfterReadResponse = await fetch(
      `${ctx.baseUrl}/v1/notifications/unread-count`,
      {
        headers: {authorization: `Bearer ${bob.accessToken}`},
      },
    );
    assert.equal(unreadAfterReadResponse.status, 200);
    const unreadAfterRead = await unreadAfterReadResponse.json();
    assert.equal(unreadAfterRead.totalUnread, 2);
  } finally {
    await stopTestServer(ctx);
  }
});

test("websocket realtime and push queue work for chat delivery", async () => {
  const ctx = await startTestServer();

  try {
    const aliceResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "ws-alice@lineage.app",
        password: "secret123",
        displayName: "Alice WS",
      }),
    });
    assert.equal(aliceResponse.status, 201);
    const alice = await aliceResponse.json();

    const bobResponse = await fetch(`${ctx.baseUrl}/v1/auth/register`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: "ws-bob@lineage.app",
        password: "secret123",
        displayName: "Bob WS",
      }),
    });
    assert.equal(bobResponse.status, 201);
    const bob = await bobResponse.json();

    const pushDeviceResponse = await fetch(`${ctx.baseUrl}/v1/push/devices`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${bob.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        provider: "rustore",
        token: "rustore-test-token",
        platform: "android",
      }),
    });
    assert.equal(pushDeviceResponse.status, 201);

    const socket = new WebSocket(
      `${ctx.wsBaseUrl}/v1/realtime?accessToken=${bob.accessToken}`,
    );

    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, {once: true});
      socket.addEventListener("error", reject, {once: true});
    });

    const observedEvents = [];
    const eventPromise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("Timed out waiting for realtime chat events"));
      }, 3000);

      socket.addEventListener("message", (event) => {
        const payload = JSON.parse(String(event.data));
        observedEvents.push(payload);

        const hasReady = observedEvents.some(
          (item) => item.type === "connection.ready",
        );
        const hasChatEvent = observedEvents.some(
          (item) => item.type === "chat.message.created",
        );
        const hasNotificationEvent = observedEvents.some(
          (item) =>
            item.type === "notification.created" &&
            item.notification?.type === "chat_message",
        );

        if (hasReady && hasChatEvent && hasNotificationEvent) {
          clearTimeout(timer);
          resolve(observedEvents);
        }
      });
    });

    const createChatResponse = await fetch(`${ctx.baseUrl}/v1/chats/direct`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${alice.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({otherUserId: bob.user.id}),
    });
    assert.equal(createChatResponse.status, 200);
    const chatPayload = await createChatResponse.json();

    const sendMessageResponse = await fetch(
      `${ctx.baseUrl}/v1/chats/${chatPayload.chatId}/messages`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${alice.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({text: "Realtime привет"}),
      },
    );
    assert.equal(sendMessageResponse.status, 201);

    const realtimeEvents = await eventPromise;
    assert.ok(
      realtimeEvents.some((item) => item.type === "connection.ready"),
    );
    assert.ok(
      realtimeEvents.some(
        (item) =>
          item.type === "chat.message.created" &&
          item.message?.text === "Realtime привет",
      ),
    );
    assert.ok(
      realtimeEvents.some(
        (item) =>
          item.type === "notification.created" &&
          item.notification?.type === "chat_message",
      ),
    );

    const deliveriesResponse = await fetch(
      `${ctx.baseUrl}/v1/push/deliveries?limit=10`,
      {
        headers: {authorization: `Bearer ${bob.accessToken}`},
      },
    );
    assert.equal(deliveriesResponse.status, 200);
    const deliveriesPayload = await deliveriesResponse.json();
    assert.ok(deliveriesPayload.deliveries.length >= 1);
    assert.ok(
      deliveriesPayload.deliveries.some(
        (delivery) =>
          delivery.provider === "rustore" && delivery.status === "queued",
      ),
    );

    socket.close();
  } finally {
    await stopTestServer(ctx);
  }
});
