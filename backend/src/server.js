const {createConfig} = require("./config");
const {FileStore} = require("./store");
const {createApp} = require("./app");
const {RealtimeHub} = require("./realtime-hub");
const {PushGateway} = require("./push-gateway");

async function startServer() {
  const config = createConfig();
  const store = new FileStore(config.dataPath);
  await store.initialize();

  const realtimeHub = new RealtimeHub({store});
  const pushGateway = new PushGateway({store, config});
  const app = createApp({store, config, realtimeHub, pushGateway});
  const server = app.listen(config.port, "127.0.0.1", () => {
    console.log(
      `[lineage-backend] listening on http://127.0.0.1:${config.port}`,
    );
    console.log(`[lineage-backend] data path: ${config.dataPath}`);
  });
  realtimeHub.attach(server);

  return {app, server, store, config, realtimeHub, pushGateway};
}

if (require.main === module) {
  startServer().catch((error) => {
    console.error("[lineage-backend] failed to start", error);
    process.exitCode = 1;
  });
}

module.exports = {
  startServer,
};
