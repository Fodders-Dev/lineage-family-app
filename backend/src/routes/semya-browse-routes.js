// Phase B Week 3 Ship 7: семья browse mode endpoints.
//
// Per SHARED-TREE-PROPOSAL.md §3.4 Mode 2 + ENTITY-DESIGN.md §1.5.
//
// Endpoints:
//   POST   /v1/semya/:id/browse-token              — create capability token
//                                                    (owner либо editor с
//                                                    invite-grant)
//   GET    /v1/browse/:token                        — resolve token → семья
//                                                    + tree summary
//                                                    (read-only). Auth
//                                                    NOT required — token
//                                                    is the capability.
//   GET    /v1/semya/:id/browse-tokens             — list active tokens
//                                                    (member+ access — для
//                                                    settings UI)
//   DELETE /v1/semya/:id/browse-token/:tokenId     — revoke (creator либо
//                                                    owner)
//
// Browse session = ephemeral. No persistent membership row created.
// Tap «pull person» → Ship 6 endpoint (caller still needs target editor
// membership; browse access alone не gives mutation power).
//
// Token chains BLOCKED per Артёма spec: GET /v1/browse/:token returns
// read-only payload без token-creation capability. Browse holder must
// request direct invite (Ship 4) либо browse-token (this endpoint) от
// семья owner/editor-с-grant — neither is open к browse-only callers.
//
// Privacy boundary per SHARED-TREE-PROPOSAL §3.5:
// * Persons + relations exposed (basic shape для tree visualization)
// * Photos NOT exposed (semья membership boundary)
// * Person attributes (sensitive contacts category) NOT exposed
// * Notes/familySummary/bio через branchPersonViews — only `label`
//   field exposed
//
// Ship 7 keeps payload minimal — Ship 7+1 либо frontend can request
// richer fields if user feedback signals need.

function registerSemyaBrowseRoutes(
  app,
  {store, requireAuth, requireSemyaAccess},
) {
  function mapTokenSummary(token) {
    if (!token) return null;
    return {
      id: token.id,
      semyaId: token.semyaId,
      createdByUserId: token.createdByUserId,
      createdAt: token.createdAt,
      expiresAt: token.expiresAt,
      revokedAt: token.revokedAt ?? null,
      lastUsedAt: token.lastUsedAt ?? null,
    };
  }

  function mapTokenWithSecret(token) {
    return token
      ? {...mapTokenSummary(token), token: token.token}
      : null;
  }

  function tokenStatus(token) {
    if (token.revokedAt) return "revoked";
    if (token.expiresAt && Date.parse(token.expiresAt) <= Date.now()) {
      return "expired";
    }
    return "active";
  }

  // POST /v1/semya/:id/browse-token — owner либо editor c invite-grant.
  app.post("/v1/semya/:id/browse-token", requireAuth, async (req, res) => {
    const access = await requireSemyaAccess(req, res, req.params.id, {
      requiredRole: "viewer",
    });
    if (!access) return;
    const canCreate =
      access.membership.role === "owner" ||
      (access.membership.role === "editor" &&
        access.membership.hasInviteGrant === true);
    if (!canCreate) {
      res.status(403).json({
        message: "Создавать ссылки на просмотр может владелец либо редактор с правом приглашать",
      });
      return;
    }

    const expiresInDays =
      typeof req.body?.expiresInDays === "number"
        ? Math.max(1, Math.min(90, Math.floor(req.body.expiresInDays)))
        : 30;

    try {
      const token = await store.createBrowseToken({
        semyaId: req.params.id,
        createdByUserId: req.auth.user.id,
        expiresInDays,
      });
      // Secret leaks ONCE — на create response. Subsequent listings
      // return token summary без plaintext secret.
      res.status(201).json({token: mapTokenWithSecret(token)});
    } catch (error) {
      const code = error?.message;
      if (code === "SEMYA_NOT_FOUND") {
        res.status(404).json({message: "Семья не найдена"});
        return;
      }
      if (code === "INVALID_SEMYA_ID" || code === "INVALID_ACTOR") {
        res.status(400).json({message: "Некорректные параметры"});
        return;
      }
      throw error;
    }
  });

  // GET /v1/semya/:id/browse-tokens — list active tokens (для settings).
  app.get("/v1/semya/:id/browse-tokens", requireAuth, async (req, res) => {
    const access = await requireSemyaAccess(req, res, req.params.id, {
      requiredRole: "viewer",
    });
    if (!access) return;
    const tokens = await store.listBrowseTokensForSemya(req.params.id);
    res.json({
      tokens: tokens.map((t) => ({
        ...mapTokenSummary(t),
        status: tokenStatus(t),
      })),
    });
  });

  // DELETE /v1/semya/:id/browse-token/:tokenId — revoke (creator либо
  // owner). Store layer enforces permission (NOT_CREATOR_OR_OWNER).
  app.delete(
    "/v1/semya/:id/browse-token/:tokenId",
    requireAuth,
    async (req, res) => {
      // Permission gate: viewer+ к семья (защита от outsider probing
      // token IDs). Store layer enforces creator-or-owner check.
      const access = await requireSemyaAccess(req, res, req.params.id, {
        requiredRole: "viewer",
      });
      if (!access) return;

      try {
        const token = await store.revokeBrowseToken({
          tokenId: req.params.tokenId,
          actingUserId: req.auth.user.id,
        });
        res.json({token: mapTokenSummary(token)});
      } catch (error) {
        const code = error?.message;
        if (code === "TOKEN_NOT_FOUND") {
          res.status(404).json({message: "Ссылка не найдена"});
          return;
        }
        if (code === "NOT_CREATOR_OR_OWNER") {
          res.status(403).json({
            message: "Отозвать может создатель либо владелец семьи",
          });
          return;
        }
        if (code === "TOKEN_ALREADY_REVOKED") {
          res.status(409).json({
            message: "Эта ссылка уже отозвана",
          });
          return;
        }
        if (code === "INVALID_TOKEN_ID") {
          res.status(400).json({message: "Некорректные параметры"});
          return;
        }
        throw error;
      }
    },
  );

  // GET /v1/browse/:token — capability resolve. NO auth required —
  // token само is the capability. Treat path as bearer-secret —
  // log SHA prefix, не plaintext token.
  app.get("/v1/browse/:token", async (req, res) => {
    const tokenValue = String(req.params.token || "").trim();
    if (!tokenValue) {
      res.status(400).json({message: "Нужен токен"});
      return;
    }

    const token = await store.findBrowseTokenByValue(tokenValue);
    if (!token) {
      res.status(404).json({message: "Ссылка не найдена"});
      return;
    }
    if (token.revokedAt) {
      res.status(410).json({message: "Эта ссылка отозвана"});
      return;
    }
    if (token.expiresAt && Date.parse(token.expiresAt) <= Date.now()) {
      res.status(410).json({message: "Срок действия ссылки истёк"});
      return;
    }

    const semya = await store.findSemyaById(token.semyaId);
    if (!semya || semya.deletedAt) {
      res.status(404).json({message: "Семья не найдена"});
      return;
    }
    const tree = await store.findTree(semya.treeId);
    if (!tree) {
      res.status(404).json({message: "Дерево семьи не найдено"});
      return;
    }

    // Best-effort analytics — touch lastUsedAt async.
    // Не блокируем response.
    store.touchBrowseTokenLastUsed(token.id).catch(() => {});

    // Read-only payload. Photos + sensitive attributes filtered per
    // privacy boundary (SHARED-TREE-PROPOSAL §3.5). Person basic
    // shape sufficient для tree visualization.
    // SPEED-12: readSharedSnapshot() — публичный no-auth маршрут, ничего
    // не мутирует ниже (только filter/map на persons/relations).
    const db = await store.readSharedSnapshot();
    const persons = (db.persons || [])
      .filter((p) => p.treeId === tree.id)
      .map((p) => ({
        id: p.id,
        treeId: p.treeId,
        // `name` combined field per buildPersonRecord canonical
        // storage (store.js:4943). Не split firstName/lastName/
        // middleName в DB — combined string на write. UI tree
        // renderer reads `name` для labels.
        name: p.name ?? null,
        maidenName: p.maidenName ?? null,
        gender: p.gender ?? null,
        birthDate: p.birthDate ?? null,
        // D3: точность дат («знаю только год») — иначе гость увидит
        // фейковую полную дату там, где известен только год.
        birthDatePrecision: p.birthDatePrecision || "exact",
        deathDate: p.deathDate ?? null,
        deathDatePrecision: p.deathDatePrecision || "exact",
        identityId: p.identityId ?? null,
        // Photo URLs + bio + notes + sensitive attributes
        // intentionally omitted (privacy boundary).
      }));
    const relations = (db.relations || [])
      .filter((r) => r.treeId === tree.id)
      .map((r) => ({
        id: r.id,
        treeId: r.treeId,
        person1Id: r.person1Id,
        person2Id: r.person2Id,
        relation1to2: r.relation1to2,
        relation2to1: r.relation2to1,
      }));

    res.json({
      browse: {
        semya: {
          id: semya.id,
          name: semya.name,
          description: semya.description ?? null,
        },
        tree: {
          id: tree.id,
          name: tree.name,
          kind: tree.kind ?? "family",
        },
        persons,
        relations,
        readOnly: true,
        sessionExpiresAt: token.expiresAt,
      },
    });
  });
}

module.exports = {registerSemyaBrowseRoutes};
