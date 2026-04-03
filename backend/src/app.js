const express = require("express");
const cors = require("cors");
const fs = require("node:fs/promises");
const path = require("node:path");

const {
  computeProfileStatus,
  composeDisplayName,
  sanitizeProfile,
} = require("./profile-utils");
const {PushGateway} = require("./push-gateway");

function createApp({store, config, realtimeHub = null, pushGateway = null}) {
  const app = express();
  const resolvedPushGateway =
    pushGateway ?? new PushGateway({store, config});

  app.use(cors({origin: config.corsOrigin}));
  app.use(express.json({limit: "10mb"}));
  app.use("/media", express.static(config.mediaRootPath));

  app.get("/health", async (req, res) => {
    res.json({
      status: "ok",
      service: "lineage-minimal-backend",
    });
  });

  async function requirePublicTree(req, res, publicTreeId) {
    const tree = await store.findPublicTreeByRouteId(publicTreeId);
    if (!tree) {
      res.status(404).json({message: "Публичное дерево не найдено"});
      return null;
    }
    return tree;
  }

  async function requireAuth(req, res, next) {
    const header = req.headers.authorization || "";
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";

    if (!token) {
      res.status(401).json({message: "Требуется Bearer token"});
      return;
    }

    const session = await store.findSession(token);
    if (!session) {
      res.status(401).json({message: "Сессия не найдена или истекла"});
      return;
    }

    const user = await store.findUserById(session.userId);
    if (!user) {
      res.status(401).json({message: "Пользователь сессии не найден"});
      return;
    }

    await store.touchSession(token);
    req.auth = {token, session, user};
    next();
  }

  function requireOwnUser(req, res) {
    if (req.params.userId !== req.auth.user.id) {
      res.status(403).json({message: "Доступ к чужим данным запрещен"});
      return false;
    }
    return true;
  }

  function sanitizeRelativePath(inputValue) {
    const rawValue = String(inputValue || "").trim().replace(/\\/g, "/");
    const normalized = path.posix.normalize(`/${rawValue}`).replace(/^\/+/, "");

    if (!normalized || normalized === "." || normalized.startsWith("..")) {
      throw new Error("INVALID_MEDIA_PATH");
    }

    return normalized;
  }

  function resolveMediaFilePath(bucket, relativePath) {
    const safeBucket = sanitizeRelativePath(bucket);
    const safeRelativePath = sanitizeRelativePath(relativePath);
    const rootPath = path.resolve(config.mediaRootPath);
    const resolvedPath = path.resolve(rootPath, safeBucket, safeRelativePath);

    if (
      resolvedPath !== rootPath &&
      !resolvedPath.startsWith(`${rootPath}${path.sep}`)
    ) {
      throw new Error("INVALID_MEDIA_PATH");
    }

    return {
      safeBucket,
      safeRelativePath,
      resolvedPath,
    };
  }

  function buildMediaUrl(req, bucket, relativePath) {
    const encodedPath = [bucket, ...relativePath.split("/").filter(Boolean)]
      .map((segment) => encodeURIComponent(segment))
      .join("/");

    return `${req.protocol}://${req.get("host")}/media/${encodedPath}`;
  }

  function mapProfileNote(note) {
    return {
      id: note.id,
      title: note.title,
      content: note.content,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
    };
  }

  function mapTree(tree) {
    return {
      id: tree.id,
      name: tree.name,
      description: tree.description,
      creatorId: tree.creatorId,
      memberIds: Array.isArray(tree.memberIds) ? tree.memberIds : [],
      members: Array.isArray(tree.members) ? tree.members : [],
      createdAt: tree.createdAt,
      updatedAt: tree.updatedAt,
      isPrivate: tree.isPrivate !== false,
      publicSlug: tree.publicSlug || null,
      isCertified: tree.isCertified === true,
      certificationNote: tree.certificationNote || null,
    };
  }

  function mapPerson(person) {
    return {
      id: person.id,
      treeId: person.treeId,
      userId: person.userId,
      name: person.name,
      maidenName: person.maidenName,
      photoUrl: person.photoUrl,
      gender: person.gender,
      birthDate: person.birthDate,
      birthPlace: person.birthPlace,
      deathDate: person.deathDate,
      deathPlace: person.deathPlace,
      bio: person.bio,
      isAlive: person.isAlive !== false,
      creatorId: person.creatorId,
      createdAt: person.createdAt,
      updatedAt: person.updatedAt,
      notes: person.notes,
    };
  }

  function mapRelation(relation) {
    return {
      id: relation.id,
      treeId: relation.treeId,
      person1Id: relation.person1Id,
      person2Id: relation.person2Id,
      relation1to2: relation.relation1to2,
      relation2to1: relation.relation2to1,
      isConfirmed: relation.isConfirmed === true,
      createdAt: relation.createdAt,
      updatedAt: relation.updatedAt,
      createdBy: relation.createdBy,
    };
  }

  function mapRelationRequest(request) {
    return {
      id: request.id,
      treeId: request.treeId,
      senderId: request.senderId,
      recipientId: request.recipientId,
      senderToRecipient: request.senderToRecipient,
      relationType: request.senderToRecipient,
      targetPersonId: request.targetPersonId || request.offlineRelativeId || null,
      offlineRelativeId:
        request.offlineRelativeId || request.targetPersonId || null,
      createdAt: request.createdAt,
      updatedAt: request.updatedAt,
      respondedAt: request.respondedAt || null,
      status: request.status || "pending",
      message: request.message || null,
    };
  }

  function mapTreeInvitation(invitation, tree = null) {
    return {
      invitationId: invitation.id,
      treeId: invitation.treeId,
      userId: invitation.userId,
      role: invitation.role || "pending",
      addedAt: invitation.addedAt,
      addedBy: invitation.addedBy || null,
      acceptedAt: invitation.acceptedAt || null,
      relationToTree: invitation.relationToTree || null,
      tree: tree ? mapTree(tree) : null,
      invitedBy: invitation.addedBy || null,
    };
  }

  function mapNotification(notification) {
    return {
      id: notification.id,
      userId: notification.userId,
      type: notification.type,
      title: notification.title,
      body: notification.body,
      data: notification.data || {},
      createdAt: notification.createdAt,
      readAt: notification.readAt || null,
      isRead: Boolean(notification.readAt),
    };
  }

  function mapPushDevice(device) {
    return {
      id: device.id,
      userId: device.userId,
      provider: device.provider,
      platform: device.platform,
      createdAt: device.createdAt,
      updatedAt: device.updatedAt,
      lastSeenAt: device.lastSeenAt,
    };
  }

  function mapPushDelivery(delivery) {
    return {
      id: delivery.id,
      notificationId: delivery.notificationId,
      userId: delivery.userId,
      deviceId: delivery.deviceId,
      provider: delivery.provider,
      status: delivery.status,
      createdAt: delivery.createdAt,
      updatedAt: delivery.updatedAt,
      deliveredAt: delivery.deliveredAt || null,
      lastError: delivery.lastError || null,
      responseCode: delivery.responseCode ?? null,
    };
  }

  function mapChatMessage(message) {
    const explicitAttachments = Array.isArray(message.attachments)
      ? message.attachments
          .filter((attachment) => String(attachment?.url || "").trim())
          .map((attachment) => ({
            type: String(attachment.type || "file"),
            url: String(attachment.url || "").trim(),
            mimeType: attachment.mimeType || null,
            fileName: attachment.fileName || null,
            sizeBytes: Number.isFinite(Number(attachment.sizeBytes))
              ? Number(attachment.sizeBytes)
              : null,
            durationMs: Number.isFinite(Number(attachment.durationMs))
              ? Number(attachment.durationMs)
              : null,
            width: Number.isFinite(Number(attachment.width))
              ? Number(attachment.width)
              : null,
            height: Number.isFinite(Number(attachment.height))
              ? Number(attachment.height)
              : null,
            thumbnailUrl: attachment.thumbnailUrl || null,
          }))
      : [];
    const attachments = explicitAttachments.length > 0
      ? explicitAttachments
      : [
          ...new Set(
            [
              ...(Array.isArray(message.mediaUrls) ? message.mediaUrls : []),
              message.imageUrl,
            ]
              .map((value) => String(value || "").trim())
              .filter(Boolean),
          ),
        ].map((url) => ({
          type: "image",
          url,
          mimeType: "image/jpeg",
          fileName: null,
          sizeBytes: null,
          durationMs: null,
          width: null,
          height: null,
          thumbnailUrl: null,
        }));
    return {
      id: message.id,
      chatId: message.chatId,
      senderId: message.senderId,
      text: message.text,
      timestamp: message.timestamp,
      isRead: message.isRead === true,
      attachments,
      imageUrl: message.imageUrl || null,
      mediaUrls: Array.isArray(message.mediaUrls) ? message.mediaUrls : [],
      participants: Array.isArray(message.participants)
        ? message.participants
        : [],
      senderName: message.senderName,
    };
  }

  function mapChatRecord(chat) {
    return {
      id: chat.id,
      type: chat.type || "direct",
      title: chat.title || null,
      participantIds: Array.isArray(chat.participantIds)
        ? chat.participantIds
        : [],
      createdBy: chat.createdBy || null,
      treeId: chat.treeId || null,
      branchRootPersonIds: Array.isArray(chat.branchRootPersonIds)
        ? chat.branchRootPersonIds
        : [],
      createdAt: chat.createdAt,
      updatedAt: chat.updatedAt,
    };
  }

  function mapChatPreview(preview) {
    return {
      id: `${preview.chatId}_${preview.userId}`,
      chatId: preview.chatId,
      userId: preview.userId,
      type: preview.type || "direct",
      title: preview.title || null,
      photoUrl: preview.photoUrl || null,
      participantIds: Array.isArray(preview.participantIds)
        ? preview.participantIds
        : [],
      otherUserId: preview.otherUserId,
      otherUserName: preview.otherUserName || "Пользователь",
      otherUserPhotoUrl: preview.otherUserPhotoUrl || null,
      lastMessage: preview.lastMessage || "",
      lastMessageTime: preview.lastMessageTime,
      unreadCount: Number(preview.unreadCount || 0),
      lastMessageSenderId: preview.lastMessageSenderId || "",
    };
  }

  async function requireTreeAccess(req, res, treeId) {
    const tree = await store.findTree(treeId);
    if (!tree) {
      res.status(404).json({message: "Семейное дерево не найдено"});
      return null;
    }

    const memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    const hasAccess =
      tree.creatorId === req.auth.user.id || memberIds.includes(req.auth.user.id);

    if (!hasAccess) {
      res.status(403).json({message: "Доступ к дереву запрещён"});
      return null;
    }

    return tree;
  }

  async function requireChatAccess(req, res, chatId) {
    const chat = await store.findChat(chatId);
    if (!chat) {
      res.status(404).json({message: "Чат не найден"});
      return null;
    }

    const participantIds = Array.isArray(chat.participantIds)
      ? chat.participantIds
      : [];
    if (!participantIds.includes(req.auth.user.id)) {
      res.status(403).json({message: "Доступ к чату запрещён"});
      return null;
    }

    return chat;
  }

  function authResponse(user, sessionTokens) {
    const profile = sanitizeProfile(user.profile);
    const profileStatus = computeProfileStatus(user.profile);
    return {
      accessToken: sessionTokens.token,
      refreshToken: sessionTokens.refreshToken,
      user: {
        id: user.id,
        email: user.email,
        displayName: profile.displayName,
        photoUrl: profile.photoUrl,
        providerIds: user.providerIds || ["password"],
      },
      profileStatus,
    };
  }

  async function createAndDispatchNotification({
    userId,
    type,
    title,
    body,
    data,
  }) {
    const notification = await store.createNotification({
      userId,
      type,
      title,
      body,
      data,
    });

    if (!notification) {
      return null;
    }

    const mappedNotification = mapNotification(notification);
    realtimeHub?.publishToUser(userId, {
      type: "notification.created",
      notification: mappedNotification,
    });
    await resolvedPushGateway.dispatchNotification(notification);

    return mappedNotification;
  }

  app.post("/v1/auth/register", async (req, res) => {
    const {email, password, displayName} = req.body || {};

    if (!email || !password || !displayName) {
      res.status(400).json({message: "Нужны email, password и displayName"});
      return;
    }

    try {
      const user = await store.createUser({email, password, displayName});
      const sessionTokens = await store.createSession(user.id);
      res.status(201).json(authResponse(user, sessionTokens));
    } catch (error) {
      if (error.message === "EMAIL_ALREADY_EXISTS") {
        res.status(409).json({message: "Этот email уже зарегистрирован"});
        return;
      }
      res.status(500).json({message: "Не удалось зарегистрировать пользователя"});
    }
  });

  app.post("/v1/auth/login", async (req, res) => {
    const {email, password} = req.body || {};
    if (!email || !password) {
      res.status(400).json({message: "Нужны email и password"});
      return;
    }

    const user = await store.authenticate(email, password);
    if (!user) {
      res.status(401).json({message: "Неверный email или пароль"});
      return;
    }

    const sessionTokens = await store.createSession(user.id);
    res.json(authResponse(user, sessionTokens));
  });

  app.get("/v1/auth/session", requireAuth, async (req, res) => {
    const user = await store.findUserById(req.auth.user.id);
    const profile = sanitizeProfile(user.profile);
    res.json({
      session: {
        accessToken: req.auth.token,
        refreshToken: req.auth.session.refreshToken,
        userId: user.id,
      },
      user: {
        id: user.id,
        email: user.email,
        displayName: profile.displayName,
        photoUrl: profile.photoUrl,
        providerIds: user.providerIds || ["password"],
      },
      profileStatus: computeProfileStatus(user.profile),
    });
  });

  app.post("/v1/auth/logout", requireAuth, async (req, res) => {
    await store.deleteSession(req.auth.token);
    res.json({ok: true});
  });

  app.post("/v1/auth/password-reset", async (req, res) => {
    const {email} = req.body || {};
    res.status(202).json({
      ok: true,
      email: email ? String(email).trim().toLowerCase() : null,
      message: "Password reset flow is stubbed in minimal backend",
    });
  });

  app.delete("/v1/auth/account", requireAuth, async (req, res) => {
    await store.deleteUser(req.auth.user.id);
    res.status(204).send();
  });

  app.post("/v1/auth/google", async (req, res) => {
    res.status(501).json({
      message:
        "Google sign-in для minimal backend ещё не реализован. Используйте email/password flow.",
    });
  });

  app.get("/v1/profile/me/bootstrap", requireAuth, async (req, res) => {
    res.json({
      profile: sanitizeProfile(req.auth.user.profile),
      profileStatus: computeProfileStatus(req.auth.user.profile),
    });
  });

  app.put("/v1/profile/me/bootstrap", requireAuth, async (req, res) => {
    const updatedUser = await store.updateProfile(req.auth.user.id, (profile) => ({
      ...profile,
      ...req.body,
      displayName: composeDisplayName({
        ...profile,
        ...req.body,
        displayName:
          req.body.displayName !== undefined
            ? req.body.displayName
            : profile.displayName,
      }),
    }));

    res.json({
      profile: sanitizeProfile(updatedUser.profile),
      profileStatus: computeProfileStatus(updatedUser.profile),
    });
  });

  app.patch("/v1/profile/me", requireAuth, async (req, res) => {
    const updatedUser = await store.updateProfile(req.auth.user.id, (profile) => ({
      ...profile,
      ...req.body,
    }));
    const sanitizedProfile = sanitizeProfile(updatedUser.profile);

    res.json({
      user: {
        id: updatedUser.id,
        email: updatedUser.email,
        displayName: sanitizedProfile.displayName,
        photoUrl: sanitizedProfile.photoUrl,
      },
      profileStatus: computeProfileStatus(updatedUser.profile),
    });
  });

  app.post("/v1/profile/me/verify-phone", requireAuth, async (req, res) => {
    const {phoneNumber, countryCode} = req.body || {};
    if (!phoneNumber) {
      res.status(400).json({message: "Нужен phoneNumber"});
      return;
    }

    const updatedUser = await store.updateProfile(req.auth.user.id, (profile) => ({
      ...profile,
      phoneNumber: String(phoneNumber),
      countryCode: countryCode ? String(countryCode) : profile.countryCode,
      isPhoneVerified: true,
    }));

    res.json({
      profile: sanitizeProfile(updatedUser.profile),
      profileStatus: computeProfileStatus(updatedUser.profile),
    });
  });

  app.get("/v1/users/:userId/profile-notes", requireAuth, async (req, res) => {
    if (!requireOwnUser(req, res)) {
      return;
    }

    const notes = await store.listProfileNotes(req.params.userId);
    if (notes === null) {
      res.status(404).json({message: "Пользователь не найден"});
      return;
    }

    res.json({
      notes: notes.map(mapProfileNote),
    });
  });

  app.post("/v1/users/:userId/profile-notes", requireAuth, async (req, res) => {
    if (!requireOwnUser(req, res)) {
      return;
    }

    const {title, content} = req.body || {};
    if (!String(title || "").trim() || !String(content || "").trim()) {
      res.status(400).json({message: "Нужны title и content"});
      return;
    }

    const note = await store.addProfileNote(req.params.userId, {
      title,
      content,
    });
    if (note === null) {
      res.status(404).json({message: "Пользователь не найден"});
      return;
    }

    res.status(201).json({note: mapProfileNote(note)});
  });

  app.patch(
    "/v1/users/:userId/profile-notes/:noteId",
    requireAuth,
    async (req, res) => {
      if (!requireOwnUser(req, res)) {
        return;
      }

      const note = await store.updateProfileNote(
        req.params.userId,
        req.params.noteId,
        {
          title: req.body?.title,
          content: req.body?.content,
        },
      );

      if (note === null) {
        res.status(404).json({message: "Пользователь не найден"});
        return;
      }
      if (note === undefined) {
        res.status(404).json({message: "Заметка не найдена"});
        return;
      }

      res.json({note: mapProfileNote(note)});
    },
  );

  app.delete(
    "/v1/users/:userId/profile-notes/:noteId",
    requireAuth,
    async (req, res) => {
      if (!requireOwnUser(req, res)) {
        return;
      }

      const deleted = await store.deleteProfileNote(
        req.params.userId,
        req.params.noteId,
      );
      if (deleted === null) {
        res.status(404).json({message: "Пользователь не найден"});
        return;
      }
      if (deleted === false) {
        res.status(404).json({message: "Заметка не найдена"});
        return;
      }

      res.status(204).send();
    },
  );

  app.post("/v1/media/upload", requireAuth, async (req, res) => {
    const {bucket, path: mediaPath, fileBase64, contentType} = req.body || {};

    if (!bucket || !mediaPath || !fileBase64) {
      res.status(400).json({
        message: "Нужны bucket, path и fileBase64",
      });
      return;
    }

    try {
      const {safeBucket, safeRelativePath, resolvedPath} = resolveMediaFilePath(
        bucket,
        mediaPath,
      );

      const fileBuffer = Buffer.from(String(fileBase64), "base64");
      if (fileBuffer.length === 0) {
        res.status(400).json({message: "Пустой fileBase64 payload"});
        return;
      }

      await fs.mkdir(path.dirname(resolvedPath), {recursive: true});
      await fs.writeFile(resolvedPath, fileBuffer);

      res.status(201).json({
        bucket: safeBucket,
        path: safeRelativePath,
        contentType: contentType ? String(contentType) : null,
        size: fileBuffer.length,
        url: buildMediaUrl(req, safeBucket, safeRelativePath),
      });
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
      const url = new URL(urlValue);
      const mediaPrefix = "/media/";
      if (!url.pathname.startsWith(mediaPrefix)) {
        res.status(400).json({message: "URL не относится к media backend"});
        return;
      }

      const relativePath = decodeURIComponent(
        url.pathname.slice(mediaPrefix.length),
      );
      const [bucket, ...restParts] = relativePath.split("/").filter(Boolean);
      const mediaPath = restParts.join("/");
      const {resolvedPath} = resolveMediaFilePath(bucket, mediaPath);

      await fs.rm(resolvedPath, {force: true});
      res.status(204).send();
    } catch (error) {
      if (error.message === "INVALID_MEDIA_PATH" || error instanceof TypeError) {
        res.status(400).json({message: "Недопустимый media URL"});
        return;
      }
      res.status(500).json({message: "Не удалось удалить файл"});
    }
  });

  app.post("/v1/trees", requireAuth, async (req, res) => {
    const {name, description, isPrivate} = req.body || {};
    if (!String(name || "").trim()) {
      res.status(400).json({message: "Нужно название дерева"});
      return;
    }

    const tree = await store.createTree({
      creatorId: req.auth.user.id,
      name,
      description,
      isPrivate,
    });

    res.status(201).json({tree: mapTree(tree)});
  });

  app.get("/v1/trees", requireAuth, async (req, res) => {
    const trees = await store.listUserTrees(req.auth.user.id);
    res.json({
      trees: trees.map(mapTree),
    });
  });

  app.delete("/v1/trees/:treeId", requireAuth, async (req, res) => {
    const tree = await store.findTree(req.params.treeId);
    if (!tree) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }

    const memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    const members = Array.isArray(tree.members) ? tree.members : [];
    const hasAccess =
      tree.creatorId === req.auth.user.id ||
      memberIds.includes(req.auth.user.id) ||
      members.includes(req.auth.user.id);
    if (!hasAccess) {
      res.status(403).json({message: "Доступ к дереву запрещён"});
      return;
    }

    const result = await store.removeTreeForUser({
      treeId: req.params.treeId,
      userId: req.auth.user.id,
    });
    if (result === null) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }
    if (result === false) {
      res.status(403).json({message: "Доступ к дереву запрещён"});
      return;
    }

    res.json({
      action: result.action,
      tree: mapTree(result.tree),
    });
  });

  app.get("/v1/public/trees/:publicTreeId", async (req, res) => {
    const tree = await requirePublicTree(req, res, req.params.publicTreeId);
    if (!tree) {
      return;
    }

    const [persons, relations] = await Promise.all([
      store.listPersons(tree.id),
      store.listRelations(tree.id),
    ]);

    res.json({
      tree: mapTree(tree),
      stats: {
        peopleCount: persons.length,
        relationsCount: relations.length,
      },
    });
  });

  app.get("/v1/public/trees/:publicTreeId/persons", async (req, res) => {
    const tree = await requirePublicTree(req, res, req.params.publicTreeId);
    if (!tree) {
      return;
    }

    const persons = await store.listPersons(tree.id);
    res.json({
      tree: mapTree(tree),
      persons: persons.map(mapPerson),
    });
  });

  app.get("/v1/public/trees/:publicTreeId/relations", async (req, res) => {
    const tree = await requirePublicTree(req, res, req.params.publicTreeId);
    if (!tree) {
      return;
    }

    const relations = await store.listRelations(tree.id);
    res.json({
      tree: mapTree(tree),
      relations: relations.map(mapRelation),
    });
  });

  app.get("/v1/trees/selectable", requireAuth, async (req, res) => {
    const trees = await store.listUserTrees(req.auth.user.id);
    res.json({
      trees: trees.map((tree) => ({
        id: tree.id,
        name: tree.name,
        createdAt: tree.createdAt,
      })),
    });
  });

  app.get("/v1/trees/:treeId/persons", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    const persons = await store.listPersons(tree.id);
    res.json({
      persons: persons.map(mapPerson),
    });
  });

  app.post("/v1/trees/:treeId/persons", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    const requestedUserId = req.body?.userId;
    if (requestedUserId && requestedUserId !== req.auth.user.id) {
      res.status(403).json({
        message: "Нельзя привязать к профилю другого пользователя",
      });
      return;
    }

    const person = await store.createPerson({
      treeId: tree.id,
      creatorId: req.auth.user.id,
      userId: requestedUserId || null,
      personData: req.body || {},
    });

    if (!person) {
      res.status(404).json({message: "Семейное дерево не найдено"});
      return;
    }

    res.status(201).json({person: mapPerson(person)});
  });

  app.get(
    "/v1/trees/:treeId/persons/:personId",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const person = await store.findPerson(tree.id, req.params.personId);
      if (!person) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      res.json({person: mapPerson(person)});
    },
  );

  app.patch(
    "/v1/trees/:treeId/persons/:personId",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const person = await store.updatePerson(
        tree.id,
        req.params.personId,
        req.body || {},
      );
      if (!person) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      res.json({person: mapPerson(person)});
    },
  );

  app.delete(
    "/v1/trees/:treeId/persons/:personId",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const deleted = await store.deletePerson(tree.id, req.params.personId);
      if (!deleted) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      res.status(204).send();
    },
  );

  app.get("/v1/trees/:treeId/relations", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    const relations = await store.listRelations(tree.id);
    res.json({
      relations: relations.map(mapRelation),
    });
  });

  app.post("/v1/trees/:treeId/relations", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    const {person1Id, person2Id, relation1to2, relation2to1, isConfirmed} =
      req.body || {};
    if (!person1Id || !person2Id || !relation1to2) {
      res.status(400).json({
        message: "Нужны person1Id, person2Id и relation1to2",
      });
      return;
    }

    const relation = await store.upsertRelation({
      treeId: tree.id,
      person1Id: String(person1Id),
      person2Id: String(person2Id),
      relation1to2: String(relation1to2),
      relation2to1: relation2to1 ? String(relation2to1) : undefined,
      isConfirmed: isConfirmed !== false,
      createdBy: req.auth.user.id,
    });

    if (!relation) {
      res.status(404).json({
        message: "Один или оба человека не найдены в дереве",
      });
      return;
    }

    res.status(201).json({relation: mapRelation(relation)});
  });

  app.get("/v1/tree-invitations/pending", requireAuth, async (req, res) => {
    const invitations = await store.listPendingTreeInvitations(req.auth.user.id);
    const treeCache = new Map();

    for (const invitation of invitations) {
      if (!treeCache.has(invitation.treeId)) {
        treeCache.set(invitation.treeId, await store.findTree(invitation.treeId));
      }
    }

    res.json({
      invitations: invitations.map((invitation) =>
        mapTreeInvitation(invitation, treeCache.get(invitation.treeId) || null),
      ),
    });
  });

  app.post(
    "/v1/trees/:treeId/invitations",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const recipientUserId = String(req.body?.recipientUserId || "").trim();
      const recipientEmail = String(req.body?.recipientEmail || "").trim().toLowerCase();
      const relationToTree = req.body?.relationToTree;

      if (!recipientUserId && !recipientEmail) {
        res.status(400).json({message: "Нужен recipientUserId или recipientEmail"});
        return;
      }

      let targetUserId = recipientUserId;
      if (!targetUserId && recipientEmail) {
        const users = await store.searchUsersByField({
          field: "email",
          value: recipientEmail,
          limit: 1,
        });
        if (!users.length) {
          res.status(404).json({message: "Пользователь с таким email не найден"});
          return;
        }
        targetUserId = users[0].id;
      }

      const invitation = await store.createTreeInvitation({
        treeId: tree.id,
        userId: targetUserId,
        addedBy: req.auth.user.id,
        relationToTree,
      });

      if (invitation === null) {
        res.status(404).json({message: "Семейное дерево не найдено"});
        return;
      }
      if (invitation === undefined) {
        res.status(404).json({message: "Приглашаемый пользователь не найден"});
        return;
      }
      if (invitation === false) {
        res.status(409).json({
          message: "Этот пользователь уже состоит в семейном дереве",
        });
        return;
      }
      if (invitation === "DUPLICATE") {
        res.status(409).json({
          message: "Для этого пользователя уже есть активное приглашение",
        });
        return;
      }

      await createAndDispatchNotification({
        userId: targetUserId,
        type: "tree_invitation",
        title: "Приглашение в семейное дерево",
        body: `Вас пригласили в дерево «${tree.name}»`,
        data: {
          invitationId: invitation.id,
          treeId: tree.id,
          treeName: tree.name,
          invitedBy: req.auth.user.id,
        },
      });

      res.status(201).json({
        invitation: mapTreeInvitation(invitation, tree),
      });
    },
  );

  app.post(
    "/v1/tree-invitations/:invitationId/respond",
    requireAuth,
    async (req, res) => {
      const accept = req.body?.accept == true;
      const invitation = await store.findTreeInvitation(req.params.invitationId);
      if (!invitation) {
        res.status(404).json({message: "Приглашение не найдено"});
        return;
      }

      if (invitation.userId !== req.auth.user.id) {
        res.status(403).json({message: "Нельзя отвечать на чужое приглашение"});
        return;
      }

      const result = await store.respondToTreeInvitation(
        req.params.invitationId,
        accept,
      );
      if (result === null) {
        res.status(404).json({message: "Приглашение не найдено"});
        return;
      }
      if (result === undefined) {
        res.status(404).json({message: "Семейное дерево не найдено"});
        return;
      }

      if (result.accepted && result.invitation.addedBy) {
        await createAndDispatchNotification({
          userId: result.invitation.addedBy,
          type: "tree_invitation_accepted",
          title: "Приглашение принято",
          body: `Пользователь принял приглашение в дерево «${result.tree.name}»`,
          data: {
            treeId: result.tree.id,
            treeName: result.tree.name,
            invitationId: result.invitation.id,
            memberUserId: result.invitation.userId,
          },
        });
      }

      res.json({
        ok: true,
        accepted: result.accepted,
        tree: mapTree(result.tree),
        invitation: mapTreeInvitation(result.invitation, result.tree),
      });
    },
  );

  app.get(
    "/v1/trees/:treeId/relation-requests",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const requests = await store.listRelationRequests({
        treeId: tree.id,
        senderId: req.query.senderId ? String(req.query.senderId) : null,
        recipientId: req.query.recipientId ? String(req.query.recipientId) : null,
        status: req.query.status ? String(req.query.status) : null,
      });

      res.json({
        requests: requests.map(mapRelationRequest),
      });
    },
  );

  app.get("/v1/relation-requests/pending", requireAuth, async (req, res) => {
    const requests = await store.listRelationRequests({
      treeId: req.query.treeId ? String(req.query.treeId) : null,
      recipientId: req.auth.user.id,
      status: "pending",
    });

    res.json({
      requests: requests.map(mapRelationRequest),
    });
  });

  app.post(
    "/v1/trees/:treeId/relation-requests",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const recipientId = String(req.body?.recipientId || "").trim();
      const senderToRecipient = String(
        req.body?.senderToRecipient || req.body?.relationType || "other",
      ).trim();
      const targetPersonId = String(
        req.body?.targetPersonId || req.body?.offlineRelativeId || "",
      ).trim();
      const message = req.body?.message;

      if (!recipientId) {
        res.status(400).json({message: "Нужен recipientId"});
        return;
      }

      const request = await store.createRelationRequest({
        treeId: tree.id,
        senderId: req.auth.user.id,
        recipientId,
        senderToRecipient,
        targetPersonId: targetPersonId || null,
        message,
      });

      if (request === null) {
        res.status(404).json({message: "Семейное дерево не найдено"});
        return;
      }
      if (request === undefined) {
        res.status(404).json({message: "Отправитель или получатель не найден"});
        return;
      }
      if (request === false) {
        res.status(400).json({message: "Нельзя отправить запрос самому себе"});
        return;
      }
      if (request === "TARGET_PERSON_NOT_FOUND") {
        res.status(404).json({message: "Офлайн-профиль для приглашения не найден"});
        return;
      }
      if (request === "DUPLICATE") {
        res.status(409).json({message: "Похожий запрос уже ожидает ответа"});
        return;
      }

      await createAndDispatchNotification({
        userId: recipientId,
        type: "relation_request",
        title: "Новый запрос на родство",
        body: "Вам отправили запрос на подтверждение родственной связи",
        data: {
          requestId: request.id,
          treeId: request.treeId,
          senderId: request.senderId,
          relationType: request.senderToRecipient,
        },
      });

      res.status(201).json({request: mapRelationRequest(request)});
    },
  );

  app.post(
    "/v1/relation-requests/:requestId/respond",
    requireAuth,
    async (req, res) => {
      const responseStatus = String(req.body?.response || "").trim();
      if (!responseStatus) {
        res.status(400).json({message: "Нужен response"});
        return;
      }

      const request = await store.findRelationRequest(req.params.requestId);
      if (!request) {
        res.status(404).json({message: "Запрос не найден"});
        return;
      }

      if (request.recipientId !== req.auth.user.id) {
        res.status(403).json({message: "Нельзя отвечать на чужой запрос"});
        return;
      }

      if (request.status !== "pending") {
        res.status(409).json({message: "Этот запрос уже обработан"});
        return;
      }

      if (!["accepted", "rejected", "canceled"].includes(responseStatus)) {
        res.status(400).json({message: "Недопустимый статус ответа"});
        return;
      }

      let recipientPerson = null;
      let senderPerson = null;
      let relation = null;

      if (responseStatus === "accepted") {
        if (request.targetPersonId) {
          const linkedPerson = await store.linkPersonToUser({
            treeId: request.treeId,
            personId: request.targetPersonId,
            userId: req.auth.user.id,
          });

          if (linkedPerson === null || linkedPerson === undefined) {
            res.status(404).json({message: "Профиль для привязки не найден"});
            return;
          }
          if (linkedPerson === false) {
            res.status(409).json({
              message: "Этот профиль уже связан с другим пользователем",
            });
            return;
          }

          recipientPerson = linkedPerson;
        } else {
          recipientPerson = await store.ensureUserPersonInTree({
            treeId: request.treeId,
            userId: req.auth.user.id,
          });
        }

        senderPerson = await store.ensureUserPersonInTree({
          treeId: request.treeId,
          userId: request.senderId,
          creatorId: request.senderId,
        });

        if (!recipientPerson || !senderPerson) {
          res.status(404).json({
            message: "Не удалось подготовить участников родственной связи",
          });
          return;
        }

        relation = await store.upsertRelation({
          treeId: request.treeId,
          person1Id: senderPerson.id,
          person2Id: recipientPerson.id,
          relation1to2: request.senderToRecipient,
          isConfirmed: true,
          createdBy: request.senderId,
        });
      }

      const updatedRequest = await store.respondToRelationRequest(
        request.id,
        responseStatus,
      );

      await createAndDispatchNotification({
        userId: request.senderId,
        type:
          responseStatus === "accepted"
            ? "relation_request_accepted"
            : "relation_request_updated",
        title:
          responseStatus === "accepted"
            ? "Запрос на родство принят"
            : "Запрос на родство обновлён",
        body:
          responseStatus === "accepted"
            ? "Ваш запрос на родство был принят"
            : "Получатель обработал ваш запрос на родство",
        data: {
          requestId: request.id,
          treeId: request.treeId,
          recipientId: request.recipientId,
          status: responseStatus,
        },
      });

      res.json({
        request: mapRelationRequest(updatedRequest),
        person: recipientPerson ? mapPerson(recipientPerson) : null,
        relation: relation ? mapRelation(relation) : null,
      });
    },
  );

  app.get("/v1/chats", requireAuth, async (req, res) => {
    const previews = await store.listChatPreviews(req.auth.user.id);
    res.json({
      chats: previews.map(mapChatPreview),
    });
  });

  app.get("/v1/chats/unread-count", requireAuth, async (req, res) => {
    const previews = await store.listChatPreviews(req.auth.user.id);
    const totalUnread = previews.reduce((sum, preview) => {
      return sum + Number(preview.unreadCount || 0);
    }, 0);

    res.json({
      totalUnread,
    });
  });

  app.post("/v1/chats/direct", requireAuth, async (req, res) => {
    const otherUserId = String(req.body?.otherUserId || "").trim();
    if (!otherUserId) {
      res.status(400).json({message: "Нужен otherUserId"});
      return;
    }

    const otherUser = await store.findUserById(otherUserId);
    if (!otherUser) {
      res.status(404).json({message: "Собеседник не найден"});
      return;
    }

    const chat = await store.ensureDirectChat(req.auth.user.id, otherUserId);
    if (chat === null) {
      res.status(400).json({message: "Не удалось создать личный чат"});
      return;
    }
    if (chat === undefined) {
      res.status(404).json({message: "Один из участников не найден"});
      return;
    }

    res.json({
      chatId: chat.id,
      chat: mapChatRecord(chat),
    });
  });

  app.post("/v1/chats/groups", requireAuth, async (req, res) => {
    const participantIds = Array.isArray(req.body?.participantIds)
      ? req.body.participantIds
      : [];
    const title = req.body?.title;
    const treeId = req.body?.treeId;

    const chat = await store.createGroupChat({
      title,
      participantIds,
      createdBy: req.auth.user.id,
      treeId,
    });
    if (chat === false) {
      res.status(400).json({
        message: "Для группового чата нужно выбрать минимум двух участников",
      });
      return;
    }
    if (chat === null) {
      res.status(404).json({message: "Один или несколько участников не найдены"});
      return;
    }

    const mappedChat = mapChatRecord(chat);
    for (const participantId of chat.participantIds) {
      realtimeHub?.publishToUser(participantId, {
        type: "chat.created",
        chatId: chat.id,
        chat: mappedChat,
      });
    }

    res.status(201).json({
      chatId: chat.id,
      chat: mappedChat,
    });
  });

  app.post("/v1/chats/branches", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();
    const branchRootPersonIds = Array.isArray(req.body?.branchRootPersonIds)
      ? req.body.branchRootPersonIds
      : [];
    const title = req.body?.title;

    if (!treeId) {
      res.status(400).json({message: "Нужен treeId"});
      return;
    }

    const tree = await requireTreeAccess(req, res, treeId);
    if (!tree) {
      return;
    }

    const chat = await store.createBranchChat({
      treeId: tree.id,
      branchRootPersonIds,
      createdBy: req.auth.user.id,
      title,
    });
    if (chat === false) {
      res.status(400).json({
        message: "В этой ветке пока нет других участников с аккаунтами",
      });
      return;
    }
    if (chat === null) {
      res.status(404).json({message: "Ветка не найдена в выбранном дереве"});
      return;
    }

    const mappedChat = mapChatRecord(chat);
    for (const participantId of chat.participantIds) {
      realtimeHub?.publishToUser(participantId, {
        type: "chat.created",
        chatId: chat.id,
        chat: mappedChat,
      });
    }

    res.status(201).json({
      chatId: chat.id,
      chat: mappedChat,
    });
  });

  app.get("/v1/chats/:chatId/messages", requireAuth, async (req, res) => {
    const chat = await requireChatAccess(req, res, req.params.chatId);
    if (!chat) {
      return;
    }

    const messages = await store.listChatMessages(req.params.chatId);
    res.json({
      chat: mapChatRecord(chat),
      messages: messages.map(mapChatMessage),
    });
  });

  app.post("/v1/chats/:chatId/messages", requireAuth, async (req, res) => {
    const chat = await requireChatAccess(req, res, req.params.chatId);
    if (!chat) {
      return;
    }

    const text = String(req.body?.text || "").trim();
    const attachments = Array.isArray(req.body?.attachments)
      ? req.body.attachments
      : [];
    const mediaUrls = Array.isArray(req.body?.mediaUrls) ? req.body.mediaUrls : [];
    const imageUrl = req.body?.imageUrl;
    if (
      !text &&
      attachments.length === 0 &&
      mediaUrls.length === 0 &&
      !String(imageUrl || "").trim()
    ) {
      res.status(400).json({message: "Нужен text или вложение"});
      return;
    }

    const message = await store.addChatMessage({
      chatId: req.params.chatId,
      senderId: req.auth.user.id,
      text,
      attachments,
      mediaUrls,
      imageUrl,
    });

    if (message === false) {
      res.status(400).json({message: "Сообщение не должно быть пустым"});
      return;
    }
    if (!message) {
      res.status(400).json({message: "Не удалось отправить сообщение"});
      return;
    }

    const mappedMessage = mapChatMessage(message);
    const recipientIds = (chat.participantIds || []).filter(
      (participantId) => participantId !== req.auth.user.id,
    );
    for (const recipientId of recipientIds) {
      const firstAttachmentType = Array.isArray(mappedMessage.attachments)
        ? mappedMessage.attachments.find((attachment) =>
            String(attachment?.url || "").trim(),
          )?.type
        : null;
      await createAndDispatchNotification({
        userId: recipientId,
        type: "chat_message",
        title:
          chat.type === "group" || chat.type === "branch"
            ? chat.title || message.senderName || "Групповой чат"
            : message.senderName || "Новое сообщение",
        body:
          message.text ||
          (firstAttachmentType === "video"
            ? "Видео"
            : firstAttachmentType === "audio"
              ? "Голосовое"
              : firstAttachmentType === "file"
                ? "Файл"
                : (Array.isArray(message.mediaUrls) && message.mediaUrls.length > 0)
                  ? "Фото"
                  : "Новое сообщение"),
        data: {
          chatId: message.chatId,
          chatType: chat.type || "direct",
          chatTitle: chat.title || null,
          senderId: message.senderId,
          senderName: message.senderName,
          messageId: message.id,
          attachments: mappedMessage.attachments,
        },
      });
    }

    for (const participantId of chat.participantIds || []) {
      realtimeHub?.publishToUser(participantId, {
        type: "chat.message.created",
        chatId: message.chatId,
        chat: mapChatRecord(chat),
        message: mappedMessage,
      });
    }

    res.status(201).json({message: mappedMessage});
  });

  app.post("/v1/chats/:chatId/read", requireAuth, async (req, res) => {
    const chat = await requireChatAccess(req, res, req.params.chatId);
    if (!chat) {
      return;
    }

    await store.markChatAsRead(req.params.chatId, req.auth.user.id);
    realtimeHub?.publishToUser(req.auth.user.id, {
      type: "chat.read.updated",
      chatId: req.params.chatId,
      chat: mapChatRecord(chat),
      userId: req.auth.user.id,
    });
    res.json({ok: true});
  });

  app.get("/v1/users/search", requireAuth, async (req, res) => {
    const query = String(req.query.query || "");
    const limit = Number(req.query.limit || 10);
    const users = await store.searchUsers({query, limit});

    res.json({
      users: users.map((user) => ({
        id: user.id,
        ...sanitizeProfile(user.profile),
      })),
    });
  });

  app.get("/v1/users/search/by-field", requireAuth, async (req, res) => {
    const field = String(req.query.field || "");
    const value = String(req.query.value || "");
    const limit = Number(req.query.limit || 10);

    if (!field || !value) {
      res.status(400).json({message: "Нужны field и value"});
      return;
    }

    const users = await store.searchUsersByField({field, value, limit});
    res.json({
      users: users.map((user) => ({
        id: user.id,
        ...sanitizeProfile(user.profile),
      })),
    });
  });

  app.get("/v1/users/:userId/profile", requireAuth, async (req, res) => {
    const user = await store.findUserById(req.params.userId);
    if (!user) {
      res.status(404).json({message: "Пользователь не найден"});
      return;
    }

    res.json({
      profile: sanitizeProfile(user.profile),
      profileStatus: computeProfileStatus(user.profile),
    });
  });

  app.patch("/v1/users/:userId/profile", requireAuth, async (req, res) => {
    if (req.params.userId !== req.auth.user.id) {
      res.status(403).json({message: "Изменение чужого профиля запрещено"});
      return;
    }

    const updatedUser = await store.updateProfile(req.auth.user.id, (profile) => ({
      ...profile,
      ...req.body,
    }));

    res.json({
      profile: sanitizeProfile(updatedUser.profile),
      profileStatus: computeProfileStatus(updatedUser.profile),
    });
  });

  app.get("/v1/notifications", requireAuth, async (req, res) => {
    const status = req.query.status ? String(req.query.status) : null;
    const limit = Number(req.query.limit || 50);
    const notifications = await store.listNotifications(req.auth.user.id, {
      status,
      limit,
    });

    res.json({
      notifications: notifications.map(mapNotification),
    });
  });

  app.get("/v1/notifications/unread-count", requireAuth, async (req, res) => {
    const totalUnread = await store.countUnreadNotifications(req.auth.user.id);
    res.json({totalUnread});
  });

  app.post(
    "/v1/notifications/:notificationId/read",
    requireAuth,
    async (req, res) => {
      const notification = await store.markNotificationRead(
        req.params.notificationId,
        req.auth.user.id,
      );
      if (!notification) {
        res.status(404).json({message: "Уведомление не найдено"});
        return;
      }

      res.json({
        notification: mapNotification(notification),
      });
    },
  );

  app.get("/v1/push/devices", requireAuth, async (req, res) => {
    const devices = await store.listPushDevices(req.auth.user.id);
    res.json({
      devices: devices.map(mapPushDevice),
    });
  });

  app.get("/v1/push/web/config", requireAuth, async (req, res) => {
    res.json({
      enabled: Boolean(config.webPushEnabled),
      publicKey: config.webPushEnabled ? config.webPushPublicKey : null,
    });
  });

  app.post("/v1/push/devices", requireAuth, async (req, res) => {
    const provider = String(req.body?.provider || "").trim();
    const token = String(req.body?.token || "").trim();
    const platform = String(req.body?.platform || "unknown").trim();

    if (!provider || !token) {
      res.status(400).json({message: "Нужны provider и token"});
      return;
    }

    const device = await store.registerPushDevice({
      userId: req.auth.user.id,
      provider,
      token,
      platform,
    });

    if (device === null) {
      res.status(404).json({message: "Пользователь не найден"});
      return;
    }
    if (device === false) {
      res.status(400).json({message: "Недопустимые provider или token"});
      return;
    }

    res.status(201).json({
      device: mapPushDevice(device),
    });
  });

  app.delete("/v1/push/devices/:deviceId", requireAuth, async (req, res) => {
    const deleted = await store.deletePushDevice(
      req.params.deviceId,
      req.auth.user.id,
    );
    if (!deleted) {
      res.status(404).json({message: "Устройство не найдено"});
      return;
    }

    res.status(204).send();
  });

  app.get("/v1/push/deliveries", requireAuth, async (req, res) => {
    const limit = Number(req.query.limit || 50);
    const deliveries = await store.listPushDeliveries(req.auth.user.id, {
      limit,
    });
    res.json({
      deliveries: deliveries.map(mapPushDelivery),
    });
  });

  app.post("/v1/invitations/pending/process", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();
    const personId = String(req.body?.personId || "").trim();

    if (!treeId || !personId) {
      res.status(400).json({message: "Нужны treeId и personId"});
      return;
    }

    const linkedPerson = await store.linkPersonToUser({
      treeId,
      personId,
      userId: req.auth.user.id,
    });

    if (linkedPerson === null) {
      res.status(404).json({message: "Семейное дерево или пользователь не найдены"});
      return;
    }
    if (linkedPerson === undefined) {
      res.status(404).json({message: "Профиль приглашения не найден"});
      return;
    }
    if (linkedPerson === false) {
      res.status(409).json({
        message: "Этот профиль уже связан с другим пользователем",
      });
      return;
    }

    const tree = await store.findTree(treeId);
    res.json({
      ok: true,
      tree: tree ? mapTree(tree) : null,
      person: mapPerson(linkedPerson),
    });
  });

  app.use((req, res) => {
    res.status(404).json({message: "Route not found"});
  });

  app.use((error, req, res, next) => {
    console.error("[backend] Unhandled error:", error);

    if (res.headersSent) {
      next(error);
      return;
    }

    res.status(500).json({
      message: "Внутренняя ошибка backend",
    });
  });

  return app;
}

module.exports = {
  createApp,
};
