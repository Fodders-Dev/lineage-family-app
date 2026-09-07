const {
  buildVkAuthorizeUrl,
  createVkPkcePair,
} = require("../vk-auth");
const {sanitizeFinalRedirect} = require("./auth-redirect-util");

function resolveVkDisplayName(user) {
  const explicitName = [
    String(user?.first_name || "").trim(),
    String(user?.last_name || "").trim(),
  ].filter(Boolean).join(" ");

  if (explicitName) {
    return explicitName;
  }

  return String(user?.email || "").trim() || null;
}

function buildVkIdentityFromUserInfo(userInfo) {
  const user = userInfo?.user && typeof userInfo.user === "object"
    ? userInfo.user
    : {};
  const providerUserId =
    String(user?.user_id || userInfo?.user_id || "").trim();
  if (!providerUserId) {
    throw new Error("VK_USER_INFO_INVALID");
  }

  const email = String(user?.email || "").trim().toLowerCase() || null;
  const phoneNumber = String(user?.phone || "").trim() || null;
  const displayName = resolveVkDisplayName(user);
  const avatar = String(user?.avatar || "").trim() || null;

  return {
    provider: "vk",
    providerUserId,
    email,
    phoneNumber,
    displayName,
    metadata: {
      firstName: String(user?.first_name || "").trim() || null,
      lastName: String(user?.last_name || "").trim() || null,
      avatar,
      email,
      phoneNumber,
    },
  };
}

function registerVkAuthRoutes(
  app,
  {
    store,
    requireAuth,
    vkAuthClient,
    resolvePublicApiUrl,
    resolvePublicAppUrl,
    authResponse,
    readDeviceContext = () => ({}),
  },
) {
  function vkAuthRedirectUrl(code, {intent = "login", finalRedirect} = {}) {
    const params = {
      vkAuthCode: code,
      ...(intent === "link" ? {vkIntent: "link"} : {}),
    };
    // Single output chokepoint: only an allowlisted finalRedirect ever
    // receives the auth code; anything else falls back to the app's own
    // /#/login (blocks open-redirect auth-code exfiltration).
    const safeRedirect = sanitizeFinalRedirect(finalRedirect, resolvePublicAppUrl());
    if (safeRedirect) {
      const sep = safeRedirect.includes("?") ? "&" : "?";
      const query = new URLSearchParams(params).toString();
      return `${safeRedirect}${sep}${query}`;
    }
    const query = new URLSearchParams(params);
    return `${resolvePublicAppUrl()}/#/login?${query.toString()}`;
  }

  app.get("/v1/auth/vk/start", async (req, res) => {
    if (!vkAuthClient.isEnabled) {
      res.status(503).send("VK ID login is not configured.");
      return;
    }

    const intent = String(req.query?.intent || "").trim().toLowerCase() === "link"
      ? "link"
      : "login";
    const callbackUrl = `${resolvePublicApiUrl(req).replace(/\/$/, "")}/v1/auth/vk/callback`;
    const {codeVerifier, codeChallenge} = createVkPkcePair();
    const deviceContext = readDeviceContext(req);
    const finalRedirectRaw = typeof req.query?.finalRedirect === "string"
        ? req.query.finalRedirect
        : null;
    // Don't even stash an off-origin redirect in the handoff (defence in
    // depth — the builder re-checks at the output chokepoint too).
    const finalRedirect = sanitizeFinalRedirect(
        finalRedirectRaw,
        resolvePublicAppUrl(),
    );
    // 152-ФЗ: версия согласия (клиент ставит её при повторном старте после
    // модалки) едет через redirect-танец в handoff, чтобы callback применил
    // тот же безусловный гейт, что и Google. Флаг consentCapable в query
    // старые клиенты ещё шлют — игнорируется (гейт безусловный с 06.09.2026).
    const consentDocVersion =
        typeof req.query?.consentDocVersion === "string"
            ? req.query.consentDocVersion.trim()
            : "";
    const authFlowHandoff = await store.createAuthHandoff({
      type: "vk_auth_flow",
      payload: {
        intent,
        codeVerifier,
        redirectUri: callbackUrl,
        deviceContext,
        finalRedirect,
        consentDocVersion: consentDocVersion || null,
      },
    });

    res.setHeader("cache-control", "no-store");
    res.redirect(
      302,
      buildVkAuthorizeUrl({
        appId: vkAuthClient.webAppId,
        redirectUri: callbackUrl,
        state: authFlowHandoff.code,
        codeChallenge,
      }),
    );
  });

  app.get("/v1/auth/vk/callback", async (req, res) => {
    let stashedFinalRedirect = null;
    try {
      if (!vkAuthClient.isEnabled) {
        throw new Error("VK_AUTH_NOT_CONFIGURED");
      }

      const providerError = String(req.query?.error || "").trim();
      if (providerError) {
        const error = new Error(providerError);
        error.description = String(req.query?.error_description || "").trim();
        throw error;
      }

      const state = String(req.query?.state || "").trim();
      const code = String(req.query?.code || "").trim();
      const deviceId = String(
        req.query?.device_id || req.query?.deviceId || "",
      ).trim();
      if (!state || !code || !deviceId) {
        throw new Error("VK_AUTH_CALLBACK_INVALID");
      }

      const authFlowHandoff = await store.consumeAuthHandoff(state, {
        type: "vk_auth_flow",
      });
      if (!authFlowHandoff) {
        throw new Error("VK_AUTH_STATE_INVALID");
      }

      const intent = String(authFlowHandoff.payload?.intent || "").trim().toLowerCase() === "link"
        ? "link"
        : "login";
      const callbackUrl = String(authFlowHandoff.payload?.redirectUri || "").trim() ||
        `${resolvePublicApiUrl(req).replace(/\/$/, "")}/v1/auth/vk/callback`;
      const codeVerifier = String(authFlowHandoff.payload?.codeVerifier || "").trim();
      if (!codeVerifier) {
        throw new Error("VK_AUTH_STATE_INVALID");
      }
      stashedFinalRedirect =
        typeof authFlowHandoff.payload?.finalRedirect === "string"
          ? authFlowHandoff.payload.finalRedirect
          : null;

      // Prefer the device context that was stashed when /start was loaded
      // by the original device — the callback is hit by the OAuth provider
      // and so does not carry the Flutter X-Client-Instance-Id header.
      const stashedDeviceContext =
        authFlowHandoff.payload?.deviceContext &&
        typeof authFlowHandoff.payload.deviceContext === "object"
          ? authFlowHandoff.payload.deviceContext
          : null;
      const effectiveDeviceContext =
        stashedDeviceContext &&
        Object.values(stashedDeviceContext).some((value) => value)
          ? stashedDeviceContext
          : readDeviceContext(req);

      const vkTokenResult = await vkAuthClient.exchangeCode({
        code,
        deviceId,
        state,
        codeVerifier,
        redirectUri: callbackUrl,
      });
      const vkUserInfo = await vkAuthClient.fetchUserInfo(
        vkTokenResult.access_token,
      );
      const vkIdentity = buildVkIdentityFromUserInfo(vkUserInfo);
      const linkedUser = await store.findUserByAuthIdentity(
        vkIdentity.provider,
        vkIdentity.providerUserId,
      );

      if (linkedUser) {
        if (intent === "link") {
          const authHandoff = await store.createAuthHandoff({
            type: "vk_auth_result",
            userId: linkedUser.id,
            payload: {
              status: "already_linked",
              message:
                "Этот VK ID уже привязан к аккаунту Родни. Если это ваш аккаунт, входите через VK ID с экрана входа.",
            },
          });
          res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }));
          return;
        }

        const refreshedUser = await store.linkAuthIdentity(
          linkedUser.id,
          vkIdentity,
        );
        const sessionTokens = await store.createSession(refreshedUser.id, effectiveDeviceContext);
        // Phase 6 chunk 4a: existing-user re-auth — mid-wizard resume only.
        const requiresOnboarding = await store.hasIncompleteOnboarding({
          userId: refreshedUser.id,
        });
        const authHandoff = await store.createAuthHandoff({
          type: "vk_auth_result",
          userId: refreshedUser.id,
          payload: {
            status: "authenticated",
            auth: authResponse(refreshedUser, sessionTokens, {
              requiresOnboarding,
            }),
          },
        });
        res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }));
        return;
      }

      const resolution = await store.resolveAuthIdentityTarget({
        provider: vkIdentity.provider,
        providerUserId: vkIdentity.providerUserId,
        email: vkIdentity.email,
        phoneNumber: vkIdentity.phoneNumber,
      });

      const vkProfile = {
        firstName: vkIdentity.metadata?.firstName || "",
        lastName: vkIdentity.metadata?.lastName || "",
        email: vkIdentity.email || "",
        phoneNumber: vkIdentity.phoneNumber || "",
        photoUrl: vkIdentity.metadata?.avatar || "",
      };

      // Ship Bug B (2026-05-26): refuse silent cross-provider merge.
      // Only applies to login intent — link intent is post-auth,
      // already handles собственную same-user check ниже. VK flow
      // exits через handoff so we surface mismatch via dedicated
      // status кодуа что frontend сможет render disambig modal
      // mirror Q2 pattern.
      if (
        intent === "login" &&
        resolution?.reason === "email_provider_mismatch"
      ) {
        const authHandoff = await store.createAuthHandoff({
          type: "vk_auth_result",
          payload: {
            status: "email_provider_mismatch",
            email: resolution.email || vkIdentity.email || null,
            existingProviders: resolution.existingProviders || [],
            vkProfile,
            message:
              "Этот email уже привязан к другому способу входа в Родне.",
          },
        });
        res.redirect(
          302,
          vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }),
        );
        return;
      }

      if (intent === "link") {
        const pendingLinkHandoff = await store.createAuthHandoff({
          type: "vk_pending_link",
          payload: {
            vkIdentity,
            vkProfile,
            resolvedUserId: resolution?.user?.id || null,
            resolutionReason: resolution?.reason || "new_account",
          },
        });
        const authHandoff = await store.createAuthHandoff({
          type: "vk_auth_result",
          payload: {
            status: "pending_link",
            linkCode: pendingLinkHandoff.code,
            vkProfile,
            message:
              "VK ID подтверждён. После возвращения мы привяжем его к текущему аккаунту Родни, если не найдём конфликт по подтверждённому номеру или email.",
          },
        });
        res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }));
        return;
      }

      if (resolution?.user?.id) {
        const user = await store.linkAuthIdentity(resolution.user.id, vkIdentity);
        const sessionTokens = await store.createSession(user.id, effectiveDeviceContext);
        // Phase 6 chunk 4a: resolved existing user via email/phone match.
        const requiresOnboarding = await store.hasIncompleteOnboarding({
          userId: user.id,
        });
        const authHandoff = await store.createAuthHandoff({
          type: "vk_auth_result",
          userId: user.id,
          payload: {
            status: "authenticated",
            auth: authResponse(user, sessionTokens, {requiresOnboarding}),
          },
        });
        res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }));
        return;
      }

      if (!vkIdentity.email) {
        const pendingLinkHandoff = await store.createAuthHandoff({
          type: "vk_pending_link",
          payload: {
            vkIdentity,
            vkProfile,
            resolvedUserId: null,
            resolutionReason: resolution?.reason || "new_account",
          },
        });
        const authHandoff = await store.createAuthHandoff({
          type: "vk_auth_result",
          payload: {
            status: "pending_link",
            linkCode: pendingLinkHandoff.code,
            vkProfile,
            message:
              "VK ID не вернул email для безопасного создания нового аккаунта. Войдите в существующий аккаунт Родни и привяжите VK ID оттуда.",
          },
        });
        res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }));
        return;
      }

      // 152-ФЗ / RuStore: тот же гейт, что у Google (google-auth-routes);
      // consentDocVersion припрятана на /start. Есть версия → создаём с ней,
      // нет → requires_consent (модалка на клиенте, повторный поток).
      const consentDocVersion =
          typeof authFlowHandoff.payload?.consentDocVersion === "string"
              ? authFlowHandoff.payload.consentDocVersion.trim()
              : "";
      // Гейт безусловный (06.09.2026), как в google-auth-routes: без версии
      // согласия свежий аккаунт не создаём — отдаём requires_consent, клиент
      // показывает модалку и повторяет поток с consentDocVersion.
      if (!consentDocVersion) {
        const authHandoff = await store.createAuthHandoff({
          type: "vk_auth_result",
          payload: {
            status: "requires_consent",
            provider: "vk",
            vkProfile,
          },
        });
        res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
          intent,
          finalRedirect: stashedFinalRedirect,
        }));
        return;
      }

      const user = await store.createUser({
        email: vkIdentity.email,
        displayName: vkIdentity.displayName || vkIdentity.email,
        password: null,
        authIdentity: vkIdentity,
        photoUrl: vkIdentity.metadata?.avatar || null,
        consentDocVersion: consentDocVersion || null,
      });
      const sessionTokens = await store.createSession(user.id, effectiveDeviceContext);
      const authHandoff = await store.createAuthHandoff({
        type: "vk_auth_result",
        userId: user.id,
        payload: {
          status: "authenticated",
          // Phase 6 chunk 4a: fresh VK signup → wizard required.
          auth: authResponse(user, sessionTokens, {requiresOnboarding: true}),
        },
      });
      res.redirect(302, vkAuthRedirectUrl(authHandoff.code, {
            intent,
            finalRedirect: stashedFinalRedirect,
          }));
    } catch (error) {
      console.error("[backend] vk auth callback failed", error);
      const appUrl = resolvePublicAppUrl();
      const normalizedMessage = (() => {
        switch (error?.message) {
          case "VK_AUTH_NOT_CONFIGURED":
            return "VK ID login пока не настроен";
          case "VK_AUTH_STATE_INVALID":
            return "VK ID login устарел. Повторите попытку.";
          case "VK_AUTH_CALLBACK_INVALID":
          case "VK_AUTH_CODE_REQUIRED":
            return "VK ID не вернул код авторизации. Повторите попытку.";
          case "EMAIL_ALREADY_EXISTS":
            return "Этот email уже зарегистрирован. Войдите в Родню и привяжите VK ID оттуда.";
          case "invalid_request":
          case "access_denied":
            return error?.description || "Вход через VK ID отменён.";
          default:
            return "Не удалось завершить вход через VK ID";
        }
      })();
      if (stashedFinalRedirect &&
          /^[a-z][a-z0-9+.-]*:\/\//.test(stashedFinalRedirect)) {
        const sep = stashedFinalRedirect.includes("?") ? "&" : "?";
        res.redirect(
          302,
          `${stashedFinalRedirect}${sep}vkAuthError=${encodeURIComponent(normalizedMessage)}`,
        );
      } else {
        res.redirect(
          302,
          `${appUrl}/#/login?vkAuthError=${encodeURIComponent(normalizedMessage)}`,
        );
      }
    }
  });

  app.post("/v1/auth/vk/exchange", async (req, res) => {
    const code = String(req.body?.code || "").trim();
    if (!code) {
      res.status(400).json({message: "Нужен code"});
      return;
    }

    const handoff = await store.consumeAuthHandoff(code, {
      type: "vk_auth_result",
    });
    if (!handoff) {
      res.status(404).json({message: "VK ID handoff не найден или уже использован"});
      return;
    }

    res.json(handoff.payload || {});
  });

  app.post("/v1/auth/vk/link", requireAuth, async (req, res) => {
    const code = String(req.body?.code || "").trim();
    if (!code) {
      res.status(400).json({message: "Нужен code"});
      return;
    }

    const handoff = await store.consumeAuthHandoff(code, {
      type: "vk_pending_link",
    });
    if (!handoff) {
      res.status(404).json({message: "VK ID link code не найден или уже использован"});
      return;
    }

    const resolvedUserId = String(handoff.payload?.resolvedUserId || "").trim();
    if (resolvedUserId && resolvedUserId !== req.auth.user.id) {
      res.status(409).json({
        message:
          "Этот VK ID уже совпал с другим аккаунтом Родни по подтверждённому номеру или email. Войдите в тот аккаунт и привяжите VK ID там.",
      });
      return;
    }

    try {
      const updatedUser = await store.linkAuthIdentity(
        req.auth.user.id,
        handoff.payload?.vkIdentity || {},
      );
      res.json({
        ok: true,
        user: {
          id: updatedUser.id,
          identityId: updatedUser.identityId || null,
          email: updatedUser.email,
          providerIds: updatedUser.providerIds || ["password"],
        },
      });
    } catch (error) {
      if (error?.message === "AUTH_IDENTITY_ALREADY_LINKED") {
        res.status(409).json({
          message:
            "Этот VK ID уже привязан к другому аккаунту Родни.",
        });
        return;
      }
      if (error?.message === "AUTH_PROVIDER_ALREADY_LINKED_FOR_USER") {
        res.status(409).json({
          message:
            "К этому аккаунту уже привязан другой VK ID. Сначала отвяжите его или используйте уже связанный вход.",
        });
        return;
      }
      if (error?.message === "INVALID_AUTH_IDENTITY") {
        res.status(400).json({message: "Некорректные данные VK ID"});
        return;
      }
      throw error;
    }
  });
}

module.exports = {
  registerVkAuthRoutes,
};
