const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");
const {Pool} = require("pg");

const {
  FileStore,
  EMPTY_DB,
  computeNotificationCoalesceKey,
  decodeNotificationCursor,
  encodeNotificationCursor,
  createNotificationRecord,
  createPushDeliveryRecord,
  buildChatSearchSnippet,
  buildPersonRecord,
  chatMessageSearchHaystack,
  cloneUserWithAuthState,
  collectMessageMediaUrls,
  createChatDraftRecord,
  createChatPinRecord,
  createPersonIdentityRecord,
  deriveSessionPublicId,
  describeMessagePreview,
  isMessageReadByUser,
  normalizeChatMessageCall,
  normalizeChatSearchQuery,
  normalizeDbState,
  normalizeNullableString,
  normalizeOptionalIsoTimestamp,
  normalizeParticipantIds,
  normalizeReactionEmoji,
  normalizeSessionDeviceContext,
  normalizeStoredCall,
  nowIso,
  parseDirectParticipantsFromChatId,
  SESSION_TOUCH_MIN_INTERVAL_MS,
  verifyPassword,
} = require("./store");
const {
  normalizeMessageAttachments,
  normalizeReplyReference,
} = require("./chat-utils");
const {backfillPersonIdentities} = require("./migration-utils");

const DEFAULT_POSTGRES_CONNECTION_TIMEOUT_MS = 5_000;
const DEFAULT_POSTGRES_QUERY_TIMEOUT_MS = 15_000;
const DEFAULT_POSTGRES_READ_QUERY_TIMEOUT_MS = 60_000;
const DEFAULT_POSTGRES_READ_RETRY_COUNT = 1;
const DEFAULT_POSTGRES_READ_RETRY_DELAY_MS = 250;
const DEFAULT_POSTGRES_IDLE_TIMEOUT_MS = 30_000;
const DEFAULT_WRITE_QUEUE_TIMEOUT_MS = 15_000;
const DEFAULT_POSTGRES_POOL_MAX = 64;
const DEFAULT_POSTGRES_APPLICATION_NAME = "rodnya_backend";
const SHARED_POOL_REGISTRY = new Map();

function isProjectionHydrationFallbackError(error) {
  const message = String(error?.message || "").toLowerCase();
  return message.includes('column "data" does not exist');
}

function isProjectionArrayInsertFallbackError(error) {
  const message = String(error?.message || "").toLowerCase();
  return message.includes("jsonb_array_elements(jsonb) does not exist");
}

function isProjectionArrayTextFallbackError(error) {
  const message = String(error?.message || "").toLowerCase();
  return message.includes("jsonb_array_elements_text(jsonb) does not exist");
}

function computeProjectionHash(value) {
  return JSON.stringify(Array.isArray(value) ? value : []);
}

function quoteIdentifier(value) {
  const normalized = String(value || "").trim();
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(normalized)) {
    throw new Error(`Invalid PostgreSQL identifier: ${value}`);
  }
  return `"${normalized}"`;
}

function buildSharedPoolKey({
  connectionString,
  connectionTimeoutMillis,
  queryTimeoutMs,
  idleTimeoutMillis,
  poolMax,
  applicationName,
}) {
  return JSON.stringify({
    connectionString: String(connectionString || "").trim(),
    connectionTimeoutMillis,
    queryTimeoutMs,
    idleTimeoutMillis,
    poolMax,
    applicationName: String(applicationName || DEFAULT_POSTGRES_APPLICATION_NAME).trim() ||
      DEFAULT_POSTGRES_APPLICATION_NAME,
  });
}

function acquireSharedPool({
  connectionString,
  connectionTimeoutMillis,
  queryTimeoutMs,
  idleTimeoutMillis,
  poolMax,
  applicationName,
  poolFactory,
}) {
  const registryKey = buildSharedPoolKey({
    connectionString,
    connectionTimeoutMillis,
    queryTimeoutMs,
    idleTimeoutMillis,
    poolMax,
    applicationName,
  });
  let entry = SHARED_POOL_REGISTRY.get(registryKey);
  if (!entry) {
    entry = {
      refs: 0,
      pool: poolFactory({
        connectionString,
        connectionTimeoutMillis,
        idleTimeoutMillis,
        keepAlive: true,
        max: poolMax,
        query_timeout: queryTimeoutMs > 0 ? queryTimeoutMs : undefined,
        statement_timeout: queryTimeoutMs > 0 ? queryTimeoutMs : undefined,
        application_name:
          String(applicationName || DEFAULT_POSTGRES_APPLICATION_NAME).trim() ||
          DEFAULT_POSTGRES_APPLICATION_NAME,
      }),
    };
    SHARED_POOL_REGISTRY.set(registryKey, entry);
  }
  entry.refs += 1;

  let released = false;
  return {
    pool: entry.pool,
    async release() {
      if (released) {
        return;
      }
      released = true;
      entry.refs = Math.max(0, entry.refs - 1);
      if (entry.refs === 0) {
        SHARED_POOL_REGISTRY.delete(registryKey);
        await entry.pool.end();
      }
    },
  };
}



class PostgresStore extends FileStore {
  constructor({
    connectionString,
    schema = "public",
    table = "rodnya_state",
    rowId = "default",
    pool = null,
    poolFactory = (options) => new Pool(options),
    connectionTimeoutMillis = DEFAULT_POSTGRES_CONNECTION_TIMEOUT_MS,
    queryTimeoutMs = DEFAULT_POSTGRES_QUERY_TIMEOUT_MS,
    readQueryTimeoutMs = DEFAULT_POSTGRES_READ_QUERY_TIMEOUT_MS,
    readRetryCount = DEFAULT_POSTGRES_READ_RETRY_COUNT,
    readRetryDelayMs = DEFAULT_POSTGRES_READ_RETRY_DELAY_MS,
    writeQueueTimeoutMs = null,
    idleTimeoutMillis = DEFAULT_POSTGRES_IDLE_TIMEOUT_MS,
    poolMax = DEFAULT_POSTGRES_POOL_MAX,
    applicationName = DEFAULT_POSTGRES_APPLICATION_NAME,
    snapshotCachePath = null,
  }) {
    super(`postgres://${schema}.${table}/${rowId}`);

    if (!pool && !String(connectionString || "").trim()) {
      throw new Error(
        "RODNYA_POSTGRES_URL is required when RODNYA_BACKEND_STORAGE=postgres",
      );
    }

    this._poolRelease = null;
    if (pool) {
      this._pool = pool;
      this._ownsPool = false;
    } else {
      const sharedPool = acquireSharedPool({
        connectionString,
        connectionTimeoutMillis,
        queryTimeoutMs,
        idleTimeoutMillis,
        poolMax,
        applicationName,
        poolFactory,
      });
      this._pool = sharedPool.pool;
      this._poolRelease = sharedPool.release;
      this._ownsPool = false;
    }
    this._schema = String(schema || "public").trim() || "public";
    this._table = String(table || "rodnya_state").trim() || "rodnya_state";
    this._rowId = String(rowId || "default").trim() || "default";
    this._qualifiedTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._table)}`;
    this._authUsersTable = `${this._table}_auth_users`;
    this._authSessionsTable = `${this._table}_auth_sessions`;
    this._qualifiedAuthUsersTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._authUsersTable)}`;
    this._qualifiedAuthSessionsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._authSessionsTable)}`;
    // SPEED-6: горячие чат-коллекции живут в собственных таблицах, а не в
    // JSONB-блобе — send = INSERT, access-check = индексный SELECT.
    this._chatMessagesTable = `${this._table}_chat_messages`;
    this._chatReactionsTable = `${this._table}_chat_reactions`;
    this._chatDraftsTable = `${this._table}_chat_drafts`;
    this._chatPinsTable = `${this._table}_chat_pins`;
    this._chatsProjectionTable = `${this._table}_chats_projection`;
    this._chatParticipantsTable = `${this._table}_chat_participants`;
    this._chatBackupsTable = `${this._table}_chat_backups`;
    this._qualifiedChatMessagesTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatMessagesTable)}`;
    this._qualifiedChatReactionsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatReactionsTable)}`;
    this._qualifiedChatDraftsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatDraftsTable)}`;
    this._qualifiedChatPinsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatPinsTable)}`;
    this._qualifiedChatsProjectionTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatsProjectionTable)}`;
    this._qualifiedChatParticipantsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatParticipantsTable)}`;
    this._qualifiedChatBackupsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._chatBackupsTable)}`;
    // SPEED-7: notifications и pushDeliveries уезжают из блоба целиком —
    // фан-аут уведомлений = INSERT'ы вместо whole-blob RMW на каждую запись.
    this._notificationsTable = `${this._table}_notifications`;
    this._pushDeliveriesTable = `${this._table}_push_deliveries`;
    this._notificationBackupsTable = `${this._table}_notification_backups`;
    this._qualifiedNotificationsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._notificationsTable)}`;
    this._qualifiedPushDeliveriesTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._pushDeliveriesTable)}`;
    this._qualifiedNotificationBackupsTableName = `${quoteIdentifier(this._schema)}.${quoteIdentifier(this._notificationBackupsTable)}`;
    // SPEED-7: гейт готовности — false, пока бут-миграция не подтвердила
    // маркер. При транзиентно недоступном состоянии миграция скипается, и
    // ВСЕ notification-оверрайды делегируют в FileStore-путь по блобу:
    // иначе тихая пустая лента + drain обнулил бы массивы ДО миграции и
    // write-once бэкап отката навсегда запомнил бы пустоту (ревью, P1).
    this._notificationTablesReady = false;
    this._lastChatsProjectionHash = null;
    this._chatPurgeSweepScheduled = false;
    this._chatsProjectionDirty = false;
    this._chatRowMutationQueue = Promise.resolve();
    this._initializePromise = null;
    this._cachedState = null;
    this._snapshotLoadPromise = null;
    this.storageMode = "postgres";
    this.storageTarget = `${this._schema}.${this._table}:${this._rowId}`;
    const normalizedWriteQueueTimeoutMs = Number(writeQueueTimeoutMs);
    this._writeQueueTimeoutMs =
      Number.isFinite(normalizedWriteQueueTimeoutMs) &&
      normalizedWriteQueueTimeoutMs > 0
        ? Math.floor(normalizedWriteQueueTimeoutMs)
        : queryTimeoutMs > 0
          ? Math.max(queryTimeoutMs, DEFAULT_WRITE_QUEUE_TIMEOUT_MS)
          : DEFAULT_WRITE_QUEUE_TIMEOUT_MS;
    this._readQueryTimeoutMs =
      Number.isFinite(Number(readQueryTimeoutMs)) && Number(readQueryTimeoutMs) > 0
        ? Math.floor(Number(readQueryTimeoutMs))
        : 0;
    this._readRetryCount =
      Number.isFinite(Number(readRetryCount)) && Number(readRetryCount) >= 0
        ? Math.floor(Number(readRetryCount))
        : DEFAULT_POSTGRES_READ_RETRY_COUNT;
    this._readRetryDelayMs =
      Number.isFinite(Number(readRetryDelayMs)) && Number(readRetryDelayMs) >= 0
        ? Math.floor(Number(readRetryDelayMs))
        : DEFAULT_POSTGRES_READ_RETRY_DELAY_MS;
    this._snapshotCachePath = String(snapshotCachePath || "").trim() || null;
    this._snapshotCacheHydrationPromise = null;
    this._stateWriteQueue = Promise.resolve();
    this._sessionWriteQueue = Promise.resolve();
    this._writeQueue = this._stateWriteQueue;
    this._lastUsersProjectionHash = null;
    this._lastSessionsProjectionHash = null;
  }

  async initialize() {
    if (!this._initializePromise) {
      this._initializePromise = this._bootstrap();
    }
    await this._initializePromise;
  }

  async healthCheck() {
    await this.initialize();
    await this._pool.query("SELECT 1");
  }

  async _bootstrap() {
    await this._pool.query(
      `CREATE SCHEMA IF NOT EXISTS ${quoteIdentifier(this._schema)}`,
    );

    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedTableName} (
        id TEXT PRIMARY KEY,
        data JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
    await this._pool.query(
      `
        INSERT INTO ${this._qualifiedTableName} (id, data)
        VALUES ($1, $2::jsonb)
        ON CONFLICT (id) DO NOTHING
      `,
      [this._rowId, JSON.stringify(EMPTY_DB)],
    );
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedAuthUsersTableName} (
        id TEXT PRIMARY KEY,
        email TEXT,
        user_data JSONB NOT NULL
      )
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._authUsersTable}_email_idx`)}
        ON ${this._qualifiedAuthUsersTableName} (email)
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedAuthSessionsTableName} (
        token TEXT PRIMARY KEY,
        refresh_token TEXT,
        user_id TEXT NOT NULL,
        created_at TEXT,
        session_data JSONB NOT NULL
      )
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._authSessionsTable}_refresh_idx`)}
        ON ${this._qualifiedAuthSessionsTableName} (refresh_token)
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._authSessionsTable}_user_idx`)}
        ON ${this._qualifiedAuthSessionsTableName} (user_id)
    `);
    try {
      await this._pool.query(`
        CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._table}_messages_fts_idx`)}
          ON ${this._qualifiedTableName}
          USING GIN (to_tsvector('russian', COALESCE(data->>'messages', '')))
      `);
    } catch (error) {
      const message = String(error?.message || "").toLowerCase();
      if (
        !message.includes("to_tsvector") &&
        !message.includes("text search configuration")
      ) {
        throw error;
      }
      console.warn(
        "[backend] postgres-store skipped message fts index",
        JSON.stringify({
          table: `${this._schema}.${this._table}`,
          rowId: this._rowId,
          message: error?.message || String(error),
        }),
      );
    }
    await this._createChatTables();
    await this._createNotificationTables();
    await this._backfillPersonIdentitiesInStateRow();
    await this._hydrateAuthProjectionTablesFromStateRow();
    await this._migrateChatCollectionsToTables();
    await this._migrateNotificationCollectionsToTables();
    await this._hydrateChatProjectionFromState();
  }

  // ── SPEED-6: чат-таблицы ─────────────────────────────────────────────
  // Сообщения/реакции/черновики/пины уезжают из JSONB-блоба в таблицы:
  // отправка = один INSERT вне глобальной _mutateQueue, история — индексная
  // страница, dedup — уникальный индекс. Записи ЧАТОВ остаются в блобе
  // (звонки, deleteUser, merge персон читают их внутри _mutate-applyFn),
  // но зеркалятся в projection-таблицу — access-check на send-пути стал
  // индексным SELECT вместо чтения всего блоба.
  async _createChatTables() {
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatMessagesTableName} (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        ts TEXT NOT NULL,
        client_message_id TEXT NOT NULL DEFAULT '',
        expires_at TEXT NOT NULL DEFAULT '',
        haystack TEXT NOT NULL DEFAULT '',
        dedup_key TEXT NOT NULL,
        message_data JSONB NOT NULL
      )
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._chatMessagesTable}_page_idx`)}
        ON ${this._qualifiedChatMessagesTableName} (chat_id, ts, id)
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._chatMessagesTable}_sender_idx`)}
        ON ${this._qualifiedChatMessagesTableName} (sender_id)
    `);
    // Жёсткая гарантия dedup по (chatId, senderId, clientMessageId):
    // dedup_key = "chat|sender|clientMessageId" для сообщений с client-id,
    // иначе просто id строки (уникален сам по себе). Полный (не партиальный)
    // уникальный индекс — партиальные индексы ломают pg-mem, а вычисляемый
    // ключ переносим на любой движок.
    await this._pool.query(`
      CREATE UNIQUE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._chatMessagesTable}_dedup_idx`)}
        ON ${this._qualifiedChatMessagesTableName} (dedup_key)
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._chatMessagesTable}_expires_idx`)}
        ON ${this._qualifiedChatMessagesTableName} (expires_at)
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatReactionsTableName} (
        message_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        emoji TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (message_id, user_id, emoji)
      )
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatDraftsTableName} (
        user_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        draft_data JSONB NOT NULL,
        PRIMARY KEY (user_id, chat_id)
      )
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatPinsTableName} (
        chat_id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        pin_data JSONB NOT NULL
      )
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatsProjectionTableName} (
        id TEXT PRIMARY KEY,
        chat_data JSONB NOT NULL
      )
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatParticipantsTableName} (
        chat_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        PRIMARY KEY (chat_id, user_id)
      )
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._chatParticipantsTable}_user_idx`)}
        ON ${this._qualifiedChatParticipantsTableName} (user_id)
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedChatBackupsTableName} (
        id TEXT PRIMARY KEY,
        backup_data JSONB NOT NULL
      )
    `);
  }

  _canonicalChatIdFor(chatId) {
    const normalized = String(chatId || "").trim();
    const directParticipants = parseDirectParticipantsFromChatId(normalized);
    return directParticipants.length === 2
      ? directParticipants.join("_")
      : normalized;
  }

  _equivalentChatIdList(chatId, resolvedChatId = null) {
    const ids = new Set();
    const normalized = String(chatId || "").trim();
    if (normalized) {
      ids.add(normalized);
    }
    const canonical = this._canonicalChatIdFor(normalized);
    if (canonical) {
      ids.add(canonical);
    }
    const resolved = String(resolvedChatId || "").trim();
    if (resolved) {
      ids.add(resolved);
    }
    return Array.from(ids);
  }

  _chatMessageRowValues(message) {
    const id = String(message?.id || "").trim();
    const chatId = String(message?.chatId || "").trim();
    const senderId = String(message?.senderId || "").trim();
    const clientMessageId = normalizeNullableString(message?.clientMessageId) || "";
    const dedupKey = clientMessageId
      ? `${chatId}|${senderId}|${clientMessageId}`
      : id;
    return [
      id,
      chatId,
      senderId,
      String(message?.timestamp || "").trim(),
      clientMessageId,
      normalizeOptionalIsoTimestamp(message?.expiresAt) || "",
      // Переводы строк из haystack схлопываем в пробелы: семантика поиска
      // (подстрока в пределах терма) не меняется, а LIKE-движки (в т.ч.
      // pg-mem) не спотыкаются о многострочность.
      chatMessageSearchHaystack(message).replace(/\s+/g, " "),
      dedupKey,
      JSON.stringify(message),
    ];
  }

  async _insertChatMessageRow(message) {
    await this._pool.query(
      `INSERT INTO ${this._qualifiedChatMessagesTableName}
         (id, chat_id, sender_id, ts, client_message_id, expires_at, haystack, dedup_key, message_data)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)`,
      this._chatMessageRowValues(message),
    );
  }

  // Receipt/edit-пути делают SELECT→изменение→полная перезапись message_data.
  // В FileStore их сериализовала глобальная _mutateQueue; здесь — узкая
  // очередь ТОЛЬКО для таких RMW строк сообщений (два конкурентных
  // delivered-ack'а иначе теряют друг друга). Отправка (чистый INSERT) в
  // очереди не участвует — ack-путь остаётся неблокирующим.
  _enqueueChatRowMutation(operation) {
    this._chatRowMutationQueue = (this._chatRowMutationQueue || Promise.resolve())
      .then(operation, operation);
    return this._chatRowMutationQueue;
  }

  async _updateChatMessageRow(message) {
    const values = this._chatMessageRowValues(message);
    await this._pool.query(
      `UPDATE ${this._qualifiedChatMessagesTableName}
          SET chat_id = $2,
              sender_id = $3,
              ts = $4,
              client_message_id = $5,
              expires_at = $6,
              haystack = $7,
              dedup_key = $8,
              message_data = $9::jsonb
        WHERE id = $1`,
      values,
    );
  }

  // Одноразовая (идемпотентная) миграция чат-коллекций из блоба в таблицы.
  // ── SPEED-7: notifications + pushDeliveries ──────────────────────────
  // Обе коллекции — только-пишущие с точки зрения чужих _mutate-applyFn
  // (никто их не читает внутри applyFn), поэтому в отличие от чатов их можно
  // вынести целиком, без projection. NULL-колонок нет (pg-mem не дружит с
  // параметризованным NULL): read_at='' = непрочитано, silent 0/1.
  /// Находка репетиции на прод-дампе: на проде с апреля 2026 живёт
  /// таблица rodnya_state_notifications СТАРОЙ схемы (notification_id PK,
  /// без type/silent/coalesce_key) — артефакт раннего эксперимента, никем
  /// не читается (актуальные уведомления жили в блобе). CREATE IF NOT
  /// EXISTS молча пропускал создание, а CREATE INDEX падал на
  /// несуществующей колонке id и валил бут. Несовместимую таблицу
  /// переименовываем (сохраняем, не дропаем) и создаём заново.
  // PK-констрейнты новых таблиц имеют ЯВНЫЕ имена (<t>_pk, не дефолтный
  // _pkey): после эвакуации+DROP легаси-таблицы pg-mem (а потенциально и
  // осиротевшие объекты на реальном PG) держат старое имя «..._pkey».
  async _renameIfIncompatibleTable(qualifiedName, bareName, probeColumn) {
    try {
      await this._pool.query(
        `SELECT ${probeColumn} FROM ${qualifiedName} LIMIT 1`,
      );
      return; // таблица есть и совместима
    } catch (error) {
      const message = String(error?.message || "").toLowerCase();
      const isColumnMismatch =
        error?.code === "42703" ||
        (message.includes("column") && message.includes("does not exist"));
      if (!isColumnMismatch) {
        // Таблицы нет (или иная причина) — CREATE IF NOT EXISTS разберётся.
        return;
      }
    }
    // Эвакуация содержимого в backup-таблицу + DROP. Не RENAME (тянет имя
    // PK-констрейнта — CREATE новой таблицы падает на «_pkey already
    // exists») и не CTAS (pg-mem его не парсит): только простые операции.
    console.warn(
      "[backend] incompatible legacy table evacuated before SPEED-7 DDL",
      JSON.stringify({table: bareName}),
    );
    const legacyRows = await this._pool.query(
      `SELECT * FROM ${qualifiedName}`,
    );
    await this._pool.query(
      `INSERT INTO ${this._qualifiedNotificationBackupsTableName} (id, backup_data)
       VALUES ($1, $2::jsonb)
       ON CONFLICT (id) DO NOTHING`,
      [
        `legacy-table-${bareName}`,
        JSON.stringify({savedAt: nowIso(), rows: legacyRows.rows}),
      ],
    );
    await this._pool.query(`DROP TABLE ${qualifiedName}`);
  }

  async _createNotificationTables() {
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedNotificationBackupsTableName} (
        id TEXT PRIMARY KEY,
        backup_data JSONB NOT NULL
      )
    `);
    await this._renameIfIncompatibleTable(
      this._qualifiedNotificationsTableName,
      this._notificationsTable,
      "id",
    );
    await this._renameIfIncompatibleTable(
      this._qualifiedPushDeliveriesTableName,
      this._pushDeliveriesTable,
      "id",
    );
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedNotificationsTableName} (
        id TEXT,
        user_id TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'generic',
        created_at TEXT NOT NULL,
        read_at TEXT NOT NULL DEFAULT '',
        silent INT NOT NULL DEFAULT 0,
        coalesce_key TEXT NOT NULL DEFAULT '',
        notification_data JSONB NOT NULL,
        CONSTRAINT ${quoteIdentifier(`${this._notificationsTable}_pk`)} PRIMARY KEY (id)
      )
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._notificationsTable}_page_idx`)}
        ON ${this._qualifiedNotificationsTableName} (user_id, created_at, id)
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._notificationsTable}_unread_idx`)}
        ON ${this._qualifiedNotificationsTableName} (user_id, read_at)
    `);
    // НЕ уникальный: несколько ПРОЧИТАННЫХ записей с одним ключом легальны,
    // коалесинг применяется только к непрочитанным (SELECT → UPDATE/INSERT).
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._notificationsTable}_coalesce_idx`)}
        ON ${this._qualifiedNotificationsTableName} (user_id, coalesce_key)
    `);
    await this._pool.query(`
      CREATE TABLE IF NOT EXISTS ${this._qualifiedPushDeliveriesTableName} (
        id TEXT,
        notification_id TEXT NOT NULL DEFAULT '',
        user_id TEXT NOT NULL,
        device_id TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT 'unknown',
        status TEXT NOT NULL DEFAULT 'queued',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        delivery_data JSONB NOT NULL,
        CONSTRAINT ${quoteIdentifier(`${this._pushDeliveriesTable}_pk`)} PRIMARY KEY (id)
      )
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._pushDeliveriesTable}_user_idx`)}
        ON ${this._qualifiedPushDeliveriesTableName} (user_id, created_at)
    `);
    await this._pool.query(`
      CREATE INDEX IF NOT EXISTS ${quoteIdentifier(`${this._pushDeliveriesTable}_device_idx`)}
        ON ${this._qualifiedPushDeliveriesTableName} (device_id)
    `);
  }

  _notificationRowValues(notification) {
    const record = notification || {};
    return [
      String(record.id || "").trim(),
      String(record.userId || "").trim(),
      String(record.type || "generic").trim() || "generic",
      String(record.createdAt || "").trim(),
      String(record.readAt || "").trim(),
      record.silent === true ? 1 : 0,
      computeNotificationCoalesceKey(record),
      JSON.stringify(record),
    ];
  }

  _pushDeliveryRowValues(delivery) {
    const record = delivery || {};
    return [
      String(record.id || "").trim(),
      String(record.notificationId || "").trim(),
      String(record.userId || "").trim(),
      String(record.deviceId || "").trim(),
      String(record.provider || "unknown").trim() || "unknown",
      String(record.status || "queued").trim() || "queued",
      String(record.createdAt || "").trim(),
      String(record.updatedAt || record.createdAt || "").trim(),
      JSON.stringify(record),
    ];
  }

  // Маркер — migrationStatus.notificationsToTables; исходные массивы целиком
  // сохраняются в backup-таблицу (план отката — scripts/
  // restore-notifications-to-blob.js), после чего вычищаются из блоба.
  async _migrateNotificationCollectionsToTables() {
    const MARKER = "complete-v1";
    let state = null;
    try {
      const result = await this._pool.query(
        `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`,
        [this._rowId],
      );
      const rawData = result.rows[0]?.data ?? EMPTY_DB;
      state = normalizeDbState(
        typeof rawData === "string" ? JSON.parse(rawData) : rawData,
      );
    } catch (error) {
      // Состояние недоступно (БД лежит) — общий деградированный режим, не
      // провал миграции: следующий бут повторит попытку (как SPEED-6).
      console.warn(
        "[backend] notification collections migration skipped — state unavailable",
        JSON.stringify({message: error?.message || String(error)}),
      );
      return;
    }
    try {
      if (state?.migrationStatus?.notificationsToTables === MARKER) {
        this._notificationTablesReady = true;
        return;
      }

      const notifications = Array.isArray(state.notifications)
        ? state.notifications
        : [];
      const pushDeliveries = Array.isArray(state.pushDeliveries)
        ? state.pushDeliveries
        : [];

      await this._pool.query(
        `INSERT INTO ${this._qualifiedNotificationBackupsTableName} (id, backup_data)
         VALUES ($1, $2::jsonb)
         ON CONFLICT (id) DO NOTHING`,
        [
          `pre-migration-${MARKER}`,
          JSON.stringify({
            savedAt: nowIso(),
            notifications,
            pushDeliveries,
          }),
        ],
      );

      let skippedNotifications = 0;
      for (const notification of notifications) {
        const rowValues = this._notificationRowValues(notification);
        if (!rowValues[0] || !rowValues[1] || !rowValues[3]) {
          // Без id/userId/createdAt запись не адресуема ни одним
          // рантайм-путём — оставляем только в бэкапе.
          skippedNotifications += 1;
          continue;
        }
        await this._pool.query(
          `INSERT INTO ${this._qualifiedNotificationsTableName}
             (id, user_id, type, created_at, read_at, silent, coalesce_key, notification_data)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
           ON CONFLICT DO NOTHING`,
          rowValues,
        );
      }
      let skippedDeliveries = 0;
      for (const delivery of pushDeliveries) {
        const rowValues = this._pushDeliveryRowValues(delivery);
        if (!rowValues[0] || !rowValues[2] || !rowValues[6]) {
          skippedDeliveries += 1;
          continue;
        }
        await this._pool.query(
          `INSERT INTO ${this._qualifiedPushDeliveriesTableName}
             (id, notification_id, user_id, device_id, provider, status, created_at, updated_at, delivery_data)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)
           ON CONFLICT DO NOTHING`,
          rowValues,
        );
      }

      const nextState = {
        ...state,
        notifications: [],
        pushDeliveries: [],
        migrationStatus: {
          ...(state.migrationStatus || {}),
          notificationsToTables: MARKER,
        },
      };
      await this._pool.query(
        `UPDATE ${this._qualifiedTableName}
            SET data = $2::jsonb,
                updated_at = NOW()
          WHERE id = $1`,
        [this._rowId, JSON.stringify(nextState)],
      );
      this._cachedState = normalizeDbState(nextState);
      // Sidecar-кэш обязан пережить границу миграции (см. SPEED-6): иначе
      // fallback-чтение воскресит домиграционный блоб без маркера.
      await this._persistSnapshotCache(this._cachedState);
      this._notificationTablesReady = true;
      console.log(
        "[backend] notification collections migrated to tables",
        JSON.stringify({
          notifications: notifications.length,
          pushDeliveries: pushDeliveries.length,
          skipped: {
            notifications: skippedNotifications,
            pushDeliveries: skippedDeliveries,
          },
        }),
      );
    } catch (error) {
      // Оверрайды читают ТОЛЬКО таблицы — старт с недомигрированными данными
      // означал бы split-brain. Роняем бут (как SPEED-6).
      console.error(
        "[backend] notification collections migration FAILED — refusing to serve",
        JSON.stringify({message: error?.message || String(error)}),
      );
      throw error;
    }
  }

  // Маркер — migrationStatus.chatCollectionsToTables в самом блобе; исходные
  // массивы целиком сохраняются в backup-таблицу (план отката — scripts/
  // restore-chat-collections-to-blob.js), после чего вычищаются из блоба.
  // chatId сообщений канонизируется (a_b с сортировкой) прямо при переносе,
  // чтобы рантайм-запросы работали по одному id вместо alias-набора.
  async _migrateChatCollectionsToTables() {
    const MARKER = "complete-v1";
    let state = null;
    try {
      const result = await this._pool.query(
        `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`,
        [this._rowId],
      );
      const rawData = result.rows[0]?.data ?? EMPTY_DB;
      state = normalizeDbState(
        typeof rawData === "string" ? JSON.parse(rawData) : rawData,
      );
    } catch (error) {
      // Состояние недоступно (БД лежит) — это не «миграция сломалась», а
      // общий деградированный режим: _read будет сервить sidecar-кэш, а
      // табличные чат-методы честно упадут той же ошибкой соединения.
      // Следующий бут повторит попытку.
      console.warn(
        "[backend] chat collections migration skipped — state unavailable",
        JSON.stringify({message: error?.message || String(error)}),
      );
      return;
    }
    try {
      if (state?.migrationStatus?.chatCollectionsToTables === MARKER) {
        return;
      }

      const messages = Array.isArray(state.messages) ? state.messages : [];
      const reactions = Array.isArray(state.messageReactions)
        ? state.messageReactions
        : [];
      const drafts = Array.isArray(state.chatDrafts) ? state.chatDrafts : [];
      const pins = Array.isArray(state.chatPins) ? state.chatPins : [];

      await this._pool.query(
        `INSERT INTO ${this._qualifiedChatBackupsTableName} (id, backup_data)
         VALUES ($1, $2::jsonb)
         ON CONFLICT (id) DO NOTHING`,
        [
          `pre-migration-${MARKER}`,
          JSON.stringify({
            savedAt: nowIso(),
            messages,
            messageReactions: reactions,
            chatDrafts: drafts,
            chatPins: pins,
          }),
        ],
      );

      // Канонизировать можно ТОЛЬКО настоящие direct-alias'ы: id групповых
      // и branch-чатов (`chat_<uuid>`) тоже парсится на 2 части и сортировка
      // переставила бы их местами, оторвав сообщения от чата. Правило: id
      // сохранённого чата не трогаем, id с префиксом chat_ не трогаем.
      const storedChatIds = new Set(
        (Array.isArray(state.chats) ? state.chats : [])
          .map((chat) => String(chat?.id || "").trim())
          .filter(Boolean),
      );
      const canonicalizeMigratedChatId = (rawChatId) => {
        const normalized = String(rawChatId || "").trim();
        if (storedChatIds.has(normalized) || normalized.startsWith("chat_")) {
          return normalized;
        }
        return this._canonicalChatIdFor(normalized);
      };

      const seenMessageIds = new Set();
      let skippedMessages = 0;
      for (const message of messages) {
        const messageId = String(message?.id || "").trim();
        if (!messageId || seenMessageIds.has(messageId)) {
          skippedMessages += 1;
          continue;
        }
        seenMessageIds.add(messageId);
        const canonicalMessage = {
          ...message,
          chatId: canonicalizeMigratedChatId(message?.chatId),
        };
        // Targetless ON CONFLICT: легаси-дубликат по dedup_key (одинаковый
        // clientMessageId в раздельных когда-то alias-чатах) не должен
        // ронять бут — молча оставляем первый, остальное есть в бэкапе.
        await this._pool.query(
          `INSERT INTO ${this._qualifiedChatMessagesTableName}
             (id, chat_id, sender_id, ts, client_message_id, expires_at, haystack, dedup_key, message_data)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)
           ON CONFLICT DO NOTHING`,
          this._chatMessageRowValues(canonicalMessage),
        );
      }
      for (const reaction of reactions) {
        const messageId = String(reaction?.messageId || "").trim();
        const userId = String(reaction?.userId || "").trim();
        const emoji = normalizeReactionEmoji(reaction?.emoji);
        if (!messageId || !userId || !emoji) {
          continue;
        }
        await this._pool.query(
          `INSERT INTO ${this._qualifiedChatReactionsTableName}
             (message_id, user_id, emoji, created_at)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (message_id, user_id, emoji) DO NOTHING`,
          [messageId, userId, emoji, String(reaction?.createdAt || nowIso())],
        );
      }
      let skippedDrafts = 0;
      for (const draft of drafts) {
        const userId = String(draft?.userId || "").trim();
        const chatId = canonicalizeMigratedChatId(draft?.chatId);
        if (!userId || !chatId || !String(draft?.text || "").trim()) {
          skippedDrafts += 1;
          continue;
        }
        await this._pool.query(
          `INSERT INTO ${this._qualifiedChatDraftsTableName}
             (user_id, chat_id, draft_data)
           VALUES ($1, $2, $3::jsonb)
           ON CONFLICT (user_id, chat_id) DO NOTHING`,
          [userId, chatId, JSON.stringify({...draft, chatId})],
        );
      }
      let skippedPins = 0;
      for (const pin of pins) {
        const chatId = canonicalizeMigratedChatId(pin?.chatId);
        const messageId = String(pin?.messageId || "").trim();
        if (!chatId || !messageId) {
          skippedPins += 1;
          continue;
        }
        await this._pool.query(
          `INSERT INTO ${this._qualifiedChatPinsTableName}
             (chat_id, message_id, pin_data)
           VALUES ($1, $2, $3::jsonb)
           ON CONFLICT (chat_id) DO NOTHING`,
          [chatId, messageId, JSON.stringify({...pin, chatId})],
        );
      }

      const nextState = {
        ...state,
        messages: [],
        messageReactions: [],
        chatDrafts: [],
        chatPins: [],
        migrationStatus: {
          ...(state.migrationStatus || {}),
          chatCollectionsToTables: MARKER,
        },
      };
      await this._pool.query(
        `UPDATE ${this._qualifiedTableName}
            SET data = $2::jsonb,
                updated_at = NOW()
          WHERE id = $1`,
        [this._rowId, JSON.stringify(nextState)],
      );
      this._cachedState = normalizeDbState(nextState);
      // Sidecar-кэш обязан пережить границу миграции, иначе fallback-чтение
      // при недоступной БД воскресит домиграционный блоб (с сообщениями и
      // без маркера) и следующая мутация затрёт им состояние.
      await this._persistSnapshotCache(this._cachedState);
      console.log(
        "[backend] chat collections migrated to tables",
        JSON.stringify({
          messages: seenMessageIds.size,
          reactions: reactions.length,
          drafts: drafts.length,
          pins: pins.length,
          skipped: {
            messages: skippedMessages,
            drafts: skippedDrafts,
            pins: skippedPins,
          },
        }),
      );
    } catch (error) {
      // Миграция обязана завершиться до обслуживания запросов: table-оверрайды
      // читают ТОЛЬКО таблицы, и старт с недомигрированными данными означал бы
      // split-brain (сообщения в блобе, чтение из пустых таблиц). Роняем бут —
      // systemd перезапустит, ошибка видна в journalctl.
      console.error(
        "[backend] chat collections migration FAILED — refusing to serve",
        JSON.stringify({message: error?.message || String(error)}),
      );
      throw error;
    }
  }

  // Зеркало db.chats → projection-таблица (+ таблица участников для
  // индексного membership-чека). Полная перезаливка — чатов немного, а
  // DELETE+INSERT в один приём проще инкрементального диффа. Вызывается на
  // буте и из _write при изменении хэша коллекции.
  async _replaceChatProjection(chats) {
    const normalizedChats = (Array.isArray(chats) ? chats : []).filter(
      (chat) => String(chat?.id || "").trim(),
    );
    // Транзакция (как у auth-гидратации): без неё конкурентный findChat в
    // окне DELETE→INSERT видел бы пустую projection и валил access-check
    // существующих чатов. На пулах без connect (pg-mem) — plain-фолбэк.
    await this._withProjectionClient(async (client, useTransaction) => {
      try {
        if (useTransaction) {
          await client.query("BEGIN");
          await client.query("SET LOCAL statement_timeout = 0");
        }
        await client.query(`DELETE FROM ${this._qualifiedChatsProjectionTableName}`);
        await client.query(`DELETE FROM ${this._qualifiedChatParticipantsTableName}`);
        for (const chat of normalizedChats) {
          const chatId = String(chat.id).trim();
          await client.query(
            `INSERT INTO ${this._qualifiedChatsProjectionTableName} (id, chat_data)
             VALUES ($1, $2::jsonb)
             ON CONFLICT (id) DO UPDATE SET chat_data = EXCLUDED.chat_data`,
            [chatId, JSON.stringify(chat)],
          );
          for (const participantId of normalizeParticipantIds(chat.participantIds)) {
            await client.query(
              `INSERT INTO ${this._qualifiedChatParticipantsTableName} (chat_id, user_id)
               VALUES ($1, $2)
               ON CONFLICT (chat_id, user_id) DO NOTHING`,
              [chatId, participantId],
            );
          }
        }
        if (useTransaction) {
          await client.query("COMMIT");
        }
      } catch (error) {
        if (useTransaction) {
          try {
            await client.query("ROLLBACK");
          } catch (_) {
            // исходная ошибка важнее
          }
        }
        throw error;
      }
    });
    this._lastChatsProjectionHash = computeProjectionHash(normalizedChats);
    this._chatsProjectionDirty = false;
  }

  async _hydrateChatProjectionFromState() {
    try {
      const result = await this._pool.query(
        `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`,
        [this._rowId],
      );
      const rawData = result.rows[0]?.data ?? EMPTY_DB;
      const state = normalizeDbState(
        typeof rawData === "string" ? JSON.parse(rawData) : rawData,
      );
      await this._replaceChatProjection(state.chats);
    } catch (error) {
      // Деградация вместо падения (БД могла мигнуть): dirty-флаг переводит
      // резолв чатов на блоб через super.findChat, а первый успешный _write
      // (хэш стартует null → mismatch) перезальёт projection и снимет флаг.
      this._chatsProjectionDirty = true;
      console.warn(
        "[backend] postgres-store skipped chat projection hydration",
        JSON.stringify({message: error?.message || String(error)}),
      );
    }
  }

  async _backfillPersonIdentitiesInStateRow() {
    try {
      const result = await this._pool.query(
        `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`,
        [this._rowId],
      );
      const rawData = result.rows[0]?.data ?? EMPTY_DB;
      const normalized = normalizeDbState(rawData);
      const migration = backfillPersonIdentities(normalized);
      if (!migration.changed) {
        this._cachedState = normalized;
        return;
      }

      await this._pool.query(
        `UPDATE ${this._qualifiedTableName}
            SET data = $2::jsonb,
                updated_at = NOW()
          WHERE id = $1`,
        [this._rowId, JSON.stringify(migration.snapshot)],
      );
      this._cachedState = normalizeDbState(migration.snapshot);
    } catch (error) {
      console.warn(
        "[backend] postgres-store skipped person identity backfill",
        JSON.stringify({
          table: `${this._schema}.${this._table}`,
          rowId: this._rowId,
          message: error?.message || String(error),
        }),
      );
    }
  }

  async _withProjectionClient(work) {
    if (typeof this._pool.connect !== "function") {
      return work(this._pool, false);
    }

    const client = await this._pool.connect();
    try {
      return await work(client, true);
    } finally {
      client.release();
    }
  }

  async _hydrateAuthProjectionTablesFromStateRow() {
    await this._withProjectionClient(async (client, useTransaction) => {
      try {
        if (useTransaction) {
          await client.query("BEGIN");
          await client.query("SET LOCAL statement_timeout = 0");
        }
        await client.query(`DELETE FROM ${this._qualifiedAuthUsersTableName}`);
        await client.query(
          `INSERT INTO ${this._qualifiedAuthUsersTableName} (id, email, user_data)
           SELECT
             user_entry->>'id',
             NULLIF(lower(COALESCE(user_entry->>'email', '')), ''),
             user_entry
             FROM ${this._qualifiedTableName},
                  LATERAL jsonb_array_elements(COALESCE(data->'users', '[]'::jsonb)) AS user_entry
            WHERE id = $1
              AND COALESCE(user_entry->>'id', '') <> ''`,
          [this._rowId],
        );
        await client.query(`DELETE FROM ${this._qualifiedAuthSessionsTableName}`);
        await client.query(
          `INSERT INTO ${this._qualifiedAuthSessionsTableName} (
             token,
             refresh_token,
             user_id,
             created_at,
             session_data
           )
           SELECT
             session_entry->>'token',
             NULLIF(COALESCE(session_entry->>'refreshToken', ''), ''),
             COALESCE(session_entry->>'userId', ''),
             NULLIF(COALESCE(session_entry->>'createdAt', ''), ''),
             session_entry
             FROM ${this._qualifiedTableName},
                  LATERAL jsonb_array_elements(COALESCE(data->'sessions', '[]'::jsonb)) AS session_entry
            WHERE id = $1
              AND COALESCE(session_entry->>'token', '') <> ''`,
          [this._rowId],
        );
        if (useTransaction) {
          await client.query("COMMIT");
        }
      } catch (error) {
        if (isProjectionHydrationFallbackError(error)) {
          if (useTransaction) {
            try {
              await client.query("ROLLBACK");
            } catch (_) {
              // ignore rollback failures for fallback path
            }
          }
          const result = await this._pool.query(
            `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`,
            [this._rowId],
          );
          const rawData = result.rows[0]?.data ?? EMPTY_DB;
          await this._replaceProjectedUsers(rawData.users);
          await this._replaceProjectedSessions(rawData.sessions);
          return;
        }
        if (useTransaction) {
          try {
            await client.query("ROLLBACK");
          } catch (_) {
            // ignore rollback failures, the original error is more useful
          }
        }
        throw error;
      }
    });
  }

  async _replaceProjectedUsers(users) {
    const normalizedUsers = Array.isArray(users) ? users : [];
    await this._pool.query(`DELETE FROM ${this._qualifiedAuthUsersTableName}`);
    try {
      await this._pool.query(
        `INSERT INTO ${this._qualifiedAuthUsersTableName} (id, email, user_data)
         SELECT
           user_entry->>'id',
           NULLIF(lower(COALESCE(user_entry->>'email', '')), ''),
           user_entry
           FROM jsonb_array_elements($1::jsonb) AS user_entry
          WHERE COALESCE(user_entry->>'id', '') <> ''`,
        [JSON.stringify(normalizedUsers)],
      );
    } catch (error) {
      if (!isProjectionArrayInsertFallbackError(error)) {
        throw error;
      }
      for (const user of normalizedUsers) {
        const userId = String(user?.id || "").trim();
        if (!userId) {
          continue;
        }
        const email = String(user?.email || "").trim().toLowerCase() || null;
        await this._pool.query(
          `INSERT INTO ${this._qualifiedAuthUsersTableName} (id, email, user_data)
           VALUES ($1, $2, $3::jsonb)`,
          [userId, email, JSON.stringify(user)],
        );
      }
    }
    this._lastUsersProjectionHash = computeProjectionHash(normalizedUsers);
  }

  async _replaceProjectedSessions(sessions) {
    const normalizedSessions = Array.isArray(sessions) ? sessions : [];
    await this._pool.query(`DELETE FROM ${this._qualifiedAuthSessionsTableName}`);
    try {
      await this._pool.query(
        `INSERT INTO ${this._qualifiedAuthSessionsTableName} (
           token,
           refresh_token,
           user_id,
           created_at,
           session_data
         )
         SELECT
           session_entry->>'token',
           NULLIF(COALESCE(session_entry->>'refreshToken', ''), ''),
           COALESCE(session_entry->>'userId', ''),
           NULLIF(COALESCE(session_entry->>'createdAt', ''), ''),
           session_entry
           FROM jsonb_array_elements($1::jsonb) AS session_entry
          WHERE COALESCE(session_entry->>'token', '') <> ''`,
        [JSON.stringify(normalizedSessions)],
      );
    } catch (error) {
      if (!isProjectionArrayInsertFallbackError(error)) {
        throw error;
      }
      for (const session of normalizedSessions) {
        const token = String(session?.token || "").trim();
        if (!token) {
          continue;
        }
        await this._pool.query(
          `INSERT INTO ${this._qualifiedAuthSessionsTableName} (
             token,
             refresh_token,
             user_id,
             created_at,
             session_data
           )
           VALUES ($1, $2, $3, $4, $5::jsonb)`,
          [
            token,
            String(session?.refreshToken || "").trim() || null,
            String(session?.userId || "").trim(),
            String(session?.createdAt || "").trim() || null,
            JSON.stringify(session),
          ],
        );
      }
    }
    this._lastSessionsProjectionHash = computeProjectionHash(normalizedSessions);
  }

  async _syncSessionsPathFromProjection() {
    await this._pool.query(
      `UPDATE ${this._qualifiedTableName}
          SET data = jsonb_set(
                data,
                '{sessions}',
                COALESCE(
                  (
                    SELECT jsonb_agg(session_data ORDER BY created_at NULLS FIRST, token)
                      FROM ${this._qualifiedAuthSessionsTableName}
                  ),
                  '[]'::jsonb
                ),
                true
              ),
              updated_at = NOW()
        WHERE id = $1`,
      [this._rowId],
    );
  }

  async _awaitReadConsistency() {
    try {
      await this._awaitWriteQueue(this._stateWriteQueue);
    } catch (error) {
      if (error?.code !== "POSTGRES_WRITE_QUEUE_TIMEOUT") {
        throw error;
      }
      console.warn(
        "[backend] postgres-store continuing read while write queue is busy",
        JSON.stringify({
          table: `${this._schema}.${this._table}`,
          rowId: this._rowId,
          writeQueueTimeoutMs: this._writeQueueTimeoutMs,
        }),
      );
    }
  }

  async _selectProjectedSessionsForUser(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    const result = await this._pool.query(
      `SELECT session_data
         FROM ${this._qualifiedAuthSessionsTableName}
        WHERE user_id = $1
        ORDER BY created_at NULLS FIRST, token`,
      [normalizedUserId],
    );
    return result.rows.map((row) => row.session_data).filter(Boolean);
  }

  async _upsertProjectedSession(session) {
    const token = String(session?.token || "").trim();
    if (!token) {
      return;
    }
    await this._pool.query(
      `INSERT INTO ${this._qualifiedAuthSessionsTableName} (
         token,
         refresh_token,
         user_id,
         created_at,
         session_data
       )
       VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (token) DO UPDATE
       SET refresh_token = EXCLUDED.refresh_token,
           user_id = EXCLUDED.user_id,
           created_at = EXCLUDED.created_at,
           session_data = EXCLUDED.session_data`,
      [
        token,
        String(session?.refreshToken || "").trim() || null,
        String(session?.userId || "").trim(),
        String(session?.createdAt || "").trim() || null,
        JSON.stringify(session),
      ],
    );
  }

  async _selectSessionsArray() {
    await this.initialize();
    return this._selectProjectedSessionsArray();
  }

  async _selectProjectedSessionsArray() {
    const result = await this._pool.query(
      `SELECT session_data
         FROM ${this._qualifiedAuthSessionsTableName}
        ORDER BY created_at NULLS FIRST, token`,
    );
    return result.rows.map((row) => row.session_data).filter(Boolean);
  }

  async _updateSessionsArray(sessions) {
    await this._replaceProjectedSessions(sessions);
  }

  async authenticate(email, password) {
    const normalizedEmail = String(email || "").trim().toLowerCase();
    if (!normalizedEmail) {
      return null;
    }
    await this.initialize();
    const result = await this._pool.query(
      `SELECT user_data
         FROM ${this._qualifiedAuthUsersTableName}
        WHERE email = $1
        LIMIT 1`,
      [normalizedEmail],
    );
    const user = result.rows[0]?.user_data ?? null;

    if (!user || !verifyPassword(password, user)) {
      return null;
    }

    this._rememberUser(user);
    return cloneUserWithAuthState(user);
  }

  async findUserById(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return null;
    }
    const cachedUser = this._userCache.get(normalizedUserId);
    if (cachedUser) {
      return cloneUserWithAuthState(cachedUser);
    }

    await this.initialize();
    const result = await this._pool.query(
      `SELECT user_data
         FROM ${this._qualifiedAuthUsersTableName}
        WHERE id = $1
        LIMIT 1`,
      [normalizedUserId],
    );
    const user = result.rows[0]?.user_data ?? null;
    if (user) {
      this._rememberUser(user);
    }
    return user ? cloneUserWithAuthState(user) : null;
  }

  async findUserByEmail(email) {
    const normalizedEmail = String(email || "").trim().toLowerCase();
    if (!normalizedEmail) {
      return null;
    }

    await this.initialize();
    const result = await this._pool.query(
      `SELECT user_data
         FROM ${this._qualifiedAuthUsersTableName}
        WHERE email = $1
        LIMIT 1`,
      [normalizedEmail],
    );
    const user = result.rows[0]?.user_data ?? null;
    if (user) {
      this._rememberUser(user);
    }
    return user ? cloneUserWithAuthState(user) : null;
  }

  _logWriteFailure(error) {
    console.error(
      "[backend] postgres-store write failed",
      JSON.stringify({
        table: `${this._schema}.${this._table}`,
        rowId: this._rowId,
        message: String(error?.message || error || "unknown_error"),
      }),
    );
  }

  _enqueueWrite(queueName, operation) {
    const previousQueue = this[queueName].catch(() => {});
    const nextWrite = (async () => {
      await this._awaitWriteQueue(previousQueue);
      return operation();
    })();

    this[queueName] = nextWrite.catch((error) => {
      this._logWriteFailure(error);
      throw error;
    });
    if (queueName === "_stateWriteQueue") {
      this._writeQueue = this[queueName];
    }

    return nextWrite;
  }

  async createSession(userId, deviceContext = {}) {
    const createdAt = nowIso();
    const token = crypto.randomBytes(32).toString("hex");
    const refreshToken = crypto.randomBytes(32).toString("hex");
    const normalizedDeviceContext = normalizeSessionDeviceContext(deviceContext);
    const incomingInstanceId = normalizedDeviceContext.instanceId;

    const nextWrite = this._enqueueWrite("_sessionWriteQueue", async () => {
      await this.initialize();
      const userSessions = await this._selectProjectedSessionsForUser(userId);

      const supersededInstanceMatches = incomingInstanceId
        ? userSessions.filter((s) => s.instanceId === incomingInstanceId)
        : [];
      const remainingAfterInstanceMatch = incomingInstanceId
        ? userSessions.filter((s) => s.instanceId !== incomingInstanceId)
        : userSessions;

      const sessionsToKeep = remainingAfterInstanceMatch.slice(-4);
      const overflowEvicted = remainingAfterInstanceMatch.slice(
        0,
        Math.max(
          0,
          remainingAfterInstanceMatch.length - sessionsToKeep.length,
        ),
      );
      const evictedSessions = [
        ...supersededInstanceMatches,
        ...overflowEvicted,
      ];

      const createdSession = {
        token,
        refreshToken,
        userId,
        createdAt,
        lastSeenAt: createdAt,
        ...normalizedDeviceContext,
      };
      for (const session of evictedSessions) {
        const sessionToken = String(session?.token || "").trim();
        if (!sessionToken) {
          continue;
        }
        await this._pool.query(
          `DELETE FROM ${this._qualifiedAuthSessionsTableName} WHERE token = $1`,
          [sessionToken],
        );
      }
      await this._upsertProjectedSession(createdSession);
      return {createdSession, evictedSessions};
    });

    const {createdSession, evictedSessions} = await nextWrite;
    for (const session of evictedSessions) {
      this._forgetSession(session?.token);
    }
    this._rememberSession(createdSession);
    return {
      token,
      refreshToken,
      session: structuredClone(createdSession),
      evictedTokens: evictedSessions
        .map((entry) => String(entry?.token || "").trim())
        .filter(Boolean),
    };
  }

  async listSessionsForUser(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    await this.initialize();
    const sessions = await this._selectProjectedSessionsForUser(normalizedUserId);
    return sessions
      .map((session) => structuredClone(session))
      .sort((left, right) => {
        const leftAt = String(left.lastSeenAt || left.createdAt || "");
        const rightAt = String(right.lastSeenAt || right.createdAt || "");
        return rightAt.localeCompare(leftAt);
      });
  }

  async findSessionByPublicId(userId, publicId) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedPublicId = String(publicId || "").trim();
    if (!normalizedUserId || !normalizedPublicId) {
      return null;
    }
    const sessions = await this.listSessionsForUser(normalizedUserId);
    for (const session of sessions) {
      const candidate = deriveSessionPublicId(
        session.token,
        session.instanceId || "",
      );
      if (candidate === normalizedPublicId) {
        return session;
      }
    }
    return null;
  }

  async updateSessionMetadata(token, patch = {}) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }

    const nextWrite = this._enqueueWrite("_sessionWriteQueue", async () => {
      await this.initialize();
      const result = await this._pool.query(
        `SELECT session_data
           FROM ${this._qualifiedAuthSessionsTableName}
          WHERE token = $1
          LIMIT 1`,
        [normalizedToken],
      );
      const storedSession = result.rows[0]?.session_data ?? null;
      if (!storedSession) {
        return null;
      }
      const session = structuredClone(storedSession);
      const allowedKeys = ["deviceName", "platform", "appVersion"];
      for (const key of allowedKeys) {
        if (patch[key] === undefined) continue;
        const normalized = String(patch[key] ?? "").trim();
        session[key] = normalized || null;
      }
      await this._upsertProjectedSession(session);
      return session;
    });

    const updated = await nextWrite;
    if (!updated) {
      return null;
    }
    this._rememberSession(updated);
    return structuredClone(updated);
  }

  async findSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }
    const cachedSession = this._sessionCache.get(normalizedToken);
    if (cachedSession) {
      return structuredClone(cachedSession);
    }

    await this.initialize();
    const result = await this._pool.query(
      `SELECT session_data
         FROM ${this._qualifiedAuthSessionsTableName}
        WHERE token = $1
        LIMIT 1`,
      [normalizedToken],
    );
    const session = result.rows[0]?.session_data ?? null;
    if (session) {
      this._rememberSession(session);
    }
    return session ? structuredClone(session) : null;
  }

  async findSessionByRefreshToken(refreshToken) {
    const normalizedRefreshToken = String(refreshToken || "").trim();
    if (!normalizedRefreshToken) {
      return null;
    }

    await this.initialize();
    const result = await this._pool.query(
      `SELECT session_data
         FROM ${this._qualifiedAuthSessionsTableName}
        WHERE refresh_token = $1
        LIMIT 1`,
      [normalizedRefreshToken],
    );
    const session = result.rows[0]?.session_data ?? null;
    if (session) {
      this._rememberSession(session);
    }
    return session ? structuredClone(session) : null;
  }

  async touchSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }

    const nowMs = Date.now();
    const cachedTouchedAt = this._sessionTouchCache.get(normalizedToken);
    if (
      Number.isFinite(cachedTouchedAt) &&
      nowMs - cachedTouchedAt < SESSION_TOUCH_MIN_INTERVAL_MS
    ) {
      return null;
    }

    this._sessionTouchCache.set(normalizedToken, nowMs);
    const nextWrite = this._enqueueWrite("_sessionWriteQueue", async () => {
      await this.initialize();
      const result = await this._pool.query(
        `SELECT session_data
           FROM ${this._qualifiedAuthSessionsTableName}
          WHERE token = $1
          LIMIT 1`,
        [normalizedToken],
      );
      const storedSession = result.rows[0]?.session_data ?? null;
      if (!storedSession) {
        this._forgetSession(normalizedToken);
        return null;
      }

      const session = structuredClone(storedSession);
      const lastSeenAtMs = new Date(session.lastSeenAt || 0).getTime();
      if (
        Number.isFinite(lastSeenAtMs) &&
        nowMs - lastSeenAtMs < SESSION_TOUCH_MIN_INTERVAL_MS
      ) {
        this._sessionTouchCache.set(normalizedToken, lastSeenAtMs);
        this._rememberSession(session);
        return session;
      }

      session.lastSeenAt = nowIso();
      await this._upsertProjectedSession(session);
      return session;
    });

    const touchedSession = await nextWrite;
    if (!touchedSession) {
      return null;
    }
    this._rememberSession(touchedSession);
    return structuredClone(touchedSession);
  }

  async deleteSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }

    const nextWrite = this._enqueueWrite("_sessionWriteQueue", async () => {
      await this.initialize();
      const selectResult = await this._pool.query(
        `SELECT session_data
           FROM ${this._qualifiedAuthSessionsTableName}
          WHERE token = $1
          LIMIT 1`,
        [normalizedToken],
      );
      const removed = selectResult.rows[0]?.session_data ?? null;
      await this._pool.query(
        `DELETE FROM ${this._qualifiedAuthSessionsTableName} WHERE token = $1`,
        [normalizedToken],
      );
      return removed;
    });

    this._forgetSession(normalizedToken);
    const removed = await nextWrite;
    return removed ? structuredClone(removed) : null;
  }

  async deleteSessionsForUser(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return;
    }

    const nextWrite = this._enqueueWrite("_sessionWriteQueue", async () => {
      await this.initialize();
      const result = await this._pool.query(
        `SELECT token
           FROM ${this._qualifiedAuthSessionsTableName}
          WHERE user_id = $1`,
        [normalizedUserId],
      );
      const deletedTokens = result.rows
        .map((row) => String(row?.token || "").trim())
        .filter(Boolean);
      if (deletedTokens.length > 0) {
        await this._pool.query(
          `DELETE FROM ${this._qualifiedAuthSessionsTableName} WHERE user_id = $1`,
          [normalizedUserId],
        );
      }
      return deletedTokens;
    });

    const deletedTokens = (await nextWrite) || [];
    for (const token of deletedTokens) {
      this._forgetSession(token);
    }
  }

  async createPerson({
    treeId,
    creatorId,
    personData,
    userId = null,
  }) {
    if (userId) {
      return super.createPerson({
        treeId,
        creatorId,
        personData,
        userId,
      });
    }

    const normalizedTreeId = String(treeId || "").trim();
    if (!normalizedTreeId) {
      return null;
    }

    const person = buildPersonRecord({
      treeId: normalizedTreeId,
      creatorId,
      personData,
      userId: null,
    });
    const identity = createPersonIdentityRecord({personIds: [person.id]});
    person.identityId = identity.id;

    return this._enqueueWrite("_stateWriteQueue", async () => {
      await this.initialize();
      const result = await this._pool.query(
        `UPDATE ${this._qualifiedTableName}
            SET data = jsonb_set(
                  jsonb_set(
                    data,
                    '{persons}',
                    COALESCE(data->'persons', '[]'::jsonb) || jsonb_build_array($2::jsonb),
                    true
                  ),
                  '{personIdentities}',
                  COALESCE(data->'personIdentities', '[]'::jsonb) || jsonb_build_array($4::jsonb),
                  true
                ),
                updated_at = NOW()
          WHERE id = $1
            AND EXISTS (
              SELECT 1
                FROM jsonb_array_elements(COALESCE(data->'trees', '[]'::jsonb)) AS tree_entry
               WHERE COALESCE(tree_entry->>'id', '') = $3
            )
          RETURNING updated_at`,
        [
          this._rowId,
          JSON.stringify(person),
          normalizedTreeId,
          JSON.stringify(identity),
        ],
      );
      if (result.rowCount === 0) {
        return null;
      }
      return structuredClone(person);
    });
  }

  async deletePerson(treeId, personId, actorId = null) {
    const normalizedTreeId = String(treeId || "").trim();
    const normalizedPersonId = String(personId || "").trim();
    if (!normalizedTreeId || !normalizedPersonId) {
      return null;
    }

    return super.deletePerson(normalizedTreeId, normalizedPersonId, actorId);
  }

  async _selectStoredTreeInvitationsForUser(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    const result = await this._pool.query(
      `SELECT invitation_entry AS invitation_data
         FROM ${this._qualifiedTableName},
              LATERAL jsonb_array_elements(COALESCE(data->'treeInvitations', '[]'::jsonb)) AS invitation_entry
        WHERE id = $1
          AND COALESCE(invitation_entry->>'userId', '') = $2
          AND COALESCE(invitation_entry->>'role', 'pending') = 'pending'
        ORDER BY COALESCE(invitation_entry->>'addedAt', '') DESC`,
      [this._rowId, normalizedUserId],
    );
    return result.rows.map((row) => row.invitation_data).filter(Boolean);
  }

  async listPendingTreeInvitations(userId) {
    await this.initialize();
    await this._awaitReadConsistency();
    return this._selectStoredTreeInvitationsForUser(userId);
  }

  // ── SPEED-7: notifications/pushDeliveries поверх таблиц ─────────────
  // После бут-миграции блоб этих коллекций не содержит; блоб-массивы —
  // «транзитная очередь» для унаследованных inline-путей (_notifyReviewers,
  // article_block_conflict), которую _write дренирует в таблицы.

  _rowToNotification(row) {
    const record = row?.notification_data;
    if (!record) {
      return null;
    }
    const parsed = typeof record === "string" ? JSON.parse(record) : record;
    // Колонка read_at — источник истины прочитанности: массовые пометки
    // обновляют ТОЛЬКО её (не перезаписывая notification_data, чтобы не
    // затирать конкурентный коалесинг-бамп — ревью, P1). Здесь колонка
    // доводится в JSONB-представление, если SELECT её принёс.
    const columnReadAt =
      row.read_at !== undefined ? String(row.read_at || "") : "";
    if (columnReadAt !== "" && !parsed.readAt) {
      parsed.readAt = columnReadAt;
    }
    return parsed;
  }

  async createNotification({userId, type, title, body, data, silent = false}) {
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.createNotification({userId, type, title, body, data, silent});
    }
    const user = await this.findUserById(userId);
    if (!user) {
      return null;
    }
    const notification = createNotificationRecord({
      userId,
      type,
      title,
      body,
      data,
      silent,
    });
    await this._pool.query(
      `INSERT INTO ${this._qualifiedNotificationsTableName}
         (id, user_id, type, created_at, read_at, silent, coalesce_key, notification_data)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)`,
      this._notificationRowValues(notification),
    );
    // TOCTOU с deleteUser (ревью, P2): в FileStore проверка юзера и вставка
    // атомарны внутри _mutate; здесь между findUserById и INSERT юзера могли
    // удалить — компенсирующая перепроверка убирает свежую сироту.
    const userStillExists = await this.findUserById(userId);
    if (!userStillExists) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedNotificationsTableName} WHERE id = $1`,
        [notification.id],
      );
      return null;
    }
    return structuredClone(notification);
  }

  async listNotifications(userId, {status = null, limit = 50} = {}) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    const normalizedLimit = Number.isFinite(Number(limit))
      ? Math.max(0, Math.floor(Number(limit)))
      : 50;
    if (normalizedLimit === 0) {
      return [];
    }
    const normalizedStatus = String(status || "").trim().toLowerCase();
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.listNotifications(userId, {status, limit});
    }
    await this._awaitReadConsistency();
    const result = await this._pool.query(
      `SELECT notification_data, read_at
         FROM ${this._qualifiedNotificationsTableName}
        WHERE user_id = $1
          AND (
            $2 = ''
            OR ($2 = 'unread' AND read_at = '')
            OR ($2 = 'read' AND read_at <> '')
          )
        ORDER BY created_at DESC, id DESC
        LIMIT $3`,
      [normalizedUserId, normalizedStatus, normalizedLimit],
    );
    return result.rows
      .map((row) => this._rowToNotification(row))
      .filter(Boolean);
  }

  async countUnreadNotifications(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return 0;
    }
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.countUnreadNotifications(userId);
    }
    await this._awaitReadConsistency();
    const result = await this._pool.query(
      `SELECT COUNT(*)::int AS total
         FROM ${this._qualifiedNotificationsTableName}
        WHERE user_id = $1
          AND read_at = ''`,
      [normalizedUserId],
    );
    return Number(result.rows[0]?.total || 0);
  }

  async markNotificationRead(notificationId, userId) {
    const normalizedId = String(notificationId || "").trim();
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedId || !normalizedUserId) {
      return null;
    }
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.markNotificationRead(notificationId, userId);
    }
    await this._awaitReadConsistency();
    const result = await this._pool.query(
      `SELECT notification_data, read_at
         FROM ${this._qualifiedNotificationsTableName}
        WHERE id = $1 AND user_id = $2
        LIMIT 1`,
      [normalizedId, normalizedUserId],
    );
    const row = result.rows[0];
    if (!row) {
      return null;
    }
    const notification = this._rowToNotification(row);
    if (String(row.read_at || "") !== "") {
      // Уже прочитано — как FileStore: вернуть запись без повторной записи.
      return structuredClone(notification);
    }
    notification.readAt = nowIso();
    await this._pool.query(
      `UPDATE ${this._qualifiedNotificationsTableName}
          SET read_at = $2,
              notification_data = $3::jsonb
        WHERE id = $1`,
      [normalizedId, notification.readAt, JSON.stringify(notification)],
    );
    return structuredClone(notification);
  }

  async markNotificationsReadByDataKey({
    userId,
    dataKey,
    dataValue,
    types = null,
  }) {
    if (!userId || !dataKey) return 0;
    const normalizedUserId = String(userId).trim();
    const normalizedValue = dataValue == null ? null : String(dataValue);
    const typeFilter = Array.isArray(types) && types.length > 0
      ? new Set(types.map((entry) => String(entry)))
      : null;
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.markNotificationsReadByDataKey({userId, dataKey, dataValue, types});
    }
    await this._awaitReadConsistency();
    // data-фильтр — в JS по полной записи (byte-parity с FileStore, без
    // jsonb-путей в WHERE — pg-mem их поддерживает выборочно).
    const result = await this._pool.query(
      `SELECT id, notification_data
         FROM ${this._qualifiedNotificationsTableName}
        WHERE user_id = $1
          AND read_at = ''`,
      [normalizedUserId],
    );
    const now = nowIso();
    let markedCount = 0;
    for (const row of result.rows) {
      const notification = this._rowToNotification(row);
      if (!notification) continue;
      if (typeFilter && !typeFilter.has(String(notification.type || ""))) {
        continue;
      }
      const data = notification.data || {};
      const candidate = data[dataKey];
      if (candidate == null) continue;
      if (String(candidate) !== normalizedValue) continue;
      notification.readAt = now;
      await this._pool.query(
        `UPDATE ${this._qualifiedNotificationsTableName}
            SET read_at = $2,
                notification_data = $3::jsonb
          WHERE id = $1`,
        [String(row.id), now, JSON.stringify(notification)],
      );
      markedCount += 1;
    }
    return markedCount;
  }

  async markAllNotificationsRead(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) return 0;
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.markAllNotificationsRead(userId);
    }
    await this._awaitReadConsistency();
    // ОДИН UPDATE только колонки read_at: перезапись notification_data из
    // JS-снапшота затирала бы конкурентный коалесинг-бамп (ревью, P1) —
    // JSONB доводится колонкой в _rowToNotification при чтении.
    const result = await this._pool.query(
      `UPDATE ${this._qualifiedNotificationsTableName}
          SET read_at = $2
        WHERE user_id = $1
          AND read_at = ''
        RETURNING id`,
      [normalizedUserId, nowIso()],
    );
    return result.rows.length;
  }

  async listNotificationsPage(userId, {status = null, limit = 50, cursor = null} = {}) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedLimit = Math.min(
      200,
      Math.max(1, Math.floor(Number(limit) || 50)),
    );
    if (!normalizedUserId) {
      return {notifications: [], nextCursor: null};
    }
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.listNotificationsPage(userId, {status, limit, cursor});
    }
    await this._awaitReadConsistency();
    const normalizedStatus = String(status || "").trim().toLowerCase();
    const decodedCursor = decodeNotificationCursor(cursor);
    // Keyset вместо OFFSET; кортежное сравнение разложено в OR — pg-mem
    // row-value сравнения не поддерживает.
    const params = [normalizedUserId, normalizedStatus, normalizedLimit + 1];
    let cursorClause = "";
    if (decodedCursor) {
      params.push(decodedCursor.createdAt, decodedCursor.id);
      cursorClause = `AND (created_at < $4 OR (created_at = $4 AND id < $5))`;
    }
    const result = await this._pool.query(
      `SELECT notification_data, read_at
         FROM ${this._qualifiedNotificationsTableName}
        WHERE user_id = $1
          AND (
            $2 = ''
            OR ($2 = 'unread' AND read_at = '')
            OR ($2 = 'read' AND read_at <> '')
          )
          ${cursorClause}
        ORDER BY created_at DESC, id DESC
        LIMIT $3`,
      params,
    );
    const rows = result.rows
      .map((row) => this._rowToNotification(row))
      .filter(Boolean);
    const hasMore = rows.length > normalizedLimit;
    const pageItems = hasMore ? rows.slice(0, normalizedLimit) : rows;
    const last = pageItems[pageItems.length - 1];
    return {
      notifications: pageItems,
      nextCursor:
        hasMore && last
          ? encodeNotificationCursor(String(last.createdAt || ""), String(last.id || ""))
          : null,
    };
  }

  /// Табличная реализация коалесинга (движок планов из store.js): hit по
  /// (user_id, coalesce_key) среди unread → бамп, miss → INSERT. Гонка двух
  /// конкурентных реакций может дать дубль вместо бампа — как и у прежних
  /// голых _read/_write пар; не хуже (см. дизайн-док, «намеренные отличия»).
  async _applyNotificationCoalescePlan(plan) {
    if (!plan) {
      return null;
    }
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super._applyNotificationCoalescePlan(plan);
    }
    const coalesceKey = computeNotificationCoalesceKey({
      type: plan.type,
      data: plan.keyData,
    });
    const existingResult = await this._pool.query(
      `SELECT id, notification_data
         FROM ${this._qualifiedNotificationsTableName}
        WHERE user_id = $1
          AND coalesce_key = $2
          AND read_at = ''
        ORDER BY created_at DESC, id DESC
        LIMIT 1`,
      [String(plan.userId || "").trim(), coalesceKey],
    );
    const existingRow = existingResult.rows[0];
    if (existingRow) {
      const existing = this._rowToNotification(existingRow);
      plan.patchExisting(existing);
      existing.createdAt = nowIso();
      existing.readAt = null;
      const updated = await this._pool.query(
        `UPDATE ${this._qualifiedNotificationsTableName}
            SET created_at = $2,
                read_at = '',
                notification_data = $3::jsonb
          WHERE id = $1
            AND read_at = ''`,
        [String(existingRow.id), existing.createdAt, JSON.stringify(existing)],
      );
      // Гвард read_at='': конкурентный markNotificationRead успел пометить
      // запись прочитанной между SELECT и UPDATE — бамп не должен тихо
      // «распрочитывать» её (ревью, P2). 0 строк → падаем в miss-ветку:
      // «после прочтения — новая запись».
      if (Number(updated.rowCount || 0) > 0) {
        return structuredClone(existing);
      }
    }
    const notification = plan.buildRecord();
    await this._pool.query(
      `INSERT INTO ${this._qualifiedNotificationsTableName}
         (id, user_id, type, created_at, read_at, silent, coalesce_key, notification_data)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
       ON CONFLICT DO NOTHING`,
      this._notificationRowValues(notification),
    );
    return structuredClone(notification);
  }

  async createPushDelivery({
    notificationId,
    userId,
    deviceId,
    provider,
    status = "queued",
  }) {
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.createPushDelivery({notificationId, userId, deviceId, provider, status});
    }
    const delivery = createPushDeliveryRecord({
      notificationId,
      userId,
      deviceId,
      provider,
      status,
    });
    await this._pool.query(
      `INSERT INTO ${this._qualifiedPushDeliveriesTableName}
         (id, notification_id, user_id, device_id, provider, status, created_at, updated_at, delivery_data)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)`,
      this._pushDeliveryRowValues(delivery),
    );
    return structuredClone(delivery);
  }

  async listPushDeliveries(userId, {limit = 50} = {}) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.listPushDeliveries(userId, {limit});
    }
    await this._awaitReadConsistency();
    const result = await this._pool.query(
      `SELECT delivery_data
         FROM ${this._qualifiedPushDeliveriesTableName}
        WHERE user_id = $1
        ORDER BY created_at DESC, id DESC
        LIMIT $2`,
      [normalizedUserId, Math.max(0, Math.floor(Number(limit) || 50))],
    );
    return result.rows
      .map((row) => {
        const record = row?.delivery_data;
        if (!record) return null;
        return typeof record === "string" ? JSON.parse(record) : record;
      })
      .filter(Boolean);
  }

  async updatePushDelivery(
    deliveryId,
    {status, deliveredAt, lastError, responseCode} = {},
  ) {
    const normalizedId = String(deliveryId || "").trim();
    if (!normalizedId) {
      return null;
    }
    await this.initialize();
    if (!this._notificationTablesReady) {
      return super.updatePushDelivery(deliveryId, {status, deliveredAt, lastError, responseCode});
    }
    const result = await this._pool.query(
      `SELECT delivery_data
         FROM ${this._qualifiedPushDeliveriesTableName}
        WHERE id = $1
        LIMIT 1`,
      [normalizedId],
    );
    const rawRecord = result.rows[0]?.delivery_data;
    if (!rawRecord) {
      return null;
    }
    const delivery =
      typeof rawRecord === "string" ? JSON.parse(rawRecord) : rawRecord;
    if (status !== undefined) {
      delivery.status = String(status || delivery.status).trim();
    }
    if (deliveredAt !== undefined) {
      delivery.deliveredAt = deliveredAt || null;
    }
    if (lastError !== undefined) {
      delivery.lastError = lastError ? String(lastError) : null;
    }
    if (responseCode !== undefined) {
      const normalizedCode = Number(responseCode);
      delivery.responseCode = Number.isFinite(normalizedCode)
        ? normalizedCode
        : null;
    }
    delivery.updatedAt = nowIso();
    await this._pool.query(
      `UPDATE ${this._qualifiedPushDeliveriesTableName}
          SET status = $2,
              updated_at = $3,
              delivery_data = $4::jsonb
        WHERE id = $1`,
      [
        normalizedId,
        String(delivery.status || "queued"),
        delivery.updatedAt,
        JSON.stringify(delivery),
      ],
    );
    return structuredClone(delivery);
  }

  /// Drain «транзитной очереди»: унаследованные FileStore-пути, пушащие в
  /// db.notifications/db.pushDeliveries внутри своих applyFn/голых write'ов
  /// (_notifyReviewers, article_block_conflict, будущие), доезжают в таблицы
  /// здесь. Для типов с coalesce-ключом hit по unread = skip (семантика
  /// `continue` в _notifyReviewers). Возвращает состояние с пустыми
  /// транзит-массивами — в блоб и кэш они не попадают.
  async _drainTransientNotificationCollections(data) {
    if (!this._notificationTablesReady) {
      // До подтверждённой миграции блоб — единственный источник правды.
      return data;
    }
    const notifications = Array.isArray(data?.notifications)
      ? data.notifications
      : [];
    const pushDeliveries = Array.isArray(data?.pushDeliveries)
      ? data.pushDeliveries
      : [];
    if (notifications.length === 0 && pushDeliveries.length === 0) {
      return data;
    }
    try {
    for (const notification of notifications) {
      const rowValues = this._notificationRowValues(notification);
      if (!rowValues[0] || !rowValues[1] || !rowValues[3]) {
        continue;
      }
      const coalesceKey = rowValues[6];
      if (coalesceKey) {
        const existing = await this._pool.query(
          `SELECT id
             FROM ${this._qualifiedNotificationsTableName}
            WHERE user_id = $1
              AND coalesce_key = $2
              AND read_at = ''
            LIMIT 1`,
          [rowValues[1], coalesceKey],
        );
        if (existing.rows[0]) {
          continue;
        }
      }
      await this._pool.query(
        `INSERT INTO ${this._qualifiedNotificationsTableName}
           (id, user_id, type, created_at, read_at, silent, coalesce_key, notification_data)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
         ON CONFLICT DO NOTHING`,
        rowValues,
      );
    }
    for (const delivery of pushDeliveries) {
      const rowValues = this._pushDeliveryRowValues(delivery);
      if (!rowValues[0] || !rowValues[2] || !rowValues[6]) {
        continue;
      }
      await this._pool.query(
        `INSERT INTO ${this._qualifiedPushDeliveriesTableName}
           (id, notification_id, user_id, device_id, provider, status, created_at, updated_at, delivery_data)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)
         ON CONFLICT DO NOTHING`,
        rowValues,
      );
    }
    } catch (error) {
      // Best-effort: сбой INSERT'а уведомления не должен ронять бизнес-
      // мутацию, которая его породила. Транзит НЕ обнуляем — блоб запишется
      // с массивами, следующий _write повторит drain (дедуп по id).
      console.warn(
        "[backend] notification drain failed — keeping transit in blob",
        JSON.stringify({message: error?.message || String(error)}),
      );
      return data;
    }
    return {...data, notifications: [], pushDeliveries: []};
  }

  // ── SPEED-6: чат-методы поверх таблиц ────────────────────────────────
  // Сообщения/реакции/черновики/пины читаются и пишутся ТОЛЬКО в таблицах
  // (после бут-миграции блоб их не содержит), записи чатов — из
  // projection-таблицы (источник истины — блоб, синк по хэшу в _write).
  // Семантика 1-в-1 повторяет FileStore-методы store.js; про намеренные
  // отличия — docs/speed6_messages_table_design.md.

  async _selectProjectedUsersByIds(userIds) {
    const normalizedUserIds = Array.from(
      new Set(
        (Array.isArray(userIds) ? userIds : [])
          .map((value) => String(value || "").trim())
          .filter(Boolean),
      ),
    );
    if (normalizedUserIds.length === 0) {
      return new Map();
    }
    const placeholders = normalizedUserIds.map((_, index) => `$${index + 1}`);
    const result = await this._pool.query(
      `SELECT id, user_data
         FROM ${this._qualifiedAuthUsersTableName}
        WHERE id IN (${placeholders.join(", ")})`,
      normalizedUserIds,
    );
    return new Map(
      result.rows
        .map((row) => [String(row?.id || row?.user_data?.id || "").trim(), row?.user_data])
        .filter(([userId, user]) => userId && user),
    );
  }

  _isProjectedMessageReadByUser(message, userId) {
    const readBy = normalizeParticipantIds(message?.readBy);
    if (readBy.length > 0) {
      return readBy.includes(userId);
    }
    return message?.isRead === true;
  }

  _chatMessageFromRow(row) {
    const data = row?.message_data;
    if (data == null) {
      return null;
    }
    return typeof data === "string" ? JSON.parse(data) : data;
  }

  _chatJsonFromRow(row, column) {
    const data = row?.[column];
    if (data == null) {
      return null;
    }
    return typeof data === "string" ? JSON.parse(data) : data;
  }

  _escapeLikePattern(value) {
    return String(value || "").replace(/[\\%_]/g, (match) => `\\${match}`);
  }

  async _selectChatProjectionById(chatId) {
    const normalized = String(chatId || "").trim();
    if (!normalized) {
      return null;
    }
    const result = await this._pool.query(
      `SELECT chat_data FROM ${this._qualifiedChatsProjectionTableName} WHERE id = $1`,
      [normalized],
    );
    return this._chatJsonFromRow(result.rows[0], "chat_data");
  }

  async _selectLatestChatMessage(equivalentChatIds, nowTimestamp) {
    const ids = equivalentChatIds.filter(Boolean);
    if (ids.length === 0) {
      return null;
    }
    const placeholders = ids.map((_, index) => `$${index + 1}`);
    const result = await this._pool.query(
      `SELECT ts, id, message_data
         FROM ${this._qualifiedChatMessagesTableName}
        WHERE chat_id IN (${placeholders.join(", ")})
          AND (expires_at = '' OR expires_at > $${ids.length + 1})
        ORDER BY ts DESC, id DESC
        LIMIT 1`,
      [...ids, nowTimestamp],
    );
    return result.rows[0] || null;
  }

  // Аналог FileStore._resolveChat поверх таблиц: сохранённый чат из
  // projection (с updatedAt, доведённым до timestamp последнего сообщения —
  // на PG-пути блобный chat.updatedAt на send не бампится), либо
  // синтезированный виртуальный direct-чат из канонического `a_b` id.
  async _resolveChatFromTables(chatId) {
    const normalizedChatId = String(chatId || "").trim();
    if (!normalizedChatId) {
      return null;
    }
    if (this._chatsProjectionDirty) {
      // Projection не догидратировалась на буте — правду о чатах даёт блоб.
      const blobChat = await super.findChat(normalizedChatId);
      return blobChat ? {chat: blobChat, stored: true} : null;
    }
    const nowTimestamp = nowIso();
    let chat = await this._selectChatProjectionById(normalizedChatId);
    let stored = Boolean(chat);
    if (!chat) {
      const directParticipants = parseDirectParticipantsFromChatId(normalizedChatId);
      if (directParticipants.length !== 2) {
        return null;
      }
      const canonicalChatId = directParticipants.join("_");
      if (canonicalChatId !== normalizedChatId) {
        chat = await this._selectChatProjectionById(canonicalChatId);
        stored = Boolean(chat);
      }
      if (!chat) {
        const latestRow = await this._selectLatestChatMessage(
          this._equivalentChatIdList(normalizedChatId, canonicalChatId),
          nowTimestamp,
        );
        const latestMessage = this._chatMessageFromRow(latestRow);
        const firstTimestamp = latestMessage ? null : nowIso();
        let earliestTimestamp = firstTimestamp;
        if (latestRow) {
          const ids = this._equivalentChatIdList(normalizedChatId, canonicalChatId);
          const placeholders = ids.map((_, index) => `$${index + 1}`);
          const earliest = await this._pool.query(
            `SELECT ts
               FROM ${this._qualifiedChatMessagesTableName}
              WHERE chat_id IN (${placeholders.join(", ")})
                AND (expires_at = '' OR expires_at > $${ids.length + 1})
              ORDER BY ts ASC, id ASC
              LIMIT 1`,
            [...ids, nowTimestamp],
          );
          earliestTimestamp = earliest.rows[0]?.ts || nowIso();
        }
        return {
          chat: {
            id: canonicalChatId,
            type: "direct",
            participantIds: directParticipants,
            title: null,
            createdBy: directParticipants[0],
            treeId: null,
            branchRootPersonIds: [],
            createdAt: earliestTimestamp || nowIso(),
            updatedAt: latestRow?.ts || earliestTimestamp || nowIso(),
          },
          stored: false,
        };
      }
    }

    const equivalentIds = this._equivalentChatIdList(normalizedChatId, chat.id);
    const latestRow = await this._selectLatestChatMessage(equivalentIds, nowTimestamp);
    if (
      latestRow?.ts &&
      String(latestRow.ts).localeCompare(String(chat.updatedAt || "")) > 0
    ) {
      chat = {...chat, updatedAt: latestRow.ts};
    }
    return {chat, stored};
  }

  async findChat(chatId) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    try {
      const resolved = await this._resolveChatFromTables(chatId);
      return resolved ? structuredClone(resolved.chat) : null;
    } catch (error) {
      // Записи чатов живут и в блобе — при недоступности projection-таблиц
      // (например, урезанный тестовый движок) корректен старый путь.
      console.warn(
        "[backend] postgres findChat fell back to state read",
        JSON.stringify({message: error?.message || String(error)}),
      );
      return super.findChat(chatId);
    }
  }

  async isUserBlockedBetween(userIdA, userIdB) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    try {
      const result = await this._pool.query(
        `SELECT 1 AS blocked
           FROM ${this._qualifiedTableName},
                LATERAL jsonb_array_elements(COALESCE(data->'blocks', '[]'::jsonb)) AS block_entry
          WHERE id = $1
            AND (
              (COALESCE(block_entry->>'blockerId', '') = $2 AND COALESCE(block_entry->>'blockedUserId', '') = $3)
              OR (COALESCE(block_entry->>'blockerId', '') = $3 AND COALESCE(block_entry->>'blockedUserId', '') = $2)
            )
          LIMIT 1`,
        [this._rowId, String(userIdA || ""), String(userIdB || "")],
      );
      return result.rows.length > 0;
    } catch (error) {
      if (!isProjectionArrayTextFallbackError(error) && !isProjectionHydrationFallbackError(error)) {
        throw error;
      }
      return super.isUserBlockedBetween(userIdA, userIdB);
    }
  }

  async _aggregateReactionsByMessageIds(messageIds) {
    const ids = Array.from(
      new Set(
        (Array.isArray(messageIds) ? messageIds : [])
          .map((value) => String(value || "").trim())
          .filter(Boolean),
      ),
    );
    const aggregated = new Map();
    if (ids.length === 0) {
      return aggregated;
    }
    const placeholders = ids.map((_, index) => `$${index + 1}`);
    const result = await this._pool.query(
      `SELECT message_id, user_id, emoji, created_at
         FROM ${this._qualifiedChatReactionsTableName}
        WHERE message_id IN (${placeholders.join(", ")})
        ORDER BY created_at ASC`,
      ids,
    );
    for (const row of result.rows) {
      const messageId = String(row?.message_id || "").trim();
      const userId = String(row?.user_id || "").trim();
      const emoji = normalizeReactionEmoji(row?.emoji);
      if (!messageId || !userId || !emoji) {
        continue;
      }
      const grouped = aggregated.get(messageId) || new Map();
      const existing = grouped.get(emoji) || {emoji, userIds: [], count: 0};
      if (!existing.userIds.includes(userId)) {
        existing.userIds.push(userId);
        existing.count = existing.userIds.length;
      }
      grouped.set(emoji, existing);
      aggregated.set(messageId, grouped);
    }
    const finalized = new Map();
    for (const [messageId, grouped] of aggregated) {
      finalized.set(
        messageId,
        Array.from(grouped.values()).sort((left, right) =>
          String(left.emoji || "").localeCompare(String(right.emoji || "")),
        ),
      );
    }
    return finalized;
  }

  _attachTableReactions(message, reactionsByMessageId) {
    const clone = structuredClone(message);
    clone.reactions = reactionsByMessageId.get(String(message?.id || "").trim()) || [];
    return clone;
  }

  // Физическая зачистка протухших сообщений (аналог _schedulePurgeSweep):
  // read-пути фильтруют expires_at прямо в SQL, а фактический DELETE с
  // каскадом реакций/пинов гоняем фоном не чаще раза в минуту.
  _scheduleChatTablePurgeSweep() {
    if (this._chatPurgeSweepScheduled) {
      return;
    }
    const now = Date.now();
    if (this._lastChatPurgeSweepAt && now - this._lastChatPurgeSweepAt < 60_000) {
      return;
    }
    this._chatPurgeSweepScheduled = true;
    Promise.resolve()
      .then(async () => {
        const nowTimestamp = nowIso();
        const deleted = await this._pool.query(
          `DELETE FROM ${this._qualifiedChatMessagesTableName}
            WHERE expires_at <> '' AND expires_at <= $1
            RETURNING id`,
          [nowTimestamp],
        );
        const deletedIds = deleted.rows
          .map((row) => String(row?.id || "").trim())
          .filter(Boolean);
        if (deletedIds.length > 0) {
          const placeholders = deletedIds.map((_, index) => `$${index + 1}`);
          await this._pool.query(
            `DELETE FROM ${this._qualifiedChatReactionsTableName}
              WHERE message_id IN (${placeholders.join(", ")})`,
            deletedIds,
          );
          await this._pool.query(
            `DELETE FROM ${this._qualifiedChatPinsTableName}
              WHERE message_id IN (${placeholders.join(", ")})`,
            deletedIds,
          );
        }
      })
      .catch((error) => {
        console.warn(
          "[backend] chat table purge sweep failed",
          error?.message || error,
        );
      })
      .then(() => {
        this._chatPurgeSweepScheduled = false;
        this._lastChatPurgeSweepAt = Date.now();
      });
  }

  // Фоновая материализация виртуального direct-чата в блоб (и через
  // hash-синк — в projection). НЕ на ack-пути: сообщение уже в таблице,
  // access и превью работают и без сохранённой записи чата.
  _scheduleDirectChatMaterialize(chat) {
    const record = {
      id: String(chat?.id || "").trim(),
      type: "direct",
      participantIds: normalizeParticipantIds(chat?.participantIds),
      title: null,
      photoUrl: null,
      createdBy: chat?.createdBy || null,
      treeId: null,
      branchRootPersonIds: [],
      createdAt: chat?.createdAt || nowIso(),
      updatedAt: chat?.updatedAt || nowIso(),
    };
    if (!record.id || record.participantIds.length !== 2) {
      return;
    }
    Promise.resolve()
      .then(() =>
        this._mutate((db, skip) => {
          if (db.chats.some((entry) => entry.id === record.id)) {
            return skip(undefined);
          }
          db.chats.push(record);
          return undefined;
        }),
      )
      .catch((error) => {
        console.warn(
          "[backend] direct chat materialize failed",
          error?.message || error,
        );
      });
  }

  async addChatMessage({
    chatId,
    senderId,
    text,
    attachments = [],
    mediaUrls = [],
    imageUrl = null,
    clientMessageId = null,
    expiresAt = null,
    replyTo = null,
    call = null,
  }) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved) {
      return null;
    }
    const {chat, stored} = resolved;

    const participants = normalizeParticipantIds(chat.participantIds);
    if (!participants.includes(senderId) || participants.length < 2) {
      return null;
    }

    const normalizedText = String(text || "").trim();
    const normalizedAttachments = normalizeMessageAttachments({
      attachments,
      mediaUrls,
      imageUrl,
    });
    const normalizedMediaUrls = normalizedAttachments.map((entry) => entry.url);
    const normalizedImageUrl =
      normalizedAttachments.find((entry) => entry.type === "image")?.url ||
      normalizedAttachments[0]?.url ||
      null;
    const normalizedClientMessageId = String(clientMessageId || "").trim() || null;
    const normalizedExpiresAt = normalizeOptionalIsoTimestamp(expiresAt);
    const normalizedReplyTo = normalizeReplyReference(replyTo);
    const normalizedCall = normalizeChatMessageCall(call);
    if (!normalizedText && normalizedAttachments.length === 0 && !normalizedCall) {
      return false;
    }

    const equivalentIds = this._equivalentChatIdList(chatId, chat.id);

    const findExistingByClientId = async () => {
      if (!normalizedClientMessageId) {
        return null;
      }
      const placeholders = equivalentIds.map((_, index) => `$${index + 1}`);
      const result = await this._pool.query(
        `SELECT id, message_data
           FROM ${this._qualifiedChatMessagesTableName}
          WHERE chat_id IN (${placeholders.join(", ")})
            AND sender_id = $${equivalentIds.length + 1}
            AND client_message_id = $${equivalentIds.length + 2}
          LIMIT 1`,
        [...equivalentIds, senderId, normalizedClientMessageId],
      );
      return this._chatMessageFromRow(result.rows[0]);
    };

    const existingMessage = await findExistingByClientId();
    if (existingMessage) {
      const reactions = await this._aggregateReactionsByMessageIds([existingMessage.id]);
      return {
        ...this._attachTableReactions(existingMessage, reactions),
        _deduplicated: true,
      };
    }

    const senderUsers = await this._selectProjectedUsersByIds([senderId]);
    const sender = senderUsers.get(String(senderId || "").trim()) || null;

    const timestamp = nowIso();
    const message = {
      id: crypto.randomUUID(),
      chatId: chat.id,
      senderId,
      text: normalizedText,
      timestamp,
      isRead: false,
      participants,
      deliveredTo: [senderId],
      readBy: [senderId],
      senderName: sender?.profile?.displayName || "Пользователь",
      attachments: normalizedAttachments,
      imageUrl: normalizedImageUrl,
      mediaUrls: normalizedMediaUrls.length > 0 ? normalizedMediaUrls : null,
      clientMessageId: normalizedClientMessageId,
      expiresAt: normalizedExpiresAt,
      replyTo: normalizedReplyTo,
    };
    if (normalizedCall) {
      message.call = normalizedCall;
    }

    try {
      await this._insertChatMessageRow(message);
    } catch (error) {
      // Гонка одинаковых clientMessageId упирается в уникальный dedup-индекс —
      // возвращаем уже сохранённое сообщение, как это делает FileStore.
      const isUniqueViolation =
        error?.code === "23505" ||
        String(error?.message || "").toLowerCase().includes("duplicate key");
      if (!isUniqueViolation || !normalizedClientMessageId) {
        throw error;
      }
      const racedMessage = await findExistingByClientId();
      if (!racedMessage) {
        throw error;
      }
      const reactions = await this._aggregateReactionsByMessageIds([racedMessage.id]);
      return {
        ...this._attachTableReactions(racedMessage, reactions),
        _deduplicated: true,
      };
    }

    if (!stored) {
      this._scheduleDirectChatMaterialize({...chat, updatedAt: timestamp});
    }
    this._scheduleChatTablePurgeSweep();

    const result = structuredClone(message);
    result.reactions = [];
    return result;
  }

  async listChatMessages(chatId, {limit = null, beforeId = null, afterId = null} = {}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved) {
      return [];
    }
    const equivalentIds = this._equivalentChatIdList(chatId, resolved.chat.id);
    const nowTimestamp = nowIso();
    const placeholders = equivalentIds.map((_, index) => `$${index + 1}`);
    const baseParams = [...equivalentIds, nowTimestamp];
    const scopeSql = `chat_id IN (${placeholders.join(", ")})
          AND (expires_at = '' OR expires_at > $${equivalentIds.length + 1})`;

    const normalizedBeforeId = normalizeNullableString(beforeId);
    const normalizedAfterId = normalizeNullableString(afterId);
    let cursorCondition = "";
    const params = [...baseParams];
    if (normalizedBeforeId || normalizedAfterId) {
      const cursorId = normalizedBeforeId || normalizedAfterId;
      const cursorResult = await this._pool.query(
        `SELECT ts, id
           FROM ${this._qualifiedChatMessagesTableName}
          WHERE ${scopeSql}
            AND id = $${baseParams.length + 1}
          LIMIT 1`,
        [...baseParams, cursorId],
      );
      const cursorRow = cursorResult.rows[0];
      if (!cursorRow) {
        // Неизвестный курсор => пустая страница (клиентский reconcile
        // кэша опирается ровно на эту семантику FileStore).
        return [];
      }
      params.push(cursorRow.ts, cursorRow.id);
      const tsParam = `$${params.length - 1}`;
      const idParam = `$${params.length}`;
      cursorCondition = normalizedBeforeId
        ? `AND (ts < ${tsParam} OR (ts = ${tsParam} AND id < ${idParam}))`
        : `AND (ts > ${tsParam} OR (ts = ${tsParam} AND id > ${idParam}))`;
    }

    const normalizedLimit = Number.isFinite(Number(limit))
      ? Math.max(0, Math.floor(Number(limit)))
      : null;
    const limitSql = normalizedLimit === null ? "" : `LIMIT ${normalizedLimit}`;
    const result = await this._pool.query(
      `SELECT message_data
         FROM ${this._qualifiedChatMessagesTableName}
        WHERE ${scopeSql}
          ${cursorCondition}
        ORDER BY ts DESC, id DESC
        ${limitSql}`,
      params,
    );
    const messages = result.rows
      .map((row) => this._chatMessageFromRow(row))
      .filter(Boolean);
    const reactions = await this._aggregateReactionsByMessageIds(
      messages.map((message) => message.id),
    );
    this._scheduleChatTablePurgeSweep();
    return messages.map((message) => this._attachTableReactions(message, reactions));
  }

  async _selectChatMessageInScope({chatId, resolvedChatId, messageId, nowTimestamp}) {
    const normalizedMessageId = String(messageId || "").trim();
    if (!normalizedMessageId) {
      return null;
    }
    const equivalentIds = this._equivalentChatIdList(chatId, resolvedChatId);
    const placeholders = equivalentIds.map((_, index) => `$${index + 1}`);
    const result = await this._pool.query(
      `SELECT message_data
         FROM ${this._qualifiedChatMessagesTableName}
        WHERE chat_id IN (${placeholders.join(", ")})
          AND (expires_at = '' OR expires_at > $${equivalentIds.length + 1})
          AND id = $${equivalentIds.length + 2}
        LIMIT 1`,
      [...equivalentIds, nowTimestamp, normalizedMessageId],
    );
    return this._chatMessageFromRow(result.rows[0]);
  }

  async updateChatMessage({chatId, messageId, userId, text}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !resolved.chat.participantIds.includes(userId)) {
      return false;
    }
    return this._enqueueChatRowMutation(async () => {
      const message = await this._selectChatMessageInScope({
        chatId,
        resolvedChatId: resolved.chat.id,
        messageId,
        nowTimestamp: nowIso(),
      });
      if (!message) {
        return null;
      }
      if (message.senderId !== userId) {
        return undefined;
      }

      const normalizedText = String(text || "").trim();
      const attachments = normalizeMessageAttachments(message);
      if (!normalizedText && attachments.length === 0) {
        return "EMPTY_MESSAGE";
      }

      message.text = normalizedText;
      message.updatedAt = nowIso();
      await this._updateChatMessageRow(message);
      const reactions = await this._aggregateReactionsByMessageIds([message.id]);
      return this._attachTableReactions(message, reactions);
    });
  }

  async deleteChatMessage({chatId, messageId, userId}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !resolved.chat.participantIds.includes(userId)) {
      return false;
    }
    const message = await this._selectChatMessageInScope({
      chatId,
      resolvedChatId: resolved.chat.id,
      messageId,
      nowTimestamp: nowIso(),
    });
    if (!message) {
      return null;
    }
    if (message.senderId !== userId) {
      return undefined;
    }

    await this._pool.query(
      `DELETE FROM ${this._qualifiedChatMessagesTableName} WHERE id = $1`,
      [message.id],
    );
    await this._pool.query(
      `DELETE FROM ${this._qualifiedChatReactionsTableName} WHERE message_id = $1`,
      [message.id],
    );
    const pinDelete = await this._pool.query(
      `DELETE FROM ${this._qualifiedChatPinsTableName}
        WHERE message_id = $1
        RETURNING chat_id`,
      [message.id],
    );

    // Как в FileStore: после удаления реакции сообщения уже вычищены,
    // возвращается пустой агрегат.
    const deletedMessage = structuredClone(message);
    deletedMessage.reactions = [];
    if (pinDelete.rows.length > 0) {
      deletedMessage._clearedPinnedMessage = true;
    }
    return deletedMessage;
  }

  async toggleChatMessageReaction({chatId, messageId, userId, emoji}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !resolved.chat.participantIds.includes(userId)) {
      return false;
    }
    const message = await this._selectChatMessageInScope({
      chatId,
      resolvedChatId: resolved.chat.id,
      messageId,
      nowTimestamp: nowIso(),
    });
    if (!message) {
      return null;
    }

    const normalizedEmoji = normalizeReactionEmoji(emoji);
    if (!normalizedEmoji) {
      return "INVALID_EMOJI";
    }

    const existing = await this._pool.query(
      `SELECT 1 AS present
         FROM ${this._qualifiedChatReactionsTableName}
        WHERE message_id = $1 AND user_id = $2 AND emoji = $3
        LIMIT 1`,
      [message.id, userId, normalizedEmoji],
    );
    let added = false;
    if (existing.rows.length > 0) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatReactionsTableName}
          WHERE message_id = $1 AND user_id = $2 AND emoji = $3`,
        [message.id, userId, normalizedEmoji],
      );
    } else {
      await this._pool.query(
        `INSERT INTO ${this._qualifiedChatReactionsTableName}
           (message_id, user_id, emoji, created_at)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (message_id, user_id, emoji) DO NOTHING`,
        [message.id, userId, normalizedEmoji, nowIso()],
      );
      added = true;
    }

    const reactions = await this._aggregateReactionsByMessageIds([message.id]);
    return {
      chatId: message.chatId || resolved.chat.id,
      messageId: message.id,
      reactions: reactions.get(message.id) || [],
      added,
    };
  }

  async markChatMessageDelivered({chatId, messageId, userIds = []}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved) {
      return false;
    }
    return this._enqueueChatRowMutation(async () => {
      const message = await this._selectChatMessageInScope({
        chatId,
        resolvedChatId: resolved.chat.id,
        messageId,
        nowTimestamp: nowIso(),
      });
      if (!message) {
        return null;
      }

      const participantIds = normalizeParticipantIds(resolved.chat.participantIds);
      const recipientIds = normalizeParticipantIds(userIds).filter(
        (userId) => participantIds.includes(userId) && userId !== message.senderId,
      );
      if (recipientIds.length === 0) {
        return {
          chatId: message.chatId || resolved.chat.id,
          messageId: message.id,
          deliveredTo: normalizeParticipantIds(message.deliveredTo),
          changedUserIds: [],
        };
      }

      const deliveredTo = normalizeParticipantIds(message.deliveredTo);
      let changed = false;
      for (const userId of recipientIds) {
        if (!deliveredTo.includes(userId)) {
          deliveredTo.push(userId);
          changed = true;
        }
      }
      message.deliveredTo = deliveredTo;
      if (changed) {
        await this._updateChatMessageRow(message);
      }

      return {
        chatId: message.chatId || resolved.chat.id,
        messageId: message.id,
        deliveredTo: normalizeParticipantIds(message.deliveredTo),
        changedUserIds: changed ? recipientIds : [],
      };
    });
  }

  async markChatAsRead(chatId, userId) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !resolved.chat.participantIds.includes(userId)) {
      return false;
    }
    const equivalentIds = this._equivalentChatIdList(chatId, resolved.chat.id);
    return this._enqueueChatRowMutation(async () => {
      const nowTimestamp = nowIso();
      const placeholders = equivalentIds.map((_, index) => `$${index + 1}`);
      const result = await this._pool.query(
        `SELECT message_data
           FROM ${this._qualifiedChatMessagesTableName}
          WHERE chat_id IN (${placeholders.join(", ")})
            AND (expires_at = '' OR expires_at > $${equivalentIds.length + 1})
            AND sender_id <> $${equivalentIds.length + 2}`,
        [...equivalentIds, nowTimestamp, userId],
      );

      let changed = false;
      const readMessageIds = [];
      for (const row of result.rows) {
        const message = this._chatMessageFromRow(row);
        if (!message) {
          continue;
        }
        let messageChanged = false;
        const deliveredTo = normalizeParticipantIds(message.deliveredTo);
        if (!deliveredTo.includes(userId)) {
          deliveredTo.push(userId);
          message.deliveredTo = deliveredTo;
          messageChanged = true;
        }
        const readBy = normalizeParticipantIds(message.readBy);
        if (!readBy.includes(userId)) {
          readBy.push(userId);
          message.readBy = readBy;
          readMessageIds.push(message.id);
          messageChanged = true;
        }
        if (message.isRead !== true) {
          message.isRead = true;
          messageChanged = true;
        }
        if (messageChanged) {
          changed = true;
          await this._updateChatMessageRow(message);
        }
      }

      return {
        changed,
        chatId: resolved.chat.id,
        userId,
        messageIds: readMessageIds,
      };
    });
  }

  async getChatDraft({userId, chatId}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !this._canAccessChatDraft(resolved.chat, userId)) {
      return null;
    }
    const result = await this._pool.query(
      `SELECT draft_data
         FROM ${this._qualifiedChatDraftsTableName}
        WHERE user_id = $1 AND chat_id = $2
        LIMIT 1`,
      [String(userId || "").trim(), resolved.chat.id],
    );
    const draft = this._chatJsonFromRow(result.rows[0], "draft_data");
    return draft ? structuredClone(draft) : null;
  }

  async listChatDrafts(userId) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    const result = await this._pool.query(
      `SELECT draft_data
         FROM ${this._qualifiedChatDraftsTableName}
        WHERE user_id = $1`,
      [normalizedUserId],
    );
    const drafts = [];
    for (const row of result.rows) {
      const draft = this._chatJsonFromRow(row, "draft_data");
      if (!draft || !String(draft.text || "").trim()) {
        continue;
      }
      const resolved = await this._resolveChatFromTables(draft.chatId);
      if (!resolved || !this._canAccessChatDraft(resolved.chat, normalizedUserId)) {
        continue;
      }
      drafts.push(draft);
    }
    return drafts
      .sort((left, right) =>
        String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")),
      )
      .map((draft) => structuredClone(draft));
  }

  async saveChatDraft({userId, chatId, text}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !this._canAccessChatDraft(resolved.chat, userId)) {
      return null;
    }
    const normalizedUserId = String(userId || "").trim();
    const normalizedText = String(text || "");
    if (!normalizedText.trim()) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatDraftsTableName}
          WHERE user_id = $1 AND chat_id = $2`,
        [normalizedUserId, resolved.chat.id],
      );
      return null;
    }
    const draft = createChatDraftRecord({
      userId: normalizedUserId,
      chatId: resolved.chat.id,
      text: normalizedText,
    });
    await this._pool.query(
      `INSERT INTO ${this._qualifiedChatDraftsTableName} (user_id, chat_id, draft_data)
       VALUES ($1, $2, $3::jsonb)
       ON CONFLICT (user_id, chat_id) DO UPDATE SET draft_data = EXCLUDED.draft_data`,
      [normalizedUserId, resolved.chat.id, JSON.stringify(draft)],
    );
    return structuredClone(draft);
  }

  async _selectChatPin(equivalentChatIds) {
    const ids = equivalentChatIds.filter(Boolean);
    if (ids.length === 0) {
      return null;
    }
    const placeholders = ids.map((_, index) => `$${index + 1}`);
    const result = await this._pool.query(
      `SELECT chat_id, message_id, pin_data
         FROM ${this._qualifiedChatPinsTableName}
        WHERE chat_id IN (${placeholders.join(", ")})
        LIMIT 1`,
      ids,
    );
    return result.rows[0] || null;
  }

  async getChatPinnedMessage({userId, chatId}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !this._canAccessChatPin(resolved.chat, userId)) {
      return null;
    }
    const equivalentIds = this._equivalentChatIdList(chatId, resolved.chat.id);
    const pinRow = await this._selectChatPin(equivalentIds);
    if (!pinRow) {
      return null;
    }
    const pin = this._chatJsonFromRow(pinRow, "pin_data") || {};
    const message = await this._selectChatMessageInScope({
      chatId,
      resolvedChatId: resolved.chat.id,
      messageId: pinRow.message_id,
      nowTimestamp: nowIso(),
    });
    if (!message) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatPinsTableName} WHERE message_id = $1`,
        [pinRow.message_id],
      );
      return null;
    }
    const freshPin = {
      ...createChatPinRecord({
        chatId: resolved.chat.id,
        message,
        pinnedBy: pin.pinnedBy || userId,
      }),
      pinnedAt: pin.pinnedAt || nowIso(),
    };
    return structuredClone(freshPin);
  }

  async pinChatMessage({userId, chatId, messageId}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !this._canAccessChatPin(resolved.chat, userId)) {
      return false;
    }
    const message = await this._selectChatMessageInScope({
      chatId,
      resolvedChatId: resolved.chat.id,
      messageId,
      nowTimestamp: nowIso(),
    });
    if (!message) {
      return null;
    }
    const equivalentIds = this._equivalentChatIdList(chatId, resolved.chat.id);
    const placeholders = equivalentIds.map((_, index) => `$${index + 1}`);
    await this._pool.query(
      `DELETE FROM ${this._qualifiedChatPinsTableName}
        WHERE chat_id IN (${placeholders.join(", ")})`,
      equivalentIds,
    );
    const pin = createChatPinRecord({
      chatId: resolved.chat.id,
      message,
      pinnedBy: userId,
    });
    await this._pool.query(
      `INSERT INTO ${this._qualifiedChatPinsTableName} (chat_id, message_id, pin_data)
       VALUES ($1, $2, $3::jsonb)
       ON CONFLICT (chat_id) DO UPDATE
         SET message_id = EXCLUDED.message_id,
             pin_data = EXCLUDED.pin_data`,
      [resolved.chat.id, pin.messageId, JSON.stringify(pin)],
    );
    return structuredClone(pin);
  }

  async clearChatPinnedMessage({userId, chatId}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const resolved = await this._resolveChatFromTables(chatId);
    if (!resolved || !this._canAccessChatPin(resolved.chat, userId)) {
      return false;
    }
    const equivalentIds = this._equivalentChatIdList(chatId, resolved.chat.id);
    const placeholders = equivalentIds.map((_, index) => `$${index + 1}`);
    await this._pool.query(
      `DELETE FROM ${this._qualifiedChatPinsTableName}
        WHERE chat_id IN (${placeholders.join(", ")})`,
      equivalentIds,
    );
    return true;
  }

  async searchChatMessages({
    userId,
    query,
    chatId = null,
    limit = 50,
  } = {}) {
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const normalizedUserId = String(userId || "").trim();
    const terms = normalizeChatSearchQuery(query);
    if (!normalizedUserId || terms.length === 0) {
      return [];
    }
    const normalizedLimit = Math.min(
      Math.max(1, Number.parseInt(String(limit || "50"), 10) || 50),
      100,
    );

    const normalizedChatId = normalizeNullableString(chatId);
    let scopeIds = null;
    if (normalizedChatId) {
      const resolved = await this._resolveChatFromTables(normalizedChatId);
      if (
        !resolved ||
        !normalizeParticipantIds(resolved.chat.participantIds).includes(normalizedUserId)
      ) {
        return [];
      }
      scopeIds = this._equivalentChatIdList(normalizedChatId, resolved.chat.id);
    }

    const params = [];
    const conditions = [];
    for (const term of terms) {
      params.push(`%${this._escapeLikePattern(term)}%`);
      conditions.push(`haystack LIKE $${params.length}`);
    }
    params.push(nowIso());
    conditions.push(`(expires_at = '' OR expires_at > $${params.length})`);
    if (scopeIds) {
      const placeholders = scopeIds.map((id) => {
        params.push(id);
        return `$${params.length}`;
      });
      conditions.push(`chat_id IN (${placeholders.join(", ")})`);
    }

    const result = await this._pool.query(
      `SELECT message_data
         FROM ${this._qualifiedChatMessagesTableName}
        WHERE ${conditions.join(" AND ")}
        ORDER BY ts DESC, id DESC
        LIMIT 1000`,
      params,
    );

    const chatCache = new Map();
    const results = [];
    for (const row of result.rows) {
      if (results.length >= normalizedLimit) {
        break;
      }
      const message = this._chatMessageFromRow(row);
      const messageChatId = String(message?.chatId || "").trim();
      if (!message || !messageChatId) {
        continue;
      }
      let participantIds = normalizeParticipantIds(
        Array.isArray(message.participants) && message.participants.length > 0
          ? message.participants
          : null,
      );
      if (participantIds.length === 0) {
        if (!chatCache.has(messageChatId)) {
          chatCache.set(
            messageChatId,
            await this._selectChatProjectionById(messageChatId),
          );
        }
        participantIds = normalizeParticipantIds(
          chatCache.get(messageChatId)?.participantIds,
        );
      }
      if (!participantIds.includes(normalizedUserId)) {
        continue;
      }
      results.push({
        messageId: message.id,
        chatId: messageChatId,
        senderId: message.senderId || "",
        senderName: message.senderName || "Участник",
        text: message.text || "",
        snippet: buildChatSearchSnippet(message, terms),
        matchedAt: message.timestamp,
      });
    }
    return structuredClone(results);
  }

  async _selectChatsForUserFromTables(userId) {
    const result = await this._pool.query(
      `SELECT p.chat_data
         FROM ${this._qualifiedChatsProjectionTableName} p
         JOIN ${this._qualifiedChatParticipantsTableName} m
           ON m.chat_id = p.id
        WHERE m.user_id = $1`,
      [String(userId || "").trim()],
    );
    return result.rows
      .map((row) => this._chatJsonFromRow(row, "chat_data"))
      .filter((chat) => chat && String(chat.id || "").trim());
  }

  async _selectChatMessagesForPreviews(userId, chatIds) {
    const normalizedUserId = String(userId || "").trim();
    const params = [];
    const scopeParts = [];
    if (chatIds.length > 0) {
      const placeholders = chatIds.map((id) => {
        params.push(id);
        return `$${params.length}`;
      });
      scopeParts.push(`chat_id IN (${placeholders.join(", ")})`);
    }
    // Виртуальные direct-чаты без сохранённой записи: канонический id
    // содержит userId как первый или второй компонент.
    params.push(`${this._escapeLikePattern(normalizedUserId)}_%`);
    scopeParts.push(`chat_id LIKE $${params.length}`);
    params.push(`%_${this._escapeLikePattern(normalizedUserId)}`);
    scopeParts.push(`chat_id LIKE $${params.length}`);
    params.push(nowIso());
    const result = await this._pool.query(
      `SELECT message_data
         FROM ${this._qualifiedChatMessagesTableName}
        WHERE (${scopeParts.join(" OR ")})
          AND (expires_at = '' OR expires_at > $${params.length})
        ORDER BY ts DESC, id DESC`,
      params,
    );
    return result.rows
      .map((row) => this._chatMessageFromRow(row))
      .filter(Boolean);
  }

  async listChatPreviews(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const storedChats = await this._selectChatsForUserFromTables(normalizedUserId);
    const relatedChats = new Map();
    for (const chat of storedChats) {
      relatedChats.set(String(chat.id).trim(), structuredClone(chat));
    }
    const storedMessages = await this._selectChatMessagesForPreviews(
      normalizedUserId,
      Array.from(relatedChats.keys()),
    );

    const messagesByChatId = new Map();
    for (const message of storedMessages) {
      const rawChatId = String(message?.chatId || "").trim();
      const messageParticipants = normalizeParticipantIds(message?.participants);
      let resolvedChat = rawChatId ? relatedChats.get(rawChatId) || null : null;
      if (!resolvedChat) {
        const parsedDirectParticipants = parseDirectParticipantsFromChatId(rawChatId);
        const directParticipants =
          messageParticipants.length === 2
            ? messageParticipants
            : parsedDirectParticipants;
        if (
          directParticipants.length === 2 &&
          directParticipants.includes(normalizedUserId)
        ) {
          const canonicalChatId = directParticipants.join("_");
          resolvedChat = relatedChats.get(canonicalChatId) || {
            id: canonicalChatId,
            type: "direct",
            participantIds: directParticipants,
            title: null,
            createdBy: directParticipants[0] || null,
            treeId: null,
            branchRootPersonIds: [],
            createdAt: message?.timestamp || nowIso(),
            updatedAt: message?.timestamp || nowIso(),
          };
          relatedChats.set(canonicalChatId, resolvedChat);
        }
      }
      if (!resolvedChat?.id) {
        continue;
      }
      const resolvedChatId = String(resolvedChat.id).trim();
      const bucket = messagesByChatId.get(resolvedChatId) || [];
      bucket.push(message);
      messagesByChatId.set(resolvedChatId, bucket);
    }

    const participantIds = new Set();
    for (const chat of relatedChats.values()) {
      for (const participantId of normalizeParticipantIds(chat?.participantIds)) {
        if (participantId && participantId !== normalizedUserId) {
          participantIds.add(participantId);
        }
      }
    }
    const usersById = await this._selectProjectedUsersByIds(Array.from(participantIds));
    const previews = [];
    for (const chat of relatedChats.values()) {
      const participants = normalizeParticipantIds(chat?.participantIds);
      if (!participants.includes(normalizedUserId)) {
        continue;
      }
      const isGroup = chat?.type === "group" || chat?.type === "branch";
      const otherUserId = isGroup
        ? ""
        : participants.find((participantId) => participantId !== normalizedUserId) || "";
      const relevantMessages = (messagesByChatId.get(String(chat?.id || "").trim()) || [])
        .sort((left, right) =>
          String(right?.timestamp || "").localeCompare(String(left?.timestamp || "")),
        );
      const lastMessage = relevantMessages[0] || null;
      const preview = {
        chatId: String(chat?.id || "").trim(),
        userId: normalizedUserId,
        type: chat?.type || "direct",
        title: chat?.title || null,
        photoUrl: isGroup ? chat?.photoUrl || null : null,
        participantIds: participants,
        otherUserId,
        otherUserName: "Пользователь",
        otherUserPhotoUrl: null,
        lastMessage: lastMessage ? describeMessagePreview(lastMessage) : "",
        lastMessageTime:
          lastMessage?.timestamp || chat?.updatedAt || chat?.createdAt || "",
        unreadCount: relevantMessages.filter((message) => {
          return message?.senderId !== normalizedUserId &&
            !this._isProjectedMessageReadByUser(message, normalizedUserId);
        }).length,
        lastMessageSenderId: lastMessage?.senderId || "",
      };
      if (isGroup) {
        const otherParticipantNames = participants
          .filter((participantId) => participantId !== normalizedUserId)
          .map((participantId) => {
            const user = usersById.get(participantId);
            return user?.profile?.displayName || user?.email || "";
          })
          .filter(Boolean);
        preview.otherUserName =
          chat?.title ||
          (otherParticipantNames.length > 0
            ? otherParticipantNames.slice(0, 3).join(", ")
            : "Групповой чат");
      } else if (otherUserId) {
        const otherUser = usersById.get(otherUserId);
        if (otherUser) {
          preview.otherUserName =
            otherUser.profile?.displayName || otherUser.email || "Пользователь";
          preview.otherUserPhotoUrl = otherUser.profile?.photoUrl || null;
        }
      }
      previews.push(preview);
    }

    this._scheduleChatTablePurgeSweep();
    return previews
      .sort((left, right) =>
        String(right.lastMessageTime || "").localeCompare(String(left.lastMessageTime || "")),
      )
      .map((preview) => structuredClone(preview));
  }

  async countUnreadChatMessages(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return 0;
    }
    await this.initialize();
    // Барьер write-queue тут не нужен: данные живут в чат-таблицах, чьи
    // писатели — прямой SQL, а не блоб-очередь; HTTP-порядок запросов даёт
    // нужную последовательность. Ожидание блоб-очереди (нотификации/пуш-логи
    // фан-аута) добавляло до ~300мс на access под бёрстом.
    const storedChats = await this._selectChatsForUserFromTables(normalizedUserId);
    const chatIds = storedChats.map((chat) => String(chat.id).trim());
    const messages = await this._selectChatMessagesForPreviews(
      normalizedUserId,
      chatIds,
    );
    const chatIdSet = new Set(chatIds);
    let total = 0;
    for (const message of messages) {
      if (message?.senderId === normalizedUserId) {
        continue;
      }
      const messageChatId = String(message?.chatId || "").trim();
      const participants = normalizeParticipantIds(message?.participants);
      const isMember =
        chatIdSet.has(messageChatId) ||
        participants.includes(normalizedUserId) ||
        parseDirectParticipantsFromChatId(messageChatId).includes(normalizedUserId);
      if (!isMember) {
        continue;
      }
      if (!this._isProjectedMessageReadByUser(message, normalizedUserId)) {
        total += 1;
      }
    }
    return total;
  }

  async listOwnedMediaUrls(userId) {
    const urls = new Set(await super.listOwnedMediaUrls(userId));
    const result = await this._pool.query(
      `SELECT message_data
         FROM ${this._qualifiedChatMessagesTableName}
        WHERE sender_id = $1`,
      [String(userId || "").trim()],
    );
    for (const row of result.rows) {
      const message = this._chatMessageFromRow(row);
      if (!message) {
        continue;
      }
      collectMessageMediaUrls(urls, message);
    }
    return Array.from(urls);
  }

  async deleteUser(userId) {
    await this.initialize();
    const normalizedUserId = String(userId || "").trim();
    const beforeResult = await this._pool.query(
      `SELECT chat_id FROM ${this._qualifiedChatParticipantsTableName} WHERE user_id = $1`,
      [normalizedUserId],
    );
    const beforeChatIds = beforeResult.rows
      .map((row) => String(row?.chat_id || "").trim())
      .filter(Boolean);
    const result = await super.deleteUser(userId);

    // Блобная часть уже вычистила записи чатов (projection пересинкан в
    // _write); зеркалим табличную часть семантики FileStore.deleteUser.
    const survivingChatIds = new Set();
    if (beforeChatIds.length > 0) {
      const placeholders = beforeChatIds.map((_, index) => `$${index + 1}`);
      const surviving = await this._pool.query(
        `SELECT id FROM ${this._qualifiedChatsProjectionTableName}
          WHERE id IN (${placeholders.join(", ")})`,
        beforeChatIds,
      );
      for (const row of surviving.rows) {
        survivingChatIds.add(String(row?.id || "").trim());
      }
    }
    const removedChatIds = beforeChatIds.filter((id) => !survivingChatIds.has(id));

    const deletedMessageIds = new Set();
    const collectDeleted = (rows) => {
      for (const row of rows) {
        const id = String(row?.id || "").trim();
        if (id) {
          deletedMessageIds.add(id);
        }
      }
    };
    const bySender = await this._pool.query(
      `DELETE FROM ${this._qualifiedChatMessagesTableName}
        WHERE sender_id = $1
        RETURNING id`,
      [normalizedUserId],
    );
    collectDeleted(bySender.rows);
    if (removedChatIds.length > 0) {
      const placeholders = removedChatIds.map((_, index) => `$${index + 1}`);
      const byChat = await this._pool.query(
        `DELETE FROM ${this._qualifiedChatMessagesTableName}
          WHERE chat_id IN (${placeholders.join(", ")})
          RETURNING id`,
        removedChatIds,
      );
      collectDeleted(byChat.rows);
    }
    // Как FileStore: удаляются ВСЕ сообщения, в чьём participants-снапшоте
    // есть пользователь (включая чужие сообщения в выживших групповых чатах),
    // плюс стороны виртуальных direct-чатов. Полный скан — deleteUser редкий
    // и не на горячем пути; LIKE-эвристика пропускала групповые снапшоты.
    const candidates = await this._pool.query(
      `SELECT id, message_data
         FROM ${this._qualifiedChatMessagesTableName}`,
    );
    const participantMessageIds = [];
    for (const row of candidates.rows) {
      const message = this._chatMessageFromRow(row);
      const participants = normalizeParticipantIds(message?.participants);
      if (
        participants.includes(normalizedUserId) ||
        parseDirectParticipantsFromChatId(String(message?.chatId || "")).includes(
          normalizedUserId,
        )
      ) {
        participantMessageIds.push(String(row.id).trim());
      }
    }
    if (participantMessageIds.length > 0) {
      const placeholders = participantMessageIds.map((_, index) => `$${index + 1}`);
      const byParticipants = await this._pool.query(
        `DELETE FROM ${this._qualifiedChatMessagesTableName}
          WHERE id IN (${placeholders.join(", ")})
          RETURNING id`,
        participantMessageIds,
      );
      collectDeleted(byParticipants.rows);
    }

    await this._pool.query(
      `DELETE FROM ${this._qualifiedChatReactionsTableName} WHERE user_id = $1`,
      [normalizedUserId],
    );
    if (deletedMessageIds.size > 0) {
      const ids = Array.from(deletedMessageIds);
      const placeholders = ids.map((_, index) => `$${index + 1}`);
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatReactionsTableName}
          WHERE message_id IN (${placeholders.join(", ")})`,
        ids,
      );
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatPinsTableName}
          WHERE message_id IN (${placeholders.join(", ")})`,
        ids,
      );
    }
    await this._pool.query(
      `DELETE FROM ${this._qualifiedChatDraftsTableName} WHERE user_id = $1`,
      [normalizedUserId],
    );
    if (removedChatIds.length > 0) {
      const placeholders = removedChatIds.map((_, index) => `$${index + 1}`);
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatDraftsTableName}
          WHERE chat_id IN (${placeholders.join(", ")})`,
        removedChatIds,
      );
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatPinsTableName}
          WHERE chat_id IN (${placeholders.join(", ")})`,
        removedChatIds,
      );
    }
    // Пины, поставленные удаляемым пользователем (FileStore выкидывает их).
    const pins = await this._pool.query(
      `SELECT chat_id, pin_data FROM ${this._qualifiedChatPinsTableName}`,
    );
    for (const row of pins.rows) {
      const pin = this._chatJsonFromRow(row, "pin_data");
      if (String(pin?.pinnedBy || "").trim() === normalizedUserId) {
        await this._pool.query(
          `DELETE FROM ${this._qualifiedChatPinsTableName} WHERE chat_id = $1`,
          [String(row.chat_id).trim()],
        );
      }
    }

    // ── SPEED-7: каскад notifications/push_deliveries ──────────────────
    // Множества «умерших» сущностей — ИЗ РЕЗУЛЬТАТА super.deleteUser
    // (вычислены внутри _mutate-applyFn): реконструкция дифом блоба
    // до/после приписывала бы каскаду конкурентные удаления ДРУГИХ
    // пользователей и убивала их уведомления (находка ревью, P0).
    const asSet = (list) =>
      new Set(
        (Array.isArray(list) ? list : [])
          .map((entry) => String(entry || "").trim())
          .filter(Boolean),
      );
    const removedIds = {
      chats: asSet(result?.removedChatIds),
      trees: asSet(result?.removedTreeIds),
      posts: asSet(result?.removedPostIds),
      comments: asSet(result?.removedCommentIds),
      relationRequests: asSet(result?.removedRelationRequestIds),
      treeInvitations: asSet(result?.removedInvitationIds),
    };
    if (result === null) {
      // Юзера не было (skip в applyFn) — каскадить нечего.
      return result;
    }

    // Полный скан: та же семантика, что у массивного фильтра FileStore
    // (deleteUser редкий, таблица сотни строк — дешевле, чем jsonb-WHERE,
    // который pg-mem поддерживает выборочно). DELETE — точечно по id:
    // уведомление, вставленное конкурентно ПОСЛЕ скана, не удаляется —
    // узкое окно записи-сироты со ссылкой на умершую сущность (createNotification
    // для самого юзера уже отбит findUserById по auth-проекции).
    const allNotifications = await this._pool.query(
      `SELECT id, user_id, notification_data
         FROM ${this._qualifiedNotificationsTableName}`,
    );
    const notificationIdsToDelete = [];
    const survivingNotificationIds = new Set();
    for (const row of allNotifications.rows) {
      const rowId = String(row?.id || "").trim();
      const notification = this._rowToNotification(row) || {};
      const data =
        notification.data && typeof notification.data === "object"
          ? notification.data
          : {};
      const doomed =
        String(row?.user_id || "").trim() === normalizedUserId ||
        data.userId === userId ||
        data.senderId === userId ||
        data.recipientId === userId ||
        data.actorId === userId ||
        data.targetUserId === userId ||
        data.authorId === userId ||
        data.ownerId === userId ||
        (data.chatId && removedIds.chats.has(data.chatId)) ||
        (data.treeId && removedIds.trees.has(data.treeId)) ||
        (data.postId && removedIds.posts.has(data.postId)) ||
        (data.commentId && removedIds.comments.has(data.commentId)) ||
        (data.requestId && removedIds.relationRequests.has(data.requestId)) ||
        (data.invitationId && removedIds.treeInvitations.has(data.invitationId));
      if (doomed) {
        notificationIdsToDelete.push(rowId);
      } else {
        survivingNotificationIds.add(rowId);
      }
    }
    for (const id of notificationIdsToDelete) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedNotificationsTableName} WHERE id = $1`,
        [id],
      );
    }

    // Повторный точечный проход закрывает GDPR-окно: уведомление про
    // юзера, вставленное конкурентно ПОСЛЕ основного скана (ревью, P1).
    // Прямые записи юзера — одним DELETE; ссылки в data.* — вторым сканом.
    await this._pool.query(
      `DELETE FROM ${this._qualifiedNotificationsTableName} WHERE user_id = $1`,
      [normalizedUserId],
    );
    const lateRows = await this._pool.query(
      `SELECT id, notification_data
         FROM ${this._qualifiedNotificationsTableName}`,
    );
    for (const row of lateRows.rows) {
      const notification = this._rowToNotification(row) || {};
      const data =
        notification.data && typeof notification.data === "object"
          ? notification.data
          : {};
      const referencesUser =
        data.userId === userId ||
        data.senderId === userId ||
        data.recipientId === userId ||
        data.actorId === userId ||
        data.targetUserId === userId ||
        data.authorId === userId ||
        data.ownerId === userId;
      if (referencesUser) {
        await this._pool.query(
          `DELETE FROM ${this._qualifiedNotificationsTableName} WHERE id = $1`,
          [String(row.id)],
        );
        survivingNotificationIds.delete(String(row.id));
      }
    }

    const allDeliveries = await this._pool.query(
      `SELECT id, user_id, notification_id
         FROM ${this._qualifiedPushDeliveriesTableName}`,
    );
    for (const row of allDeliveries.rows) {
      const ownerId = String(row?.user_id || "").trim();
      const notificationId = String(row?.notification_id || "").trim();
      const doomed =
        ownerId === normalizedUserId ||
        (notificationId && !survivingNotificationIds.has(notificationId));
      if (doomed) {
        await this._pool.query(
          `DELETE FROM ${this._qualifiedPushDeliveriesTableName} WHERE id = $1`,
          [String(row.id)],
        );
      }
    }

    return result;
  }

  async removeTreeForUser({treeId, userId}) {
    await this.initialize();
    const normalizedTreeId = String(treeId || "").trim();
    const projected = await this._pool.query(
      `SELECT id, chat_data FROM ${this._qualifiedChatsProjectionTableName}`,
    );
    const treeChatIds = [];
    for (const row of projected.rows) {
      const chat = this._chatJsonFromRow(row, "chat_data");
      if (String(chat?.treeId || "").trim() === normalizedTreeId) {
        treeChatIds.push(String(row.id).trim());
      }
    }

    const result = await super.removeTreeForUser({treeId, userId});

    if (result?.action === "deleted" && treeChatIds.length > 0) {
      const placeholders = treeChatIds.map((_, index) => `$${index + 1}`);
      const deleted = await this._pool.query(
        `DELETE FROM ${this._qualifiedChatMessagesTableName}
          WHERE chat_id IN (${placeholders.join(", ")})
          RETURNING id`,
        treeChatIds,
      );
      const deletedIds = deleted.rows
        .map((row) => String(row?.id || "").trim())
        .filter(Boolean);
      if (deletedIds.length > 0) {
        const idPlaceholders = deletedIds.map((_, index) => `$${index + 1}`);
        await this._pool.query(
          `DELETE FROM ${this._qualifiedChatReactionsTableName}
            WHERE message_id IN (${idPlaceholders.join(", ")})`,
          deletedIds,
        );
      }
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatDraftsTableName}
          WHERE chat_id IN (${placeholders.join(", ")})`,
        treeChatIds,
      );
      await this._pool.query(
        `DELETE FROM ${this._qualifiedChatPinsTableName}
          WHERE chat_id IN (${placeholders.join(", ")})`,
        treeChatIds,
      );
    }

    // SPEED-7: зеркалим notification-каскад FileStore. Hard-delete дерева —
    // все уведомления с data.treeId; выход участника — только его
    // собственные с этим treeId. Скан+JS-фильтр (см. deleteUser).
    if (result) {
      const treeDeleted = result.action === "deleted";
      const rows = await this._pool.query(
        `SELECT id, user_id, notification_data
           FROM ${this._qualifiedNotificationsTableName}`,
      );
      const normalizedUserId = String(userId || "").trim();
      for (const row of rows.rows) {
        const notification = this._rowToNotification(row) || {};
        const dataTreeId = String(notification?.data?.treeId || "").trim();
        if (dataTreeId !== normalizedTreeId) {
          continue;
        }
        if (!treeDeleted && String(row?.user_id || "").trim() !== normalizedUserId) {
          continue;
        }
        await this._pool.query(
          `DELETE FROM ${this._qualifiedNotificationsTableName} WHERE id = $1`,
          [String(row.id)],
        );
      }
    }
    return result;
  }

  async deletePushDevice(deviceId, userId) {
    await this.initialize();
    const result = await super.deletePushDevice(deviceId, userId);
    // SPEED-7: блобный каскад по deliveries стал no-op (массив пуст) —
    // чистим таблицу. Только при фактическом удалении устройства.
    if (result) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedPushDeliveriesTableName}
          WHERE device_id = $1`,
        [String(deviceId || "").trim()],
      );
    }
    return result;
  }

  async unbindPushDevicesForSession({userId, sessionPublicId}) {
    await this.initialize();
    const result = await super.unbindPushDevicesForSession({
      userId,
      sessionPublicId,
    });
    // Источник истины — ФАКТИЧЕСКИ удалённые устройства из super (пре-снапшот
    // блоба мог устареть между чтением и мутацией — находка ревью).
    const deviceIds = (Array.isArray(result) ? result : [])
      .map((entry) => String(entry?.id || "").trim())
      .filter(Boolean);
    for (const deviceId of deviceIds) {
      await this._pool.query(
        `DELETE FROM ${this._qualifiedPushDeliveriesTableName}
          WHERE device_id = $1`,
        [deviceId],
      );
    }
    return result;
  }

  async hardDeleteExpired(options = {}) {
    const summary = await super.hardDeleteExpired(options);
    // SPEED-7: retention таблиц — те же три окна notifications + TTL/cap
    // pushDeliveries, что в _sweepUnboundedLogs (блобные массивы после
    // миграции пусты, их счётчики в summary нулевые). ISO-строки
    // сравниваются лексикографически; пустой/непарсибельный created_at не
    // трогаем (гвард <> '' + сам формат cutoff).
    const {now = new Date(), dryRun = false, logRetention = {}} = options || {};
    const startedAt = now instanceof Date ? now : new Date(now);
    const nowTs = startedAt.getTime();
    const HOUR = 3_600_000;
    const DAY = 86_400_000;
    const cutoffIso = (ms) => new Date(nowTs - ms).toISOString();
    const counts = {
      notificationsSilent: 0,
      notificationsRead: 0,
      notificationsUnread: 0,
      pushDeliveries: 0,
    };
    const sweepNotifications = async (whereSql, params, key) => {
      if (dryRun) {
        const counted = await this._pool.query(
          `SELECT COUNT(*)::int AS total
             FROM ${this._qualifiedNotificationsTableName}
            WHERE created_at <> '' AND ${whereSql}`,
          params,
        );
        counts[key] += Number(counted.rows[0]?.total || 0);
        return;
      }
      const deleted = await this._pool.query(
        `DELETE FROM ${this._qualifiedNotificationsTableName}
          WHERE created_at <> '' AND ${whereSql}
          RETURNING id`,
        params,
      );
      counts[key] += deleted.rows.length;
    };
    const notifSilentMs =
      Math.max(0, Number(logRetention.notifSilentHours ?? 48)) * HOUR;
    const notifReadMs =
      Math.max(0, Number(logRetention.notifReadDays ?? 30)) * DAY;
    const notifUnreadMs =
      Math.max(0, Number(logRetention.notifUnreadDays ?? 365)) * DAY;
    if (notifSilentMs > 0) {
      await sweepNotifications(
        `silent = 1 AND created_at < $1`,
        [cutoffIso(notifSilentMs)],
        "notificationsSilent",
      );
    }
    if (notifReadMs > 0) {
      await sweepNotifications(
        `silent = 0 AND read_at <> '' AND created_at < $1`,
        [cutoffIso(notifReadMs)],
        "notificationsRead",
      );
    }
    if (notifUnreadMs > 0) {
      await sweepNotifications(
        `silent = 0 AND read_at = '' AND created_at < $1`,
        [cutoffIso(notifUnreadMs)],
        "notificationsUnread",
      );
    }

    const deliveriesDays = Number(logRetention.pushDeliveriesDays ?? 7);
    const deliveriesTtlMs = Math.max(0, deliveriesDays) * DAY;
    if (deliveriesTtlMs > 0) {
      if (dryRun) {
        const counted = await this._pool.query(
          `SELECT COUNT(*)::int AS total
             FROM ${this._qualifiedPushDeliveriesTableName}
            WHERE created_at <> '' AND created_at < $1`,
          [cutoffIso(deliveriesTtlMs)],
        );
        counts.pushDeliveries += Number(counted.rows[0]?.total || 0);
      } else {
        const deleted = await this._pool.query(
          `DELETE FROM ${this._qualifiedPushDeliveriesTableName}
            WHERE created_at <> '' AND created_at < $1
            RETURNING id`,
          [cutoffIso(deliveriesTtlMs)],
        );
        counts.pushDeliveries += deleted.rows.length;
      }
    }
    const rawCap = Number(logRetention.pushDeliveriesMax ?? 2000);
    const deliveriesCap =
      Number.isFinite(rawCap) && rawCap > 0 ? Math.floor(rawCap) : null;
    if (deliveriesCap !== null) {
      const counted = await this._pool.query(
        `SELECT COUNT(*)::int AS total
           FROM ${this._qualifiedPushDeliveriesTableName}`,
      );
      const overflow = Number(counted.rows[0]?.total || 0) - deliveriesCap;
      if (overflow > 0) {
        if (dryRun) {
          counts.pushDeliveries += overflow;
        } else {
          const oldest = await this._pool.query(
            `SELECT id
               FROM ${this._qualifiedPushDeliveriesTableName}
              ORDER BY created_at ASC, id ASC
              LIMIT $1`,
            [overflow],
          );
          for (const row of oldest.rows) {
            await this._pool.query(
              `DELETE FROM ${this._qualifiedPushDeliveriesTableName} WHERE id = $1`,
              [String(row.id)],
            );
            counts.pushDeliveries += 1;
          }
        }
      }
    }

    if (summary && summary.logRetention) {
      summary.logRetention.notificationsSilent =
        Number(summary.logRetention.notificationsSilent || 0) +
        counts.notificationsSilent;
      summary.logRetention.notificationsRead =
        Number(summary.logRetention.notificationsRead || 0) +
        counts.notificationsRead;
      summary.logRetention.notificationsUnread =
        Number(summary.logRetention.notificationsUnread || 0) +
        counts.notificationsUnread;
      summary.logRetention.pushDeliveries =
        Number(summary.logRetention.pushDeliveries || 0) +
        counts.pushDeliveries;
    }
    return summary;
  }

  async findActiveCall({userId, chatId = null} = {}) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedChatId = String(chatId || "").trim();
    if (!normalizedUserId) {
      return null;
    }
    await this.initialize();
    await this._awaitReadConsistency();
    try {
      const result = await this._pool.query(
        `SELECT call_entry AS call_data
           FROM ${this._qualifiedTableName},
                LATERAL jsonb_array_elements(COALESCE(data->'calls', '[]'::jsonb)) AS call_entry
          WHERE id = $1
            AND COALESCE(call_entry->>'state', '') IN ('active', 'ringing')
            AND (
              $3 = ''
              OR COALESCE(call_entry->>'chatId', '') = $3
            )
            AND EXISTS (
              SELECT 1
                FROM jsonb_array_elements_text(COALESCE(call_entry->'participantIds', '[]'::jsonb)) AS participant_id(value)
               WHERE participant_id.value = $2
            )
          ORDER BY
            CASE COALESCE(call_entry->>'state', '')
              WHEN 'active' THEN 0
              WHEN 'ringing' THEN 1
              ELSE 99
            END,
            COALESCE(call_entry->>'updatedAt', '') DESC
          LIMIT 1`,
        [this._rowId, normalizedUserId, normalizedChatId],
      );
      const call = normalizeStoredCall(result.rows[0]?.call_data ?? null);
      return call ? structuredClone(call) : null;
    } catch (error) {
      if (!isProjectionArrayTextFallbackError(error)) {
        throw error;
      }
      return super.findActiveCall({userId: normalizedUserId, chatId: normalizedChatId});
    }
  }

  async listUserTrees(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }

    await this.initialize();
    await this._awaitReadConsistency();
    try {
      const result = await this._pool.query(
        `SELECT tree_entry AS tree_data
           FROM ${this._qualifiedTableName},
                LATERAL jsonb_array_elements(COALESCE(data->'trees', '[]'::jsonb)) AS tree_entry
          WHERE id = $1
            AND (
              COALESCE(tree_entry->>'creatorId', '') = $2
              OR EXISTS (
                SELECT 1
                  FROM jsonb_array_elements_text(COALESCE(tree_entry->'memberIds', '[]'::jsonb)) AS member_id(value)
                 WHERE member_id.value = $2
              )
            )
          ORDER BY COALESCE(tree_entry->>'updatedAt', '') DESC`,
        [this._rowId, normalizedUserId],
      );
      return result.rows
        .map((row) => row.tree_data)
        .filter(Boolean)
        .map((tree) => structuredClone(tree));
    } catch (error) {
      if (!isProjectionArrayTextFallbackError(error)) {
        throw error;
      }
      return super.listUserTrees(normalizedUserId);
    }
  }

  async findTree(treeId) {
    const normalizedTreeId = String(treeId || "").trim();
    if (!normalizedTreeId) {
      return null;
    }

    await this.initialize();
    await this._awaitReadConsistency();
    const result = await this._pool.query(
      `SELECT tree_entry AS tree_data
         FROM ${this._qualifiedTableName},
              LATERAL jsonb_array_elements(COALESCE(data->'trees', '[]'::jsonb)) AS tree_entry
        WHERE id = $1
          AND COALESCE(tree_entry->>'id', '') = $2
        LIMIT 1`,
      [this._rowId, normalizedTreeId],
    );
    const tree = result.rows[0]?.tree_data ?? null;
    return tree ? structuredClone(tree) : null;
  }

  async _read() {
    await this.initialize();
    await this._hydrateCachedStateFromSnapshotCache();

    try {
      await this._awaitReadConsistency();
      const normalizedState = await this._loadSnapshot();
      normalizedState.sessions = await this._selectProjectedSessionsArray();
      this._lastUsersProjectionHash = computeProjectionHash(normalizedState.users);
      this._lastSessionsProjectionHash = computeProjectionHash(normalizedState.sessions);
      // ВАЖНО: _lastChatsProjectionHash здесь НЕ трогаем — _read утверждал
      // бы синхронность projection, не наблюдая её; после сорванного
      // _replaceChatProjection это маскировало бы починку на след. _write.
      // Phase 3.1c: keep the unified-graph mirror eventually
      // consistent with the legacy collections. The base FileStore
      // calls this in its own _read; PostgresStore overrides _read
      // entirely, so we have to mirror the call here or the graph
      // never gets populated on the prod backend (which is exactly
      // what was happening — Phase 4 BFS saw 0 graphRelations on
      // prod even though backend was deployed). Idempotent — no-op
      // when the graph already matches the legacy side.
      this._syncGraphFromLegacy(normalizedState);
      this._cachedState = structuredClone(normalizedState);
      await this._persistSnapshotCache(this._cachedState);
      return normalizedState;
    } catch (error) {
      return this._serveCachedSnapshotFallback(error, {phase: "read"});
    }
  }

  async _write(data) {
    // Phase 3.1c: mirror legacy → graph on the OUT-bound side too,
    // so the persisted snapshot already has the graph rows that
    // mirror whatever legacy mutation the caller just made. Safe
    // to call before _enqueueWrite — sync is idempotent and doesn't
    // touch I/O. (FileStore._write does the same; PostgresStore
    // overrides _write entirely so we have to mirror the call here.)
    if (data && typeof data === "object") {
      this._syncGraphFromLegacy(data);
    }
    return this._enqueueWrite("_stateWriteQueue", async () => {
      await this.initialize();
      // store-race guard: read the freshest persisted calls inside this
      // serialized write link and keep any terminal call terminal, so a write
      // built on a stale pre-teardown snapshot can't resurrect an ended call
      // (inherited FileStore._preserveTerminalCalls; same invariant as file).
      try {
        const currentResult = await this._pool.query(
          `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`,
          [this._rowId],
        );
        const currentData = currentResult.rows?.[0]?.data;
        const parsedCurrent =
          typeof currentData === "string"
            ? JSON.parse(currentData)
            : currentData;
        this._preserveTerminalCalls(data, parsedCurrent?.calls);
      } catch (_) {
        // First write / row absent — nothing persisted to preserve.
      }
      data = await this._drainTransientNotificationCollections(data);
      const nextUsersHash = computeProjectionHash(data?.users);
      const nextSessionsHash = computeProjectionHash(data?.sessions);
      const nextChatsHash = computeProjectionHash(data?.chats);
      await this._pool.query(
        `
          INSERT INTO ${this._qualifiedTableName} (id, data, updated_at)
          VALUES ($1, $2::jsonb, NOW())
          ON CONFLICT (id) DO UPDATE
          SET data = EXCLUDED.data,
              updated_at = NOW()
        `,
        [this._rowId, JSON.stringify(data)],
      );
      if (this._lastUsersProjectionHash !== nextUsersHash) {
        await this._replaceProjectedUsers(data.users);
      } else {
        this._lastUsersProjectionHash = nextUsersHash;
      }
      if (this._lastSessionsProjectionHash !== nextSessionsHash) {
        await this._replaceProjectedSessions(data.sessions);
      } else {
        this._lastSessionsProjectionHash = nextSessionsHash;
      }
      if (this._lastChatsProjectionHash !== nextChatsHash) {
        await this._replaceChatProjection(data?.chats);
      } else {
        this._lastChatsProjectionHash = nextChatsHash;
      }
      this._cachedState = normalizeDbState(data);
      await this._persistSnapshotCache(this._cachedState);
    });
  }

  async _loadSnapshot() {
    if (this._snapshotLoadPromise) {
      return this._snapshotLoadPromise;
    }

    this._snapshotLoadPromise = this._readSnapshotWithRetry()
      .then((snapshot) => normalizeDbState(snapshot))
      .finally(() => {
        this._snapshotLoadPromise = null;
      });

    return this._snapshotLoadPromise;
  }

  async _readSnapshotWithRetry() {
    let lastError = null;
    const attempts = Math.max(1, this._readRetryCount + 1);
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      try {
        return await this._readSnapshotFromDatabase();
      } catch (error) {
        lastError = error;
        if (!this._isRetriableReadError(error) || attempt >= attempts - 1) {
          break;
        }
        if (this._readRetryDelayMs > 0) {
          await new Promise((resolve) => setTimeout(resolve, this._readRetryDelayMs));
        }
      }
    }
    throw lastError;
  }

  async _readSnapshotFromDatabase() {
    const queryText = `SELECT data FROM ${this._qualifiedTableName} WHERE id = $1`;
    const queryValues = [this._rowId];

    if (typeof this._pool.connect !== "function") {
      const result = await this._pool.query(queryText, queryValues);
      return result.rows[0]?.data ?? EMPTY_DB;
    }

    const client = await this._pool.connect();
    try {
      if (this._readQueryTimeoutMs > 0) {
        await client.query("BEGIN");
        await client.query(
          `SET LOCAL statement_timeout = ${this._readQueryTimeoutMs}`,
        );
      }
      const result = await client.query({
        text: queryText,
        values: queryValues,
        query_timeout: this._readQueryTimeoutMs > 0
          ? this._readQueryTimeoutMs
          : undefined,
      });
      if (this._readQueryTimeoutMs > 0) {
        await client.query("COMMIT");
      }
      return result.rows[0]?.data ?? EMPTY_DB;
    } catch (error) {
      if (this._readQueryTimeoutMs > 0) {
        try {
          await client.query("ROLLBACK");
        } catch (_) {
          // Ignore rollback failures after read timeout.
        }
      }
      throw error;
    } finally {
      client.release();
    }
  }

  _isRetriableReadError(error) {
    const message = String(error?.message || "").toLowerCase();
    const code = String(error?.code || "").trim().toUpperCase();
    return (
      code === "POSTGRES_WRITE_QUEUE_TIMEOUT" ||
      message.includes("query read timeout") ||
      message.includes("statement timeout") ||
      message.includes("write queue timed out") ||
      message.includes("connection timeout") ||
      code === "57014" ||
      code === "ETIMEDOUT"
    );
  }

  _serveCachedSnapshotFallback(error, {phase} = {}) {
    if (!this._cachedState || !this._isRetriableReadError(error)) {
      throw error;
    }

    console.warn(
      "[backend] postgres-store serving cached snapshot",
      JSON.stringify({
        table: `${this._schema}.${this._table}`,
        rowId: this._rowId,
        phase: String(phase || "read"),
        message: String(error?.message || error || "unknown_error"),
      }),
    );
    return structuredClone(this._cachedState);
  }

  async _hydrateCachedStateFromSnapshotCache() {
    if (this._cachedState || !this._snapshotCachePath) {
      return;
    }
    if (!this._snapshotCacheHydrationPromise) {
      this._snapshotCacheHydrationPromise = fs.readFile(
        this._snapshotCachePath,
        "utf8",
      )
        .then((rawSnapshot) => {
          const parsedSnapshot = JSON.parse(rawSnapshot);
          this._cachedState = normalizeDbState(parsedSnapshot);
        })
        .catch((error) => {
          if (error?.code === "ENOENT") {
            return;
          }
          console.warn(
            "[backend] postgres-store snapshot cache hydrate failed",
            JSON.stringify({
              table: `${this._schema}.${this._table}`,
              rowId: this._rowId,
              path: this._snapshotCachePath,
              message: String(error?.message || error || "unknown_error"),
            }),
          );
        })
        .finally(() => {
          this._snapshotCacheHydrationPromise = null;
        });
    }
    await this._snapshotCacheHydrationPromise;
  }

  async _persistSnapshotCache(snapshot) {
    if (!this._snapshotCachePath || !snapshot) {
      return;
    }
    try {
      await fs.mkdir(path.dirname(this._snapshotCachePath), {recursive: true});
      await fs.writeFile(
        this._snapshotCachePath,
        JSON.stringify(snapshot),
        "utf8",
      );
    } catch (error) {
      console.warn(
        "[backend] postgres-store snapshot cache persist failed",
        JSON.stringify({
          table: `${this._schema}.${this._table}`,
          rowId: this._rowId,
          path: this._snapshotCachePath,
          message: String(error?.message || error || "unknown_error"),
        }),
      );
    }
  }

  async _awaitWriteQueue(queuePromise = this._stateWriteQueue) {
    const pendingWrite = queuePromise.catch(() => {});
    if (this._writeQueueTimeoutMs <= 0) {
      await pendingWrite;
      return;
    }

    let timer = null;
    try {
      await Promise.race([
        pendingWrite,
        new Promise((_, reject) => {
          timer = setTimeout(() => {
            const error = new Error("Postgres write queue timed out");
            error.code = "POSTGRES_WRITE_QUEUE_TIMEOUT";
            reject(error);
          }, this._writeQueueTimeoutMs);
          if (typeof timer?.unref === "function") {
            timer.unref();
          }
        }),
      ]);
    } finally {
      if (timer) {
        clearTimeout(timer);
      }
    }
  }

  async close() {
    await Promise.allSettled([this._stateWriteQueue, this._sessionWriteQueue]);
    if (this._poolRelease) {
      await this._poolRelease();
      this._poolRelease = null;
      return;
    }
    if (this._ownsPool) {
      await this._pool.end();
    }
  }
}

module.exports = {
  PostgresStore,
};
