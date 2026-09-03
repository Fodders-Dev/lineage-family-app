const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

const {PostgresStore} = require("../src/postgres-store");
const {FileStore} = require("../src/store");

test("PostgresStore keeps state reads and writes on postgres paths", async () => {
  assert.notEqual(PostgresStore.prototype._read, FileStore.prototype._read);
  assert.notEqual(PostgresStore.prototype._write, FileStore.prototype._write);

  const source = await fs.readFile(
    path.join(__dirname, "../src/postgres-store.js"),
    "utf8",
  );
  assert.doesNotMatch(source, /super\._(?:read|write)\s*\(/);
  assert.doesNotMatch(
    source,
    /FileStore\.prototype\._(?:read|write)\.(?:call|apply)\s*\(/,
  );
});

test("PostgresStore recovers from a failed write without poisoning the queue", async () => {
  let state = {users: []};
  let writeAttempts = 0;
  const pool = {
    async query(sql, params = []) {
      if (sql.includes("CREATE SCHEMA") || sql.includes("ALTER TABLE")) {
        return {rows: []};
      }
      if (sql.includes("CREATE TABLE") || sql.includes("CREATE INDEX")) {
        return {rows: []};
      }
      if (sql.includes("ON CONFLICT (id) DO NOTHING")) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (sql.includes("SELECT session_data")) {
        return {rows: []};
      }
      if (sql.includes("SELECT data")) {
        return {rows: [{data: state}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        writeAttempts += 1;
        if (writeAttempts === 1) {
          throw new Error("write_failed_once");
        }
        state = JSON.parse(params[1]);
        return {rows: []};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });

  await store.initialize();
  await assert.rejects(
    store._write({users: [{id: "u-1"}]}),
    /write_failed_once/,
  );

  await assert.doesNotReject(store._read());
  await assert.doesNotReject(store._write({users: [{id: "u-2"}]}));

  const snapshot = await store._read();
  assert.deepEqual(snapshot.users, [{id: "u-2"}]);
});

test("PostgresStore reads can fall back when the write queue is stuck", async () => {
  const pool = {
    async query(sql) {
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (sql.includes("SELECT session_data")) {
        return {rows: []};
      }
      if (sql.includes("SELECT data")) {
        return {rows: [{data: {users: []}}]};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    queryTimeoutMs: 25,
    writeQueueTimeoutMs: 25,
  });

  await store.initialize();
  store._stateWriteQueue = new Promise(() => {});
  store._writeQueue = store._stateWriteQueue;

  const snapshot = await store._read();
  assert.deepEqual(snapshot.users, []);
});

test("PostgresStore writes time out behind a stuck state queue and recover", async () => {
  let state = {users: []};
  let writeAttempts = 0;
  const pool = {
    async query(sql, params = []) {
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (sql.includes("SELECT session_data")) {
        return {rows: []};
      }
      if (sql.includes("SELECT data")) {
        return {rows: [{data: state}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        writeAttempts += 1;
        state = JSON.parse(params[1]);
        return {rows: []};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    queryTimeoutMs: 25,
    writeQueueTimeoutMs: 25,
  });

  await store.initialize();
  store._stateWriteQueue = new Promise(() => {});
  store._writeQueue = store._stateWriteQueue;

  await assert.rejects(
    store._write({users: [{id: "u-stuck"}]}),
    (error) => error?.code === "POSTGRES_WRITE_QUEUE_TIMEOUT",
  );

  await assert.doesNotReject(store._write({users: [{id: "u-recovered"}]}));

  assert.equal(writeAttempts, 1);
  const snapshot = await store._read();
  assert.deepEqual(snapshot.users, [{id: "u-recovered"}]);
});

test("PostgresStore reuses one shared pool for identical config", async () => {
  let state = {users: []};
  let createdPoolCount = 0;
  let endCount = 0;
  let poolOptions = null;
  const poolFactory = (options) => {
    createdPoolCount += 1;
    poolOptions = options;
    return {
      async query(sql) {
        if (
          sql.includes("CREATE SCHEMA") ||
          sql.includes("CREATE TABLE") ||
          sql.includes("CREATE INDEX") ||
          sql.includes("ON CONFLICT (id) DO NOTHING")
        ) {
          return {rows: []};
        }
        if (
          sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
          sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
          sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
          sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
        ) {
          return {rows: []};
        }
        if (sql.includes("SELECT session_data")) {
          return {rows: []};
        }
        if (sql.includes("SELECT data")) {
          return {rows: [{data: state}]};
        }
        if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
      },
      async end() {
        endCount += 1;
      },
    };
  };

  const firstStore = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    poolFactory,
  });
  const secondStore = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    poolFactory,
  });

  await firstStore.initialize();
  await secondStore.initialize();

  const firstSnapshot = await firstStore._read();
  const secondSnapshot = await secondStore._read();

  assert.deepEqual(firstSnapshot.users, state.users);
  assert.deepEqual(secondSnapshot.users, state.users);
  assert.equal(createdPoolCount, 1);
  assert.equal(poolOptions.query_timeout, 15_000);
  assert.equal(poolOptions.statement_timeout, 15_000);

  await firstStore.close();
  assert.equal(endCount, 0);

  await secondStore.close();
  assert.equal(endCount, 1);
});

test("PostgresStore auth hot paths avoid full state reads", async () => {
  const passwordSalt = "salt-1";
  const passwordHash = crypto
    .scryptSync("secret123", passwordSalt, 64)
    .toString("hex");
  const userRecord = {
    id: "user-1",
    email: "smoke@rodnya-tree.ru",
    passwordSalt,
    passwordHash,
    profile: {displayName: "Smoke User"},
  };
  let sessions = [
    {
      token: "token-1",
      refreshToken: "refresh-1",
      userId: "user-1",
      createdAt: "2026-01-01T00:00:00.000Z",
      lastSeenAt: "2020-01-01T00:00:00.000Z",
    },
  ];
  let projectedUsers = [userRecord];
  let projectedSessions = [...sessions];
  const queries = [];
  let allowFullStateReads = true;
  const pool = {
    async query(sql, params = []) {
      queries.push(sql);
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") &&
        !sql.includes("WHERE ")
      ) {
        projectedUsers = [];
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") &&
        !sql.includes("WHERE ")
      ) {
        projectedSessions = [];
        return {rows: []};
      }
      if (
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") &&
        sql.includes("FROM \"public\".\"rodnya_state\",")
      ) {
        projectedUsers = [userRecord];
        return {rows: []};
      }
      if (
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"") &&
        sql.includes("FROM \"public\".\"rodnya_state\",")
      ) {
        projectedSessions = [...sessions];
        return {rows: []};
      }
      if (
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") &&
        sql.includes("jsonb_array_elements($1::jsonb)")
      ) {
        projectedUsers = JSON.parse(params[0]);
        return {rows: []};
      }
      if (
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"") &&
        sql.includes("jsonb_array_elements($1::jsonb)")
      ) {
        projectedSessions = JSON.parse(params[0]);
        sessions = projectedSessions;
        return {rows: []};
      }
      if (
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"") &&
        sql.includes("ON CONFLICT (token) DO UPDATE")
      ) {
        const nextSession = JSON.parse(params[4]);
        projectedSessions = [
          ...projectedSessions.filter((entry) => entry.token !== nextSession.token),
          nextSession,
        ];
        sessions = projectedSessions;
        return {rows: []};
      }
      if (sql.includes("SELECT user_data")) {
        const userParam = params[0];
        const match = projectedUsers.find(
          (entry) => entry.id === userParam || entry.email === userParam,
        );
        return {rows: match ? [{user_data: match}] : []};
      }
      if (sql.includes("SELECT session_data")) {
        const sessionParam = params[0];
        if (sql.includes("ORDER BY created_at NULLS FIRST, token")) {
          if (sql.includes("WHERE user_id = $1")) {
            return {
              rows: projectedSessions
                .filter((entry) => entry.userId === sessionParam)
                .map((entry) => ({session_data: entry})),
            };
          }
          return {
            rows: projectedSessions.map((entry) => ({session_data: entry})),
          };
        }
        const match = projectedSessions.find(
          (entry) =>
            entry.token === sessionParam || entry.refreshToken === sessionParam,
          );
        return {rows: match ? [{session_data: match}] : []};
      }
      if (sql.includes("SELECT token")) {
        return {
          rows: projectedSessions
            .filter((entry) => entry.userId === params[0])
            .map((entry) => ({token: entry.token})),
        };
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") &&
        sql.includes("WHERE token = $1")
      ) {
        projectedSessions = projectedSessions.filter((entry) => entry.token !== params[0]);
        sessions = projectedSessions;
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") &&
        sql.includes("WHERE user_id = $1")
      ) {
        projectedSessions = projectedSessions.filter((entry) => entry.userId !== params[0]);
        sessions = projectedSessions;
        return {rows: []};
      }
      if (sql.includes("SELECT data")) {
        if (!allowFullStateReads) {
          throw new Error("full_state_read_not_allowed");
        }
        return {rows: [{data: {migrationStatus: {chatCollectionsToTables: "complete-v1"}}}]};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    queryTimeoutMs: 25,
    writeQueueTimeoutMs: 25,
  });

  await store.initialize();
  allowFullStateReads = false;
  queries.length = 0;
  store._stateWriteQueue = new Promise(() => {});
  store._writeQueue = store._stateWriteQueue;

  const authenticatedUser = await store.authenticate(
    "smoke@rodnya-tree.ru",
    "secret123",
  );
  assert.equal(authenticatedUser?.id, "user-1");

  const userById = await store.findUserById("user-1");
  assert.equal(userById?.email, "smoke@rodnya-tree.ru");

  const userByEmail = await store.findUserByEmail("smoke@rodnya-tree.ru");
  assert.equal(userByEmail?.id, "user-1");

  const sessionByToken = await store.findSession("token-1");
  assert.equal(sessionByToken?.userId, "user-1");

  const sessionByRefreshToken = await store.findSessionByRefreshToken("refresh-1");
  assert.equal(sessionByRefreshToken?.token, "token-1");

  store._sessionTouchCache.clear();
  const touchedSession = await store.touchSession("token-1");
  assert.equal(touchedSession?.token, "token-1");
  assert.notEqual(touchedSession?.lastSeenAt, "2020-01-01T00:00:00.000Z");

  const createdSession = await store.createSession("user-1");
  assert.ok(createdSession?.token);
  assert.ok(createdSession?.refreshToken);
  assert.equal(sessions.filter((entry) => entry.userId === "user-1").length, 2);

  await store.deleteSession("token-1");
  assert.equal(sessions.some((entry) => entry.token === "token-1"), false);

  await store.deleteSessionsForUser("user-1");
  assert.equal(sessions.length, 0);
  assert.equal(
    queries.some((sql) => sql.includes("SELECT data FROM")),
    false,
  );
  assert.equal(
    queries.some((sql) => sql.includes("jsonb_set(") && sql.includes("'{sessions}'")),
    false,
  );
});

test("PostgresStore persists snapshot cache after successful write", async () => {
  const cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-pg-cache-"));
  const snapshotCachePath = path.join(cacheDir, "state-cache.json");
  let state = {users: []};
  const pool = {
    async query(sql, params = []) {
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (sql.includes("SELECT session_data")) {
        return {rows: []};
      }
      if (sql.includes("SELECT data")) {
        return {rows: [{data: state}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        state = JSON.parse(params[1]);
        return {rows: []};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  try {
    const store = new PostgresStore({
      connectionString: "postgresql://unused/rodnya",
      pool,
      snapshotCachePath,
    });

    await store.initialize();
    await store._write({users: [{id: "u-7"}]});

    const persistedSnapshot = JSON.parse(
      await fs.readFile(snapshotCachePath, "utf8"),
    );
    assert.deepEqual(persistedSnapshot.users, [{id: "u-7"}]);
  } finally {
    await fs.rm(cacheDir, {recursive: true, force: true});
  }
});

test("PostgresStore hydrates cached snapshot from the sidecar file after restart", async () => {
  const cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-pg-cache-"));
  const snapshotCachePath = path.join(cacheDir, "state-cache.json");
  const persistedSnapshot = {
    chats: [{id: "chat-1"}],
    messages: [{id: "msg-1", chatId: "chat-1"}],
  };

  const pool = {
    async query(sql) {
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (sql.includes("SELECT data")) {
        throw new Error("Connection terminated due to connection timeout");
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  try {
    await fs.writeFile(
      snapshotCachePath,
      JSON.stringify(persistedSnapshot),
      "utf8",
    );

    const store = new PostgresStore({
      connectionString: "postgresql://unused/rodnya",
      pool,
      readRetryDelayMs: 0,
      snapshotCachePath,
    });

    await store.initialize();

    const snapshot = await store._read();
    assert.deepEqual(snapshot.chats, [{id: "chat-1"}]);
    assert.deepEqual(snapshot.messages, [{id: "msg-1", chatId: "chat-1"}]);
  } finally {
    await fs.rm(cacheDir, {recursive: true, force: true});
  }
});

test("PostgresStore tree hot paths avoid full state reads", async () => {
  const ownerTree = {
    id: "tree-owner",
    creatorId: "user-1",
    memberIds: ["user-2"],
    updatedAt: "2026-04-21T12:00:00.000Z",
    title: "Owner Tree",
  };
  const memberTree = {
    id: "tree-member",
    creatorId: "user-3",
    memberIds: ["user-1"],
    updatedAt: "2026-04-21T13:00:00.000Z",
    title: "Member Tree",
  };
  const otherTree = {
    id: "tree-other",
    creatorId: "user-9",
    memberIds: [],
    updatedAt: "2026-04-21T11:00:00.000Z",
    title: "Other Tree",
  };
  const trees = [ownerTree, memberTree, otherTree];
  const queries = [];
  let allowFullStateReads = true;
  const pool = {
    async query(sql, params = []) {
      queries.push(sql);
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("SELECT tree_entry AS tree_data") &&
        sql.includes("jsonb_array_elements_text")
      ) {
        const userId = params[1];
        const rows = trees
          .filter((tree) => {
            return (
              tree.creatorId === userId ||
              (Array.isArray(tree.memberIds) && tree.memberIds.includes(userId))
            );
          })
          .sort((left, right) =>
            String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")),
          )
          .map((tree) => ({tree_data: tree}));
        return {rows};
      }
      if (sql.includes("SELECT tree_entry AS tree_data")) {
        const treeId = params[1];
        const tree = trees.find((entry) => entry.id === treeId) || null;
        return {rows: tree ? [{tree_data: tree}] : []};
      }
      if (sql.includes("SELECT data")) {
        if (!allowFullStateReads) {
          throw new Error("full_state_read_not_allowed");
        }
        return {rows: [{data: {migrationStatus: {chatCollectionsToTables: "complete-v1"}}}]};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });

  await store.initialize();
  allowFullStateReads = false;
  queries.length = 0;

  const userTrees = await store.listUserTrees("user-1");
  assert.deepEqual(
    userTrees.map((tree) => tree.id),
    ["tree-member", "tree-owner"],
  );

  const foundTree = await store.findTree("tree-owner");
  assert.equal(foundTree?.title, "Owner Tree");

  assert.equal(
    queries.some((sql) => sql.includes("SELECT data FROM")),
    false,
  );
});

test("PostgresStore createPerson fast path skips auth projection rewrites", async () => {
  const userRecord = {
    id: "user-1",
    email: "smoke@rodnya-tree.ru",
    profile: {displayName: "Smoke User"},
  };
  let state = {
    users: [userRecord],
    sessions: [
      {
        token: "token-1",
        refreshToken: "refresh-1",
        userId: "user-1",
        createdAt: "2026-01-01T00:00:00.000Z",
        lastSeenAt: "2026-01-01T00:00:00.000Z",
      },
    ],
    trees: [
      {
        id: "tree-1",
        creatorId: "user-1",
        memberIds: [],
        members: [],
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
        name: "Smoke Tree",
      },
    ],
    persons: [],
    relations: [],
    treeChangeRecords: [],
    personIdentities: [],
  };
  let projectedSessions = [...state.sessions];
  const queries = [];
  let allowProjectionHydration = true;
  let allowFullStateReads = true;
  const pool = {
    async query(sql, params = []) {
      queries.push(sql);
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        if (allowProjectionHydration) {
          return {rows: []};
        }
        throw new Error(`auth_projection_rewrite_not_allowed:${sql}`);
      }
      if (sql.includes("SELECT session_data")) {
        return {
          rows: projectedSessions.map((entry) => ({session_data: entry})),
        };
      }
      if (
        sql.includes("UPDATE \"public\".\"rodnya_state\"") &&
        sql.includes("'{persons}'")
      ) {
        const nextPerson = JSON.parse(params[1]);
        const treeId = params[2];
        const nextIdentity = JSON.parse(params[3]);
        const tree = state.trees.find((entry) => entry.id === treeId) || null;
        if (!tree) {
          return {rowCount: 0, rows: []};
        }
        state = {
          ...state,
          persons: [...state.persons, nextPerson],
          personIdentities: [...state.personIdentities, nextIdentity],
        };
        return {rowCount: 1, rows: [{updated_at: nextPerson.updatedAt}]};
      }
      if (sql.includes("SELECT data")) {
        if (!allowFullStateReads) {
          throw new Error("full_state_read_not_allowed");
        }
        return {rows: [{data: {migrationStatus: {chatCollectionsToTables: "complete-v1"}}}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        state = JSON.parse(params[1]);
        return {rows: []};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });

  await store.initialize();
  allowFullStateReads = false;
  allowProjectionHydration = false;
  queries.length = 0;

  const person = await store.createPerson({
    treeId: "tree-1",
    creatorId: "user-1",
    personData: {
      firstName: "Иван",
      lastName: "Петров",
      gender: "male",
    },
  });

  assert.equal(person?.treeId, "tree-1");
  assert.ok(person?.identityId);
  assert.equal(state.persons.length, 1);
  assert.equal(state.persons[0].identityId, person.identityId);
  assert.equal(state.personIdentities.length, 1);
  assert.equal(state.personIdentities[0].id, person.identityId);
  assert.deepEqual(state.personIdentities[0].personIds, [person.id]);
  assert.equal(state.treeChangeRecords.length, 0);
  assert.equal(
    queries.some(
      (sql) =>
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\""),
    ),
    false,
  );
  assert.equal(
    queries.some(
      (sql) =>
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\""),
    ),
    false,
  );
  assert.equal(
    queries.some((sql) => sql.includes("SELECT data FROM")),
    false,
  );
  assert.equal(
    queries.some((sql) => sql.includes("'{treeChangeRecords}'")),
    false,
  );
  assert.equal(
    queries.some((sql) => sql.includes("'{trees}'")),
    false,
  );
});

test("PostgresStore deletePerson supports identity-backed offline people", async () => {
  let state = {
    users: [],
    sessions: [],
    trees: [
      {
        id: "tree-1",
        creatorId: "user-1",
        memberIds: [],
        members: [],
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
        name: "Smoke Tree",
      },
    ],
    persons: [
      {
        id: "person-1",
        treeId: "tree-1",
        userId: null,
        identityId: "identity-1",
        name: "Smoke Relative",
        creatorId: "user-1",
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
    ],
    relations: [],
    treeChangeRecords: [],
    personIdentities: [
      {
        id: "identity-1",
        userId: null,
        personIds: ["person-1"],
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
    ],
  };
  let projectedSessions = [];
  const queries = [];
  const pool = {
    async query(sql, params = []) {
      queries.push(sql);
      if (
        sql.includes("CREATE SCHEMA") ||
        sql.includes("CREATE TABLE") ||
        sql.includes("CREATE INDEX") ||
        sql.includes("ON CONFLICT (id) DO NOTHING")
      ) {
        return {rows: []};
      }
      if (
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("DELETE FROM \"public\".\"rodnya_state_auth_sessions\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_users\"") ||
        sql.includes("INSERT INTO \"public\".\"rodnya_state_auth_sessions\"")
      ) {
        return {rows: []};
      }
      if (sql.includes("SELECT session_data")) {
        return {
          rows: projectedSessions.map((entry) => ({session_data: entry})),
        };
      }
      if (sql.includes("SELECT data")) {
        return {rows: [{data: state}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        state = JSON.parse(params[1]);
        return {rows: []};
      }
      if (sql.includes("_chat")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: []};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });

  await store.initialize();
  queries.length = 0;

  const deleted = await store.deletePerson("tree-1", "person-1", "user-1");

  assert.equal(deleted, true);
  assert.equal(state.persons.length, 0);
  assert.equal(state.personIdentities.length, 0);
  assert.equal(state.treeChangeRecords.length, 1);
  assert.equal(state.treeChangeRecords[0].type, "person.deleted");
});

test("PostgresStore communication hot paths avoid full state reads", async () => {
  // pg-mem гоняет НАСТОЯЩИЙ SQL стора: бут-миграция переносит сообщения из
  // блоба в таблицы (канонизируя alias-чат id), а превью/непрочитанные/поиск
  // работают по таблицам без единого чтения всего состояния.
  const {newDb} = require("pg-mem");
  const memDb = newDb();
  const {Pool} = memDb.adapters.createPg();
  const rawPool = new Pool();
  const queries = [];
  // Вместо пре-создания таблицы (pg-mem не переваривает повторный
  // CREATE TABLE IF NOT EXISTS) подменяем содержимое seed-вставки пустого
  // состояния в _bootstrap — миграция увидит блоб с чатами и сообщениями.
  const pool = {
    query: (sql, params) => {
      queries.push(String(sql));
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

  const seededState = {
    users: [
      {id: "user-1", email: "ivan@rodnya-tree.ru", profile: {displayName: "Иван"}},
      {
        id: "user-2",
        email: "anna@rodnya-tree.ru",
        profile: {
          displayName: "Анна",
          photoUrl: "https://cdn.rodnya-tree.ru/anna.jpg",
        },
      },
      {
        id: "user-3",
        email: "boris@rodnya-tree.ru",
        profile: {
          displayName: "Борис",
          photoUrl: "https://cdn.rodnya-tree.ru/boris.jpg",
        },
      },
    ],
    chats: [
      {
        id: "user-1_user-2",
        type: "direct",
        title: null,
        participantIds: ["user-1", "user-2"],
        createdAt: "2026-04-21T11:00:00.000Z",
        updatedAt: "2026-04-21T12:02:00.000Z",
      },
      {
        id: "chat_group",
        type: "group",
        title: "Семейный чат",
        participantIds: ["user-1", "user-2", "user-3"],
        createdAt: "2026-04-21T10:00:00.000Z",
        updatedAt: "2026-04-21T11:30:00.000Z",
      },
    ],
    messages: [
      {
        id: "message-direct-1",
        chatId: "user-1_user-2",
        senderId: "user-2",
        text: "Привет",
        timestamp: "2026-04-21T12:01:00.000Z",
        isRead: false,
        participants: ["user-1", "user-2"],
      },
      {
        id: "message-direct-2",
        chatId: "user-2_user-1",
        senderId: "user-2",
        text: "Как дела?",
        timestamp: "2026-04-21T12:02:00.000Z",
        isRead: false,
        participants: ["user-1", "user-2"],
      },
      {
        id: "message-group-1",
        chatId: "chat_group",
        senderId: "user-3",
        text: "Собираемся вечером",
        timestamp: "2026-04-21T11:30:00.000Z",
        isRead: true,
        participants: ["user-1", "user-2", "user-3"],
      },
    ],
  };

  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
  });
  await store.initialize();
  queries.length = 0;

  const previews = await store.listChatPreviews("user-1");
  assert.equal(previews.length, 2);
  assert.equal(previews[0]?.chatId, "user-1_user-2");
  assert.equal(previews[0]?.lastMessage, "Как дела?");
  assert.equal(previews[0]?.unreadCount, 2);
  assert.equal(previews[0]?.otherUserName, "Анна");
  assert.equal(await store.countUnreadChatMessages("user-1"), 2);

  const history = await store.listChatMessages("user-1_user-2", {limit: 10});
  assert.deepEqual(
    history.map((message) => message.id),
    ["message-direct-2", "message-direct-1"],
  );
  assert.equal(history[0]?.chatId, "user-1_user-2");

  const searchResults = await store.searchChatMessages({
    userId: "user-1",
    query: "вечером",
    chatId: "chat_group",
    limit: 5,
  });
  assert.deepEqual(
    searchResults.map((entry) => entry.messageId),
    ["message-group-1"],
  );

  assert.equal(
    queries.some((sql) => sql.includes("SELECT data FROM")),
    false,
  );
});

// ── SPEED-8a: кэш чтения по версии строки ──────────────────────────────────

test("каждый UPDATE строки состояния инкрементит version (статический сторож кэша)", async () => {
  const source = await fs.readFile(
    path.join(__dirname, "../src/postgres-store.js"),
    "utf8",
  );
  const updates = [...source.matchAll(/UPDATE \$\{this\._qualifiedTableName\}/g)];
  assert.ok(updates.length >= 5, `ожидали точечные UPDATE, нашли ${updates.length}`);
  for (const match of updates) {
    const window = source.slice(match.index, match.index + 900);
    assert.match(
      window,
      /version = /,
      `UPDATE без version @${source.slice(0, match.index).split("\n").length}: кэш чтения отдаст устаревшее`,
    );
  }
});

function buildVersionedPool(initialState) {
  let state = initialState;
  let version = 3;
  const counters = {snapshotSelects: 0, versionSelects: 0, upserts: 0};
  const pool = {
    counters,
    bump(nextState) {
      state = nextState;
      version += 1;
    },
    async query(sql, params = []) {
      if (sql.includes("CREATE SCHEMA") || sql.includes("CREATE TABLE") ||
          sql.includes("CREATE INDEX") || sql.includes("ALTER TABLE")) {
        return {rows: []};
      }
      if (sql.includes("ON CONFLICT (id) DO NOTHING")) {
        return {rows: []};
      }
      if (sql.includes("DELETE FROM") || sql.includes("INSERT INTO \"public\".\"rodnya_state_auth")) {
        return {rows: []};
      }
      if (sql.includes("SELECT session_data")) {
        return {rows: []};
      }
      if (sql.includes("SELECT version FROM")) {
        counters.versionSelects += 1;
        return {rows: [{version}]};
      }
      if (sql.includes("SELECT data, version FROM")) {
        counters.snapshotSelects += 1;
        return {rows: [{data: state, version}]};
      }
      if (sql.includes("SELECT data FROM")) {
        return {rows: [{data: state}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        counters.upserts += 1;
        state = JSON.parse(params[1]);
        version += 1;
        return {rows: [{version}]};
      }
      if (sql.includes("_chat") || sql.includes("_notification") || sql.includes("_push")) {
        return {rows: []};
      }
      if (sql.startsWith("UPDATE") && sql.includes("SET data")) {
        return {rows: [], rowCount: 1};
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };
  return pool;
}

test("SPEED-8a: повторный _read без записей не перечитывает блоб", async () => {
  const pool = buildVersionedPool({users: [{id: "u1", email: "a@b"}], trees: []});
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });

  const first = await store._read();
  assert.equal(first.users[0].id, "u1");
  assert.equal(pool.counters.snapshotSelects, 1);

  const second = await store._read();
  assert.equal(second.users[0].id, "u1");
  assert.equal(pool.counters.snapshotSelects, 1, "версия совпала — блоб не читаем");
  assert.ok(pool.counters.versionSelects >= 2);

  // Клон, а не общий объект: мутация результата не портит кэш.
  second.users.push({id: "u2"});
  const third = await store._read();
  assert.equal(third.users.length, 1);
});

test("SPEED-8a: после _write следующий _read отдаёт новое состояние без перечитывания", async () => {
  const pool = buildVersionedPool({users: [{id: "u1", email: "a@b"}], trees: []});
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });

  const state = await store._read();
  state.trees.push({id: "t1", name: "Наше дерево", memberIds: ["u1"]});
  await store._write(state);
  assert.equal(pool.counters.upserts, 1);

  const after = await store._read();
  assert.equal(after.trees.length, 1);
  assert.equal(after.trees[0].id, "t1");
  assert.equal(pool.counters.snapshotSelects, 1, "запись обновила кэш под новой версией");
});

test("SPEED-8a: чужая запись (version ушла вперёд) инвалидирует кэш", async () => {
  const pool = buildVersionedPool({users: [{id: "u1", email: "a@b"}], trees: []});
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });

  await store._read();
  pool.bump({users: [{id: "u1", email: "a@b"}, {id: "u2", email: "c@d"}], trees: []});
  const after = await store._read();
  assert.equal(after.users.length, 2);
  assert.equal(pool.counters.snapshotSelects, 2);
});

test("SPEED-8a: без колонки version (старый pool) кэш выключен, чтение честное", async () => {
  let state = {users: [{id: "u1", email: "a@b"}], trees: []};
  let selects = 0;
  const pool = {
    async query(sql, params = []) {
      if (sql.includes("CREATE") || sql.includes("ALTER TABLE") ||
          sql.includes("ON CONFLICT (id) DO NOTHING") || sql.includes("DELETE FROM") ||
          sql.includes("SELECT session_data") || sql.includes("_chat") ||
          sql.includes("_notification") || sql.includes("_push") ||
          sql.includes("INSERT INTO \"public\".\"rodnya_state_auth")) {
        return {rows: []};
      }
      if (sql.includes("SELECT version FROM")) {
        throw new Error("column version does not exist");
      }
      if (sql.includes("SELECT data")) {
        // Считаем только чтения снимка из _read (бут-миграции тоже
        // читают блоб — они не про кэш).
        if (sql.includes("SELECT data, version FROM")) {
          selects += 1;
        }
        return {rows: [{data: state}]};
      }
      if (sql.includes("ON CONFLICT (id) DO UPDATE")) {
        state = JSON.parse(params[1]);
        return {rows: []};
      }
      // Всё прочее (LATERAL-выборки миграций, проекции) этому тесту
      // безразлично — важен только отказ колонки version.
      return {rows: [], rowCount: 0};
    },
  };
  const store = new PostgresStore({
    connectionString: "postgresql://unused/rodnya",
    pool,
    snapshotCachePath: null,
  });
  await store._read();
  await store._read();
  assert.equal(selects, 2, "нет version — каждое чтение идёт в БД");
});
