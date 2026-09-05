const {FileStore} = require("./store");
const {PostgresStore} = require("./postgres-store");

// SPEED-9: прогрев read-кэша (SPEED-8a) сразу после boot — иначе первый
// реальный HTTP-запрос после деплоя/рестарта первым платит cache-miss
// `_read()` (SELECT блоба + parse + _syncGraphFromLegacy + structuredClone +
// sidecar-запись, ~350мс на проде — см. docs/speed_measurement.md SPEED-8a).
// Поведенчески нейтрально: тот же _read() всё равно случился бы на первом
// запросе, просто выполняется раньше, до старта приёма трафика. Ошибка
// прогрева не должна ронять старт — следующий _read() честно перечитает БД.
async function warmPostgresReadCache(store) {
  try {
    await store._read();
  } catch (error) {
    console.warn(
      "[backend] postgres-store cache warm-up read failed",
      error?.message || String(error),
    );
  }
}

async function createStore(config) {
  const storageBackend = String(config?.storageBackend || "file")
    .trim()
    .toLowerCase();

  switch (storageBackend) {
    case "file":
    case "file-store": {
      const store = new FileStore(config.dataPath);
      await store.initialize();
      store.storageMode = "file-store";
      store.storageTarget = config.dataPath;
      return store;
    }
    case "postgres":
    case "postgresql": {
      const store = new PostgresStore({
        connectionString: config.postgresUrl,
        schema: config.postgresSchema,
        table: config.postgresStateTable,
        rowId: config.postgresStateRowId,
        poolMax: config.postgresPoolMax,
        snapshotCachePath: config.postgresSnapshotCachePath,
        pool: config.postgresPool || config._pool || null,
        applicationName: config.postgresApplicationName,
      });
      await store.initialize();
      await warmPostgresReadCache(store);
      return store;
    }
    default:
      throw new Error(
        `Unsupported RODNYA_BACKEND_STORAGE value: ${storageBackend}`,
      );
  }
}

module.exports = {
  createStore,
  warmPostgresReadCache,
};
