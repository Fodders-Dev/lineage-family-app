// SPEED-7: сквозные тесты notifications/pushDeliveries поверх таблиц на
// pg-mem — НАСТОЯЩИЙ SQL стора: бут-миграция блоб→таблицы, create/list/
// count/markRead, коалесинг реакций, drain «транзитной очереди» из
// унаследованных путей, каскады deleteUser/removeTreeForUser/устройств и
// retention-окна hardDeleteExpired.
const test = require("node:test");
const assert = require("node:assert/strict");

const {newDb} = require("pg-mem");
const {PostgresStore} = require("../src/postgres-store");
const {createNotificationRecord} = require("../src/store");

const USERS = [
  {id: "user-1", email: "ivan@rodnya-tree.ru", profile: {displayName: "Иван"}},
  {id: "user-2", email: "anna@rodnya-tree.ru", profile: {displayName: "Анна"}},
];

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

const NOTIF_TABLE = `"public"."rodnya_state_notifications"`;
const DELIV_TABLE = `"public"."rodnya_state_push_deliveries"`;

function seedNotification(overrides) {
  return {
    id: overrides.id,
    userId: overrides.userId,
    type: overrides.type || "generic",
    title: overrides.title || "Заголовок",
    body: overrides.body || "Текст",
    data: overrides.data || {},
    silent: overrides.silent === true,
    createdAt: overrides.createdAt || "2026-08-01T10:00:00.000Z",
    readAt: overrides.readAt || null,
  };
}

test("миграция: блоб → таблицы, бэкап, маркер, идемпотентность", async () => {
  const seeded = {
    users: USERS,
    notifications: [
      seedNotification({id: "n-1", userId: "user-1"}),
      seedNotification({
        id: "n-2",
        userId: "user-1",
        readAt: "2026-08-02T10:00:00.000Z",
      }),
      seedNotification({id: "n-3", userId: "user-2", silent: true}),
      // Битая запись (без id) — остаётся только в бэкапе.
      {userId: "user-1", type: "broken", createdAt: "2026-08-01T10:00:00.000Z"},
    ],
    pushDeliveries: [
      {
        id: "pd-1",
        notificationId: "n-1",
        userId: "user-1",
        deviceId: "dev-1",
        provider: "fcm",
        status: "sent",
        createdAt: "2026-08-01T10:00:01.000Z",
        updatedAt: "2026-08-01T10:00:02.000Z",
      },
      // Битая (без id) — только бэкап.
      {userId: "user-1", createdAt: "2026-08-01T10:00:01.000Z"},
    ],
  };
  const {store, rawPool} = buildStore(seeded);
  await store.initialize();

  const notifRows = await rawPool.query(
    `SELECT id, user_id, read_at, silent FROM ${NOTIF_TABLE}`,
  );
  assert.equal(notifRows.rows.length, 3);
  const byId = new Map(notifRows.rows.map((row) => [row.id, row]));
  assert.equal(byId.get("n-1").read_at, "");
  assert.notEqual(byId.get("n-2").read_at, "");
  assert.equal(Number(byId.get("n-3").silent), 1);

  const delivRows = await rawPool.query(`SELECT id FROM ${DELIV_TABLE}`);
  assert.equal(delivRows.rows.length, 1);

  const state = await store._read();
  assert.deepEqual(state.notifications, []);
  assert.deepEqual(state.pushDeliveries, []);
  assert.equal(state.migrationStatus?.notificationsToTables, "complete-v1");

  const backup = await rawPool.query(
    `SELECT backup_data FROM "public"."rodnya_state_notification_backups"`,
  );
  assert.equal(backup.rows.length, 1);
  const backupData =
    typeof backup.rows[0].backup_data === "string"
      ? JSON.parse(backup.rows[0].backup_data)
      : backup.rows[0].backup_data;
  assert.equal(backupData.notifications.length, 4);
  assert.equal(backupData.pushDeliveries.length, 2);
});

test("create/list/count/markRead: контракт FileStore на таблицах", async () => {
  const {store} = buildStore({users: USERS, notifications: [], pushDeliveries: []});
  await store.initialize();

  // Юзера нет → null (как _mutate-skip в FileStore).
  assert.equal(
    await store.createNotification({
      userId: "ghost",
      type: "generic",
      title: "x",
      body: "y",
    }),
    null,
  );

  const first = await store.createNotification({
    userId: "user-1",
    type: "chat_message",
    title: "Новое сообщение",
    body: "Привет",
    data: {chatId: "chat-1"},
  });
  assert.ok(first?.id);
  const second = await store.createNotification({
    userId: "user-1",
    type: "tree_mutated",
    title: "",
    body: "",
    data: {treeId: "tree-1"},
    silent: true,
  });
  await store.createNotification({
    userId: "user-2",
    type: "generic",
    title: "Чужое",
    body: "-",
  });

  const all = await store.listNotifications("user-1");
  assert.equal(all.length, 2);
  // Новые первыми.
  assert.equal(all[0].id, second.id);
  assert.equal(all[1].id, first.id);
  assert.equal(await store.countUnreadNotifications("user-1"), 2);

  const marked = await store.markNotificationRead(first.id, "user-1");
  assert.ok(marked.readAt);
  assert.equal(await store.countUnreadNotifications("user-1"), 1);
  const unread = await store.listNotifications("user-1", {status: "unread"});
  assert.deepEqual(unread.map((entry) => entry.id), [second.id]);
  const read = await store.listNotifications("user-1", {status: "read"});
  assert.deepEqual(read.map((entry) => entry.id), [first.id]);

  // Повторная пометка — вернуть запись, не двигая readAt.
  const again = await store.markNotificationRead(first.id, "user-1");
  assert.equal(again.readAt, marked.readAt);
  // Чужой userId → null.
  assert.equal(await store.markNotificationRead(second.id, "user-2"), null);
});

test("markNotificationsReadByDataKey гасит по chatId c фильтром типов", async () => {
  const {store} = buildStore({users: USERS, notifications: [], pushDeliveries: []});
  await store.initialize();

  await store.createNotification({
    userId: "user-1",
    type: "chat_message",
    title: "a",
    body: "b",
    data: {chatId: "chat-1"},
  });
  await store.createNotification({
    userId: "user-1",
    type: "chat_message",
    title: "c",
    body: "d",
    data: {chatId: "chat-2"},
  });
  await store.createNotification({
    userId: "user-1",
    type: "post_created",
    title: "e",
    body: "f",
    data: {chatId: "chat-1"},
  });

  const marked = await store.markNotificationsReadByDataKey({
    userId: "user-1",
    dataKey: "chatId",
    dataValue: "chat-1",
    types: ["chat_message"],
  });
  assert.equal(marked, 1);
  const unread = await store.listNotifications("user-1", {status: "unread"});
  assert.equal(unread.length, 2);
});

test("коалесинг реакций: бамп unread-записи, новая после прочтения", async () => {
  const {store, rawPool} = buildStore({
    users: USERS,
    notifications: [],
    pushDeliveries: [],
  });
  await store.initialize();

  const firstReaction = await store.addPostReactionNotification({
    postId: "post-1",
    postAuthorId: "user-1",
    actorUserId: "user-2",
    actorName: "Анна",
    emoji: "❤️",
    postSnippet: "Отпуск",
  });
  assert.equal(firstReaction.type, "post_reaction");
  const bumped = await store.addPostReactionNotification({
    postId: "post-1",
    postAuthorId: "user-1",
    actorUserId: "user-2",
    actorName: "Анна",
    emoji: "🔥",
    postSnippet: "Отпуск",
  });
  assert.equal(bumped.id, firstReaction.id, "unread-запись бампается, не дублируется");
  assert.equal(bumped.data.emoji, "🔥");
  assert.equal(bumped.body, "Анна отреагировал 🔥");

  const rows = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.equal(rows.rows.length, 1);

  // Самореакция игнорируется.
  assert.equal(
    await store.addPostReactionNotification({
      postId: "post-1",
      postAuthorId: "user-1",
      actorUserId: "user-1",
      emoji: "❤️",
    }),
    null,
  );

  // После прочтения — новая запись.
  await store.markNotificationRead(firstReaction.id, "user-1");
  const fresh = await store.addPostReactionNotification({
    postId: "post-1",
    postAuthorId: "user-1",
    actorUserId: "user-2",
    actorName: "Анна",
    emoji: "😍",
    postSnippet: "Отпуск",
  });
  assert.notEqual(fresh.id, firstReaction.id);
  const after = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.equal(after.rows.length, 2);
});

test("drain: унаследованные блоб-пути доезжают в таблицу с reviewer-дедупом", async () => {
  const {store, rawPool} = buildStore({
    users: USERS,
    notifications: [],
    pushDeliveries: [],
  });
  await store.initialize();

  // Симуляция _notifyReviewers/article_block_conflict: пуш в блоб-массив
  // внутри _mutate — ровно так пишут унаследованные inline-пути.
  const pushReviewerPing = () =>
    store._mutate((db) => {
      db.notifications.push(
        createNotificationRecord({
          userId: "user-2",
          type: "merge_proposal",
          title: "Ревью",
          body: "Проверьте предложение",
          data: {proposalId: "prop-1", claimId: "claim-1"},
        }),
      );
      return true;
    });
  await pushReviewerPing();
  await pushReviewerPing();

  const state = await store._read();
  assert.deepEqual(state.notifications, [], "блоб остаётся пустым транзитом");
  const rows = await rawPool.query(
    `SELECT id FROM ${NOTIF_TABLE} WHERE user_id = 'user-2'`,
  );
  assert.equal(rows.rows.length, 1, "reviewer-дедуп по coalesce_key при drain");
  const listed = await store.listNotifications("user-2");
  assert.equal(listed.length, 1);
  assert.equal(listed[0].type, "merge_proposal");
});

test("pushDeliveries: create/list/update и каскад deletePushDevice", async () => {
  const {store, rawPool} = buildStore({
    users: USERS,
    notifications: [],
    pushDeliveries: [],
    pushDevices: [],
  });
  await store.initialize();

  const device = await store.registerPushDevice({
    userId: "user-1",
    provider: "fcm",
    token: "tok-1",
    platform: "android",
  });
  const delivery = await store.createPushDelivery({
    notificationId: "n-x",
    userId: "user-1",
    deviceId: device.id,
    provider: "fcm",
  });
  assert.equal(delivery.status, "queued");

  const updated = await store.updatePushDelivery(delivery.id, {
    status: "sent",
    deliveredAt: "2026-08-29T10:00:00.000Z",
    responseCode: 200,
  });
  assert.equal(updated.status, "sent");
  assert.equal(updated.responseCode, 200);

  const listed = await store.listPushDeliveries("user-1");
  assert.equal(listed.length, 1);
  assert.equal(listed[0].status, "sent");

  assert.equal(await store.updatePushDelivery("missing", {status: "x"}), null);

  await store.deletePushDevice(device.id, "user-1");
  const rows = await rawPool.query(`SELECT id FROM ${DELIV_TABLE}`);
  assert.equal(rows.rows.length, 0, "каскад по deviceId чистит таблицу");
});

test("deleteUser: уведомления с участием юзера и сироты-deliveries умирают", async () => {
  const {store, rawPool} = buildStore({
    users: USERS,
    notifications: [],
    pushDeliveries: [],
    pushDevices: [],
  });
  await store.initialize();

  // user-2 получает уведомление, где user-1 — отправитель.
  await store.createNotification({
    userId: "user-2",
    type: "chat_message",
    title: "От Ивана",
    body: "Привет",
    data: {senderId: "user-1", chatId: "user-1_user-2"},
  });
  // Невязанное уведомление user-2 — переживает.
  const survivor = await store.createNotification({
    userId: "user-2",
    type: "generic",
    title: "Независимое",
    body: "-",
  });
  // Собственное уведомление user-1 — умирает.
  const own = await store.createNotification({
    userId: "user-1",
    type: "generic",
    title: "Моё",
    body: "-",
  });
  await store.createPushDelivery({
    notificationId: own.id,
    userId: "user-2",
    deviceId: "dev-2",
    provider: "fcm",
  });

  await store.deleteUser("user-1");

  const notifRows = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.deepEqual(
    notifRows.rows.map((row) => row.id),
    [survivor.id],
  );
  const delivRows = await rawPool.query(`SELECT id FROM ${DELIV_TABLE}`);
  assert.equal(
    delivRows.rows.length,
    0,
    "delivery-сирота (notificationId умершего уведомления) вычищена",
  );
});

test("removeTreeForUser: leave чистит только свои уведомления дерева", async () => {
  const tree = {
    id: "tree-1",
    name: "Дерево",
    creatorId: "user-1",
    memberIds: ["user-1", "user-2"],
    members: ["user-1", "user-2"],
  };
  const {store, rawPool} = buildStore({
    users: USERS,
    trees: [tree],
    notifications: [],
    pushDeliveries: [],
  });
  await store.initialize();

  await store.createNotification({
    userId: "user-2",
    type: "post_created",
    title: "В дереве",
    body: "-",
    data: {treeId: "tree-1"},
  });
  const foreign = await store.createNotification({
    userId: "user-1",
    type: "post_created",
    title: "У создателя",
    body: "-",
    data: {treeId: "tree-1"},
  });

  const result = await store.removeTreeForUser({
    treeId: "tree-1",
    userId: "user-2",
  });
  assert.notEqual(result?.action, "deleted");

  const rows = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.deepEqual(rows.rows.map((row) => row.id), [foreign.id]);
});

test("hardDeleteExpired: три окна notifications + TTL/cap deliveries", async () => {
  const {store, rawPool} = buildStore({
    users: USERS,
    notifications: [],
    pushDeliveries: [],
  });
  await store.initialize();

  const now = new Date("2026-08-29T12:00:00.000Z");
  const seedRow = async (record) => {
    await rawPool.query(
      `INSERT INTO ${NOTIF_TABLE}
         (id, user_id, type, created_at, read_at, silent, coalesce_key, notification_data)
       VALUES ($1, $2, $3, $4, $5, $6, '', $7)`,
      [
        record.id,
        record.userId,
        record.type || "generic",
        record.createdAt,
        record.readAt || "",
        record.silent ? 1 : 0,
        JSON.stringify(record),
      ],
    );
  };
  // silent старше 48ч — умирает; свежий silent — живёт.
  await seedRow({id: "s-old", userId: "user-1", silent: true, createdAt: "2026-08-26T12:00:00.000Z"});
  await seedRow({id: "s-new", userId: "user-1", silent: true, createdAt: "2026-08-29T00:00:00.000Z"});
  // read старше 30д — умирает; свежий read — живёт.
  await seedRow({id: "r-old", userId: "user-1", readAt: "2026-07-01T12:00:00.000Z", createdAt: "2026-07-01T12:00:00.000Z"});
  await seedRow({id: "r-new", userId: "user-1", readAt: "2026-08-20T12:00:00.000Z", createdAt: "2026-08-20T12:00:00.000Z"});
  // unread старше 365д — умирает; годовалый минус день — живёт.
  await seedRow({id: "u-old", userId: "user-1", createdAt: "2025-08-01T12:00:00.000Z"});
  await seedRow({id: "u-new", userId: "user-1", createdAt: "2025-09-15T12:00:00.000Z"});

  const seedDelivery = async (id, createdAt) => {
    await rawPool.query(
      `INSERT INTO ${DELIV_TABLE}
         (id, notification_id, user_id, device_id, provider, status, created_at, updated_at, delivery_data)
       VALUES ($1, '', 'user-1', 'dev-1', 'fcm', 'sent', $2, $2, '{}')`,
      [id, createdAt],
    );
  };
  await seedDelivery("pd-old", "2026-08-10T12:00:00.000Z");
  await seedDelivery("pd-new", "2026-08-28T12:00:00.000Z");

  // dry-run считает, но не удаляет.
  const dry = await store.hardDeleteExpired({now, dryRun: true});
  assert.equal(dry.logRetention.notificationsSilent, 1);
  assert.equal(dry.logRetention.notificationsRead, 1);
  assert.equal(dry.logRetention.notificationsUnread, 1);
  assert.equal(dry.logRetention.pushDeliveries, 1);
  assert.equal(
    (await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`)).rows.length,
    6,
  );

  const summary = await store.hardDeleteExpired({now});
  assert.equal(summary.logRetention.notificationsSilent, 1);
  assert.equal(summary.logRetention.notificationsRead, 1);
  assert.equal(summary.logRetention.notificationsUnread, 1);
  assert.equal(summary.logRetention.pushDeliveries, 1);

  const left = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.deepEqual(
    left.rows.map((row) => row.id).sort(),
    ["r-new", "s-new", "u-new"],
  );
  const leftDeliveries = await rawPool.query(`SELECT id FROM ${DELIV_TABLE}`);
  assert.deepEqual(leftDeliveries.rows.map((row) => row.id), ["pd-new"]);

  // Cap newest-N: добить 3 записи, cap=2 → умирает самая старая.
  await seedDelivery("pd-a", "2026-08-27T12:00:00.000Z");
  await seedDelivery("pd-b", "2026-08-28T13:00:00.000Z");
  const capped = await store.hardDeleteExpired({
    now,
    logRetention: {pushDeliveriesMax: 2, pushDeliveriesDays: 365},
  });
  assert.equal(capped.logRetention.pushDeliveries, 1);
  const afterCap = await rawPool.query(
    `SELECT id FROM ${DELIV_TABLE} ORDER BY created_at ASC`,
  );
  assert.deepEqual(afterCap.rows.map((row) => row.id), ["pd-new", "pd-b"]);
});

test("скип миграции (БД моргнула) → полная делегация в блоб, drain выключен", async () => {
  const seeded = {
    users: USERS,
    notifications: [seedNotification({id: "n-1", userId: "user-1"})],
    pushDeliveries: [],
  };
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  // Одна транзиентная ошибка ровно на SELECT миграции: пропускаем
  // бутстрап-инфраструктуру (CREATE/INSERT/hydrate) и роняем первый
  // SELECT data, который делает _migrateNotificationCollectionsToTables.
  // Порядок SELECT data в бутстрапе (снят трассировкой): #1 backfill
  // identities, #2 auth-hydrate, #3 чат-миграция, #4 notification-миграция,
  // #5 chat-projection hydrate. Валим ровно #4 — транзиентная ошибка именно
  // на чтении состояния notification-миграции.
  let failedOnce = false;
  let stateSelects = 0;
  const pool = {
    query: (sql, params) => {
      const text = String(sql);
      let effectiveParams = params;
      if (
        text.includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seeded)];
      }
      if (text.replace(/\s+/g, " ").trim().startsWith("SELECT data FROM")) {
        stateSelects += 1;
        if (stateSelects === 4 && !failedOnce) {
          failedOnce = true;
          return Promise.reject(new Error("connection reset"));
        }
      }
      return rawPool.query(sql, effectiveParams);
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });
  await store.initialize();
  assert.equal(failedOnce, true, "сценарий требует упавшего SELECT миграции");

  // Гейт закрыт: таблицы пустые, но лента НЕ пустая — читаем блоб.
  const listed = await store.listNotifications("user-1");
  assert.equal(listed.length, 1);
  assert.equal(listed[0].id, "n-1");
  assert.equal(await store.countUnreadNotifications("user-1"), 1);

  // Запись тоже уходит в блоб (super-путь), а drain НЕ трогает массивы —
  // write-once бэкап будущей миграции не будет отравлен пустотой.
  const created = await store.createNotification({
    userId: "user-1",
    type: "generic",
    title: "В блоб",
    body: "-",
  });
  assert.ok(created?.id);
  const state = await store._read();
  assert.equal(state.notifications.length, 2, "блоб остаётся источником правды");
  const tableRows = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.equal(tableRows.rows.length, 0, "drain выключен до миграции");
  assert.notEqual(
    state.migrationStatus?.notificationsToTables,
    "complete-v1",
    "маркер не выставлен — следующий бут повторит миграцию честно",
  );
});

test("бамп коалесинга не откатывает конкурентную пометку «прочитано»", async () => {
  const {store, rawPool} = buildStore({
    users: USERS,
    notifications: [],
    pushDeliveries: [],
  });
  await store.initialize();

  const first = await store.addPostReactionNotification({
    postId: "post-1",
    postAuthorId: "user-1",
    actorUserId: "user-2",
    actorName: "Анна",
    emoji: "❤️",
    postSnippet: "Отпуск",
  });
  // «Конкурентный» markRead между SELECT и UPDATE бампа: симулируем его
  // прямым UPDATE'ом read_at (SELECT бампа увидит unread из-за
  // отсутствия блокировки — здесь проверяем сам UPDATE-гвард).
  await rawPool.query(
    `UPDATE ${NOTIF_TABLE} SET read_at = '2026-08-29T13:00:00.000Z' WHERE id = $1`,
    [first.id],
  );

  const second = await store.addPostReactionNotification({
    postId: "post-1",
    postAuthorId: "user-1",
    actorUserId: "user-2",
    actorName: "Анна",
    emoji: "🔥",
    postSnippet: "Отпуск",
  });
  assert.notEqual(second.id, first.id, "прочитанную запись бамп не воскрешает");
  const rows = await rawPool.query(
    `SELECT id, read_at FROM ${NOTIF_TABLE} ORDER BY created_at ASC`,
  );
  assert.equal(rows.rows.length, 2);
  const firstRow = rows.rows.find((row) => row.id === first.id);
  assert.notEqual(firstRow.read_at, "", "пометка «прочитано» пережила бамп");
});

test("легаси-таблица старой схемы (прод-артефакт апреля) переименовывается", async () => {
  const seeded = {
    users: USERS,
    notifications: [seedNotification({id: "n-1", userId: "user-1"})],
    pushDeliveries: [],
  };
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  // Артефакт до initialize: старая схема с notification_id PK, без id.
  await rawPool.query(`
    CREATE TABLE "public"."rodnya_state_notifications" (
      notification_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      created_at TEXT,
      read_at TEXT,
      notification_data JSONB NOT NULL
    )
  `);
  await rawPool.query(`
    INSERT INTO "public"."rodnya_state_notifications"
      (notification_id, user_id, created_at, notification_data)
    VALUES ('old-1', 'user-x', '2026-04-21T23:00:00.000Z', '{}')
  `);
  const pool = {
    query: (sql, params) => {
      let effectiveParams = params;
      if (
        String(sql).includes("ON CONFLICT (id) DO NOTHING") &&
        Array.isArray(params) &&
        params[0] === "default"
      ) {
        effectiveParams = [params[0], JSON.stringify(seeded)];
      }
      return rawPool.query(sql, effectiveParams);
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });
  await store.initialize();

  // Легаси эвакуирована в backup-таблицу со своими данными.
  const legacy = await rawPool.query(
    `SELECT backup_data FROM "public"."rodnya_state_notification_backups"
      WHERE id = 'legacy-table-rodnya_state_notifications'`,
  );
  assert.equal(legacy.rows.length, 1);
  const legacyData =
    typeof legacy.rows[0].backup_data === "string"
      ? JSON.parse(legacy.rows[0].backup_data)
      : legacy.rows[0].backup_data;
  assert.deepEqual(
    legacyData.rows.map((row) => row.notification_id),
    ["old-1"],
  );
  // Новая таблица создана правильной схемой, миграция прошла.
  const migrated = await rawPool.query(`SELECT id FROM ${NOTIF_TABLE}`);
  assert.deepEqual(migrated.rows.map((row) => row.id), ["n-1"]);
  const listed = await store.listNotifications("user-1");
  assert.equal(listed.length, 1);
});
