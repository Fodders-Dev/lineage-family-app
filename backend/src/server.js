const fs = require("node:fs/promises");
const path = require("node:path");

const {createConfig} = require("./config");
const {createStore} = require("./store-factory");
const {createMediaStorage} = require("./media-storage");
const {createApp} = require("./app");
const {RealtimeHub} = require("./realtime-hub");
const {PushGateway} = require("./push-gateway");
const {scheduleHardDeleteJob} = require("./jobs/hard-delete-job");

async function readReleaseLabel() {
  try {
    const rawValue = await fs.readFile(
      path.join(__dirname, "..", ".last_release_id"),
      "utf8",
    );
    const normalizedValue = String(rawValue || "").trim();
    return normalizedValue || null;
  } catch (_) {
    return null;
  }
}

async function startServer() {
  const config = createConfig();
  const store = await createStore(config);
  const mediaStorage = createMediaStorage(config);
  const runtimeErrors = [];
  const captureRuntimeError = (source, error, metadata = {}) => {
    const entry = {
      timestamp: new Date().toISOString(),
      source: String(source || "runtime"),
      message: String(error?.message || error || "unknown_error"),
      stack: error?.stack ? String(error.stack) : null,
      metadata:
        metadata && typeof metadata === "object" ? {...metadata} : {},
    };
    runtimeErrors.unshift(entry);
    if (runtimeErrors.length > 20) {
      runtimeErrors.length = 20;
    }
    console.error("[rodnya-backend] runtime-error", JSON.stringify(entry));
  };
  const runtimeInfo = {
    startedAt: new Date().toISOString(),
    releaseLabel: await readReleaseLabel(),
    pid: process.pid,
    nodeVersion: process.version,
    captureError: captureRuntimeError,
    listRecentErrors: () => runtimeErrors.map((entry) => ({...entry})),
  };

  process.on("uncaughtExceptionMonitor", (error, origin) => {
    captureRuntimeError("uncaughtException", error, {
      origin: String(origin || "unknown"),
    });
  });
  process.on("unhandledRejection", (reason) => {
    captureRuntimeError("unhandledRejection", reason);
  });

  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store, config});
  const app = createApp({
    store,
    config,
    realtimeHub,
    pushGateway,
    mediaStorage,
    runtimeInfo,
  });
  const server = app.listen(config.port, "127.0.0.1", () => {
    console.log(
      `[rodnya-backend] listening on http://127.0.0.1:${config.port}`,
    );
    console.log(`[rodnya-backend] data path: ${config.dataPath}`);
    console.log(`[rodnya-backend] media root: ${config.mediaRootPath}`);
    console.log(
      `[rodnya-backend] storage mode: ${store.storageMode || config.storageBackend || "unknown"}`,
    );
    console.log(
      `[rodnya-backend] media mode: ${mediaStorage.mediaMode || config.mediaBackend || "unknown"}`,
    );
    if (runtimeInfo.releaseLabel) {
      console.log(`[rodnya-backend] release: ${runtimeInfo.releaseLabel}`);
    }
  });

  // Дефолтный Node requestTimeout (300с) — абсолютный дедлайн с начала
  // запроса: 64-МБ видео на аплинке ~1 Мбит/с физически не успевает, и
  // клиент получает голый ECONNRESET вместо ответа (ревью бинарной
  // загрузки, P1). 15 минут хватает на потолок 64 МБ при ~0.6 Мбит/с;
  // от slow-loris защищает headersTimeout (дефолт 60с) + rate-limit.
  server.requestTimeout = 15 * 60 * 1000;

  realtimeHub.attach(server);

  // Phase 3.6 hard-delete background job. Master toggle (env var
  // RODNYA_HARD_DELETE_ENABLED) defaults `false` — scheduler skips
  // registration + logs «disabled» chunk. Flip flag → restart → 60s
  // первый dry run (per DECISIONS.md 2026-05-18 rollout sequence).
  const hardDeleteJob = scheduleHardDeleteJob({store, config, runtimeInfo});

  return {
    app,
    server,
    store,
    config,
    realtimeHub,
    pushGateway,
    mediaStorage,
    runtimeInfo,
    hardDeleteJob,
  };
}

if (require.main === module) {
  startServer().catch((error) => {
    console.error("[rodnya-backend] failed to start", error);
    process.exitCode = 1;
  });
}

module.exports = {
  startServer,
};
