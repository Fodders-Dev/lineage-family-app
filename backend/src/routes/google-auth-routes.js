function registerGoogleAuthRoutes(
  app,
  {
    store,
    requireAuth,
    googleTokenVerifier,
    buildGoogleIdentityFromPayload,
    authResponse,
    readDeviceContext = () => ({}),
  },
) {
  app.post("/v1/auth/google", async (req, res) => {
    const idToken = String(req.body?.idToken || "").trim();
    if (!idToken) {
      res.status(400).json({message: "Нужен Google idToken"});
      return;
    }

    try {
      const googlePayload = await googleTokenVerifier.verifyIdToken(idToken);
      const googleIdentity = buildGoogleIdentityFromPayload(googlePayload);
      const emailVerified = googleIdentity.metadata?.emailVerified === true;
      const verifiedEmail = emailVerified ? googleIdentity.email : null;

      const resolution = await store.resolveAuthIdentityTarget({
        provider: googleIdentity.provider,
        providerUserId: googleIdentity.providerUserId,
        email: verifiedEmail,
      });

      // Ship Bug B (2026-05-26): refuse silent cross-provider merge.
      // resolveAuthIdentityTarget surfaces email_provider_mismatch
      // когда email matches existing user без provider+sub match.
      // Frontend ловит 409 → shows disambig modal с existingProviders
      // list so user can log in via their actual existing identity.
      if (resolution?.reason === "email_provider_mismatch") {
        res.status(409).json({
          error: "EMAIL_PROVIDER_MISMATCH",
          message:
            "Этот email уже привязан к другому способу входа в Родне.",
          email: resolution.email || verifiedEmail,
          existingProviders: resolution.existingProviders || [],
        });
        return;
      }

      let user = null;
      // Phase 6 chunk 4a: track create-vs-link to compute
      // `requiresOnboarding` flag.
      let isFreshSignup = false;
      if (resolution?.user?.id) {
        user = await store.linkAuthIdentity(resolution.user.id, googleIdentity);
      } else {
        if (!verifiedEmail) {
          res.status(409).json({
            message:
              "Google аккаунт не вернул подтверждённый email. Пока завершите вход через email и пароль, затем привяжите Google.",
          });
          return;
        }

        // 152-ФЗ / RuStore: свежий аккаунт через соцвход требует того же
        // явного согласия, что и чекбокс регистрации по email. Гейт
        // БЕЗУСЛОВНЫЙ (06.09.2026): rollout-флаг consentCapable больше не
        // смотрим — все клиенты с модалкой согласия ≥ 1.0.19, а свежая
        // регистрация идёт только с новых сборок (OTA/веб). Клиент без
        // модалки получит {requiresConsent:true} и аккаунт не создаст —
        // это требование закона, а не поломка. Флаг в теле игнорируется.
        const consentDocVersion = String(
          req.body?.consentDocVersion || "",
        ).trim();
        if (!consentDocVersion) {
          res.json({requiresConsent: true, provider: "google"});
          return;
        }

        user = await store.createUser({
          email: verifiedEmail,
          displayName: googleIdentity.displayName || verifiedEmail,
          password: null,
          authIdentity: googleIdentity,
          photoUrl: googleIdentity.metadata?.picture || null,
          consentDocVersion: consentDocVersion || null,
        });
        isFreshSignup = true;
      }

      const sessionTokens = await store.createSession(
        user.id,
        readDeviceContext(req),
      );
      const requiresOnboarding = isFreshSignup
        ? true
        : await store.hasIncompleteOnboarding({userId: user.id});
      res.json(authResponse(user, sessionTokens, {requiresOnboarding}));
    } catch (error) {
      if (error?.message === "GOOGLE_AUTH_NOT_CONFIGURED") {
        res.status(503).json({
          message:
            "Google sign-in пока не настроен на backend. Добавьте RODNYA_GOOGLE_WEB_CLIENT_ID.",
        });
        return;
      }
      if (
        error?.message === "GOOGLE_ID_TOKEN_REQUIRED" ||
        error?.message === "GOOGLE_ID_TOKEN_INVALID"
      ) {
        res.status(400).json({message: "Не удалось разобрать Google idToken"});
        return;
      }
      if (error?.message === "AUTH_IDENTITY_ALREADY_LINKED") {
        res.status(409).json({
          message: "Этот Google уже привязан к другому аккаунту Родни.",
        });
        return;
      }
      if (error?.message === "AUTH_PROVIDER_ALREADY_LINKED_FOR_USER") {
        res.status(409).json({
          message:
            "К этому аккаунту уже привязан другой Google-аккаунт.",
        });
        return;
      }
      if (error?.message === "EMAIL_ALREADY_EXISTS") {
        res.status(409).json({
          message:
            "Этот email уже зарегистрирован. Войдите через email и пароль, затем привяжите Google.",
        });
        return;
      }

      console.error("[backend] google auth failed", error);
      res.status(401).json({
        message: "Не удалось проверить вход через Google.",
      });
    }
  });

  app.post("/v1/auth/google/link", requireAuth, async (req, res) => {
    const idToken = String(req.body?.idToken || "").trim();
    if (!idToken) {
      res.status(400).json({message: "Нужен Google idToken"});
      return;
    }

    try {
      const googlePayload = await googleTokenVerifier.verifyIdToken(idToken);
      const googleIdentity = buildGoogleIdentityFromPayload(googlePayload);
      const updatedUser = await store.linkAuthIdentity(
        req.auth.user.id,
        googleIdentity,
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
      if (error?.message === "GOOGLE_AUTH_NOT_CONFIGURED") {
        res.status(503).json({
          message:
            "Google sign-in пока не настроен на backend. Добавьте RODNYA_GOOGLE_WEB_CLIENT_ID.",
        });
        return;
      }
      if (
        error?.message === "GOOGLE_ID_TOKEN_REQUIRED" ||
        error?.message === "GOOGLE_ID_TOKEN_INVALID"
      ) {
        res.status(400).json({message: "Не удалось разобрать Google idToken"});
        return;
      }
      if (error?.message === "AUTH_IDENTITY_ALREADY_LINKED") {
        res.status(409).json({
          message: "Этот Google уже привязан к другому аккаунту Родни.",
        });
        return;
      }
      if (error?.message === "AUTH_PROVIDER_ALREADY_LINKED_FOR_USER") {
        res.status(409).json({
          message:
            "К этому аккаунту уже привязан другой Google-аккаунт.",
        });
        return;
      }
      if (error?.message === "INVALID_AUTH_IDENTITY") {
        res.status(400).json({message: "Некорректные данные Google identity"});
        return;
      }

      console.error("[backend] google link failed", error);
      res.status(401).json({
        message: "Не удалось привязать Google к аккаунту.",
      });
    }
  });
}

module.exports = {
  registerGoogleAuthRoutes,
};
