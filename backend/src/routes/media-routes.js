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

// До этого объёма хвост недочитанного тела дренируется, чтобы ошибка
// (413/400) ДОЕХАЛА до клиента: HTTP/1.1-клиенты читают ответ только
// дольют тело, а req.destroy() до дочитки превращает честный статус в
// голый ECONNRESET (ревью: живая репродукция). Выше — рвём соединение:
// вежливость не стоит гигабайтов дочитки (Node на ранних ответах иначе
// молча дочитывает ВСЁ заявленное тело).
const MAX_ERROR_DRAIN_BYTES = 96 * 1024 * 1024;

/// Ответить ошибкой на незавершённом теле так, чтобы статус реально дошёл.
function respondAndDispose(req, res, statusCode, message) {
  res.status(statusCode).json({message});
  const declared = Number(req.headers["content-length"]);
  const drainable =
    Number.isFinite(declared) && declared <= MAX_ERROR_DRAIN_BYTES;
  if (drainable) {
    // Дочитать-и-выбросить остаток: соединение закрывается штатно.
    req.resume();
  } else {
    // Chunked без Content-Length или заведомо гигантское тело — рвём
    // после того, как ответ ушёл в сокет.
    res.on("finish", () => req.destroy());
  }
}

function registerAuthenticatedMediaRoutes(app, {mediaStorage, requireAuth}) {
  app.put("/v1/media/object", requireAuth, async (req, res) => {
    const bucket = String(req.query?.bucket || "").trim();
    const mediaPath = String(req.query?.path || "").trim();
    if (!bucket || !mediaPath) {
      respondAndDispose(
        req,
        res,
        400,
        "Нужны query-параметры bucket и path",
      );
      return;
    }
    const contentType =
      String(req.headers["content-type"] || "").trim() || null;

    // Заявленный размер больше потолка — отказ сразу, без чтения тела.
    const declaredLength = Number(req.headers["content-length"]);
    if (
      Number.isFinite(declaredLength) &&
      declaredLength > MAX_BINARY_UPLOAD_BYTES
    ) {
      respondAndDispose(req, res, 413, "Файл больше 64 МБ");
      return;
    }

    const chunks = [];
    let total = 0;
    try {
      for await (const chunk of req) {
        total += chunk.length;
        if (total > MAX_BINARY_UPLOAD_BYTES) {
          // Chunked-поток или врущий Content-Length.
          respondAndDispose(req, res, 413, "Файл больше 64 МБ");
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
      // Пути у клиентов уникальны (uuid/timestamp), перезапись существующего
      // объекта легитимному клиенту не нужна — а вот участник с чужим
      // публичным URL мог бы подменить чужое фото. Отказ до записи.
      if (
        typeof mediaStorage.objectExists === "function" &&
        (await mediaStorage.objectExists(bucket, mediaPath))
      ) {
        res.status(409).json({message: "Файл уже существует"});
        return;
      }
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

      // Sunset-телеметрия: по этому логу видно, когда волна OTA дообновит
      // клиентов (1.0.29+ шлют бинарный PUT) и легаси-путь можно закрывать.
      console.log(
        "[legacy-media-upload]",
        JSON.stringify({
          userId: req.auth?.user?.id || null,
          bucket: String(bucket),
          bytes: fileBuffer.length,
        }),
      );
      // Тот же гейт от перезаписи чужого файла, что у бинарного пути:
      // пути легитимных клиентов уникальны (uuid/timestamp), повтор
      // имени = чья-то попытка подменить файл по известному URL.
      if (
        typeof mediaStorage.objectExists === "function" &&
        (await mediaStorage.objectExists(bucket, mediaPath))
      ) {
        res.status(409).json({message: "Файл уже существует"});
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
