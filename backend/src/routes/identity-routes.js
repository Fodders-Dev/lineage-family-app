const {FileStore} = require("../store");

function registerIdentityRoutes(
  app,
  {store, requireAuth, requireTreeAccess, requireGraphPersonEdit},
) {
  app.get(
    "/v1/trees/:treeId/persons/:personId/attributes",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }
      const attributes = await store.listPersonAttributes({
        treeId: tree.id,
        personId: req.params.personId,
      });
      if (attributes === null) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }
      // Phase 3.2 (DECISIONS.md ответ A.3): sensitive attributes
      // (phone/email/currentAddress) — owner-only ВСЕГДА, даже на
      // public-узлах. Не-owner viewer не видит row'и с такими
      // ключами; non-sensitive проходят.
      // SPEED-12: req.storeSnapshot (положен requireTreeAccess на
      // федеративном пути) переиспользуется и для findGraphPersonByLegacy,
      // и для гейта ниже — вместо двух отдельных чтений блоба. Сам
      // listPersonAttributes выше НЕ переведён на снимок: он лениво
      // материализует personAttributes для legacy-person'ов
      // (upsertPersonAttributesForPerson пишет в db.personAttributes) —
      // на заморожённом снимке .push() бросил бы TypeError именно в
      // том случае, ради которого метод существует.
      const db = req.storeSnapshot || (await store.readSharedSnapshot());
      const graphPerson = await store.findGraphPersonByLegacy(
        req.params.personId,
        db,
      );
      const visibleAttributes = store.filterSensitiveAttributesForViewer({
        db,
        graphPerson,
        viewerUserId: req.auth.user.id,
        attributes,
      });
      res.json({attributes: visibleAttributes});
    },
  );

  app.put(
    "/v1/trees/:treeId/persons/:personId/attributes",
    requireAuth,
    async (req, res) => {
      // Phase 3.2: write to attributes требует edit-gate
      // (anonymous: tree-access, claimed: owner/grant). Sensitive
      // keys в payload проверяются дополнительно ниже —
      // ВСЕ sensitive writes owner-only-всегда.
      const ctx = await requireGraphPersonEdit(
        req,
        res,
        req.params.treeId,
        req.params.personId,
        "edit",
      );
      if (!ctx) return;
      const {tree, graphPerson} = ctx;

      const incomingAttributes = Array.isArray(req.body?.attributes)
        ? req.body.attributes
        : [];

      // Owner-only-всегда для sensitive fields (category=contacts),
      // регardless of grant. Не-owner может менять прочие поля
      // attribute'ов (имя/фото/места и т.д.) через layered edit-gate,
      // но contacts — только сам владелец graphPerson'а.
      const owner = graphPerson
        ? graphPerson.userId || graphPerson.createdBy || null
        : null;
      const viewerIsOwner = owner === req.auth.user.id;
      const sensitiveWriteAttempt = incomingAttributes.find(
        (entry) =>
          entry &&
          typeof entry === "object" &&
          FileStore.isSensitiveAttributeField(entry.field),
      );
      if (sensitiveWriteAttempt && !viewerIsOwner) {
        res.status(403).json({
          message:
            "Контактные поля (телефон, e-mail, адрес) может менять только владелец карточки",
        });
        return;
      }

      const updated = await store.updatePersonAttributeVisibility({
        treeId: tree.id,
        personId: req.params.personId,
        actorUserId: req.auth.user.id,
        cardVisibility: req.body?.visibility,
        attributes: incomingAttributes,
      });
      if (updated === null) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }
      if (updated === false) {
        res.status(403).json({message: "Нет доступа к приватности карточки"});
        return;
      }
      res.json({attributes: updated});
    },
  );

  app.post("/v1/identity-claims", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();
    const personId = String(req.body?.personId || "").trim();
    if (!treeId || !personId) {
      res.status(400).json({message: "Нужны treeId и personId"});
      return;
    }
    const tree = await requireTreeAccess(req, res, treeId);
    if (!tree) {
      return;
    }
    const claim = await store.createIdentityClaim({
      treeId: tree.id,
      personId,
      claimantUserId: req.auth.user.id,
      evidence: req.body?.evidence,
    });
    if (!claim) {
      res.status(404).json({message: "Карточка не найдена"});
      return;
    }
    res.status(201).json({claim});
  });

  app.get("/v1/identity-claims/pending", requireAuth, async (req, res) => {
    const claims = await store.listPendingIdentityClaimsForUser(req.auth.user.id);
    res.json({claims});
  });

  app.post(
    "/v1/identity-claims/:claimId/review",
    requireAuth,
    async (req, res) => {
      const claim = await store.reviewIdentityClaim({
        claimId: req.params.claimId,
        reviewerUserId: req.auth.user.id,
        decision: req.body?.decision,
        reason: req.body?.reason,
      });
      if (claim === null) {
        res.status(404).json({message: "Запрос не найден"});
        return;
      }
      if (claim === false) {
        res.status(403).json({message: "Нет доступа к этому запросу"});
        return;
      }
      res.json({claim});
    },
  );

  app.patch("/v1/identity-discovery/me", requireAuth, async (req, res) => {
    const result = await store.setIdentityDiscoverability({
      userId: req.auth.user.id,
      isPublicDiscoverable: req.body?.isPublicDiscoverable === true,
    });
    if (!result) {
      res.status(404).json({message: "Identity не найдена"});
      return;
    }
    res.json(result);
  });

  app.get("/v1/identity-discovery/search", requireAuth, async (req, res) => {
    const requestedLimit = Number(req.query.limit || 20);
    const results = await store.searchPublicIdentities({
      query: req.query.query,
      birthYear: req.query.birthYear,
      limit: Number.isFinite(requestedLimit) ? requestedLimit : 20,
    });
    res.json({results});
  });
}

module.exports = {
  registerIdentityRoutes,
};
