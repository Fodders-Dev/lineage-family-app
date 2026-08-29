const express = require("express");
const cors = require("cors");
const crypto = require("node:crypto");

const {
  computeProfileStatus,
  composeDisplayName,
  normalizeProfileContributionPolicy,
  normalizePrimaryTrustedChannel,
  normalizePublicUrl,
  normalizePublicUrlList,
  sanitizeProfile,
  sanitizeUserProfilePreview,
} = require("./profile-utils");
const {PushGateway} = require("./push-gateway");
const {createMediaStorage} = require("./media-storage");
const {createGoogleTokenVerifier} = require("./google-auth");
const {createVkAuthClient} = require("./vk-auth");
const {createMaxAuthClient} = require("./max-auth");
const {createLiveKitService} = require("./livekit-service");
const {
  buildBranchVisiblePersonIds,
  buildCallParticipantIdentity,
  deriveSessionPublicId,
  normalizeParticipantIds,
} = require("./store");
const {createEmailSender} = require("./email-sender");
const {createOperationalStatus} = require("./operational-status");
const {InMemoryRateLimitBackend} = require("./rate-limit-backends");
const {registerAdminRoutes} = require("./routes/admin-routes");
const {registerAppUpdateRoutes} = require("./routes/app-update-routes");
const {registerAuthSessionRoutes} = require("./routes/auth-session-routes");
const {
  registerAuthenticatedMediaRoutes,
  registerPublicMediaRoutes,
} = require("./routes/media-routes");
const {registerChatRoutes} = require("./routes/chat-routes");
const {registerCircleRoutes} = require("./routes/circle-routes");
const {registerDiagnosticsRoutes} = require("./routes/diagnostics-routes");
const {registerGoogleAuthRoutes} = require("./routes/google-auth-routes");
const {registerGraphRoutes} = require("./routes/graph-routes");
const {registerGraphPersonRoutes} = require("./routes/graph-person-routes");
const {registerOnboardingRoutes} = require("./routes/onboarding-routes");
const {registerKinshipChecksRoutes} = require("./routes/kinship-checks-routes");
const {registerSemyaRoutes} = require("./routes/semya-routes");
const {registerMembershipRoutes} = require("./routes/membership-routes");
const {
  registerSemyaInvitationRoutes,
} = require("./routes/semya-invitation-routes");
const {registerSemyaPullRoutes} = require("./routes/semya-pull-routes");
const {registerSemyaBrowseRoutes} = require("./routes/semya-browse-routes");
const {
  registerSemyaHideFilterRoutes,
} = require("./routes/semya-hide-filter-routes");
const {
  registerDeletedPersonsRoutes,
} = require("./routes/deleted-persons-routes");
const {
  registerDeletedPostsRoutes,
} = require("./routes/deleted-posts-routes");
const {
  registerProfileArticleRoutes,
} = require("./routes/profile-article-routes");
const {registerIdentityRoutes} = require("./routes/identity-routes");
const {registerMaxAuthRoutes} = require("./routes/max-auth-routes");
const {registerMergeRoutes} = require("./routes/merge-routes");
const {registerNotificationRoutes} = require("./routes/notification-routes");
const {
  registerPendingInvitationRoutes,
} = require("./routes/pending-invitation-routes");
const {registerPostRoutes} = require("./routes/post-routes");
const {registerGatheringRoutes} = require("./routes/gathering-routes");
const {registerPollRoutes} = require("./routes/poll-routes");
const {registerProfileRoutes} = require("./routes/profile-routes");
const {registerPushRoutes} = require("./routes/push-routes");
const {
  registerRelationRequestRoutes,
} = require("./routes/relation-request-routes");
const {registerSafetyRoutes} = require("./routes/safety-routes");
const {registerStoryRoutes} = require("./routes/story-routes");
const {
  registerTelegramAuthRoutes,
} = require("./routes/telegram-auth-routes");
const {
  registerTreeInvitationRoutes,
} = require("./routes/tree-invitation-routes");
const {registerTreeRoutes} = require("./routes/tree-routes");
const {registerUserRoutes} = require("./routes/user-routes");
const {registerVkAuthRoutes} = require("./routes/vk-auth-routes");
const {normalizeAttachmentWaveform} = require("./chat-utils");

const DEFAULT_CALL_INVITE_TIMEOUT_MS = 30_000;
// GP3: LiveKit `maxParticipants` is a size cap only — it never grants access
// (that stays token-gated by chat membership), and it can't be grown on an
// already-created room. So we create every call room with a generous ceiling
// so «add someone mid-call» always fits; a direct call's 16-cap room still
// only admits its 2 token-holders.
const GROUP_CALL_MAX_PARTICIPANTS = 16;
// Потолок размера страницы GET /v1/chats. requestedLimit и так
// зажат в [1,200]; это — понижаемый «рычаг» на случай инцидента.
// Был ошибочно оставлен на 3 → у всех список чатов резался до 3 бесед.
const EMERGENCY_CHAT_PREVIEW_RESPONSE_CAP = 200;

function createApp({
  store,
  config,
  realtimeHub = null,
  pushGateway = null,
  mediaStorage = null,
  googleTokenVerifier = null,
  vkAuthClient = null,
  maxAuthClient = null,
  liveKitService = null,
  runtimeInfo = null,
  // Transactional email sender for password-reset / verification.
  // When omitted we build one from `config.smtp*` (or fall back to
  // the dev console-logger when SMTP isn't configured). Tests pass
  // a recording fake so they can assert on outgoing payloads
  // without touching nodemailer.
  emailSender = null,
  // Pluggable rate-limit backend. The default is an in-memory Map
  // which is correct for a single-process deploy (current production
  // shape). When the backend is scaled out to multiple processes /
  // replicas, every process gets its own Map and the per-IP / per-
  // bucket caps multiply by the replica count — an attacker can
  // burn (replicas × limit) attempts per window. To fix that
  // horizontally, callers can pass a Redis-backed (or any other
  // shared-state) implementation here. The contract is just two
  // methods:
  //   incr(key, windowMs): returns {count, resetAt} after bumping
  //                         the bucket. Window resets when resetAt
  //                         has passed.
  //   evict(key): drop a bucket explicitly (used by the periodic
  //               cleanup tick).
  // Both must be synchronous-ish (a Promise is fine — see
  // rate-limit-backends.js for a reference Redis adapter sketch).
  rateLimitBackend = null,
}) {
  const app = express();
  // Phase B Ship 5: feature flag. When ON (env
  // `RODNYA_FEDERATED_SEMYI_ENABLED=true`), `requireTreeAccess` uses
  // семья membership для trees bound к семья (tree.semyaId set).
  // Default OFF — preserves existing behavior pre-Phase-B (legacy
  // creator + tree.memberIds gate). Production-flip Week 8 staged
  // rollout after migration script lands.
  const useSemyaModel =
    String(process.env.RODNYA_FEDERATED_SEMYI_ENABLED || "")
      .trim()
      .toLowerCase() === "true";
  const resolvedPushGateway =
    pushGateway ?? new PushGateway({store, config});
  const resolvedMediaStorage = mediaStorage ?? createMediaStorage(config);
  const resolvedGoogleTokenVerifier =
    googleTokenVerifier ?? createGoogleTokenVerifier(config);
  const resolvedVkAuthClient = vkAuthClient ?? createVkAuthClient(config);
  const resolvedMaxAuthClient = maxAuthClient ?? createMaxAuthClient(config);
  const resolvedLiveKitService = liveKitService ?? createLiveKitService(config);
  const resolvedEmailSender =
    emailSender ?? createEmailSender({config, logger: console});
  // Used by the rate-limit middleware below. Backwards-compat name
  // for what used to be a bare `Map<string, {count, resetAt}>`; the
  // middleware now routes through the pluggable backend's `incr`
  // method so a future scale-out PR can swap in a Redis-backed
  // implementation without touching the middleware logic.
  const resolvedRateLimitBackend =
    rateLimitBackend ?? new InMemoryRateLimitBackend();
  const operationalStatus = createOperationalStatus({
    store,
    config,
    realtimeHub,
    mediaStorage: resolvedMediaStorage,
    liveKitService: resolvedLiveKitService,
    vkAuthClient: resolvedVkAuthClient,
    maxAuthClient: resolvedMaxAuthClient,
    runtimeInfo,
  });
  const {normalizedRuntimeInfo, buildStatusPayload, ensureReady} =
    operationalStatus;
  const ringTimeoutTimers = new Map();
  const configuredCallInviteTimeoutMs = Number(config?.callInviteTimeoutMs);
  const callInviteTimeoutMs =
    Number.isFinite(configuredCallInviteTimeoutMs) &&
    configuredCallInviteTimeoutMs > 0
      ? Math.floor(configuredCallInviteTimeoutMs)
      : DEFAULT_CALL_INVITE_TIMEOUT_MS;

  function clearCallInviteTimeout(callId) {
    const normalizedCallId = String(callId || "").trim();
    if (!normalizedCallId) {
      return;
    }
    const existingTimer = ringTimeoutTimers.get(normalizedCallId);
    if (existingTimer) {
      clearTimeout(existingTimer);
      ringTimeoutTimers.delete(normalizedCallId);
    }
  }

  async function publishCallState(call) {
    if (!call || typeof call !== "object") {
      return;
    }

    for (const participantId of call.participantIds || []) {
      realtimeHub?.publishToUser(participantId, ({sessionPublicId}) => ({
        type: "call.state.updated",
        call: mapCallRecord(call, {
          viewerUserId: participantId,
          viewerSessionId: sessionPublicId,
        }),
      }));
    }

    if (isCallTerminalForSummary(call)) {
      try {
        await appendCallSummaryMessage(call);
      } catch (error) {
        console.warn(
          "[backend] failed to append call summary message",
          JSON.stringify({
            callId: call.id || null,
            chatId: call.chatId || null,
            message: String(error?.message || error || "unknown_error"),
          }),
        );
      }
      // BUG 2: снимаем входящую уведомку звонка у получателей. Realtime
      // publish выше доходит только до живого WS — у убитого приложения
      // нативная full-screen уведомка зависала бы. Шлём data-пуш
      // call_cancelled/call_ended (через push-gateway) — нативный
      // RodnyaPushService снимет уведомку и, если звонок не принят,
      // выложит «Пропущенный».
      await dispatchCallTerminalSignal(call);
    }
  }

  // BUG 2: терминальный сигнал звонка получателям (НЕ инициатору — у него
  // не было входящей уведомки). data-пуш в фоне (awaitPush:false, как P0):
  // не держит обработчик, и недоступное устройство не тормозит остальных.
  async function dispatchCallTerminalSignal(call) {
    const state = String(call?.state || "").trim();
    const type = state === "ended" ? "call_ended" : "call_cancelled";
    const initiatorId = String(call.initiatorId || "").trim();
    let callerName = "Звонок";
    if (initiatorId) {
      try {
        const initiator = await store.findUserById(initiatorId);
        if (initiator) {
          callerName = displayNameForCallParticipant(initiator);
        }
      } catch (_) {
        // best-effort — без имени покажем дефолтный заголовок
      }
    }
    const recipients = (call.participantIds || [])
      .map((id) => String(id || "").trim())
      .filter((id) => id && id !== initiatorId);
    for (const recipientId of recipients) {
      await createAndDispatchNotification({
        userId: recipientId,
        type,
        title: callerName,
        body: "",
        data: {
          callId: call.id,
          chatId: call.chatId,
          callState: state,
          mediaMode: call.mediaMode,
        },
        // Контрольный сигнал, не элемент списка уведомлений.
        silent: true,
        awaitPush: false,
      });
    }
  }

  function isCallTerminalForSummary(call) {
    const state = String(call?.state || "").trim();
    return (
      state === "ended" ||
      state === "rejected" ||
      state === "cancelled" ||
      state === "missed" ||
      state === "failed"
    );
  }

  function describeCallSummaryText(call) {
    const isVideo = call?.mediaMode === "video";
    const kindLabel = isVideo ? "Видеозвонок" : "Аудиозвонок";
    const state = String(call?.state || "").trim();
    if (state === "ended") {
      const startedAtMs = call.acceptedAt
        ? new Date(call.acceptedAt).getTime()
        : null;
      const endedAtMs = call.endedAt
        ? new Date(call.endedAt).getTime()
        : null;
      const durationMs =
        Number.isFinite(startedAtMs) && Number.isFinite(endedAtMs)
          ? Math.max(0, endedAtMs - startedAtMs)
          : null;
      const formatted = formatCallDurationLabel(durationMs);
      return formatted ? `📞 ${kindLabel} · ${formatted}` : `📞 ${kindLabel}`;
    }
    if (state === "missed") {
      return isVideo ? "📞 Пропущенный видеозвонок" : "📞 Пропущенный звонок";
    }
    if (state === "rejected") {
      return isVideo ? "📞 Видеозвонок отклонён" : "📞 Звонок отклонён";
    }
    if (state === "cancelled") {
      return isVideo ? "📞 Видеозвонок отменён" : "📞 Звонок отменён";
    }
    if (state === "failed") {
      return "📞 Не удалось позвонить";
    }
    return `📞 ${kindLabel}`;
  }

  function formatCallDurationLabel(durationMs) {
    if (!Number.isFinite(durationMs) || durationMs <= 0) {
      return null;
    }
    const totalSeconds = Math.floor(durationMs / 1000);
    const seconds = totalSeconds % 60;
    const totalMinutes = Math.floor(totalSeconds / 60);
    const minutes = totalMinutes % 60;
    const hours = Math.floor(totalMinutes / 60);
    const padded = (value) => String(value).padStart(2, "0");
    if (hours > 0) {
      return `${hours}:${padded(minutes)}:${padded(seconds)}`;
    }
    return `${minutes}:${padded(seconds)}`;
  }

  async function appendCallSummaryMessage(call) {
    if (!call || !call.chatId || !call.initiatorId) {
      return;
    }
    if (typeof store.findChat === "function") {
      const chat = await store.findChat(call.chatId);
      if (!chat) {
        return;
      }
    }

    const startedAtMs = call.acceptedAt
      ? new Date(call.acceptedAt).getTime()
      : null;
    const endedAtMs = call.endedAt
      ? new Date(call.endedAt).getTime()
      : null;
    const durationMs =
      Number.isFinite(startedAtMs) && Number.isFinite(endedAtMs)
        ? Math.max(0, endedAtMs - startedAtMs)
        : null;

    const message = await store.addChatMessage({
      chatId: call.chatId,
      senderId: call.initiatorId,
      text: describeCallSummaryText(call),
      attachments: [],
      mediaUrls: [],
      imageUrl: null,
      clientMessageId: `call_summary_${call.id}`,
      replyTo: null,
      call: {
        callId: call.id,
        state: call.state,
        mediaMode: call.mediaMode,
        durationMs,
        initiatorId: call.initiatorId,
        direction: "outgoing",
      },
    });

    if (!message || message._deduplicated === true) {
      return;
    }

    const chat =
      typeof store.findChat === "function"
        ? await store.findChat(call.chatId)
        : null;
    const mappedMessage = mapChatMessage(message);
    const mappedChat = chat ? mapChatRecord(chat) : null;

    if (typeof realtimeHub?.publishToChat === "function") {
      await realtimeHub.publishToChat(message.chatId, {
        type: "chat.updated",
        chatId: message.chatId,
        chat: mappedChat,
      });
      await realtimeHub.publishToChat(message.chatId, {
        type: "chat.message.created",
        chatId: message.chatId,
        chat: mappedChat,
        message: mappedMessage,
      });
    } else if (chat && Array.isArray(chat.participantIds)) {
      for (const participantId of chat.participantIds) {
        realtimeHub?.publishToUser(participantId, {
          type: "chat.updated",
          chatId: message.chatId,
          chat: mappedChat,
        });
        realtimeHub?.publishToUser(participantId, {
          type: "chat.message.created",
          chatId: message.chatId,
          chat: mappedChat,
          message: mappedMessage,
        });
      }
    }
  }

  function scheduleCallInviteTimeout(call) {
    if (
      !call ||
      typeof call !== "object" ||
      call.state !== "ringing" ||
      callInviteTimeoutMs <= 0
    ) {
      return;
    }

    clearCallInviteTimeout(call.id);
    const createdAtMs = new Date(call.createdAt || 0).getTime();
    const elapsedMs = Number.isFinite(createdAtMs)
      ? Math.max(0, Date.now() - createdAtMs)
      : 0;
    const delayMs = Math.max(250, callInviteTimeoutMs - elapsedMs);
    const timer = setTimeout(async () => {
      ringTimeoutTimers.delete(call.id);
      try {
        const expiredCall =
          typeof store.markCallMissed === "function"
            ? await store.markCallMissed({
                callId: call.id,
                reason: "missed",
              })
            : null;
        if (!expiredCall) {
          return;
        }
        logCallEvent("invite.missed", expiredCall, {
          timeoutMs: callInviteTimeoutMs,
        });
        await publishCallState(expiredCall);
      } catch (error) {
        console.error(
          "[backend] call timeout",
          JSON.stringify({
            callId: call.id || null,
            message: String(error?.message || error || "unknown_error"),
          }),
        );
      }
    }, delayMs);
    if (typeof timer?.unref === "function") {
      timer.unref();
    }
    ringTimeoutTimers.set(call.id, timer);
  }

  function isCallInviteExpired(call) {
    if (
      !call ||
      typeof call !== "object" ||
      call.state !== "ringing" ||
      callInviteTimeoutMs <= 0
    ) {
      return false;
    }

    const createdAtMs = new Date(call.createdAt || 0).getTime();
    if (!Number.isFinite(createdAtMs) || createdAtMs <= 0) {
      return false;
    }
    return Date.now() - createdAtMs >= callInviteTimeoutMs;
  }

  async function expireRingingCallIfNeeded(call, {
    reason = "missed",
    eventType = "invite.missed",
    extra = {},
  } = {}) {
    if (!isCallInviteExpired(call)) {
      return call;
    }

    const expiredCall =
      typeof store.markCallMissed === "function"
        ? await store.markCallMissed({
            callId: call.id,
            reason,
          })
        : null;
    if (!expiredCall) {
      return store.findCall(call.id);
    }
    if (expiredCall.state === "ringing") {
      return expiredCall;
    }

    clearCallInviteTimeout(expiredCall.id);
    logCallEvent(eventType, expiredCall, {
      timeoutMs: callInviteTimeoutMs,
      lazyExpired: true,
      ...extra,
    });
    await publishCallState(expiredCall);
    return expiredCall;
  }

  async function findFreshCall(callId, {viewerUserId = null} = {}) {
    const call = await store.findCall(callId);
    if (!call) {
      return null;
    }
    const expiredCall = await expireRingingCallIfNeeded(call, {
      reason: "missed",
      eventType: "invite.missed",
      extra: {
        viewerUserId,
        source: "find_call",
      },
    });
    return expiredCall || call;
  }

  async function findFreshActiveCall({userId, chatId = null} = {}) {
    const activeCall = await store.findActiveCall({userId, chatId});
    if (!activeCall) {
      return null;
    }
    const expiredCall = await expireRingingCallIfNeeded(activeCall, {
      reason: "missed",
      eventType: "invite.missed",
      extra: {
        viewerUserId: userId,
        chatId: chatId || activeCall.chatId,
        source: "find_active_call",
      },
    });
    if (!expiredCall || expiredCall.state === "ringing") {
      return expiredCall || activeCall;
    }
    return store.findActiveCall({userId, chatId});
  }

  async function reconcileUserBusyCall(userId, {chatId = null} = {}) {
    const busyCall = await store.findActiveCall({userId, chatId});
    if (!busyCall) {
      return null;
    }
    const expiredCall = await expireRingingCallIfNeeded(busyCall, {
      reason: "missed",
      eventType: "invite.missed",
      extra: {
        viewerUserId: userId,
        chatId: chatId || busyCall.chatId,
        source: "pre_invite_reconcile",
      },
    });
    return expiredCall || busyCall;
  }

  async function restoreRingingCallTimeouts() {
    if (typeof store.listRingingCalls !== "function") {
      return;
    }
    try {
      const ringingCalls = await store.listRingingCalls();
      for (const call of ringingCalls) {
        scheduleCallInviteTimeout(call);
      }
    } catch (error) {
      console.error(
        "[backend] restore ringing calls",
        JSON.stringify({
          message: String(error?.message || error || "unknown_error"),
        }),
      );
    }
  }

  void restoreRingingCallTimeouts();

  function scheduleSessionTouch(res, token, {requestId, userId} = {}) {
    if (typeof store?.touchSession !== "function") {
      return;
    }

    let started = false;
    const runTouch = () => {
      if (started) {
        return;
      }
      started = true;
      void Promise.resolve()
        .then(() => store.touchSession(token))
        .catch((error) => {
          console.warn(
            "[backend] touch session failed",
            JSON.stringify({
              requestId: requestId || null,
              userId: userId || null,
              message: String(error?.message || error || "unknown_error"),
            }),
          );
        });
    };

    res.once("finish", runTouch);
    res.once("close", runTouch);
  }

  app.set("trust proxy", true);
  app.use(cors({origin: config.corsOrigin}));
  app.use((req, res, next) => {
    const forwardedRequestId = String(req.get("x-request-id") || "").trim();
    req.requestId = forwardedRequestId || crypto.randomUUID();
    req.startedAt = Date.now();
    res.setHeader("x-request-id", req.requestId);
    // Authed API responses must never be cached by any upstream (proxy / CDN /
    // browser). Without this, a shared cache could serve a stale GET /v1/chats
    // — the suspected cause of a group's updated photoUrl missing from the chat
    // list while the details endpoint returned it fresh. The backend serves
    // only dynamic, per-user API data, so a blanket no-store is safe.
    res.setHeader("Cache-Control", "no-store");
    if (normalizedRuntimeInfo.releaseLabel) {
      res.setHeader("x-rodnya-release", normalizedRuntimeInfo.releaseLabel);
    }
    next();
  });
  app.use((req, res, next) => {
    const pathName = req.path || req.originalUrl || "/";
    if (pathName === "/health" || pathName === "/ready") {
      next();
      return;
    }

    const startedAt = Date.now();
    res.on("finish", () => {
      const durationMs = Date.now() - startedAt;
      // S1: медленные ответы (>500ms) — warning с маршрутом, чтобы
      // «быстро» было числом, а не мнением.
      const isSlow = durationMs >= 500;
      const shouldLog =
        res.statusCode >= 400 ||
        req.method !== "GET" ||
        isSlow ||
        pathName.startsWith("/v1/admin/");
      if (!shouldLog) {
        return;
      }

      const payload = JSON.stringify({
        requestId: req.requestId,
        method: req.method,
        path: pathName,
        statusCode: res.statusCode,
        durationMs,
        ip: req.ip,
      });
      if (isSlow) {
        console.warn("[backend] slow-request", payload);
        return;
      }
      console.log("[backend] request", payload);
    });
    next();
  });
  app.post(
    "/v1/livekit/webhook",
    express.text({type: "*/*"}),
    async (req, res) => {
      try {
        const authHeader =
          String(req.get("Authorization") || "").trim() ||
          String(req.get("Authorize") || "").trim() ||
          String(req.get("x-livekit-signature") || "").trim();
        const body =
          typeof req.body === "string" ? req.body : JSON.stringify(req.body || {});
        const event = await resolvedLiveKitService.receiveWebhook(body, authHeader);
        const roomName = String(event?.room?.name || event?.room?.sid || "").trim();
        const participantIdentity = String(
          event?.participant?.identity || "",
        ).trim();
        const call = await store.applyCallWebhook({
          roomName,
          event: event?.event,
          participantIdentity,
        });
        if (call) {
          if (call.state === "ringing") {
            scheduleCallInviteTimeout(call);
          } else {
            clearCallInviteTimeout(call.id);
          }
          logCallEvent("webhook.processed", call, {
            webhookEvent: String(event?.event || "").trim() || null,
            participantIdentity: participantIdentity || null,
            roomName: roomName || null,
          });
          await publishCallState(call);
        }
        res.json({ok: true});
      } catch (error) {
        res.status(401).json({message: "Webhook verification failed"});
      }
    },
  );
  // Some legacy/mobile clients still send JSON literal `null` on bodyless POSTs
  // such as like/view/read actions. Accept it and let handlers validate fields.
  // Бинарный PUT /v1/media/object обязан пройти МИМО json-парсера при
  // любом Content-Type: иначе application/json-тело перехватывается здесь
  // (до requireAuth и rate-limit), а SyntaxError улетает в глобальный
  // error-handler — 500 без токена и «Пустое тело» для легитимного клиента
  // с кривым заголовком (ревью бинарной загрузки, P1).
  const jsonBodyParser = express.json({limit: "50mb", strict: false});
  app.use((req, res, next) => {
    if (req.path.replace(/\/+$/, "") === "/v1/media/object") {
      next();
      return;
    }
    jsonBodyParser(req, res, next);
  });
  registerPublicMediaRoutes(app, {mediaStorage: resolvedMediaStorage});
  // U1: публичный эндпоинт версии для OTA-апдейтера sideload-сборок.
  registerAppUpdateRoutes(app, {config});
  // async because the rate-limit backend's `incr` returns a Promise
  // (mandatory for the Redis-backed implementation; the in-memory
  // default still resolves synchronously). Express forwards thrown
  // errors when the middleware function is `async`, so any rejection
  // is converted into a 500 by the global error handler — except we
  // catch internally and fail-open above.
  app.use(async (req, res, next) => {
    const policy = (() => {
      const pathName = req.path || "/";
      // Express матчит роуты нестрого: /v1/media/object/ попадает в тот же
      // хендлер, но строгие === в политике его не видели — запрос уезжал в
      // щедрый mutation-бакет мимо upload-лимита (ревью, P2).
      const normalizedPathName = pathName.replace(/\/+$/, "") || "/";
      if (pathName === "/health" || pathName === "/ready") {
        return null;
      }
      if (pathName.startsWith("/media/")) {
        return null;
      }
      if (pathName.startsWith("/storage/")) {
        return null;
      }
      if (
        pathName === "/v1/auth/login" ||
        pathName === "/v1/auth/register" ||
        pathName === "/v1/auth/password-reset" ||
        pathName === "/v1/auth/refresh" ||
        pathName === "/v1/auth/qr/start" ||
        pathName === "/v1/auth/qr/approve" ||
        pathName === "/v1/auth/qr/poll" ||
        // OAuth code-exchange endpoints — same brute-force surface as
        // /login. An attacker who steals a one-time auth code via a
        // sniffed SMS or phishing link can replay-attempt at the
        // exchange route without ever hitting /login, so they need to
        // sit in the same strict bucket.
        pathName === "/v1/auth/google" ||
        pathName === "/v1/auth/vk/exchange" ||
        pathName === "/v1/auth/telegram/exchange" ||
        pathName === "/v1/auth/max/exchange"
      ) {
        return {bucket: "auth", limit: config.authRateLimitMax};
      }
      if (
        normalizedPathName === "/v1/media/upload" ||
        normalizedPathName === "/v1/media/object"
      ) {
        return {bucket: "upload", limit: config.uploadRateLimitMax};
      }
      if (pathName === "/v1/reports" || pathName.startsWith("/v1/blocks")) {
        return {bucket: "safety", limit: config.safetyRateLimitMax};
      }
      if (!["GET", "HEAD", "OPTIONS"].includes(req.method)) {
        return {bucket: "mutation", limit: config.mutationRateLimitMax};
      }
      return {bucket: "default", limit: config.defaultRateLimitMax};
    })();

    if (!policy || !Number.isFinite(policy.limit) || policy.limit <= 0) {
      next();
      return;
    }

    const now = Date.now();
    const windowMs = Number.isFinite(config.rateLimitWindowMs) &&
        config.rateLimitWindowMs > 0
      ? config.rateLimitWindowMs
      : 60_000;
    const actorId = String(req.ip || "unknown").trim() || "unknown";
    const key = `${policy.bucket}:${actorId}`;

    let activeBucket;
    try {
      activeBucket = await resolvedRateLimitBackend.incr(key, windowMs);
    } catch (error) {
      // Backend hiccup (e.g. Redis blip in a future scaled-out
      // deploy) — fail OPEN so we don't 503 every request when the
      // limiter is unavailable. The trade-off is documented:
      // attacker can briefly burst during the outage, which is a
      // better failure mode than denying every legitimate request.
      console.error(
        "[backend] rate-limit backend failure — failing open",
        JSON.stringify({requestId: req.requestId, message: error?.message}),
      );
      next();
      return;
    }

    // Periodic GC sweep — only the in-memory backend exposes the
    // sweepExpired hook. Redis-backed buckets self-expire via TTL.
    if (
      typeof resolvedRateLimitBackend.sweepExpired === "function" &&
      Math.random() < 0.01 &&
      resolvedRateLimitBackend.size > 2000
    ) {
      resolvedRateLimitBackend.sweepExpired(now);
    }

    res.setHeader("x-ratelimit-limit", String(policy.limit));
    res.setHeader(
      "x-ratelimit-remaining",
      String(Math.max(0, policy.limit - activeBucket.count)),
    );
    res.setHeader(
      "x-ratelimit-reset",
      String(Math.ceil(activeBucket.resetAt / 1000)),
    );

    if (activeBucket.count > policy.limit) {
      const retryAfterSeconds = Math.max(
        1,
        Math.ceil((activeBucket.resetAt - now) / 1000),
      );
      res.setHeader("retry-after", String(retryAfterSeconds));
      res.status(429).json({
        message: "Слишком много запросов. Повторите попытку позже.",
        requestId: req.requestId,
      });
      return;
    }

    next();
  });

  app.get("/health", async (req, res) => {
    res.json(
      buildStatusPayload("ok", {
        requestId: req.requestId,
      }),
    );
  });

  app.get("/ready", async (req, res) => {
    try {
      await ensureReady();
      res.json(
        buildStatusPayload("ready", {
          requestId: req.requestId,
        }),
      );
    } catch (error) {
      res.status(503).json({
        ...buildStatusPayload("not_ready", {
          requestId: req.requestId,
          ready: false,
          message: "Backend storage paths are not accessible",
        }),
        errorCode: String(error?.code || error?.message || "NOT_READY"),
      });
    }
  });

  async function requirePublicTree(req, res, publicTreeId) {
    const tree = await store.findPublicTreeByRouteId(publicTreeId);
    if (!tree) {
      res.status(404).json({message: "Публичное дерево не найдено"});
      return null;
    }
    return tree;
  }

  function readClientInstanceId(req) {
    const raw = req.headers?.["x-client-instance-id"];
    if (Array.isArray(raw)) {
      return String(raw[0] || "").trim();
    }
    return String(raw || "").trim();
  }

  function readDeviceContext(req) {
    const deviceInfoFromBody =
      req?.body && typeof req.body === "object" && req.body.deviceInfo
        ? req.body.deviceInfo
        : {};
    const deviceInfoFromQuery =
      req?.query && typeof req.query === "object" ? req.query : {};

    function pickString(...candidates) {
      for (const candidate of candidates) {
        if (typeof candidate === "string" && candidate.trim()) {
          return candidate.trim();
        }
      }
      return null;
    }

    return {
      // Header takes priority (set by the Flutter HTTP client). For OAuth
      // start endpoints — which are loaded by an in-app browser, not the
      // Flutter HTTP client — fall back to a query param so the start URL
      // can carry the instance id forward into the callback's handoff.
      instanceId:
        readClientInstanceId(req) ||
        pickString(deviceInfoFromQuery.instanceId, deviceInfoFromQuery.instance_id),
      deviceName: pickString(
        deviceInfoFromBody.deviceName,
        deviceInfoFromQuery.deviceName,
        deviceInfoFromQuery.device_name,
      ),
      platform: pickString(
        deviceInfoFromBody.platform,
        deviceInfoFromQuery.platform,
      ),
      appVersion: pickString(
        deviceInfoFromBody.appVersion,
        deviceInfoFromQuery.appVersion,
        deviceInfoFromQuery.app_version,
      ),
    };
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

    req.auth = {
      token,
      session,
      user,
      sessionPublicId: deriveSessionPublicId(
        token,
        readClientInstanceId(req),
      ),
    };
    scheduleSessionTouch(res, token, {
      requestId: req.requestId,
      userId: user.id,
    });
    next();
  }

  function requireOwnUser(req, res) {
    if (req.params.userId !== req.auth.user.id) {
      res.status(403).json({message: "Доступ к чужим данным запрещен"});
      return false;
    }
    return true;
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
      kind: tree.kind === "friends" ? "friends" : "family",
      publicSlug: tree.publicSlug || null,
      isCertified: tree.isCertified === true,
      certificationNote: tree.certificationNote || null,
    };
  }

  function mapPerson(person) {
    const familySummary =
      person.familySummary || person.notes || person.bio || null;
    return {
      id: person.id,
      treeId: person.treeId,
      userId: person.userId,
      identityId: person.identityId || null,
      name: person.name,
      maidenName: person.maidenName,
      photoUrl: normalizePublicUrl(person.photoUrl),
      primaryPhotoUrl: normalizePublicUrl(
        person.primaryPhotoUrl || person.photoUrl || null,
      ),
      photoGallery: Array.isArray(person.photoGallery)
        ? person.photoGallery.map((entry) => ({
            id: entry.id,
            url: normalizePublicUrl(entry.url),
            thumbnailUrl: normalizePublicUrl(entry.thumbnailUrl || null),
            type: entry.type || "image",
            contentType: entry.contentType || null,
            caption: entry.caption || null,
            createdAt: entry.createdAt || null,
            updatedAt: entry.updatedAt || null,
            isPrimary: entry.isPrimary === true,
          }))
        : [],
      gender: person.gender,
      birthDate: person.birthDate,
      // F5: «знаю только год» — клиент по флагу прячет фейковое 1 января.
      birthDatePrecision: person.birthDatePrecision || "exact",
      birthPlace: person.birthPlace,
      deathDate: person.deathDate,
      deathDatePrecision: person.deathDatePrecision || "exact",
      deathPlace: person.deathPlace,
      familySummary,
      bio: familySummary,
      isAlive: person.isAlive !== false,
      visibility: person.visibility || (person.isAlive === false ? "tree" : "private"),
      creatorId: person.creatorId,
      createdAt: person.createdAt,
      updatedAt: person.updatedAt,
      notes: familySummary,
      details: person.details || null,
    };
  }

  function mapProfileContribution(contribution) {
    const fields =
      contribution?.fields && typeof contribution.fields === "object"
        ? contribution.fields
        : {};
    return {
      id: contribution.id,
      treeId: contribution.treeId,
      personId: contribution.personId,
      targetUserId: contribution.targetUserId,
      authorUserId: contribution.authorUserId || null,
      authorDisplayName: contribution.authorDisplayName || null,
      authorPhotoUrl: normalizePublicUrl(contribution.authorPhotoUrl || null),
      message: contribution.message || null,
      fields,
      status: contribution.status || "pending",
      createdAt: contribution.createdAt || null,
      updatedAt: contribution.updatedAt || null,
      respondedAt: contribution.respondedAt || null,
      responderUserId: contribution.responderUserId || null,
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
      marriageDate: relation.marriageDate || null,
      divorceDate: relation.divorceDate || null,
      customRelationLabel1to2: relation.customRelationLabel1to2 || null,
      customRelationLabel2to1: relation.customRelationLabel2to1 || null,
      parentSetId: relation.parentSetId || null,
      parentSetType: relation.parentSetType || null,
      isPrimaryParentSet:
        typeof relation.isPrimaryParentSet === "boolean"
          ? relation.isPrimaryParentSet
          : null,
      unionId: relation.unionId || null,
      unionType: relation.unionType || null,
      unionStatus: relation.unionStatus || null,
    };
  }

  function mapTreeGraphSnapshot(snapshot) {
    return {
      treeId: snapshot.treeId,
      viewerPersonId: snapshot.viewerPersonId || null,
      people: Array.isArray(snapshot.people) ? snapshot.people.map(mapPerson) : [],
      relations: Array.isArray(snapshot.relations)
        ? snapshot.relations.map(mapRelation)
        : [],
      familyUnits: Array.isArray(snapshot.familyUnits)
        ? snapshot.familyUnits.map((unit) => ({
            id: unit.id,
            rootParentSetId: unit.rootParentSetId || null,
            adultIds: Array.isArray(unit.adultIds) ? unit.adultIds : [],
            childIds: Array.isArray(unit.childIds) ? unit.childIds : [],
            relationIds: Array.isArray(unit.relationIds) ? unit.relationIds : [],
            unionId: unit.unionId || null,
            unionType: unit.unionType || null,
            unionStatus: unit.unionStatus || null,
            parentSetType: unit.parentSetType || null,
            isPrimaryParentSet: unit.isPrimaryParentSet === true,
            label: unit.label || "Семья",
          }))
        : [],
      viewerDescriptors: Array.isArray(snapshot.viewerDescriptors)
        ? snapshot.viewerDescriptors.map((descriptor) => ({
            personId: descriptor.personId,
            primaryRelationLabel: descriptor.primaryRelationLabel || null,
            isBlood: descriptor.isBlood === true,
            alternatePathCount: Number(descriptor.alternatePathCount || 0),
            pathSummary: descriptor.pathSummary || null,
            primaryPathPersonIds: Array.isArray(descriptor.primaryPathPersonIds)
              ? descriptor.primaryPathPersonIds
              : [],
          }))
        : [],
      branchBlocks: Array.isArray(snapshot.branchBlocks)
        ? snapshot.branchBlocks.map((branchBlock) => ({
            id: branchBlock.id,
            rootUnitId: branchBlock.rootUnitId,
            label: branchBlock.label || "Семья",
            memberPersonIds: Array.isArray(branchBlock.memberPersonIds)
              ? branchBlock.memberPersonIds
              : [],
          }))
        : [],
      generationRows: Array.isArray(snapshot.generationRows)
        ? snapshot.generationRows.map((row) => ({
            row: Number(row.row || 0),
            label: row.label || null,
            personIds: Array.isArray(row.personIds) ? row.personIds : [],
            familyUnitIds: Array.isArray(row.familyUnitIds) ? row.familyUnitIds : [],
          }))
        : [],
      warnings: Array.isArray(snapshot.warnings)
        ? snapshot.warnings.map((warning) => ({
            id: warning.id,
            code: warning.code || "graph_warning",
            severity: warning.severity || "warning",
            message: warning.message || "Дерево требует проверки.",
            hint: warning.hint || null,
            personIds: Array.isArray(warning.personIds) ? warning.personIds : [],
            familyUnitIds: Array.isArray(warning.familyUnitIds)
              ? warning.familyUnitIds
              : [],
            relationIds: Array.isArray(warning.relationIds) ? warning.relationIds : [],
          }))
        : [],
    };
  }

  function mapTreeChangeRecord(record) {
    return {
      id: record.id,
      treeId: record.treeId,
      actorId: record.actorId || null,
      type: record.type,
      personId: record.personId || null,
      personIds: Array.isArray(record.personIds) ? record.personIds : [],
      relationId: record.relationId || null,
      mediaId: record.mediaId || null,
      createdAt: record.createdAt,
      details:
        record.details && typeof record.details === "object"
          ? record.details
          : {},
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

  function truncateText(value, maxLength = 280) {
    if (value === null || value === undefined) {
      return null;
    }
    const rawText =
      typeof value === "string"
        ? value
        : typeof value === "number" || typeof value === "boolean"
          ? String(value)
          : "";
    if (!rawText) {
      return null;
    }
    const sampledText =
      rawText.length > maxLength * 4
        ? rawText.slice(0, maxLength * 4)
        : rawText;
    const text = sampledText.trim();
    if (!text) {
      return null;
    }
    if (text.length <= maxLength) {
      return text;
    }
    return `${text.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
  }

  function normalizeSmallPublicUrl(value) {
    if (value === null || value === undefined) {
      return null;
    }
    const rawValue = typeof value === "string" ? value : "";
    if (!rawValue || rawValue.length > 4096) {
      return null;
    }
    const normalizedValue = rawValue.trim();
    if (!normalizedValue || normalizedValue.length > 2048) {
      return null;
    }
    return normalizePublicUrl(normalizedValue);
  }

  function sanitizeNotificationData(data) {
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      return {};
    }

    const allowedKeys = [
      "invitationId",
      "treeId",
      "treeName",
      "invitedBy",
      "memberUserId",
      "requestId",
      "senderId",
      "recipientId",
      "relationType",
      "status",
      "chatId",
      "chatType",
      "chatTitle",
      "senderName",
      "messageId",
      "callId",
      "mediaMode",
      // Post / comment / story reaction notifications carry the
      // target id, the actor that reacted, and the emoji so the
      // client can deep-link to the right surface and render the
      // right glyph in the inbox.
      "postId",
      "commentId",
      "storyId",
      "actorUserId",
      "emoji",
      // Threaded comment replies carry the parent + reply ids so the
      // notifications screen can deep-link straight to the relevant
      // comment thread.
      "parentCommentId",
      "replyCommentId",
      // Post-creation fan-out (audience-mode): the author id powers
      // the avatar / display name on the notification card; the
      // branchIds tell the client which slice of the user's
      // audience the post was published into so the inbox can
      // render an «в Семья Кузнецовых» badge.
      "authorId",
    ];

    // Array-valued data fields. Sanitized member-by-member as
    // strings; anything non-string in the array is dropped so a
    // forged client can't sneak object payloads through.
    const allowedStringArrayKeys = [
      "branchIds",
    ];

    const sanitized = {};
    for (const key of allowedKeys) {
      if (!(key in data)) {
        continue;
      }
      const value = data[key];
      if (value == null) {
        sanitized[key] = null;
        continue;
      }
      if (
        typeof value === "string" ||
        typeof value === "number" ||
        typeof value === "boolean"
      ) {
        sanitized[key] =
          typeof value === "string" ? truncateText(value, 280) || "" : value;
      }
    }
    for (const key of allowedStringArrayKeys) {
      if (!(key in data)) continue;
      const value = data[key];
      if (!Array.isArray(value)) continue;
      sanitized[key] = value
        .filter((entry) => typeof entry === "string")
        .map((entry) => truncateText(entry, 280) || "")
        .filter((entry) => entry.length > 0);
    }

    return sanitized;
  }

  function mapNotification(notification) {
    return {
      id: notification.id,
      userId: notification.userId,
      type: notification.type,
      title: truncateText(notification.title, 160),
      body: truncateText(notification.body, 280),
      data: sanitizeNotificationData(notification.data),
      // Phase 6.5+ silent flag — clients filter on display path.
      silent: notification.silent === true,
      createdAt: notification.createdAt,
      readAt: notification.readAt || null,
      isRead: Boolean(notification.readAt),
    };
  }

  function resolveUserDisplayName(user) {
    if (!user) {
      return "Пользователь";
    }

    return composeDisplayName(user.profile) ||
      sanitizeProfile(user.profile).displayName ||
      user.email ||
      "Пользователь";
  }

  function mapBlock(block, blockedUser = null) {
    return {
      id: block.id,
      blockerId: block.blockerId,
      blockedUserId: block.blockedUserId,
      blockedUserDisplayName: resolveUserDisplayName(blockedUser),
      blockedUserPhotoUrl: sanitizeProfile(blockedUser?.profile).photoUrl || null,
      reason: block.reason || null,
      metadata: block.metadata || {},
      createdAt: block.createdAt,
      updatedAt: block.updatedAt,
    };
  }

  function mapReport(report, reporter = null) {
    return {
      id: report.id,
      reporterId: report.reporterId,
      reporterDisplayName: resolveUserDisplayName(reporter),
      targetType: report.targetType,
      targetId: report.targetId,
      reason: report.reason,
      details: report.details || null,
      metadata: report.metadata || {},
      status: report.status || "pending",
      resolutionNote: report.resolutionNote || null,
      resolvedAt: report.resolvedAt || null,
      resolvedBy: report.resolvedBy || null,
      createdAt: report.createdAt,
      updatedAt: report.updatedAt,
    };
  }

  function mapPushDevice(device) {
    return {
      id: device.id,
      userId: device.userId,
      provider: device.provider,
      platform: device.platform,
      sessionPublicId: device.sessionPublicId || null,
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

  function mapPost(post, commentCount = 0) {
    // Phase 3.4: surface branchIds so the Flutter feed can render
    // the "this post was published to N branches" affordance and
    // group/dedup posts visible to the user via more than one
    // branch. Always derive a non-empty list — fall back to
    // [treeId] for posts created before the field existed.
    const branchIds = Array.isArray(post.branchIds) && post.branchIds.length > 0
      ? post.branchIds
      : (post.treeId ? [post.treeId] : []);
    return {
      id: post.id,
      treeId: post.treeId,
      branchIds,
      authorId: post.authorId,
      authorName: post.authorName || "Аноним",
      authorPhotoUrl: normalizePublicUrl(post.authorPhotoUrl || null),
      content: post.content || "",
      imageUrls: normalizePublicUrlList(post.imageUrls),
      createdAt: post.createdAt,
      likedBy: Array.isArray(post.likedBy) ? post.likedBy : [],
      commentCount: Number(commentCount || 0),
      isPublic: post.isPublic === true,
      scopeType: post.scopeType === "branches" ? "branches" : "wholeTree",
      circleId: post.circleId || null,
      anchorPersonIds: Array.isArray(post.anchorPersonIds)
        ? post.anchorPersonIds
        : [],
      reactions: Array.isArray(post.reactions) ? post.reactions : [],
    };
  }

  // Phase E1: serialize a Gathering for the API. Mirrors mapPost (branch
  // fallback, public-url normalization, Array.isArray guards) plus the
  // event-specific fields.
  function mapGathering(gathering) {
    const branchIds =
      Array.isArray(gathering.branchIds) && gathering.branchIds.length > 0
        ? gathering.branchIds
        : (gathering.treeId ? [gathering.treeId] : []);
    return {
      id: gathering.id,
      treeId: gathering.treeId,
      branchIds,
      authorId: gathering.authorId,
      authorName: gathering.authorName || "Аноним",
      authorPhotoUrl: normalizePublicUrl(gathering.authorPhotoUrl || null),
      title: gathering.title || "",
      description: gathering.description || null,
      startAt: gathering.startAt || null,
      endAt: gathering.endAt || null,
      isAllDay: gathering.isAllDay === true,
      place: gathering.place || null,
      imageUrls: normalizePublicUrlList(gathering.imageUrls),
      scopeType: gathering.scopeType === "branches" ? "branches" : "wholeTree",
      circleId: gathering.circleId || null,
      anchorPersonIds: Array.isArray(gathering.anchorPersonIds)
        ? gathering.anchorPersonIds
        : [],
      rsvps: Array.isArray(gathering.rsvps) ? gathering.rsvps : [],
      createdAt: gathering.createdAt,
      updatedAt: gathering.updatedAt,
    };
  }

  // Phase E4: serialize a Poll. Mirrors mapGathering (branch fallback,
  // public-url normalization) plus poll-specific fields. options +
  // responses are returned as-is (public tallies, not anonymous).
  function mapPoll(poll) {
    const branchIds =
      Array.isArray(poll.branchIds) && poll.branchIds.length > 0
        ? poll.branchIds
        : (poll.treeId ? [poll.treeId] : []);
    return {
      id: poll.id,
      treeId: poll.treeId,
      branchIds,
      authorId: poll.authorId,
      authorName: poll.authorName || "Аноним",
      authorPhotoUrl: normalizePublicUrl(poll.authorPhotoUrl || null),
      question: poll.question || "",
      options: Array.isArray(poll.options) ? poll.options : [],
      allowMultiple: poll.allowMultiple === true,
      closesAt: poll.closesAt || null,
      imageUrls: normalizePublicUrlList(poll.imageUrls),
      scopeType: poll.scopeType === "branches" ? "branches" : "wholeTree",
      circleId: poll.circleId || null,
      anchorPersonIds: Array.isArray(poll.anchorPersonIds)
        ? poll.anchorPersonIds
        : [],
      responses: Array.isArray(poll.responses) ? poll.responses : [],
      createdAt: poll.createdAt,
      updatedAt: poll.updatedAt,
    };
  }

  function mapStory(story) {
    return {
      id: story.id,
      treeId: story.treeId,
      authorId: story.authorId,
      authorName: story.authorName || "Аноним",
      authorPhotoUrl: normalizePublicUrl(story.authorPhotoUrl || null),
      type: story.type || "text",
      text: story.text || null,
      mediaUrl: normalizePublicUrl(story.mediaUrl || null),
      thumbnailUrl: normalizePublicUrl(story.thumbnailUrl || null),
      createdAt: story.createdAt,
      updatedAt: story.updatedAt || story.createdAt,
      expiresAt: story.expiresAt,
      viewedBy: Array.isArray(story.viewedBy) ? story.viewedBy : [],
      circleId: story.circleId || null,
      scopeType: story.scopeType === "branches" ? "branches" : "wholeTree",
      anchorPersonIds: Array.isArray(story.anchorPersonIds)
        ? story.anchorPersonIds
        : [],
      reactions: Array.isArray(story.reactions) ? story.reactions : [],
    };
  }

  function mapComment(comment) {
    const likedBy = Array.isArray(comment.likedBy) ? comment.likedBy : [];
    const parentCommentId =
      comment.parentCommentId === undefined || comment.parentCommentId === null
        ? null
        : String(comment.parentCommentId).trim() || null;
    return {
      id: comment.id,
      postId: comment.postId,
      authorId: comment.authorId,
      authorName: comment.authorName || "Аноним",
      authorPhotoUrl: normalizePublicUrl(comment.authorPhotoUrl || null),
      content: comment.content || "",
      createdAt: comment.createdAt,
      likeCount: likedBy.length,
      likedBy,
      reactions: Array.isArray(comment.reactions) ? comment.reactions : [],
      parentCommentId,
    };
  }

  function mapChatMessage(message) {
    const explicitAttachments = Array.isArray(message.attachments)
      ? message.attachments
          .filter((attachment) => String(attachment?.url || "").trim())
          .map((attachment) => ({
            type: String(attachment.type || "file"),
            url: normalizePublicUrl(String(attachment.url || "").trim()),
            presentation: String(attachment.presentation || "default"),
            mimeType: attachment.mimeType || null,
            fileName: attachment.fileName || null,
            sizeBytes: Number.isFinite(Number(attachment.sizeBytes))
              ? Number(attachment.sizeBytes)
              : null,
            durationMs: Number.isFinite(Number(attachment.durationMs))
              ? Number(attachment.durationMs)
              : null,
            waveform: normalizeAttachmentWaveform(attachment.waveform),
            width: Number.isFinite(Number(attachment.width))
              ? Number(attachment.width)
              : null,
            height: Number.isFinite(Number(attachment.height))
              ? Number(attachment.height)
              : null,
            thumbnailUrl: normalizePublicUrl(attachment.thumbnailUrl || null),
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
          url: normalizePublicUrl(url),
          presentation: "default",
          mimeType: "image/jpeg",
          fileName: null,
          sizeBytes: null,
          durationMs: null,
          waveform: [],
          width: null,
          height: null,
          thumbnailUrl: null,
        }));
    const reactions = Array.isArray(message.reactions)
      ? message.reactions
          .map((reaction) => {
            const emoji = String(reaction?.emoji || "").trim();
            const userIds = Array.from(
              new Set(
                (Array.isArray(reaction?.userIds) ? reaction.userIds : [])
                  .map((value) => String(value || "").trim())
                  .filter(Boolean),
              ),
            );
            return {
              emoji,
              userIds,
              count: Number.isFinite(Number(reaction?.count))
                ? Math.max(0, Math.floor(Number(reaction.count)))
                : userIds.length,
            };
          })
          .filter((reaction) => reaction.emoji && reaction.count > 0)
      : [];
    return {
      id: message.id,
      chatId: message.chatId,
      senderId: message.senderId,
      text: message.text,
      timestamp: message.timestamp,
      updatedAt: message.updatedAt || null,
      isRead: message.isRead === true,
      deliveredTo: Array.isArray(message.deliveredTo)
        ? message.deliveredTo
            .map((value) => String(value || "").trim())
            .filter(Boolean)
        : [],
      readBy: Array.isArray(message.readBy)
        ? message.readBy
            .map((value) => String(value || "").trim())
            .filter(Boolean)
        : [],
      attachments,
      imageUrl: normalizePublicUrl(message.imageUrl || null),
      mediaUrls: normalizePublicUrlList(message.mediaUrls),
      participants: Array.isArray(message.participants)
        ? message.participants
        : [],
      senderName: message.senderName,
      clientMessageId: message.clientMessageId || null,
      expiresAt: message.expiresAt || null,
      replyTo: message.replyTo || null,
      reactions,
      call: mapChatMessageCall(message.call),
    };
  }

  function mapChatMessageCall(value) {
    if (!value || typeof value !== "object") {
      return null;
    }
    const callId = String(value.callId || "").trim();
    if (!callId) {
      return null;
    }
    return {
      callId,
      state: String(value.state || "").trim() || "ended",
      mediaMode: String(value.mediaMode || "").trim() === "video"
        ? "video"
        : "audio",
      durationMs: Number.isFinite(Number(value.durationMs))
        ? Math.max(0, Math.floor(Number(value.durationMs)))
        : null,
      initiatorId: value.initiatorId ? String(value.initiatorId).trim() : null,
      direction: value.direction === "incoming" ? "incoming" : "outgoing",
    };
  }

  function mapChatRecord(chat) {
    return {
      id: chat.id,
      type: chat.type || "direct",
      title: chat.title || null,
      photoUrl: normalizeSmallPublicUrl(chat.photoUrl || null),
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

  function mapCallSession(session) {
    if (!session || typeof session !== "object") {
      return null;
    }
    return {
      roomName: String(session.roomName || "").trim(),
      url: String(session.url || "").trim(),
      token: String(session.token || "").trim(),
      participantIdentity: String(session.participantIdentity || "").trim(),
      participantName: session.participantName || null,
      createdAt: session.createdAt || null,
    };
  }

  function mapCallMetrics(metrics) {
    if (!metrics || typeof metrics !== "object") {
      return {
        acceptLatencyMs: null,
        roomJoinFailureCount: 0,
        reconnectCount: 0,
        lastRoomJoinFailureReason: null,
        lastWebhookEvent: null,
      };
    }
    return {
      acceptLatencyMs: Number.isFinite(Number(metrics.acceptLatencyMs))
        ? Math.max(0, Math.floor(Number(metrics.acceptLatencyMs)))
        : null,
      roomJoinFailureCount: Number.isFinite(Number(metrics.roomJoinFailureCount))
        ? Math.max(0, Math.floor(Number(metrics.roomJoinFailureCount)))
        : 0,
      reconnectCount: Number.isFinite(Number(metrics.reconnectCount))
        ? Math.max(0, Math.floor(Number(metrics.reconnectCount)))
        : 0,
      lastRoomJoinFailureReason: metrics.lastRoomJoinFailureReason || null,
      lastWebhookEvent: metrics.lastWebhookEvent || null,
    };
  }

  function logCallEvent(eventType, call, extra = {}) {
    if (!call || typeof call !== "object") {
      return;
    }

    const metrics = mapCallMetrics(call.metrics);
    console.log(
      "[backend] call",
      JSON.stringify({
        eventType,
        callId: call.id || null,
        chatId: call.chatId || null,
        mediaMode: call.mediaMode || null,
        state: call.state || null,
        createdAt: call.createdAt || null,
        acceptedAt: call.acceptedAt || null,
        endedAt: call.endedAt || null,
        endedReason: call.endedReason || null,
        acceptLatencyMs: metrics.acceptLatencyMs,
        roomJoinFailureCount: metrics.roomJoinFailureCount,
        reconnectCount: metrics.reconnectCount,
        lastRoomJoinFailureReason: metrics.lastRoomJoinFailureReason,
        lastWebhookEvent: metrics.lastWebhookEvent,
        ...extra,
      }),
    );
  }

  function ownerSessionIdForViewer(call, viewerUserId) {
    if (!call || !viewerUserId) {
      return "";
    }
    // N-way: any joined participant's device session (group late-join).
    const joinedSessionByUserId =
      call.joinedSessionByUserId && typeof call.joinedSessionByUserId === "object"
        ? call.joinedSessionByUserId
        : {};
    const joinedSessionId = String(
      joinedSessionByUserId[viewerUserId] || "",
    ).trim();
    if (joinedSessionId) {
      return joinedSessionId;
    }
    // The initiator never "joins" via accept — their owning device is the one
    // that originated the call.
    if (call.initiatorId === viewerUserId) {
      return String(call.originatedBySessionId || "").trim();
    }
    // Back-compat: scalar accepter for in-flight records / old clients.
    if (call.acceptedByUserId === viewerUserId) {
      return String(call.acceptedBySessionId || "").trim();
    }
    return "";
  }

  function mapCallRecord(
    call,
    {viewerUserId = null, viewerSessionId = null} = {},
  ) {
    const ownerSessionId = ownerSessionIdForViewer(call, viewerUserId);
    const normalizedViewerSessionId = String(viewerSessionId || "").trim();
    const isOwningDevice =
      Boolean(ownerSessionId) &&
      Boolean(normalizedViewerSessionId) &&
      ownerSessionId === normalizedViewerSessionId;
    const callIsActive = (call.state || "ringing") === "active";
    const otherDeviceJoined =
      callIsActive && Boolean(ownerSessionId) && !isOwningDevice;
    const session =
      isOwningDevice && viewerUserId && call.sessionByUserId
        ? mapCallSession(call.sessionByUserId[viewerUserId])
        : null;
    return {
      id: call.id,
      chatId: call.chatId,
      initiatorId: call.initiatorId,
      recipientId: call.recipientId,
      participantIds: Array.isArray(call.participantIds)
        ? call.participantIds
        : [],
      mediaMode: call.mediaMode || "audio",
      state: call.state || "ringing",
      roomName: call.roomName || null,
      createdAt: call.createdAt,
      updatedAt: call.updatedAt,
      acceptedAt: call.acceptedAt || null,
      endedAt: call.endedAt || null,
      endedReason: call.endedReason || null,
      metrics: mapCallMetrics(call.metrics),
      session,
      joinedOnAnotherDevice: otherDeviceJoined,
    };
  }

  function mapChatParticipant(participant) {
    // `isOnline` reflects the live realtime-hub state at response time —
    // any active socket for this user counts as online. `lastSeenAt`
    // comes from the user record (persisted via markUserSeenAt on socket
    // disconnect). Together they let the chat-screen subtitle render
    // "в сети" / "была N минут назад" on first paint, without needing
    // an extra realtime event before the data shows up.
    const isOnline =
      typeof realtimeHub?.isUserOnline === "function" && participant.userId
        ? realtimeHub.isUserOnline(participant.userId)
        : false;
    return {
      userId: participant.userId,
      displayName: participant.displayName || "Пользователь",
      photoUrl: normalizePublicUrl(participant.photoUrl || null),
      isOnline,
      lastSeenAt: participant.lastSeenAt || null,
    };
  }

  function mapChatBranchRoot(branchRoot) {
    return {
      personId: branchRoot.personId,
      name: branchRoot.name || "Без имени",
      photoUrl: normalizePublicUrl(branchRoot.photoUrl || null),
    };
  }

  function mapChatPreview(preview) {
    const isGroupPreview =
      String(preview?.type || "").trim() === "group" ||
      String(preview?.type || "").trim() === "branch";
    const normalizedParticipantIds = Array.isArray(preview?.participantIds)
      ? preview.participantIds
      : [];
    const previewParticipantIds = isGroupPreview
      ? normalizedParticipantIds.slice(0, 12)
      : normalizedParticipantIds;
    return {
      id: `${preview.chatId}_${preview.userId}`,
      chatId: preview.chatId,
      userId: preview.userId,
      type: preview.type || "direct",
      title: truncateText(preview.title, 160),
      photoUrl: normalizeSmallPublicUrl(preview.photoUrl || null),
      participantIds: previewParticipantIds,
      participantCount: normalizedParticipantIds.length,
      otherUserId: preview.otherUserId,
      otherUserName: truncateText(preview.otherUserName || "Пользователь", 120),
      otherUserPhotoUrl: normalizeSmallPublicUrl(preview.otherUserPhotoUrl || null),
      lastMessage: truncateText(preview.lastMessage || "", 280) || "",
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

    // Phase B Ship 5: если feature flag ON и tree bound к семья —
    // gate via семья membership. Иначе fallback к legacy
    // (creator + tree.memberIds) для backward compat пока migration
    // не накатилась и frontend клиентов не обновили (Week 8 staged
    // rollout). Без этого dual-path existing endpoints ломаются
    // на pre-Phase-B users чьи trees not yet bound.
    if (useSemyaModel && tree.semyaId) {
      const membership = await store.findMembership(tree.semyaId, req.auth.user.id);
      if (!membership) {
        res.status(403).json({message: "Доступ к дереву запрещён"});
        return null;
      }
      // Любая роль (viewer/editor/owner) даёт read access к tree.
      // Granular per-mutation gating — existing
      // requireGraphPersonEdit + tree-routes-specific checks (Ship 6+).
      return tree;
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

  // Phase B (ENTITY-DESIGN §2): unified gate для семья endpoints.
  // requiredRole — minimum role chain: viewer < editor < owner.
  // Returns {semya, membership} либо null after sending 403/404.
  //
  // Role hierarchy (per ENTITY-DESIGN §2.1):
  //   viewer  → read семья + tree (no mutations)
  //   editor  → viewer + add/edit persons + invite (if hasInviteGrant)
  //   owner   → editor + rename/delete семья + role transitions
  //
  // Soft-deleted семьи treat как not-found (404), не denied (403).
  async function requireSemyaAccess(req, res, semyaId, {requiredRole = "viewer"} = {}) {
    const semya = await store.findSemyaById(semyaId);
    if (!semya || semya.deletedAt) {
      res.status(404).json({message: "Семья не найдена"});
      return null;
    }
    const membership = await store.findMembership(semyaId, req.auth.user.id);
    if (!membership) {
      res.status(403).json({message: "Доступ к семье запрещён"});
      return null;
    }
    const roleRank = {viewer: 0, editor: 1, owner: 2};
    const actorRank = roleRank[membership.role] ?? -1;
    const requiredRank = roleRank[requiredRole] ?? 0;
    if (actorRank < requiredRank) {
      res.status(403).json({
        message: "Недостаточно прав для этого действия",
        requiredRole,
        actorRole: membership.role,
      });
      return null;
    }
    return {semya, membership};
  }

  // Phase 3.2 (DECISIONS.md 2026-05-10 ответы C/Q1): owner-model
  // gate для mutate-routes на graphPerson canonical / soft-delete /
  // merge. Layered:
  //   1. requireTreeAccess(treeId) — viewer должен быть на дереве
  //      (creator/member). Без этого даже active grant не открывает
  //      route — grants выписываются на graphPerson, но HTTP-shape
  //      требует tree-context.
  //   2. graphPerson lookup. Если null (между migration и первым
  //      sync'ом) — fall through на legacy gate (tree-access уже
  //      пройден); claimed-protection кикnется на следующем read'е.
  //   3. Backward-compat: anonymous (graphPerson.userId === null) —
  //      tree-access достаточен (collaborative editing на «общими
  //      усилиями» dummy slots). Claimed (userId !== null) — только
  //      owner или active grant per scope. Это ровно то поведение,
  //      которое Артём защитил `additive: true` фиксом + ответом
  //      Q1 от 2026-05-10.
  async function requireGraphPersonEdit(req, res, treeId, personId, scope) {
    const normalizedScope = String(scope || "edit").trim();
    const tree = await requireTreeAccess(req, res, treeId);
    if (!tree) return null;

    const legacyPerson = await store.findPerson(treeId, personId);
    if (!legacyPerson) {
      res.status(404).json({message: "Человек не найден"});
      return null;
    }

    const graphPerson = await store.findGraphPersonByLegacy(personId);
    if (!graphPerson) {
      // Edge case — graph mirror ещё не догнал legacy write.
      // Tree-access уже пройден; на anonymous этого достаточно по
      // backward-compat правилу. Возвращаем legacy-only context.
      return {tree, legacyPerson, graphPerson: null};
    }

    const isAnonymous = !graphPerson.userId;
    if (isAnonymous) {
      return {tree, legacyPerson, graphPerson};
    }

    const owner = graphPerson.userId || graphPerson.createdBy || null;
    if (owner === req.auth.user.id) {
      return {tree, legacyPerson, graphPerson};
    }

    // Claimed: только active grant per scope.
    const dbForGrants = await store._read();
    const grants = Array.isArray(dbForGrants.graphPersonEditGrants)
      ? dbForGrants.graphPersonEditGrants
      : [];
    const hasGrant = grants.some(
      (entry) =>
        entry.graphPersonId === graphPerson.id &&
        entry.granteeUserId === req.auth.user.id &&
        entry.scope === normalizedScope &&
        !entry.revokedAt,
    );
    if (hasGrant) {
      return {tree, legacyPerson, graphPerson};
    }

    res.status(403).json({
      message:
        normalizedScope === "soft-delete"
          ? "Только владелец карточки может удалить её"
          : normalizedScope === "merge-consent"
              ? "Объединение требует согласия владельца карточки"
              : "Только владелец карточки может её редактировать",
    });
    return null;
  }

  // Cross-tree READ gate: один graphPerson по id, без tree-context.
  // Используется new graph-person endpoints + future cross-tree
  // chain hydration. Read paths которые list'ят (search,
  // identity-suggestions) не вызывают этот helper напрямую — они
  // фильтруют через `_userCanSeeGraphPerson` в bulk, чтобы скрытый
  // person тихо выпал из результата, а не вернул 403 (последнее
  // leak'ает существование).
  async function requireGraphPersonRead(req, res, graphPersonId) {
    const graphPerson = await store.findGraphPersonById(graphPersonId);
    if (!graphPerson || graphPerson.deletedAt) {
      res.status(404).json({message: "Карточка не найдена"});
      return null;
    }
    const db = await store._read();
    if (!store._userCanSeeGraphPerson(db, graphPerson, req.auth.user.id)) {
      res.status(403).json({message: "Карточка скрыта приватностью"});
      return null;
    }
    return graphPerson;
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

  async function requireCallAccess(req, res, callId) {
    const call = await findFreshCall(callId, {
      viewerUserId: req.auth.user.id,
    });
    if (!call) {
      res.status(404).json({message: "Звонок не найден"});
      return null;
    }

    if (!(call.participantIds || []).includes(req.auth.user.id)) {
      res.status(403).json({message: "Доступ к звонку запрещён"});
      return null;
    }

    return call;
  }

  // Group late-join access: unlike requireCallAccess (participantIds only), a
  // caller may "залететь" into a live call when they are a member of the call's
  // CHAT even if they weren't pre-invited. Deliberately SCOPED to POST /join +
  // discovery — the strict participantIds gate stays on /reject //cancel
  // //nudge //add //hangup so a non-participant can never act on someone else's
  // call. Chat membership is read from the authoritative chat record, never
  // from client input.
  async function requireCallJoinAccess(req, res, callId) {
    const call = await findFreshCall(callId, {
      viewerUserId: req.auth.user.id,
    });
    if (!call) {
      res.status(404).json({message: "Звонок не найден"});
      return null;
    }
    const userId = req.auth.user.id;
    if ((call.participantIds || []).includes(userId)) {
      return call;
    }
    const chat = await store.findChat(call.chatId);
    const chatMembers = Array.isArray(chat?.participantIds)
      ? chat.participantIds
      : [];
    if (chatMembers.includes(userId)) {
      return call;
    }
    res.status(403).json({message: "Доступ к звонку запрещён"});
    return null;
  }

  function requireAdmin(req, res) {
    const adminEmails = Array.isArray(config.adminEmails) ? config.adminEmails : [];
    const currentEmail = String(req.auth?.user?.email || "").trim().toLowerCase();
    const isAdmin = Boolean(currentEmail) && adminEmails.includes(currentEmail);

    if (!isAdmin) {
      res.status(403).json({message: "Нужны права модератора"});
      return false;
    }

    return true;
  }

  function resolvePublicApiUrl(req) {
    return String(config.publicApiUrl || "").trim() ||
      `${req.protocol}://${req.get("host")}`;
  }

  function displayNameForCallParticipant(user) {
    return (
      user?.profile?.displayName ||
      user?.displayName ||
      user?.email ||
      "Участник"
    );
  }

  async function createCallSessionsForParticipants({
    call,
    roomName,
    participantIds,
    ownerSessionByUserId = {},
  }) {
    const sessionEntries = await Promise.all(
      participantIds.map(async (participantId) => {
        const ownerSessionId = String(
          ownerSessionByUserId[participantId] || "",
        ).trim();
        if (!ownerSessionId) {
          return [participantId, null];
        }
        const participant = await store.findUserById(participantId);
        const session = await resolvedLiveKitService.createSession({
          roomName,
          participantIdentity: buildCallParticipantIdentity(
            participantId,
            ownerSessionId,
          ),
          participantName: displayNameForCallParticipant(participant),
          metadata: {
            callId: call.id,
            chatId: call.chatId,
            userId: participantId,
            sessionPublicId: ownerSessionId,
            mediaMode: call.mediaMode,
          },
        });
        return [participantId, session];
      }),
    );
    return Object.fromEntries(
      sessionEntries.filter(([, session]) => session != null),
    );
  }

  // Group late-join: mint a LiveKit session for the CALLER's own device and
  // merge it into the (already-active) call, so anyone with membership can
  // "залететь в звонок". Shared by POST /accept on an active call and the
  // dedicated POST /join. Responds with mapCallRecord carrying the caller's
  // real session ({url, token, roomName}). Assumes LiveKit is configured
  // (callers check) and the call is non-terminal.
  async function joinActiveCall(req, res, call) {
    const roomName = call.roomName || `call_${call.id}`;
    const callerId = req.auth.user.id;
    const callerSessionId = req.auth.sessionPublicId;
    try {
      // A non-invited chat member "залетает": put them on the roster first —
      // addCallParticipantSession (and later hangupCall) both require the
      // caller to be in participantIds. addCallParticipants only GROWS the
      // list, so a pre-invited joiner or a same-device rejoin is a no-op here.
      // addCallParticipantSession re-reads fresh, so it stays correct even if
      // this local `call` snapshot raced a concurrent add.
      let activeCall = call;
      if (
        !normalizeParticipantIds(call.participantIds || []).includes(callerId)
      ) {
        const grown = await store.addCallParticipants({
          callId: call.id,
          userIds: [callerId],
        });
        if (grown === null) {
          res.status(404).json({message: "Звонок не найден"});
          return;
        }
        if (grown === undefined) {
          res.status(409).json({message: "Звонок уже недоступен"});
          return;
        }
        if (grown && grown.call) {
          activeCall = grown.call;
        }
      }
      const callParticipantIds = normalizeParticipantIds(
        activeCall.participantIds || [],
      );
      await resolvedLiveKitService.ensureRoom(roomName, {
        maxParticipants: Math.max(
          callParticipantIds.length,
          GROUP_CALL_MAX_PARTICIPANTS,
        ),
      });
      const sessionByUserId = await createCallSessionsForParticipants({
        call: activeCall,
        roomName,
        participantIds: [callerId],
        ownerSessionByUserId: {[callerId]: callerSessionId},
      });
      const joinedCall = await store.addCallParticipantSession({
        callId: call.id,
        userId: callerId,
        sessionId: callerSessionId,
        session: sessionByUserId[callerId],
      });
      if (!joinedCall) {
        res.status(409).json({message: "Не удалось подключиться к звонку"});
        return;
      }
      clearCallInviteTimeout(joinedCall.id);

      await publishCallState(joinedCall);

      logCallEvent("join.succeeded", joinedCall, {viewerUserId: callerId});

      res.json({
        call: mapCallRecord(joinedCall, {
          viewerUserId: callerId,
          viewerSessionId: callerSessionId,
        }),
      });
    } catch (error) {
      const failedCall =
        typeof store.markCallRoomJoinFailure === "function"
          ? await store.markCallRoomJoinFailure({
              callId: call.id,
              reason: error?.message || "room_prepare_failed",
            })
          : call;
      logCallEvent("join.failed", failedCall || call, {
        viewerUserId: callerId,
        error: String(error?.message || error || "room_prepare_failed"),
      });
      res.status(502).json({message: "Не удалось подготовить комнату звонка"});
    }
  }

  function resolvePublicAppUrl() {
    return String(config.publicAppUrl || "https://rodnya-tree.ru")
      .trim()
      .replace(/\/$/, "");
  }

  function maskEmailAddress(value) {
    const normalizedValue = String(value || "").trim().toLowerCase();
    const atIndex = normalizedValue.indexOf("@");
    if (atIndex <= 0) {
      return null;
    }

    const localPart = normalizedValue.slice(0, atIndex);
    const domainPart = normalizedValue.slice(atIndex + 1);
    if (!localPart || !domainPart) {
      return null;
    }

    const visibleLocal =
      localPart.length <= 2
        ? `${localPart[0]}*`
        : `${localPart.slice(0, 2)}***`;
    return `${visibleLocal}@${domainPart}`;
  }

  function maskPhoneNumber(value) {
    const normalizedValue = String(value || "").replace(/\D+/g, "");
    if (normalizedValue.length < 7) {
      return null;
    }

    return `+${normalizedValue.slice(0, 2)}***${normalizedValue.slice(-2)}`;
  }

  function secondsUntil(value) {
    const timestamp = new Date(String(value || "")).getTime();
    if (!Number.isFinite(timestamp)) {
      return 0;
    }
    return Math.max(0, Math.ceil((timestamp - Date.now()) / 1000));
  }

  function mapLinkedAuthIdentity(identity) {
    return {
      provider: identity.provider,
      linkedAt: identity.linkedAt,
      lastUsedAt: identity.lastUsedAt || null,
      emailMasked: maskEmailAddress(identity.email),
      phoneMasked: maskPhoneNumber(
        identity.normalizedPhoneNumber || identity.phoneNumber,
      ),
      displayName: identity.displayName || null,
    };
  }

  function trustedChannelLabel(provider) {
    switch (provider) {
      case "google":
        return "Google";
      case "telegram":
        return "Telegram";
      case "vk":
        return "VK ID";
      case "max":
        return "MAX";
      case "password":
      default:
        return "Email и пароль";
    }
  }

  function trustedChannelDescription(provider) {
    switch (provider) {
      case "google":
        return "Подтверждённый вход через Google-аккаунт.";
      case "telegram":
        return "Подтверждённая связь через Telegram.";
      case "vk":
        return "Подтверждённый профиль через VK ID.";
      case "max":
        return "Подтверждённая связь через MAX.";
      case "password":
      default:
        return "Резервный вход по email и паролю.";
    }
  }

  function trustedChannelVerificationLabel(provider) {
    switch (provider) {
      case "google":
        return "Аккаунт подтверждён через Google";
      case "telegram":
        return "Связь подтверждена через Telegram";
      case "vk":
        return "Аккаунт подтверждён через VK";
      case "max":
        return "Основной канал подтверждён через MAX";
      case "password":
      default:
        return "Доступ защищён email и паролем";
    }
  }

  function resolvePrimaryTrustedChannelProvider({
    linkedProviderIds = [],
    profile = {},
  } = {}) {
    const preferredProvider = normalizePrimaryTrustedChannel(
      profile?.primaryTrustedChannel,
    );
    if (
      preferredProvider &&
      Array.isArray(linkedProviderIds) &&
      linkedProviderIds.includes(preferredProvider)
    ) {
      return preferredProvider;
    }

    for (const provider of ["telegram", "vk", "max", "google"]) {
      if (linkedProviderIds.includes(provider)) {
        return provider;
      }
    }

    return null;
  }

  function buildTrustedChannels({
    linkedProviderIds = [],
    authIdentities = [],
    profile = {},
  } = {}) {
    const mappedIdentities = Array.isArray(authIdentities)
      ? authIdentities.map(mapLinkedAuthIdentity)
      : [];
    const identityByProvider = new Map();
    for (const identity of mappedIdentities) {
      if (identity?.provider && !identityByProvider.has(identity.provider)) {
        identityByProvider.set(identity.provider, identity);
      }
    }

    const primaryProvider = resolvePrimaryTrustedChannelProvider({
      linkedProviderIds,
      profile,
    });

    return ["password", "google", "telegram", "vk", "max"].map((provider) => {
      const identity = identityByProvider.get(provider) || null;
      const isLinked = linkedProviderIds.includes(provider);
      const isTrustedChannel = isLinked && provider !== "password";
      return {
        provider,
        label: trustedChannelLabel(provider),
        description: trustedChannelDescription(provider),
        verificationLabel: trustedChannelVerificationLabel(provider),
        isLinked,
        isTrustedChannel,
        isLoginMethod: isLinked,
        isPrimary: primaryProvider === provider,
        linkedAt: identity?.linkedAt || null,
        lastUsedAt: identity?.lastUsedAt || null,
        emailMasked: identity?.emailMasked || null,
        phoneMasked: identity?.phoneMasked || null,
        displayName: identity?.displayName || null,
      };
    });
  }

  function buildTrustedChannelSummary(trustedChannels = []) {
    const primaryChannel = trustedChannels.find(
      (entry) => entry.isPrimary === true && entry.isTrustedChannel === true,
    );
    if (primaryChannel) {
      return {
        title: primaryChannel.verificationLabel,
        detail: `Основной канал: ${primaryChannel.label}`,
      };
    }

    const firstTrustedChannel = trustedChannels.find(
      (entry) => entry.isTrustedChannel === true,
    );
    if (firstTrustedChannel) {
      return {
        title: firstTrustedChannel.verificationLabel,
        detail: "Можно выбрать этот канал основным в настройках профиля.",
      };
    }

    return {
      title: "Подтверждённый канал пока не выбран",
      detail:
        "Привяжите VK, Telegram, Google или MAX, чтобы подтвердить канал связи и входа.",
    };
  }

  // Phase 6 chunk 4a (PHASE-6-PROPOSAL.md §2.8 + DECISIONS 2026-05-14
  // «post-signup redirect Option A simplified»): auth response carries
  // optional `requiresOnboarding` flag — client redirects к `/setup`
  // wizard when true. Каждый auth endpoint решает свой flag value:
  //   • register / fresh Google/VK/Telegram/MAX signup → true
  //   • login / linking existing user → computed via
  //     store.hasIncompleteOnboarding (true только если user mid-wizard)
  //   • refresh → omit flag (no redirect on token refresh)
  function authResponse(user, sessionTokens, extra = {}) {
    const profile = sanitizeProfile(user.profile);
    const profileStatus = computeProfileStatus(user.profile);
    return {
      accessToken: sessionTokens.token,
      refreshToken: sessionTokens.refreshToken,
      user: {
        id: user.id,
        identityId: user.identityId || null,
        email: user.email,
        displayName: profile.displayName,
        photoUrl: profile.photoUrl,
        providerIds: user.providerIds || ["password"],
      },
      profileStatus,
      ...extra,
    };
  }

  function resolveGoogleDisplayName(payload) {
    const explicitName = String(payload?.name || "").trim();
    if (explicitName) {
      return explicitName;
    }

    return [
      String(payload?.given_name || "").trim(),
      String(payload?.family_name || "").trim(),
    ].filter(Boolean).join(" ");
  }

  function buildGoogleIdentityFromPayload(payload) {
    const providerUserId = String(payload?.sub || "").trim();
    if (!providerUserId) {
      throw new Error("GOOGLE_ID_TOKEN_INVALID");
    }

    const email = String(payload?.email || "").trim().toLowerCase() || null;
    const displayName = resolveGoogleDisplayName(payload);
    const picture = String(payload?.picture || "").trim() || null;
    const emailVerified =
      payload?.email_verified === true ||
      String(payload?.email_verified || "").trim().toLowerCase() === "true";

    return {
      provider: "google",
      providerUserId,
      email,
      displayName: displayName || null,
      metadata: {
        emailVerified,
        givenName: String(payload?.given_name || "").trim() || null,
        familyName: String(payload?.family_name || "").trim() || null,
        picture,
      },
    };
  }

  async function resolveSharedTreeIdsForUsers(viewerUserId, targetUserId) {
    const normalizedViewerUserId = String(viewerUserId || "").trim();
    const normalizedTargetUserId = String(targetUserId || "").trim();
    if (!normalizedViewerUserId || !normalizedTargetUserId) {
      return [];
    }
    if (normalizedViewerUserId === normalizedTargetUserId) {
      return [];
    }

    const [viewerTrees, targetTrees] = await Promise.all([
      store.listUserTrees(normalizedViewerUserId),
      store.listUserTrees(normalizedTargetUserId),
    ]);

    const targetTreeIds = new Set(
      (Array.isArray(targetTrees) ? targetTrees : [])
        .map((tree) => String(tree?.id || "").trim())
        .filter(Boolean),
    );

    return (Array.isArray(viewerTrees) ? viewerTrees : [])
      .map((tree) => String(tree?.id || "").trim())
      .filter((treeId) => treeId && targetTreeIds.has(treeId));
  }

  async function buildProfileViewerContext(viewerUserId, targetUserId) {
    const normalizedViewerUserId = String(viewerUserId || "").trim();
    const normalizedTargetUserId = String(targetUserId || "").trim();
    if (!normalizedViewerUserId || !normalizedTargetUserId) {
      return null;
    }
    if (normalizedViewerUserId === normalizedTargetUserId) {
      return {
        viewerUserId: normalizedViewerUserId,
        targetUserId: normalizedTargetUserId,
        sharedTreeIds: [],
        branchRootMatches: [],
      };
    }

    const sharedTreeIds = await resolveSharedTreeIdsForUsers(
      normalizedViewerUserId,
      normalizedTargetUserId,
    );
    const branchRootMatches = new Set();
    for (const treeId of sharedTreeIds) {
      const [persons, relations] = await Promise.all([
        store.listPersons(treeId),
        store.listRelations(treeId),
      ]);
      const viewerPersonIds = (Array.isArray(persons) ? persons : [])
        .filter(
          (person) =>
            String(person?.userId || "").trim() === normalizedViewerUserId,
        )
        .map((person) => String(person?.id || "").trim())
        .filter(Boolean);
      if (viewerPersonIds.length === 0) {
        continue;
      }

      for (const person of Array.isArray(persons) ? persons : []) {
        const rootPersonId = String(person?.id || "").trim();
        if (!rootPersonId) {
          continue;
        }
        const visibleIds = buildBranchVisiblePersonIds(
          persons,
          relations,
          rootPersonId,
        );
        if (viewerPersonIds.some((personId) => visibleIds.has(personId))) {
          branchRootMatches.add(rootPersonId);
        }
      }
    }

    return {
      viewerUserId: normalizedViewerUserId,
      targetUserId: normalizedTargetUserId,
      sharedTreeIds,
      branchRootMatches: Array.from(branchRootMatches),
    };
  }

  async function buildPersonDossierPayload({
    treeId,
    personId,
    viewerUserId,
  }) {
    const dossier = await store.getPersonDossier(treeId, personId);
    if (!dossier) {
      return null;
    }

    const mappedPerson = mapPerson(dossier.person);
    const linkedUserId = String(dossier.person?.userId || "").trim();
    const viewerContext = linkedUserId
      ? await buildProfileViewerContext(viewerUserId, linkedUserId)
      : null;
    const linkedProfile = dossier.linkedProfile
      ? sanitizeProfile(dossier.linkedProfile, viewerContext)
      : null;
    // BUG3 follow-up: экран профиля читает аватар из user-профиля (пустой у
    // только что вошедшего), но фото есть на граф-персоне (поставлено ДО
    // регистрации). Тот же фолбэк, что в чат/звонок-маппинге — read-time
    // safety поверх ретро-бэкфилла (на случай фото, добавленного персоне
    // уже ПОСЛЕ привязки).
    if (linkedProfile && !linkedProfile.photoUrl && mappedPerson.photoUrl) {
      linkedProfile.photoUrl = mappedPerson.photoUrl;
    }
    const contributionPolicy = normalizeProfileContributionPolicy(
      linkedProfile?.profileContributionPolicy,
    );

    let mode = "offline";
    if (mappedPerson.isAlive === false) {
      mode = "memorial";
    } else if (linkedUserId && linkedUserId === viewerUserId) {
      mode = "self";
    } else if (linkedUserId) {
      mode = "linked";
    }

    return {
      person: mappedPerson,
      linkedProfile,
      mode,
      permissions: {
        canEditFamilyFields: true,
        canSuggestOwnerFields:
          Boolean(linkedUserId) &&
          linkedUserId !== viewerUserId &&
          mappedPerson.isAlive !== false &&
          contributionPolicy === "suggestions",
      },
      hiddenSections: linkedProfile?.hiddenProfileSections || [],
    };
  }

  async function createAndDispatchNotification({
    userId,
    type,
    title,
    body,
    data,
    silent = false,
    targetSessionPublicId = null,
    // FIX A2: latency-чувствительные пути (звонки) ставят awaitPush:false —
    // запись уведомления в БД + realtime остаются синхронными (быстро,
    // онлайн-клиент уже звенит через них), а МЕДЛЕННЫЙ HTTP-пуш (VKPNS на
    // мёртвый токен) уходит в фон и не держит ответ обработчика.
    awaitPush = true,
  }) {
    const notification = await store.createNotification({
      userId,
      type,
      title,
      body,
      data,
      silent,
    });

    if (!notification) {
      return null;
    }

    const mappedNotification = mapNotification(notification);
    realtimeHub?.publishToUser(
      userId,
      {
        type: "notification.created",
        notification: mappedNotification,
      },
      {sessionPublicId: targetSessionPublicId},
    );
    const pushDispatch = resolvedPushGateway.dispatchNotification(notification, {
      targetSessionPublicId,
    });
    if (awaitPush) {
      await pushDispatch;
    } else {
      Promise.resolve(pushDispatch).catch((error) =>
        console.error("[push] background dispatch failed", error),
      );
    }

    return mappedNotification;
  }

  registerAuthSessionRoutes(app, {
    store,
    mediaStorage: resolvedMediaStorage,
    config,
    emailSender: resolvedEmailSender,
    requireAuth,
    authResponse,
    sanitizeProfile,
    computeProfileStatus,
    readDeviceContext,
    realtimeHub,
    deriveSessionPublicId,
  });

  registerProfileRoutes(app, {
    store,
    requireAuth,
    requireOwnUser,
    sanitizeProfile,
    computeProfileStatus,
    composeDisplayName,
    mapProfileContribution,
    mapProfileNote,
    mapLinkedAuthIdentity,
    buildTrustedChannels,
    resolvePrimaryTrustedChannelProvider,
    buildTrustedChannelSummary,
  });

  registerGoogleAuthRoutes(app, {
    store,
    requireAuth,
    googleTokenVerifier: resolvedGoogleTokenVerifier,
    buildGoogleIdentityFromPayload,
    authResponse,
    readDeviceContext,
  });

  registerVkAuthRoutes(app, {
    store,
    requireAuth,
    vkAuthClient: resolvedVkAuthClient,
    resolvePublicApiUrl,
    resolvePublicAppUrl,
    authResponse,
    readDeviceContext,
  });

  registerTelegramAuthRoutes(app, {
    store,
    config,
    requireAuth,
    resolvePublicApiUrl,
    resolvePublicAppUrl,
    authResponse,
    readDeviceContext,
  });

  registerMaxAuthRoutes(app, {
    store,
    requireAuth,
    maxAuthClient: resolvedMaxAuthClient,
    resolvePublicAppUrl,
    authResponse,
    readDeviceContext,
  });
  registerAuthenticatedMediaRoutes(app, {
    mediaStorage: resolvedMediaStorage,
    requireAuth,
  });

  registerStoryRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapStory,
    pushGateway: resolvedPushGateway,
  });

  registerPostRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapPost,
    mapComment,
    createAndDispatchNotification,
    pushGateway: resolvedPushGateway,
  });

  registerGatheringRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapGathering,
    createAndDispatchNotification,
    pushGateway: resolvedPushGateway,
  });

  registerPollRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapPoll,
    createAndDispatchNotification,
    pushGateway: resolvedPushGateway,
  });

  registerCircleRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
  });

  registerMergeRoutes(app, {
    store,
    requireAuth,
    requireGraphPersonEdit,
  });

  registerIdentityRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    requireGraphPersonEdit,
  });

  registerGraphRoutes(app, {
    store,
    requireAuth,
  });

  registerGraphPersonRoutes(app, {
    store,
    requireAuth,
    requireGraphPersonRead,
  });

  // Phase 6 chunk 1 (PHASE-6-PROPOSAL.md §3.2).
  registerOnboardingRoutes(app, {
    store,
    requireAuth,
  });

  registerKinshipChecksRoutes(app, {
    store,
    requireAuth,
    createAndDispatchNotification,
  });

  // Phase B Week 2 Ship 2: семья HTTP endpoints (5 routes).
  registerSemyaRoutes(app, {
    store,
    requireAuth,
    requireSemyaAccess,
  });

  // Phase B Week 2 Ship 3: семья membership HTTP endpoints (4 routes).
  registerMembershipRoutes(app, {
    store,
    requireAuth,
    requireSemyaAccess,
  });

  // Phase B Week 2 Ship 4: семья invitation flow (3 routes).
  // FE7 (email dispatch): config + emailSender threaded so a fresh
  // email-addressed invitation auto-sends a warm accept-link email.
  registerSemyaInvitationRoutes(app, {
    store,
    config,
    requireAuth,
    requireSemyaAccess,
    createAndDispatchNotification,
    emailSender: resolvedEmailSender,
  });

  // Phase B Week 3 Ship 6: cross-семья pull-selectively endpoint.
  registerSemyaPullRoutes(app, {
    store,
    requireAuth,
    requireSemyaAccess,
    createAndDispatchNotification,
  });

  // Phase B Week 3 Ship 7: browse mode (read-only capability tokens).
  registerSemyaBrowseRoutes(app, {
    store,
    requireAuth,
    requireSemyaAccess,
  });

  // Phase B Week 3 Ship 8: hide-filter endpoints (privacy-critical).
  registerSemyaHideFilterRoutes(app, {
    store,
    requireAuth,
    requireSemyaAccess,
  });

  // Ship Q4a (2026-05-28): «корзина» — soft-deleted persons recovery.
  registerDeletedPersonsRoutes(app, {
    store,
    requireAuth,
  });

  // Ship Q4a (2026-05-28, Ship 30b): same для posts.
  registerDeletedPostsRoutes(app, {
    store,
    requireAuth,
  });

  // Profile Phase 1 (2026-05-28): article-style biography CRUD.
  // Writes reuse requireGraphPersonEdit (same gate as person edits);
  // reads use requireTreeAccess.
  registerProfileArticleRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    requireGraphPersonEdit,
  });

  registerTreeRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    requireGraphPersonEdit,
    requirePublicTree,
    mapTree,
    mapPerson,
    mapRelation,
    mapProfileContribution,
    mapTreeChangeRecord,
    mapTreeGraphSnapshot,
    buildPersonDossierPayload,
    createAndDispatchNotification,
  });

  registerTreeInvitationRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    createAndDispatchNotification,
    mapTree,
    mapTreeInvitation,
  });

  registerRelationRequestRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    createAndDispatchNotification,
    mapPerson,
    mapRelation,
    mapRelationRequest,
  });

  registerChatRoutes(app, {
    store,
    requireAuth,
    requireTreeAccess,
    requireChatAccess,
    createAndDispatchNotification,
    mapChatPreview,
    mapChatRecord,
    mapChatMessage,
    mapChatParticipant,
    mapChatBranchRoot,
    realtimeHub,
    emergencyChatPreviewResponseCap: EMERGENCY_CHAT_PREVIEW_RESPONSE_CAP,
  });

  registerDiagnosticsRoutes(app, {
    store,
    requireAuth,
    logger: console,
  });

  registerSafetyRoutes(app, {
    store,
    requireAuth,
    mapBlock,
    mapReport,
  });

  registerAdminRoutes(app, {
    store,
    requireAuth,
    requireAdmin,
    buildStatusPayload,
    mapReport,
  });

  app.post("/v1/calls", requireAuth, async (req, res) => {
    if (!resolvedLiveKitService.isConfigured) {
      res.status(503).json({message: "Звонки пока не настроены на сервере"});
      return;
    }

    const requestedChatId = String(req.body?.chatId || "").trim();
    const mediaMode = String(req.body?.mediaMode || "audio").trim().toLowerCase() === "video"
      ? "video"
      : "audio";
    if (!requestedChatId) {
      res.status(400).json({message: "Нужен chatId"});
      return;
    }

    const chat = await requireChatAccess(req, res, requestedChatId);
    if (!chat) {
      return;
    }
    const chatId = chat.id;
    const chatParticipantIds = normalizeParticipantIds(chat.participantIds || []);
    const requestedParticipantIds = Array.isArray(req.body?.participantIds)
      ? normalizeParticipantIds(req.body.participantIds)
      : [];
    const participantIds = requestedParticipantIds.length > 0
      ? normalizeParticipantIds([
          req.auth.user.id,
          ...requestedParticipantIds,
        ])
      : chatParticipantIds;
    const isSupportedCallChat =
      chat.type === "direct" || chat.type === "group" || chat.type === "branch";
    const participantsBelongToChat = participantIds.every((participantId) =>
      chatParticipantIds.includes(participantId),
    );
    if (
      !isSupportedCallChat ||
      !participantsBelongToChat ||
      !participantIds.includes(req.auth.user.id) ||
      participantIds.length < 2 ||
      (chat.type === "direct" && participantIds.length !== 2)
    ) {
      res.status(400).json({message: "Не удалось определить участников звонка"});
      return;
    }

    const recipientId = participantIds.find((entry) => entry !== req.auth.user.id);
    if (!recipientId) {
      res.status(400).json({message: "Не удалось определить собеседника"});
      return;
    }

    for (const participantId of participantIds) {
      await reconcileUserBusyCall(participantId);
    }

    const call = await store.createCallInvite({
      chatId,
      initiatorId: req.auth.user.id,
      recipientId,
      participantIds,
      mediaMode,
      originatedBySessionId: req.auth.sessionPublicId,
    });
    if (call === null) {
      res.status(404).json({message: "Чат не найден"});
      return;
    }
    if (call === false) {
      // Групповые/branch-звонки поддержаны (store.createCallInvite их
      // принимает) — этот путь остаётся только для настоящих ошибок
      // валидации участников, поэтому сообщение общее.
      res.status(400).json({message: "Не удалось создать звонок"});
      return;
    }
    if (call === "BUSY") {
      logCallEvent(
        "invite.busy",
        {
          id: null,
          chatId,
          mediaMode,
          state: "busy",
          createdAt: null,
          acceptedAt: null,
          endedAt: null,
          endedReason: "busy",
          metrics: null,
        },
        {
          initiatorId: req.auth.user.id,
          participantIds,
        },
      );
      res.status(409).json({message: "Пользователь уже участвует в другом звонке"});
      return;
    }

    // FIX A1 (P0 latency): realtimeHub publish онлайн-получателям ИДЁТ
    // ПЕРВЫМ — in-memory WS доставляет звонок мгновенно и не должен стоять
    // за последовательной рассылкой HTTP-пушей. Раньше цикл пушей (await
    // на VKPNS-fetch без таймаута к мёртвому токену) висел до 30с, и из-за
    // этого и звонящий (ждёт ответ POST), и онлайн-получатель (publish был
    // ПОСЛЕ цикла) получали звонок с задержкой.
    const originatedSessionId = String(call.originatedBySessionId || "").trim();
    for (const participantId of call.participantIds || []) {
      realtimeHub?.publishToUser(participantId, ({sessionPublicId}) => {
        const viewerSessionId = String(sessionPublicId || "").trim();
        if (
          participantId === call.initiatorId &&
          originatedSessionId &&
          viewerSessionId !== originatedSessionId
        ) {
          return null;
        }
        return {
          type: "call.invite.created",
          call: mapCallRecord(call, {
            viewerUserId: participantId,
            viewerSessionId,
          }),
        };
      });
    }

    logCallEvent("invite.created", call, {
      initiatorId: call.initiatorId,
      participantIds: call.participantIds,
    });
    scheduleCallInviteTimeout(call);

    // FIX A2: запись уведомления (createNotification + realtime) синхронная
    // и быстрая, а МЕДЛЕННЫЙ HTTP-пуш уходит в фон (awaitPush:false) — мёртвый
    // токен больше не держит ответ. Последовательно (не Promise.all) — у
    // FileStore read-modify-write, параллельные записи затирали бы друг друга.
    const callerName = displayNameForCallParticipant(req.auth.user);
    const isGroupCall = participantIds.length > 2;
    for (const inviteeId of participantIds) {
      if (inviteeId === req.auth.user.id) {
        continue;
      }
      await createAndDispatchNotification({
        userId: inviteeId,
        type: "call_invite",
        title: callerName,
        body: isGroupCall
          ? (mediaMode === "video" ? "Групповой видеозвонок" : "Групповой аудиозвонок")
          : (mediaMode === "video" ? "Видеозвонок" : "Аудиозвонок"),
        data: {
          chatId,
          callId: call.id,
          mediaMode,
        },
        awaitPush: false,
      });
    }

    // Отвечаем сразу — звонящий (custom_api_call_service ждёт ответ POST)
    // показывает экран мгновенно; онлайн-получатель уже зазвенел по
    // realtime-публикации выше, не дожидаясь HTTP-пушей.
    res.status(201).json({
      call: mapCallRecord(call, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  app.get("/v1/calls/active", requireAuth, async (req, res) => {
    const chatId = String(req.query?.chatId || "").trim();
    let activeCall = await findFreshActiveCall({
      userId: req.auth.user.id,
      chatId: chatId || null,
    });
    // Discovery for group late-join: a chat member who is NOT on the call's
    // roster can still SEE the chat's active call (session:null) so they can
    // then "залететь" via POST /join. Busy-state (findActiveCall above) stays
    // strict; this only widens READ visibility, and only when gated on
    // authoritative chat membership.
    if (!activeCall && chatId) {
      const chat = await store.findChat(chatId);
      const chatMembers = Array.isArray(chat?.participantIds)
        ? chat.participantIds
        : [];
      if (chatMembers.includes(req.auth.user.id)) {
        const chatCall = await store.findActiveCallForChat(chatId);
        if (chatCall) {
          const fresh =
            (await expireRingingCallIfNeeded(chatCall, {
              reason: "missed",
              eventType: "invite.missed",
              extra: {
                viewerUserId: req.auth.user.id,
                chatId,
                source: "discovery_join",
              },
            })) || chatCall;
          // Only surface a still-live call (a ringing one may have just
          // expired to "missed" above).
          if (fresh.state === "active" || fresh.state === "ringing") {
            activeCall = fresh;
          }
        }
      }
    }
    res.json({
      call: activeCall
        ? mapCallRecord(activeCall, {
            viewerUserId: req.auth.user.id,
            viewerSessionId: req.auth.sessionPublicId,
          })
        : null,
    });
  });

  app.get("/v1/calls/:callId", requireAuth, async (req, res) => {
    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }

    res.json({
      call: mapCallRecord(call, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  app.post("/v1/calls/:callId/nudge", requireAuth, async (req, res) => {
    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }

    const state = String(call.state || "").trim();
    if (["ended", "missed", "rejected", "cancelled", "failed"].includes(state)) {
      res.status(409).json({message: "Звонок уже завершён"});
      return;
    }

    const callParticipantIds = normalizeParticipantIds(call.participantIds || []);
    const requestedParticipantIds = Array.isArray(req.body?.participantIds)
      ? normalizeParticipantIds(req.body.participantIds)
      : [];
    const recipientIds = (requestedParticipantIds.length > 0
      ? requestedParticipantIds
      : callParticipantIds
    ).filter((participantId) => participantId !== req.auth.user.id);

    if (
      recipientIds.length === 0 ||
      recipientIds.some((participantId) => !callParticipantIds.includes(participantId))
    ) {
      res.status(400).json({message: "Не удалось определить участников дозвона"});
      return;
    }

    const callerName = displayNameForCallParticipant(req.auth.user);
    const isGroupCall = callParticipantIds.length > 2;
    // FIX A2: realtime publish мгновенно онлайн-получателям…
    for (const inviteeId of recipientIds) {
      realtimeHub?.publishToUser(inviteeId, ({sessionPublicId}) => ({
        type: "call.invite.created",
        call: mapCallRecord(call, {
          viewerUserId: inviteeId,
          viewerSessionId: sessionPublicId,
        }),
      }));
    }

    // …запись уведомления синхронно, медленный HTTP-пуш в фоне
    // (awaitPush:false). Тот же паттерн, что и POST /v1/calls.
    for (const inviteeId of recipientIds) {
      await createAndDispatchNotification({
        userId: inviteeId,
        type: "call_invite",
        title: callerName,
        body: isGroupCall
          ? (call.mediaMode === "video" ? "Вас снова зовут в групповой видеозвонок" : "Вас снова зовут в групповой аудиозвонок")
          : (call.mediaMode === "video" ? "Вас снова зовут в видеозвонок" : "Вас снова зовут в аудиозвонок"),
        data: {
          chatId: call.chatId,
          callId: call.id,
          mediaMode: call.mediaMode,
        },
        awaitPush: false,
      });
    }

    logCallEvent("invite.nudged", call, {
      initiatorId: req.auth.user.id,
      participantIds: recipientIds,
    });

    res.json({
      call: mapCallRecord(call, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  // GP3: add a NEW person to a live call (unlike /nudge, which only re-rings
  // people already on the list). Any current participant may add a chat member
  // who isn't in the call yet; the newcomers get a fresh ring and land in the
  // same room. Grows participantIds only — the last-leaves teardown is
  // unaffected (see store.addCallParticipants).
  app.post("/v1/calls/:callId/add", requireAuth, async (req, res) => {
    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }
    const state = String(call.state || "").trim();
    if (["ended", "missed", "rejected", "cancelled", "failed"].includes(state)) {
      res.status(409).json({message: "Звонок уже завершён"});
      return;
    }

    const chat = await store.findChat(call.chatId);
    if (!chat) {
      res.status(404).json({message: "Чат не найден"});
      return;
    }
    const chatParticipantIds = normalizeParticipantIds(chat.participantIds || []);
    const callParticipantIds = normalizeParticipantIds(call.participantIds || []);
    const requestedIds = Array.isArray(req.body?.participantIds)
      ? normalizeParticipantIds(req.body.participantIds)
      : [];
    // New = requested ∩ chat members − already-in-call.
    const newParticipantIds = requestedIds.filter(
      (participantId) =>
        chatParticipantIds.includes(participantId) &&
        !callParticipantIds.includes(participantId),
    );
    if (newParticipantIds.length === 0) {
      res.status(400).json({message: "Некого добавить в звонок"});
      return;
    }

    // Don't pull someone who's busy in another call into this one.
    for (const participantId of newParticipantIds) {
      await reconcileUserBusyCall(participantId);
    }

    const result = await store.addCallParticipants({
      callId: call.id,
      userIds: newParticipantIds,
    });
    if (result === null) {
      res.status(404).json({message: "Звонок не найден"});
      return;
    }
    if (result === undefined) {
      res.status(409).json({message: "Звонок уже завершён"});
      return;
    }
    if (result === false) {
      res.status(400).json({message: "Некого добавить в звонок"});
      return;
    }

    const {call: updatedCall, addedUserIds} = result;
    const grownParticipantIds = normalizeParticipantIds(
      updatedCall.participantIds || [],
    );
    // Rooms are created with a generous cap, but keep the ensure idempotent +
    // non-shrinking so the newcomers always fit.
    const roomName = updatedCall.roomName || `call_${updatedCall.id}`;
    try {
      await resolvedLiveKitService.ensureRoom(roomName, {
        maxParticipants: Math.max(
          grownParticipantIds.length,
          GROUP_CALL_MAX_PARTICIPANTS,
        ),
      });
    } catch (_) {
      // best-effort — generous creation cap already covers additions.
    }

    // Ring the newcomers (realtime + background push), same as /nudge + POST.
    const callerName = displayNameForCallParticipant(req.auth.user);
    for (const inviteeId of addedUserIds) {
      realtimeHub?.publishToUser(inviteeId, ({sessionPublicId}) => ({
        type: "call.invite.created",
        call: mapCallRecord(updatedCall, {
          viewerUserId: inviteeId,
          viewerSessionId: sessionPublicId,
        }),
      }));
    }
    for (const inviteeId of addedUserIds) {
      await createAndDispatchNotification({
        userId: inviteeId,
        type: "call_invite",
        title: callerName,
        body: updatedCall.mediaMode === "video"
          ? "Вас зовут в групповой видеозвонок"
          : "Вас зовут в групповой аудиозвонок",
        data: {
          chatId: updatedCall.chatId,
          callId: updatedCall.id,
          mediaMode: updatedCall.mediaMode,
        },
        awaitPush: false,
      });
    }
    // Refresh the roster for everyone already in the call (grown participantIds).
    await publishCallState(updatedCall);

    logCallEvent("participants.added", updatedCall, {
      initiatorId: req.auth.user.id,
      addedUserIds,
    });

    res.json({
      call: mapCallRecord(updatedCall, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  app.post("/v1/calls/:callId/accept", requireAuth, async (req, res) => {
    if (!resolvedLiveKitService.isConfigured) {
      res.status(503).json({message: "Звонки пока не настроены на сервере"});
      return;
    }

    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }
    if (call.initiatorId === req.auth.user.id) {
      res.status(403).json({message: "Только приглашенный участник может принять звонок"});
      return;
    }
    if (call.state === "active") {
      // Late-join: the call is already running — mint THIS device's session
      // and merge it in (instead of the old tokenless early-return that left
      // every late participant with session:null).
      await joinActiveCall(req, res, call);
      return;
    }
    if (call.state !== "ringing") {
      res.status(409).json({message: "Звонок уже недоступен для принятия"});
      return;
    }

    const roomName = call.roomName || `call_${call.id}`;
    const callParticipantIds = normalizeParticipantIds(call.participantIds || []);
    const accepterSessionId = req.auth.sessionPublicId;
    const ownerSessionByUserId = {
      [call.initiatorId]: String(call.originatedBySessionId || "").trim(),
      [req.auth.user.id]: accepterSessionId,
    };
    try {
      await resolvedLiveKitService.ensureRoom(roomName, {
        maxParticipants: Math.max(
          callParticipantIds.length,
          GROUP_CALL_MAX_PARTICIPANTS,
        ),
      });
      const sessionByUserId = await createCallSessionsForParticipants({
        call,
        roomName,
        participantIds: callParticipantIds,
        ownerSessionByUserId,
      });
      const acceptedCall = await store.acceptCall({
        callId: call.id,
        userId: req.auth.user.id,
        roomName,
        sessionByUserId,
        acceptedBySessionId: accepterSessionId,
      });
      if (!acceptedCall) {
        res.status(409).json({message: "Не удалось принять звонок"});
        return;
      }
      clearCallInviteTimeout(acceptedCall.id);

      await publishCallState(acceptedCall);

      logCallEvent("accept.succeeded", acceptedCall, {
        viewerUserId: req.auth.user.id,
      });

      res.json({
        call: mapCallRecord(acceptedCall, {
          viewerUserId: req.auth.user.id,
          viewerSessionId: req.auth.sessionPublicId,
        }),
      });
    } catch (error) {
      const failedCall =
        typeof store.markCallRoomJoinFailure === "function"
          ? await store.markCallRoomJoinFailure({
              callId: call.id,
              reason: error?.message || "room_prepare_failed",
            })
          : call;
      logCallEvent("accept.failed", failedCall || call, {
        viewerUserId: req.auth.user.id,
        error: String(error?.message || error || "room_prepare_failed"),
      });
      res.status(502).json({message: "Не удалось подготовить комнату звонка"});
    }
  });

  // Group late-join: any CHAT member can "залететь" into a live call. Unlike
  // /accept (invited-recipient only), /join is chat-membership-gated
  // (requireCallJoinAccess) and works for any participant — a pre-invited
  // member, a non-invited chat member, or the initiator joining from another
  // device. joinActiveCall puts a non-invited joiner on the roster first.
  app.post("/v1/calls/:callId/join", requireAuth, async (req, res) => {
    if (!resolvedLiveKitService.isConfigured) {
      res.status(503).json({message: "Звонки пока не настроены на сервере"});
      return;
    }

    const call = await requireCallJoinAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }
    // Joinable while the call is still live (ringing or active); the first
    // joiner flips ringing -> active inside addCallParticipantSession.
    if (call.state !== "ringing" && call.state !== "active") {
      res.status(409).json({message: "Звонок уже недоступен"});
      return;
    }

    await joinActiveCall(req, res, call);
  });

  app.post("/v1/calls/:callId/reject", requireAuth, async (req, res) => {
    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }
    const rejectedCall = await store.rejectCall({
      callId: call.id,
      userId: req.auth.user.id,
    });
    if (rejectedCall === null) {
      res.status(404).json({message: "Звонок не найден"});
      return;
    }
    if (rejectedCall === false) {
      res.status(403).json({message: "Только получатель может отклонить звонок"});
      return;
    }
    if (rejectedCall === undefined) {
      res.status(409).json({message: "Звонок уже неактуален"});
      return;
    }
    clearCallInviteTimeout(rejectedCall.id);
    await publishCallState(rejectedCall);
    logCallEvent("reject.completed", rejectedCall, {
      viewerUserId: req.auth.user.id,
    });
    res.json({
      call: mapCallRecord(rejectedCall, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  app.post("/v1/calls/:callId/cancel", requireAuth, async (req, res) => {
    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }
    const cancelledCall = await store.cancelCall({
      callId: call.id,
      userId: req.auth.user.id,
    });
    if (cancelledCall === null) {
      res.status(404).json({message: "Звонок не найден"});
      return;
    }
    if (cancelledCall === false) {
      res.status(403).json({message: "Только инициатор может отменить звонок"});
      return;
    }
    if (cancelledCall === undefined) {
      res.status(409).json({message: "Звонок уже неактуален"});
      return;
    }
    clearCallInviteTimeout(cancelledCall.id);
    await publishCallState(cancelledCall);
    logCallEvent("cancel.completed", cancelledCall, {
      viewerUserId: req.auth.user.id,
    });
    res.json({
      call: mapCallRecord(cancelledCall, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  app.post("/v1/calls/:callId/hangup", requireAuth, async (req, res) => {
    const call = await requireCallAccess(req, res, req.params.callId);
    if (!call) {
      return;
    }
    const endedCall = await store.hangupCall({
      callId: call.id,
      userId: req.auth.user.id,
    });
    if (endedCall === null) {
      res.status(404).json({message: "Звонок не найден"});
      return;
    }
    if (endedCall === false) {
      res.status(403).json({message: "Доступ к звонку запрещён"});
      return;
    }
    if (endedCall === undefined) {
      res.status(409).json({message: "Звонок уже завершён"});
      return;
    }
    clearCallInviteTimeout(endedCall.id);
    await publishCallState(endedCall);
    logCallEvent("hangup.completed", endedCall, {
      viewerUserId: req.auth.user.id,
    });
    res.json({
      call: mapCallRecord(endedCall, {
        viewerUserId: req.auth.user.id,
        viewerSessionId: req.auth.sessionPublicId,
      }),
    });
  });

  registerUserRoutes(app, {
    store,
    requireAuth,
    sanitizeUserProfilePreview,
    sanitizeProfile,
    computeProfileStatus,
    buildProfileViewerContext,
  });

  registerNotificationRoutes(app, {
    store,
    requireAuth,
    mapNotification,
  });

  registerPushRoutes(app, {
    store,
    config,
    requireAuth,
    mapPushDevice,
    mapPushDelivery,
  });

  registerPendingInvitationRoutes(app, {
    store,
    requireAuth,
    mapTree,
    mapPerson,
  });

  app.use((req, res) => {
    res.status(404).json({
      message: "Route not found",
      requestId: req.requestId,
    });
  });

  app.use((error, req, res, next) => {
    if (typeof runtimeInfo?.captureError === "function") {
      runtimeInfo.captureError("express", error, {
        requestId: req.requestId,
        method: req.method,
        path: req.originalUrl || req.path || "/",
      });
    }
    console.error(
      "[backend] unhandled-error",
      JSON.stringify({
        requestId: req.requestId,
        method: req.method,
        path: req.originalUrl || req.path || "/",
        name: error?.name || "Error",
        message: error?.message || String(error),
        stack: error?.stack || null,
      }),
    );

    if (res.headersSent) {
      next(error);
      return;
    }

    res.status(500).json({
      message: "Внутренняя ошибка backend",
      requestId: req.requestId,
    });
  });

  return app;
}

module.exports = {
  createApp,
};
