function handleMediaReadError(error, res) {
  if (
    error?.message === "INVALID_MEDIA_PATH" ||
    error?.message === "UNSUPPORTED_MEDIA_URL"
  ) {
    res.status(400).json({message: "Недопустимый media path"});
    return;
  }
  if (error?.message === "MEDIA_FILE_NOT_FOUND") {
    res.status(404).json({message: "Media файл не найден"});
    return;
  }
  if (!res.headersSent) {
    res.status(502).json({message: "Не удалось открыть media файл"});
  }
}

function registerPublicMediaRoutes(app, {mediaStorage}) {
  app.get(/^\/media\/(.+)$/, async (req, res) => {
    try {
      // Proxy public objects through the API when public base URL points back to
      // /media. This avoids circular redirects and keeps legacy media URLs valid.
      const handler = mediaStorage.handlePublicGetRequest
        ? mediaStorage.handlePublicGetRequest.bind(mediaStorage)
        : mediaStorage.handleGetRequest.bind(mediaStorage);
      await handler(req, res);
    } catch (error) {
      handleMediaReadError(error, res);
    }
  });

  app.get(/^\/storage\/(.+)$/, async (req, res) => {
    try {
      await mediaStorage.handlePublicGetRequest(req, res);
    } catch (error) {
      handleMediaReadError(error, res);
    }
  });
}

// Бинарная загрузка: тело запроса = сами байты файла, без base64-обёртки.
// Экономит +33% трафика и двойную память (JSON-строка + Buffer) на КАЖДОМ
// фото/видео и снимает потолок express.json(50mb) с видео. Метаданные — в
// query (bucket/path) и Content-Type. Старый POST /v1/media/upload с
// fileBase64 остаётся: его шлют клиенты до этого OTA.
const MAX_BINARY_UPLOAD_BYTES = 64 * 1024 * 1024;

function registerAuthenticatedMediaRoutes(app, {mediaStorage, requireAuth}) {
  app.put("/v1/media/object", requireAuth, async (req, res) => {
    const bucket = String(req.query?.bucket || "").trim();
    const mediaPath = String(req.query?.path || "").trim();
    if (!bucket || !mediaPath) {
      res.status(400).json({message: "Нужны query-параметры bucket и path"});
      return;
    }
    const contentType =
      String(req.headers["content-type"] || "").trim() || null;

    const chunks = [];
    let total = 0;
    try {
      for await (const chunk of req) {
        total += chunk.length;
        if (total > MAX_BINARY_UPLOAD_BYTES) {
          res.status(413).json({message: "Файл больше 64 МБ"});
          // Хвост потока не читаем — соединение закрываем, иначе клиент
          // продолжит заливать байты в никуда.
          req.destroy();
          return;
        }
        chunks.push(chunk);
      }
    } catch (error) {
      // Клиент оборвал соединение посреди загрузки — отвечать некому.
      if (!res.headersSent) {
        res.status(400).json({message: "Загрузка прервана"});
      }
      return;
    }
    if (total === 0) {
      res.status(400).json({message: "Пустое тело запроса"});
      return;
    }

    try {
      const uploadResult = await mediaStorage.saveObject({
        req,
        bucket,
        relativePath: mediaPath,
        contentType,
        fileBuffer: Buffer.concat(chunks),
      });
      res.status(201).json(uploadResult);
    } catch (error) {
      if (error.message === "INVALID_MEDIA_PATH") {
        res.status(400).json({message: "Недопустимый media path"});
        return;
      }
      res.status(500).json({message: "Не удалось сохранить файл"});
    }
  });

  app.post("/v1/media/upload", requireAuth, async (req, res) => {
    const {bucket, path: mediaPath, fileBase64, contentType} = req.body || {};

    if (!bucket || !mediaPath || !fileBase64) {
      res.status(400).json({
        message: "Нужны bucket, path и fileBase64",
      });
      return;
    }

    try {
      const fileBuffer = Buffer.from(String(fileBase64), "base64");
      if (fileBuffer.length === 0) {
        res.status(400).json({message: "Пустой fileBase64 payload"});
        return;
      }

      const uploadResult = await mediaStorage.saveObject({
        req,
        bucket,
        relativePath: mediaPath,
        contentType,
        fileBuffer,
      });

      res.status(201).json(uploadResult);
    } catch (error) {
      if (error.message === "INVALID_MEDIA_PATH") {
        res.status(400).json({message: "Недопустимый media path"});
        return;
      }
      res.status(500).json({message: "Не удалось сохранить файл"});
    }
  });

  app.delete("/v1/media", requireAuth, async (req, res) => {
    const urlValue = String(req.body?.url || "").trim();
    if (!urlValue) {
      res.status(400).json({message: "Нужен url"});
      return;
    }

    try {
      await mediaStorage.deleteObjectByUrl(urlValue);
      res.status(204).send();
    } catch (error) {
      if (
        error.message === "INVALID_MEDIA_PATH" ||
        error.message === "UNSUPPORTED_MEDIA_URL" ||
        error instanceof TypeError
      ) {
        res.status(400).json({message: "Недопустимый media URL"});
        return;
      }
      res.status(500).json({message: "Не удалось удалить файл"});
    }
  });
}

module.exports = {
  registerAuthenticatedMediaRoutes,
  registerPublicMediaRoutes,
};
