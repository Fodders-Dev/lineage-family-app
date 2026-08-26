// SPEED-6: сквозные тесты табличных чат-методов PostgresStore на pg-mem —
// НАСТОЯЩИЙ SQL стора: бут-миграция блоб→таблицы, отправка = INSERT,
// dedup, виртуальные direct-чаты, пагинация, receipts, реакции, черновики,
// пины, поиск, TTL и каскады deleteUser.
const test = require("node:test");
const assert = require("node:assert/strict");

const {newDb} = require("pg-mem");
const {PostgresStore} = require("../src/postgres-store");

const USERS = [
  {id: "user-1", email: "ivan@rodnya-tree.ru", profile: {displayName: "Иван"}},
  {id: "user-2", email: "anna@rodnya-tree.ru", profile: {displayName: "Анна"}},
  {id: "user-3", email: "boris@rodnya-tree.ru", profile: {displayName: "Борис"}},
];

const GROUP_CHAT = {
  id: "chat_group-1",
  type: "group",
  title: "Семейный чат",
  participantIds: ["user-1", "user-2", "user-3"],
  createdAt: "2026-04-21T10:00:00.000Z",
  updatedAt: "2026-04-21T10:00:00.000Z",
};

function buildStore(seededState) {
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  const pool = {
    query: (sql, params) => {
      let effectiveParams = params;
      if (
        String(sql).includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seededState)];
      }
      return rawPool.query(sql, effectiveParams);
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });
  return {store, rawPool};
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("chat tables: send is an INSERT with sender name from projection", async () => {
  const {store, rawPool} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const message = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-2",
    text: "Привет всем",
    clientMessageId: "cli-1",
  });
  assert.ok(message?.id);
  assert.equal(message.chatId, "chat_group-1");
  assert.equal(message.senderName, "Анна");
  assert.deepEqual(message.deliveredTo, ["user-2"]);
  assert.deepEqual(message.readBy, ["user-2"]);
  assert.deepEqual(message.reactions, []);
  assert.equal(message._deduplicated, undefined);

  const rows = await rawPool.query(
    `SELECT chat_id, sender_id, client_message_id FROM "public"."rodnya_state_chat_messages"`,
  );
  assert.equal(rows.rows.length, 1);
  assert.equal(rows.rows[0].client_message_id, "cli-1");

  // Дубликат по clientMessageId возвращает существующее сообщение без записи.
  const duplicate = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-2",
    text: "Привет всем",
    clientMessageId: "cli-1",
  });
  assert.equal(duplicate._deduplicated, true);
  assert.equal(duplicate.id, message.id);
  const afterDuplicate = await rawPool.query(
    `SELECT id FROM "public"."rodnya_state_chat_messages"`,
  );
  assert.equal(afterDuplicate.rows.length, 1);

  // Не-участник и слишком короткий чат отклоняются как в FileStore.
  assert.equal(
    await store.addChatMessage({chatId: "chat_group-1", senderId: "stranger", text: "hi"}),
    null,
  );
  assert.equal(
    await store.addChatMessage({chatId: "chat_group-1", senderId: "user-1", text: "   "}),
    false,
  );
});

test("chat tables: virtual direct chat resolves, canonicalizes and materializes", async () => {
  const {store} = buildStore({users: USERS, chats: []});
  await store.initialize();

  // Отправка по alias-id (b_a) без сохранённого чата.
  const message = await store.addChatMessage({
    chatId: "user-2_user-1",
    senderId: "user-1",
    text: "Первое сообщение",
  });
  assert.equal(message.chatId, "user-1_user-2");

  const chat = await store.findChat("user-2_user-1");
  assert.equal(chat?.id, "user-1_user-2");
  assert.deepEqual(chat?.participantIds, ["user-1", "user-2"]);

  // Фоновая материализация кладёт запись чата в блоб (и в projection).
  await wait(80);
  const stored = await store.findChat("user-1_user-2");
  assert.equal(stored?.id, "user-1_user-2");
  const state = await store._read();
  assert.ok(state.chats.some((entry) => entry.id === "user-1_user-2"));

  const previews = await store.listChatPreviews("user-1");
  assert.equal(previews.length, 1);
  assert.equal(previews[0].chatId, "user-1_user-2");
  assert.equal(previews[0].lastMessage, "Первое сообщение");
});

test("chat tables: pagination cursors match FileStore semantics", async () => {
  const {store} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const sent = [];
  for (let i = 1; i <= 5; i += 1) {
    sent.push(
      await store.addChatMessage({
        chatId: "chat_group-1",
        senderId: "user-1",
        text: `сообщение ${i}`,
      }),
    );
    await wait(3);
  }
  const [m1, m2, m3, m4, m5] = sent;

  const newestFirst = await store.listChatMessages("chat_group-1", {limit: 10});
  assert.deepEqual(
    newestFirst.map((m) => m.id),
    [m5.id, m4.id, m3.id, m2.id, m1.id],
  );

  const older = await store.listChatMessages("chat_group-1", {
    limit: 2,
    beforeId: m4.id,
  });
  assert.deepEqual(older.map((m) => m.id), [m3.id, m2.id]);

  const newer = await store.listChatMessages("chat_group-1", {
    limit: 10,
    afterId: m2.id,
  });
  assert.deepEqual(newer.map((m) => m.id), [m5.id, m4.id, m3.id]);

  // Неизвестный курсор => пустая страница (interior-hole reconcile клиента).
  assert.deepEqual(
    await store.listChatMessages("chat_group-1", {limit: 5, beforeId: "missing"}),
    [],
  );
});

test("chat tables: delivered/read receipts and unread counters", async () => {
  const {store} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const message = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-1",
    text: "Непрочитанное",
  });

  assert.equal(await store.countUnreadChatMessages("user-2"), 1);
  assert.equal(await store.countUnreadChatMessages("user-1"), 0);

  const delivered = await store.markChatMessageDelivered({
    chatId: "chat_group-1",
    messageId: message.id,
    userIds: ["user-2", "user-1", "stranger"],
  });
  assert.deepEqual(delivered.changedUserIds, ["user-2"]);
  assert.ok(delivered.deliveredTo.includes("user-2"));

  const readResult = await store.markChatAsRead("chat_group-1", "user-2");
  assert.equal(readResult.changed, true);
  assert.deepEqual(readResult.messageIds, [message.id]);
  assert.equal(await store.countUnreadChatMessages("user-2"), 0);

  const [latest] = await store.listChatMessages("chat_group-1", {limit: 1});
  assert.ok(latest.readBy.includes("user-2"));
  assert.ok(latest.deliveredTo.includes("user-2"));
  assert.equal(latest.isRead, true);

  // Повторное прочтение ничего не меняет.
  const repeat = await store.markChatAsRead("chat_group-1", "user-2");
  assert.equal(repeat.changed, false);
});

test("chat tables: reactions toggle and aggregate", async () => {
  const {store} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const message = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-1",
    text: "Реакции",
  });

  const added = await store.toggleChatMessageReaction({
    chatId: "chat_group-1",
    messageId: message.id,
    userId: "user-2",
    emoji: "❤️",
  });
  assert.equal(added.added, true);
  assert.deepEqual(added.reactions, [{emoji: "❤️", userIds: ["user-2"], count: 1}]);

  await store.toggleChatMessageReaction({
    chatId: "chat_group-1",
    messageId: message.id,
    userId: "user-3",
    emoji: "❤️",
  });
  const [withReactions] = await store.listChatMessages("chat_group-1", {limit: 1});
  assert.deepEqual(withReactions.reactions, [
    {emoji: "❤️", userIds: ["user-2", "user-3"], count: 2},
  ]);

  const removed = await store.toggleChatMessageReaction({
    chatId: "chat_group-1",
    messageId: message.id,
    userId: "user-2",
    emoji: "❤️",
  });
  assert.equal(removed.added, false);
  assert.deepEqual(removed.reactions, [{emoji: "❤️", userIds: ["user-3"], count: 1}]);

  assert.equal(
    await store.toggleChatMessageReaction({
      chatId: "chat_group-1",
      messageId: message.id,
      userId: "user-2",
      emoji: "   ",
    }),
    "INVALID_EMOJI",
  );
});

test("chat tables: edit and delete keep FileStore return codes and cascades", async () => {
  const {store, rawPool} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const message = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-1",
    text: "Оригинал",
  });

  // Чужое сообщение нельзя ни править, ни удалять.
  assert.equal(
    await store.updateChatMessage({
      chatId: "chat_group-1",
      messageId: message.id,
      userId: "user-2",
      text: "хак",
    }),
    undefined,
  );
  assert.equal(
    await store.deleteChatMessage({
      chatId: "chat_group-1",
      messageId: message.id,
      userId: "user-2",
    }),
    undefined,
  );

  const edited = await store.updateChatMessage({
    chatId: "chat_group-1",
    messageId: message.id,
    userId: "user-1",
    text: "Исправлено",
  });
  assert.equal(edited.text, "Исправлено");
  assert.ok(edited.updatedAt);

  assert.equal(
    await store.updateChatMessage({
      chatId: "chat_group-1",
      messageId: message.id,
      userId: "user-1",
      text: "   ",
    }),
    "EMPTY_MESSAGE",
  );

  // Пин на сообщение, затем удаление сообщения снимает пин.
  await store.pinChatMessage({
    userId: "user-2",
    chatId: "chat_group-1",
    messageId: message.id,
  });
  const deleted = await store.deleteChatMessage({
    chatId: "chat_group-1",
    messageId: message.id,
    userId: "user-1",
  });
  assert.equal(deleted.id, message.id);
  assert.equal(deleted._clearedPinnedMessage, true);
  const rows = await rawPool.query(
    `SELECT id FROM "public"."rodnya_state_chat_messages"`,
  );
  assert.equal(rows.rows.length, 0);
  assert.equal(
    await store.getChatPinnedMessage({userId: "user-2", chatId: "chat_group-1"}),
    null,
  );
});

test("chat tables: drafts save, list, clear", async () => {
  const {store} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const draft = await store.saveChatDraft({
    userId: "user-1",
    chatId: "chat_group-1",
    text: "  черновик с пробелом",
  });
  assert.equal(draft.text, "  черновик с пробелом");

  const fetched = await store.getChatDraft({userId: "user-1", chatId: "chat_group-1"});
  assert.equal(fetched?.text, "  черновик с пробелом");

  const listed = await store.listChatDrafts("user-1");
  assert.equal(listed.length, 1);
  assert.equal(listed[0].chatId, "chat_group-1");

  // Чужой пользователь черновик не видит.
  assert.equal(
    await store.getChatDraft({userId: "stranger", chatId: "chat_group-1"}),
    null,
  );

  assert.equal(
    await store.clearChatDraft({userId: "user-1", chatId: "chat_group-1"}),
    null,
  );
  assert.equal(
    await store.getChatDraft({userId: "user-1", chatId: "chat_group-1"}),
    null,
  );
});

test("chat tables: pin lifecycle", async () => {
  const {store} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  const message = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-3",
    text: "Закрепите меня",
  });

  const pin = await store.pinChatMessage({
    userId: "user-1",
    chatId: "chat_group-1",
    messageId: message.id,
  });
  assert.equal(pin.messageId, message.id);
  assert.equal(pin.pinnedBy, "user-1");
  assert.equal(pin.senderName, "Борис");

  const fetched = await store.getChatPinnedMessage({
    userId: "user-2",
    chatId: "chat_group-1",
  });
  assert.equal(fetched?.messageId, message.id);
  assert.equal(fetched?.pinnedAt, pin.pinnedAt);

  assert.equal(
    await store.clearChatPinnedMessage({userId: "user-2", chatId: "chat_group-1"}),
    true,
  );
  assert.equal(
    await store.getChatPinnedMessage({userId: "user-2", chatId: "chat_group-1"}),
    null,
  );
});

test("chat tables: search matches terms with access control", async () => {
  const directChat = {
    id: "user-1_user-2",
    type: "direct",
    title: null,
    participantIds: ["user-1", "user-2"],
    createdAt: "2026-04-21T10:00:00.000Z",
    updatedAt: "2026-04-21T10:00:00.000Z",
  };
  const {store} = buildStore({users: USERS, chats: [GROUP_CHAT, directChat]});
  await store.initialize();

  await store.addChatMessage({
    chatId: "user-1_user-2",
    senderId: "user-1",
    text: "Секретная встреча в парке",
  });
  await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-3",
    text: "Общая встреча вечером",
  });

  // user-3 не участник директа — его поиск видит только групповое сообщение.
  const forUser3 = await store.searchChatMessages({userId: "user-3", query: "встреча"});
  assert.equal(forUser3.length, 1);
  assert.equal(forUser3[0].chatId, "chat_group-1");
  assert.ok(forUser3[0].snippet.includes("встреча"));

  const forUser1 = await store.searchChatMessages({userId: "user-1", query: "встреча"});
  assert.equal(forUser1.length, 2);

  const scoped = await store.searchChatMessages({
    userId: "user-1",
    query: "встреча",
    chatId: "user-2_user-1",
  });
  assert.equal(scoped.length, 1);
  assert.equal(scoped[0].chatId, "user-1_user-2");

  assert.deepEqual(
    await store.searchChatMessages({userId: "user-1", query: "динозавр"}),
    [],
  );
});

test("chat tables: TTL hides expired messages and sweep deletes them", async () => {
  const {store, rawPool} = buildStore({users: USERS, chats: [GROUP_CHAT]});
  await store.initialize();

  await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-1",
    text: "Вечное",
  });
  const expiring = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-1",
    text: "Исчезающее",
    expiresAt: new Date(Date.now() - 1000).toISOString(),
  });
  assert.ok(expiring?.id);

  const visible = await store.listChatMessages("chat_group-1", {limit: 10});
  assert.deepEqual(visible.map((m) => m.text), ["Вечное"]);

  assert.equal(await store.countUnreadChatMessages("user-2"), 1);

  // Фоновый sweep физически удаляет протухшее.
  store._lastChatPurgeSweepAt = 0;
  store._scheduleChatTablePurgeSweep();
  await wait(80);
  const rows = await rawPool.query(
    `SELECT id FROM "public"."rodnya_state_chat_messages"`,
  );
  assert.equal(rows.rows.length, 1);
});

test("chat tables: deleteUser cascades table data", async () => {
  const directChat = {
    id: "user-1_user-2",
    type: "direct",
    title: null,
    participantIds: ["user-1", "user-2"],
    createdAt: "2026-04-21T10:00:00.000Z",
    updatedAt: "2026-04-21T10:00:00.000Z",
  };
  const {store, rawPool} = buildStore({users: USERS, chats: [GROUP_CHAT, directChat]});
  await store.initialize();

  await store.addChatMessage({
    chatId: "user-1_user-2",
    senderId: "user-2",
    text: "Директ",
  });
  const groupMessage = await store.addChatMessage({
    chatId: "chat_group-1",
    senderId: "user-3",
    text: "Группа",
  });
  await store.saveChatDraft({userId: "user-2", chatId: "chat_group-1", text: "мой черновик"});
  await store.toggleChatMessageReaction({
    chatId: "chat_group-1",
    messageId: groupMessage.id,
    userId: "user-2",
    emoji: "👍",
  });

  await store.deleteUser("user-2");

  // Сообщения директа (user-2 участник) удалены; группа выжила (3→2 участника).
  const messages = await rawPool.query(
    `SELECT chat_id FROM "public"."rodnya_state_chat_messages"`,
  );
  assert.deepEqual(
    messages.rows.map((row) => row.chat_id),
    ["chat_group-1"],
  );
  const drafts = await rawPool.query(
    `SELECT user_id FROM "public"."rodnya_state_chat_drafts"`,
  );
  assert.equal(drafts.rows.length, 0);
  const reactions = await rawPool.query(
    `SELECT user_id FROM "public"."rodnya_state_chat_reactions"`,
  );
  assert.equal(reactions.rows.length, 0);

  const previews = await store.listChatPreviews("user-1");
  assert.deepEqual(previews.map((p) => p.chatId), ["chat_group-1"]);
});
