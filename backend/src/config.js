const path = require("node:path");

function createConfig() {
  const webPushPublicKey = String(
    process.env.LINEAGE_WEB_PUSH_PUBLIC_KEY || "",
  ).trim();
  const webPushPrivateKey = String(
    process.env.LINEAGE_WEB_PUSH_PRIVATE_KEY || "",
  ).trim();
  const webPushSubject = String(
    process.env.LINEAGE_WEB_PUSH_SUBJECT || "https://rodnya-tree.ru",
  ).trim();
  const rustorePushProjectId = String(
    process.env.LINEAGE_RUSTORE_PUSH_PROJECT_ID || "",
  ).trim();
  const rustorePushServiceToken = String(
    process.env.LINEAGE_RUSTORE_PUSH_SERVICE_TOKEN || "",
  ).trim();
  const rustorePushApiBaseUrl = String(
    process.env.LINEAGE_RUSTORE_PUSH_API_BASE_URL ||
      "https://vkpns.rustore.ru",
  ).trim();

  return {
    port: Number(process.env.PORT || 8080),
    corsOrigin: process.env.LINEAGE_BACKEND_CORS_ORIGIN || "*",
    dataPath:
      process.env.LINEAGE_BACKEND_DATA_PATH ||
      path.join(__dirname, "..", "data", "dev-db.json"),
    mediaRootPath:
      process.env.LINEAGE_BACKEND_MEDIA_ROOT ||
      path.join(__dirname, "..", "data", "uploads"),
    publicApiUrl:
      process.env.LINEAGE_PUBLIC_API_URL || "",
    publicAppUrl:
      process.env.LINEAGE_PUBLIC_APP_URL || "https://rodnya-tree.ru",
    webPushPublicKey,
    webPushPrivateKey,
    webPushSubject,
    webPushEnabled: Boolean(webPushPublicKey && webPushPrivateKey),
    rustorePushProjectId,
    rustorePushServiceToken,
    rustorePushApiBaseUrl,
    rustorePushEnabled: Boolean(
      rustorePushProjectId && rustorePushServiceToken,
    ),
  };
}

module.exports = {
  createConfig,
};
