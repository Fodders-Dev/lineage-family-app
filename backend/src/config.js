const path = require("node:path");

function createConfig() {
  return {
    port: Number(process.env.PORT || 8080),
    corsOrigin: process.env.LINEAGE_BACKEND_CORS_ORIGIN || "*",
    dataPath:
      process.env.LINEAGE_BACKEND_DATA_PATH ||
      path.join(__dirname, "..", "data", "dev-db.json"),
    mediaRootPath:
      process.env.LINEAGE_BACKEND_MEDIA_ROOT ||
      path.join(__dirname, "..", "data", "uploads"),
  };
}

module.exports = {
  createConfig,
};
