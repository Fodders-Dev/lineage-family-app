function registerAuthSessionRoutes(
  app,
  {
    store,
    mediaStorage,
    config = {},
    emailSender = null,
    requireAuth,
    authResponse,
    sanitizeProfile,
    computeProfileStatus,
    readDeviceContext,
    realtimeHub = null,
    deriveSessionPublicId,
  },
) {
  app.post("/v1/auth/register", async (req, res) => {
    const {email, password, displayName, consentDocVersion} = req.body || {};

    if (!email || !password || !displayName) {
      res.status(400).json({message: "Нужны email, password и displayName"});
      return;
    }

    // ── Input shape validation ────────────────────────────────────────
    // Without these caps an attacker can:
    //   * register accounts with bogus 64KB display names → DB bloat,
    //     UI breakage in chat list / push notifications;
    //   * register trivially-cracked passwords that still pass scrypt
    //     ("a" / "1");
    //   * smuggle CRLF / control characters into displayName which
    //     end up in email subjects / push titles unescaped;
    //   * register a structurally invalid email → orphan account that
    //     can never reset password.
    const trimmedEmail = String(email).trim();
    const trimmedDisplayName = String(displayName);
    const passwordValue = String(password);

    if (trimmedEmail.length > 254) {
      res.status(400).json({
        message: "Email слишком длинный (максимум 254 символа).",
      });
      return;
    }
    // Pragmatic format check — handle 99% of real addresses without
    // trying to be a full RFC-5322 parser. Format failures here just
    // save us a downstream bounce / orphan-account.
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmedEmail)) {
      res
        .status(400)
        .json({message: "Email указан в некорректном формате."});
      return;
    }
    if (passwordValue.length < 8) {
      res
        .status(400)
        .json({message: "Пароль должен быть минимум 8 символов."});
      return;
    }
    if (passwordValue.length > 1024) {
      // Upper bound to keep scrypt's wall-clock bounded — attacker
      // could otherwise submit a 1 MB password and pin a libuv
      // thread for a second per request. 1024 chars is more than
      // any realistic password manager generates.
      res.status(400).json({message: "Пароль слишком длинный."});
      return;
    }
    // Reject control characters (CR, LF, NUL, etc.) so display names
    // can't break headers / push titles when surfaced.
    // eslint-disable-next-line no-control-regex
    if (/[\x00-\x1f\x7f]/.test(trimmedDisplayName)) {
      res.status(400).json({
        message: "Имя содержит недопустимые символы.",
      });
      return;
    }
    if (trimmedDisplayName.trim().length === 0) {
      res.status(400).json({message: "Имя не может быть пустым."});
      return;
    }
    if (trimmedDisplayName.length > 120) {
      res.status(400).json({
        message: "Имя слишком длинное (максимум 120 символов).",
      });
      return;
    }

    // 152-ФЗ: свежая регистрация по email требует того же явного согласия,
    // что и соцвход (см. google-auth-routes/vk-auth-routes, гейт
    // безусловный с 06.09.2026). Экран регистрации делает чекбокс
    // обязательным и всегда шлёт версию — сервер лишь гарантирует это на
    // случай прямого вызова API. БЕЗ consentDocVersion аккаунт не создаём.
    const trimmedConsentDocVersion = String(consentDocVersion || "").trim();
    if (!trimmedConsentDocVersion) {
      res.status(400).json({
        message: "Нужно согласие на обработку персональных данных",
        requiresConsent: true,
        provider: "email",
      });
      return;
    }

    try {
      const user = await store.createUser({
        email: trimmedEmail,
        password: passwordValue,
        displayName: trimmedDisplayName,
        // Согласие с Соглашением/ПДн: клиент шлёт версию документов,
        // момент фиксирует сервер (аддитивно — старые клиенты без поля).
        consentDocVersion: trimmedConsentDocVersion,
      });
      const deviceContext = readDeviceContext(req);
      const sessionTokens = await store.createSession(user.id, deviceContext);
      // Phase 6 chunk 4a: persist initial onboarding state row для
      // wizard resume invariant. Без этого, если client crash'ит
      // ДО `/v1/me/onboarding-state` PATCH, user впадает в legacy
      // bucket на next login и wizard скипнется silently — funnel
      // leak (DECISIONS 2026-05-14 «Option A simplified»).
      await store.updateOnboardingState({
        userId: user.id,
        currentStep: "welcome",
      });
      res.status(201).json(
        authResponse(user, sessionTokens, {requiresOnboarding: true}),
      );
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

    const deviceContext = readDeviceContext(req);
    const sessionTokens = await store.createSession(user.id, deviceContext);
    // Phase 6 chunk 4a: existing user — true только если mid-wizard.
    const requiresOnboarding = await store.hasIncompleteOnboarding({
      userId: user.id,
    });
    res.json(authResponse(user, sessionTokens, {requiresOnboarding}));
  });

  app.post("/v1/auth/refresh", async (req, res) => {
    const {refreshToken} = req.body || {};
    if (!refreshToken) {
      res.status(400).json({message: "Нужен refreshToken"});
      return;
    }

    const session = await store.findSessionByRefreshToken(refreshToken);
    if (!session) {
      res.status(401).json({message: "Сессия по refreshToken не найдена"});
      return;
    }

    const user = await store.findUserById(session.userId);
    if (!user) {
      res.status(401).json({message: "Пользователь сессии не найден"});
      return;
    }

    if (session.token) {
      await store.deleteSession(session.token);
    }

    // Inherit prior device context so refresh keeps the same device identity.
    const requestDeviceContext = readDeviceContext(req);
    const inheritedDeviceContext = {
      instanceId:
        requestDeviceContext.instanceId || session.instanceId || null,
      deviceName:
        requestDeviceContext.deviceName || session.deviceName || null,
      platform: requestDeviceContext.platform || session.platform || null,
      osVersion:
        requestDeviceContext.osVersion || session.osVersion || null,
      appVersion:
        requestDeviceContext.appVersion || session.appVersion || null,
    };
    const nextSessionTokens = await store.createSession(
      user.id,
      inheritedDeviceContext,
    );
    res.json(authResponse(user, nextSessionTokens));
  });

  function describeSession(session, currentSessionPublicId) {
    const publicId = deriveSessionPublicId(
      session.token,
      session.instanceId || "",
    );
    return {
      sessionPublicId: publicId,
      deviceName: session.deviceName || null,
      platform: session.platform || null,
      osVersion: session.osVersion || null,
      appVersion: session.appVersion || null,
      createdAt: session.createdAt || null,
      lastSeenAt: session.lastSeenAt || null,
      isCurrent: publicId === currentSessionPublicId,
    };
  }

  app.get("/v1/auth/sessions", requireAuth, async (req, res) => {
    const sessions = await store.listSessionsForUser(req.auth.user.id);
    res.json({
      sessions: sessions.map((session) =>
        describeSession(session, req.auth.sessionPublicId),
      ),
      currentSessionPublicId: req.auth.sessionPublicId,
    });
  });

  app.patch("/v1/auth/sessions/:publicId", requireAuth, async (req, res) => {
    const publicId = String(req.params.publicId || "").trim();
    if (!publicId) {
      res.status(400).json({message: "Нужен идентификатор сессии"});
      return;
    }
    const session = await store.findSessionByPublicId(
      req.auth.user.id,
      publicId,
    );
    if (!session) {
      res.status(404).json({message: "Сессия не найдена"});
      return;
    }
    const deviceName =
      req.body && Object.prototype.hasOwnProperty.call(req.body, "deviceName")
        ? req.body.deviceName
        : undefined;
    if (deviceName === undefined) {
      res.status(400).json({message: "Нужно поле deviceName"});
      return;
    }
    const updated = await store.updateSessionMetadata(session.token, {
      deviceName,
    });
    if (!updated) {
      res.status(404).json({message: "Сессия не найдена"});
      return;
    }
    res.json({session: describeSession(updated, req.auth.sessionPublicId)});
  });

  app.delete("/v1/auth/sessions/:publicId", requireAuth, async (req, res) => {
    const publicId = String(req.params.publicId || "").trim();
    if (!publicId) {
      res.status(400).json({message: "Нужен идентификатор сессии"});
      return;
    }
    if (publicId === req.auth.sessionPublicId) {
      res.status(400).json({
        message:
          "Чтобы выйти из текущей сессии, используйте /v1/auth/logout",
      });
      return;
    }
    const session = await store.findSessionByPublicId(
      req.auth.user.id,
      publicId,
    );
    if (!session) {
      res.status(404).json({message: "Сессия не найдена"});
      return;
    }
    await store.deleteSession(session.token);

    if (typeof store.unbindPushDevicesForSession === "function") {
      try {
        await store.unbindPushDevicesForSession({
          userId: req.auth.user.id,
          sessionPublicId: publicId,
        });
      } catch (error) {
        // push cleanup is best-effort; ignore
      }
    }

    if (realtimeHub && typeof realtimeHub.disconnectSession === "function") {
      realtimeHub.disconnectSession(req.auth.user.id, publicId, {
        reason: "session.revoked.remote",
      });
    }

    if (realtimeHub && typeof realtimeHub.publishToUser === "function") {
      realtimeHub.publishToUser(req.auth.user.id, {
        type: "session.list.changed",
        revokedSessionPublicId: publicId,
      });
    }

    res.status(204).send();
  });

  app.get("/v1/auth/session", requireAuth, async (req, res) => {
    const user = await store.findUserById(req.auth.user.id);
    const profile = sanitizeProfile(user.profile);
    // Phase 6 chunk 4a follow-up: include requiresOnboarding в session
    // refresh responses. Без этого client's checkProfileCompleteness path
    // overwrites session.requiresOnboarding к false (response не carries
    // the field), breaking post-signup /setup redirect logic.
    const requiresOnboarding = await store.hasIncompleteOnboarding({
      userId: user.id,
    });
    res.json({
      session: {
        accessToken: req.auth.token,
        refreshToken: req.auth.session.refreshToken,
        userId: user.id,
      },
      user: {
        id: user.id,
        identityId: user.identityId || null,
        email: user.email,
        displayName: profile.displayName,
        photoUrl: profile.photoUrl,
        providerIds: user.providerIds || ["password"],
      },
      profileStatus: computeProfileStatus(user.profile),
      requiresOnboarding,
    });
  });

  app.post("/v1/auth/logout", requireAuth, async (req, res) => {
    const sessionPublicId = req.auth.sessionPublicId;
    await store.deleteSession(req.auth.token);
    if (
      sessionPublicId &&
      typeof store.unbindPushDevicesForSession === "function"
    ) {
      try {
        await store.unbindPushDevicesForSession({
          userId: req.auth.user.id,
          sessionPublicId,
        });
      } catch (_) {
        // best-effort
      }
    }
    res.json({ok: true});
  });

  const QR_LOGIN_TTL_MS = 60_000;

  app.post("/v1/auth/qr/start", async (req, res) => {
    const deviceContext = readDeviceContext(req);
    if (!deviceContext.instanceId) {
      res.status(400).json({
        message:
          "Нужен заголовок X-Client-Instance-Id, чтобы привязать сессию к устройству",
      });
      return;
    }
    const expiresAt = new Date(Date.now() + QR_LOGIN_TTL_MS).toISOString();
    const handoff = await store.createAuthHandoff({
      type: "qr_login",
      payload: {
        deviceInfo: deviceContext,
        status: "pending",
      },
      expiresAt,
    });
    res.status(201).json({
      token: handoff.code,
      expiresAt,
    });
  });

  app.get("/v1/auth/qr/poll", async (req, res) => {
    const token = String(req.query?.token || "").trim();
    if (!token) {
      res.status(400).json({message: "Нужен token"});
      return;
    }
    const handoff = await store.findAuthHandoff(token, {type: "qr_login"});
    if (!handoff) {
      res.status(410).json({status: "expired"});
      return;
    }
    const status = String(handoff.payload?.status || "pending");
    if (status !== "approved") {
      res.json({status});
      return;
    }
    const consumed = await store.consumeAuthHandoff(token, {type: "qr_login"});
    if (!consumed) {
      res.status(410).json({status: "expired"});
      return;
    }
    res.json({
      status: "approved",
      auth: consumed.payload?.auth || null,
    });
  });

  app.post("/v1/auth/qr/approve", requireAuth, async (req, res) => {
    const token = String(req.body?.token || "").trim();
    if (!token) {
      res.status(400).json({message: "Нужен token"});
      return;
    }
    const handoff = await store.findAuthHandoff(token, {type: "qr_login"});
    if (!handoff) {
      res.status(410).json({message: "QR-код истёк или не найден"});
      return;
    }
    if (handoff.payload?.status === "approved") {
      res.status(409).json({message: "QR-код уже подтверждён"});
      return;
    }

    const storedDeviceInfo =
      handoff.payload?.deviceInfo && typeof handoff.payload.deviceInfo === "object"
        ? handoff.payload.deviceInfo
        : {};
    if (!storedDeviceInfo.instanceId) {
      res.status(400).json({
        message: "QR-код не содержит данных устройства",
      });
      return;
    }

    const sessionTokens = await store.createSession(req.auth.user.id, {
      instanceId: storedDeviceInfo.instanceId,
      deviceName: storedDeviceInfo.deviceName || null,
      platform: storedDeviceInfo.platform || null,
      osVersion: storedDeviceInfo.osVersion || null,
      appVersion: storedDeviceInfo.appVersion || null,
    });
    const user = await store.findUserById(req.auth.user.id);
    // Phase 6 chunk 4a: QR-login = existing-user handoff, mid-wizard
    // resume only.
    const requiresOnboarding = await store.hasIncompleteOnboarding({
      userId: user.id,
    });
    const auth = authResponse(user, sessionTokens, {requiresOnboarding});

    await store.updateAuthHandoffPayload(
      token,
      {status: "approved", auth, approvedAt: new Date().toISOString()},
      {type: "qr_login"},
    );

    if (realtimeHub && typeof realtimeHub.publishToUser === "function") {
      realtimeHub.publishToUser(req.auth.user.id, {
        type: "session.list.changed",
        addedSessionPublicId: deriveSessionPublicId(
          sessionTokens.token,
          storedDeviceInfo.instanceId,
        ),
      });
    }

    res.json({
      ok: true,
      sessionPublicId: deriveSessionPublicId(
        sessionTokens.token,
        storedDeviceInfo.instanceId,
      ),
    });
  });

  // ── Password reset request ──────────────────────────────────────
  // Anti-enumeration contract: this endpoint returns the SAME 202
  // shape and roughly the same wall-clock latency regardless of
  // whether the email is registered. Without that, an attacker
  // hitting POST /password-reset/request can map "registered →
  // 202 quickly + email sent" vs "not registered → 202 quickly
  // but no email" via timing or downstream observation. So we
  // do the work silently behind the response.
  //
  // Rate limiting:
  //   * The auth rate limiter (30/IP/min) caps blast radius at
  //     the IP layer.
  //   * `store.issuePasswordResetToken` enforces a 1-token-per-user-
  //     per-hour cap, which prevents an attacker who knows a user
  //     exists from flooding their inbox.
  app.post("/v1/auth/password-reset/request", async (req, res) => {
    const rawEmail = req.body?.email;
    const email = String(rawEmail || "").trim().toLowerCase();

    // Always 202. We do NOT reveal whether the email is registered.
    // Return BEFORE the async work completes — token issue + email
    // send happen in the background. The client's perceived latency
    // is identical for known + unknown emails.
    res.status(202).json({ok: true});

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return;
    }
    if (email.length > 254) {
      return;
    }

    try {
      const user = await store.findUserByEmail(email);
      if (!user) {
        return;
      }

      const issued = await store.issuePasswordResetToken(user.id);
      if (!issued) {
        // Either rate-limited or user vanished mid-call. Anti-
        // enumeration: stay silent.
        return;
      }

      // Build the reset URL. `publicAppUrl` is the user-facing
      // domain (rodnya-tree.ru in production); the path matches
      // whatever the Flutter `/reset-password` route expects.
      const baseUrl = String(
        config?.publicAppUrl || "https://rodnya-tree.ru",
      ).replace(/\/+$/u, "");
      const resetUrl = `${baseUrl}/reset-password?token=${encodeURIComponent(issued.plaintext)}`;

      if (emailSender) {
        const result = await emailSender.sendPasswordResetEmail({
          to: email,
          resetUrl,
          displayName: user.profile?.displayName || "",
        });
        if (!result?.ok) {
          console.error(
            "[backend] password reset email send failed",
            JSON.stringify({
              requestId: req.requestId,
              userId: user.id,
              email,
            }),
          );
        }
      } else {
        // Should never happen in production wiring, but guard
        // against a misconfigured app.js setup.
        console.warn(
          "[backend] password reset issued but no emailSender configured",
        );
      }
    } catch (error) {
      // Never bubble — the response was already sent. Log with
      // request id for observability.
      console.error(
        "[backend] password reset request failure",
        JSON.stringify({
          requestId: req.requestId,
          message: error?.message || String(error),
        }),
      );
    }
  });

  // ── Password reset confirm ──────────────────────────────────────
  // Caller posts the token (from the email URL) + new password.
  // We validate the new password's shape BEFORE consuming the
  // token — otherwise a malformed-password attempt would burn a
  // valid token and force the user to re-request from scratch.
  app.post("/v1/auth/password-reset/confirm", async (req, res) => {
    const tokenRaw = req.body?.token;
    const passwordRaw = req.body?.password;
    const token = typeof tokenRaw === "string" ? tokenRaw.trim() : "";
    const password = typeof passwordRaw === "string" ? passwordRaw : "";

    if (!token || !password) {
      res.status(400).json({message: "Нужны token и password"});
      return;
    }
    if (token.length > 256) {
      // Real tokens are ~43 chars (32 bytes base64url). Anything
      // bigger is almost certainly an attack probe.
      res.status(400).json({message: "Некорректный токен"});
      return;
    }
    // Same password-shape rules as /v1/auth/register.
    if (password.length < 8) {
      res
        .status(400)
        .json({message: "Пароль должен быть минимум 8 символов."});
      return;
    }
    if (password.length > 1024) {
      res.status(400).json({message: "Пароль слишком длинный."});
      return;
    }

    try {
      const userId = await store.consumePasswordResetToken(token);
      if (!userId) {
        // Same generic error for invalid/expired/already-used —
        // gives the attacker no signal.
        res.status(400).json({
          message: "Ссылка для сброса пароля недействительна или истекла",
        });
        return;
      }

      const updated = await store.updateUserPassword(userId, password);
      if (!updated) {
        // User was deleted between consume and update. Generic
        // error again.
        res.status(400).json({
          message: "Не удалось обновить пароль",
        });
        return;
      }

      res.json({ok: true});
    } catch (error) {
      console.error(
        "[backend] password reset confirm failure",
        JSON.stringify({
          requestId: req.requestId,
          message: error?.message || String(error),
        }),
      );
      res.status(500).json({message: "Не удалось сбросить пароль"});
    }
  });

  app.delete("/v1/auth/account", requireAuth, async (req, res) => {
    const ownedMediaUrls = typeof store.listOwnedMediaUrls === "function"
      ? await store.listOwnedMediaUrls(req.auth.user.id)
      : [];
    await store.deleteUser(req.auth.user.id);

    const mediaCleanupFailures = [];
    for (const mediaUrl of ownedMediaUrls) {
      try {
        await mediaStorage.deleteObjectByUrl(mediaUrl);
      } catch (error) {
        if (
          error?.message === "INVALID_MEDIA_PATH" ||
          error?.message === "UNSUPPORTED_MEDIA_URL" ||
          error instanceof TypeError
        ) {
          continue;
        }

        mediaCleanupFailures.push({
          url: mediaUrl,
          message: error?.message || "unknown_error",
        });
      }
    }

    if (mediaCleanupFailures.length > 0) {
      console.error(
        "[backend] account media cleanup warnings",
        JSON.stringify({
          requestId: req.requestId,
          userId: req.auth.user.id,
          failures: mediaCleanupFailures,
        }),
      );
    }

    res.status(204).send();
  });
}

module.exports = {
  registerAuthSessionRoutes,
};
