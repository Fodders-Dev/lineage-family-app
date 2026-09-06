const {
  findWithinTreeDuplicateCandidates,
} = require("../identity-matcher");
const {
  enforceTextLimit,
  enforceArrayCap,
} = require("../input-guards");

function registerTreeRoutes(
  app,
  {
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
  },
) {
  // Phase 6.5+ auto-refresh: dispatch silent `tree_mutated` ping
  // в audience (owner + grants + identity-linked + members).
  // Payload carries только `{treeId, kind, actorUserId}` — recipient
  // refetches tree state, backend filter handles visibility.
  // Best-effort — failure to dispatch не abortит mutation response.
  async function dispatchTreeMutation({treeId, kind, actorUserId}) {
    if (typeof createAndDispatchNotification !== "function") return;
    try {
      const audience = await store.resolveTreeAudienceUserIds(treeId, {
        excludeUserId: actorUserId,
      });
      for (const recipientId of audience) {
        await createAndDispatchNotification({
          userId: recipientId,
          type: "tree_mutated",
          title: "Дерево обновлено",
          body: "",
          data: {treeId, kind, actorUserId},
          silent: true,
        });
      }
    } catch (error) {
      console.error(
        "[backend] tree_mutated dispatch failed",
        JSON.stringify({
          treeId,
          kind,
          actorUserId,
          message: error?.message || String(error),
        }),
      );
    }
  }
  app.post("/v1/trees", requireAuth, async (req, res) => {
    const {name, description, isPrivate, kind, includeRules} = req.body || {};
    if (!String(name || "").trim()) {
      res.status(400).json({message: "Нужно название дерева"});
      return;
    }

    // Phase 3.4-prep (DECISIONS.md 2026-05-10 Q4 + fix-1): branch
    // wizard передаёт includeRules — applied поверх default manual.
    // Missing/null includeRules → silent default (legacy backward-
    // compat для клиентов без поля). Explicit-but-invalid type →
    // 400 (client-bug surface'ится, не silent fallback).
    try {
      const tree = await store.createTree({
        creatorId: req.auth.user.id,
        name,
        description,
        isPrivate,
        kind,
        includeRules:
          includeRules && typeof includeRules === "object" ? includeRules : null,
      });
      res.status(201).json({tree: mapTree(tree)});
    } catch (error) {
      if (error?.message === "INVALID_RULE_TYPE") {
        res.status(400).json({
          message:
            "type должен быть 'manual', 'blood-from-me', 'descendants-of' или 'ancestors-of'",
        });
        return;
      }
      throw error;
    }
  });

  // Phase 3.4-prep (Q4): PATCH branch.includeRules для уже
  // существующего дерева. Owner-only. UX-warning preview через
  // отдельный GET endpoint ниже.
  app.patch(
    "/v1/trees/:treeId/include-rules",
    requireAuth,
    async (req, res) => {
      try {
        const updated = await store.updateBranchIncludeRules({
          treeId: req.params.treeId,
          rules: req.body?.includeRules || req.body || {},
          actorUserId: req.auth.user.id,
        });
        if (!updated) {
          res.status(404).json({message: "Ветка не найдена"});
          return;
        }
        res.json({
          branchId: updated.id,
          includeRules: updated.includeRules,
          updatedAt: updated.updatedAt,
        });
      } catch (error) {
        if (error?.message === "NOT_OWNER") {
          res.status(403).json({
            message: "Только владелец ветки может менять её состав",
          });
          return;
        }
        if (
          error?.message === "INVALID_RULES" ||
          error?.message === "INVALID_RULE_TYPE"
        ) {
          res.status(400).json({
            message:
              "type должен быть 'manual', 'blood-from-me', 'descendants-of' или 'ancestors-of'",
          });
          return;
        }
        throw error;
      }
    },
  );

  // Phase 3.4-prep (Q4 UX warning): preview affected count для
  // нового includeRules БЕЗ commit'а. Помогает UI показать «X
  // родственников появятся, Y исчезнут» прежде чем apply. Доступ —
  // любой member ветки (читать состав branch'а до/после может тот,
  // кто ветку видит).
  app.get(
    "/v1/trees/:treeId/include-rules-preview",
    requireAuth,
    async (req, res) => {
      const type = String(req.query.type || "").trim();
      const anchorPersonIdRaw = req.query.anchorPersonId;
      const maxHopsRaw = Number(req.query.maxHops);
      const rules = {
        type,
        anchorPersonId:
          typeof anchorPersonIdRaw === "string"
            ? anchorPersonIdRaw.trim() || null
            : null,
        maxHops: Number.isFinite(maxHopsRaw) ? maxHopsRaw : 5,
      };
      try {
        const preview = await store.previewBranchIncludeRules({
          treeId: req.params.treeId,
          rules,
          viewerUserId: req.auth.user.id,
        });
        if (!preview) {
          res.status(404).json({message: "Ветка не найдена"});
          return;
        }
        res.json({preview});
      } catch (error) {
        if (error?.message === "FORBIDDEN") {
          res.status(403).json({message: "Доступ к ветке запрещён"});
          return;
        }
        if (
          error?.message === "INVALID_RULES" ||
          error?.message === "INVALID_RULE_TYPE"
        ) {
          res.status(400).json({
            message:
              "type должен быть 'manual', 'blood-from-me', 'descendants-of' или 'ancestors-of'",
          });
          return;
        }
        throw error;
      }
    },
  );

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

  // Phase 0 of unified-graph migration: cross-tree person search.
  // The Flutter add-relative screen calls this from a debounced
  // textfield as the user types — surfaces relatives they ALREADY
  // entered on any of their other trees so they don't have to
  // re-key the same human. Picking a result on the client side
  // pre-fills the form, stamps `sourcePersonId` into the create
  // payload, and the server then shares an identityId between the
  // two records (Phase 1 turns this into full edit propagation).
  //
  // Strict per-user scope: only walks the caller's accessible
  // trees (creator + member), never anyone else's. Future Phase 4
  // adds a separate opt-in social-discovery endpoint with explicit
  // consent — that's a different problem and a different route.
  app.get("/v1/persons/search", requireAuth, async (req, res) => {
    const rawQuery = req.query?.q;
    const query = typeof rawQuery === "string" ? rawQuery : "";
    if (query.length > 200) {
      // Defense in depth — `searchPersonsForUser` already does a
      // bounded substring scan, but pathological queries deserve
      // an early reject so we don't tie up the libuv thread on a
      // 1MB needle. Real names don't get this long.
      res.status(400).json({message: "Слишком длинный запрос"});
      return;
    }

    const excludeTreeId = req.query?.excludeTreeId;
    const limitRaw = Number(req.query?.limit);
    const limit = Number.isFinite(limitRaw) && limitRaw > 0
      ? Math.min(limitRaw, 50)
      : 20;

    // SPEED-12: один readSharedSnapshot() вместо двух независимых
    // _read() (searchPersonsForUser + filterLegacyPersonsByGraphVisibility
    // раньше каждый читали блоб сами).
    const db = await store.readSharedSnapshot();
    const persons = await store.searchPersonsForUser({
      userId: req.auth.user.id,
      query,
      excludeTreeId:
        typeof excludeTreeId === "string" ? excludeTreeId : null,
      limit,
      db,
    });

    // Phase 3.2: bulk visibility filter. Узлы с
    // visibility=owner-only от чужого owner'а (no grant) тихо
    // выпадают — НЕ возвращаем 403, чтобы не leak'ить
    // существование. Anonymous (graphPerson.userId=null) и
    // accessible-tree узлы остаются.
    const visiblePersons = await store.filterLegacyPersonsByGraphVisibility(
      persons,
      req.auth.user.id,
      db,
    );

    res.json({
      // Trim to the lightweight summary shape — the picker only
      // needs name + photo + tree name to render. Full Person
      // payload is fetched on demand via /v1/trees/:id/persons/:id
      // when the user actually picks. Keeps this hot path tiny
      // even for users with many trees / hundreds of persons.
      // Phase 3.4 (DECISIONS.md ответ Q4): добавлен `identityId`
      // — branch wizard'у нужен canonical graphPerson.id (=
      // identityId) для anchor descendants-of/ancestors-of rule.
      persons: visiblePersons.map((person) => ({
        id: person.id,
        identityId: person.identityId || null,
        treeId: person.treeId,
        treeName: person.treeName || "",
        displayName: person.name || "",
        photoUrl: person.primaryPhotoUrl || person.photoUrl || null,
        birthDate: person.birthDate || null,
        gender: person.gender || "unknown",
      })),
    });
  });

  app.get("/v1/trees/:treeId/persons", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    // SPEED-9 B: горячий маршрут бёрста входа. Если requireTreeAccess
    // уже прочитал блоб (федеративное дерево — прод-default), тот же
    // снимок идёт и в listPersons, и в listHiddenPersonIdsForCaller —
    // вместо 2-3 отдельных _read() на запрос остаётся максимум 1.
    const db = req.storeSnapshot || null;
    let persons = await store.listPersons(tree.id, db);

    // Phase B Ship 8: per-user hide filter. Applies whenever tree
    // bound к семя (tree.semyaId set) и caller has hide rows для
    // этой семи. Orphan hides (caller no longer member) harmless —
    // filter just shrinks их view. Cross-семя scoped: twin person
    // в другой семе НЕ auto-hidden.
    if (tree.semyaId) {
      const hiddenIds = await store.listHiddenPersonIdsForCaller(
        tree.semyaId,
        req.auth.user.id,
        db,
      );
      if (hiddenIds.length > 0) {
        const hiddenSet = new Set(hiddenIds);
        persons = persons.filter((p) => !hiddenSet.has(p.id));
      }
    }

    res.json({
      persons: persons.map(mapPerson),
    });
  });

  app.get("/v1/trees/:treeId/duplicates", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    const requestedLimit = Number(req.query.limit || 20);
    const persons = await store.listPersons(tree.id);
    const suggestions = findWithinTreeDuplicateCandidates({
      treeId: tree.id,
      persons,
      limit: Number.isFinite(requestedLimit) ? requestedLimit : 20,
    });

    res.json({
      suggestions: suggestions.map((suggestion) => ({
        id: suggestion.id,
        treeId: suggestion.treeId,
        score: suggestion.score,
        confidence: suggestion.confidence,
        reasons: suggestion.reasons,
        personA: mapPerson(suggestion.personA),
        personB: mapPerson(suggestion.personB),
      })),
    });
  });

  // ── Phase 1.2: voltage-indicator matcher ────────────────────────────
  // For one specific person, surface medium+high confidence cross-
  // tree matches the user hasn't linked or dismissed. Drives the
  // 💡 indicator on each card. The Flutter client batches calls
  // (one per visible person) and renders the dot when length > 0.
  app.get(
    "/v1/trees/:treeId/persons/:personId/identity-suggestions",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) return;
      const requestedLimit = Number(req.query.limit || 10);
      const limit = Number.isFinite(requestedLimit) && requestedLimit > 0
        ? Math.min(requestedLimit, 50)
        : 10;
      // SPEED-8d: один _read() на весь запрос вместо двух — раньше
      // findCrossTreeSuggestionsForPerson и filterLegacyPersonsByGraphVisibility
      // каждый читали блоб независимо (на PostgresStore это
      // structuredClone всего состояния + версия/сессии round-trip
      // дважды на один HTTP-вызов). Клиент батчит этот эндпоинт по
      // разу на каждую видимую карточку канваса — экономия множится
      // на число открытых карточек.
      // SPEED-12: req.storeSnapshot — тот же снимок, что уже положил
      // requireTreeAccess (федеративный путь) — вместо ЕЩЁ одного
      // чтения; readSharedSnapshot() — фолбэк для легаси-деревьев.
      const db = req.storeSnapshot || (await store.readSharedSnapshot());
      const suggestions = await store.findCrossTreeSuggestionsForPerson({
        userId: req.auth.user.id,
        treeId: tree.id,
        personId: req.params.personId,
        limit,
        db,
      });

      // Phase 3.2: filter cross-tree suggestions через visibility.
      // targetPerson который claimed чужим owner'ом и не имеет
      // grant'а для viewer'а — тихо выпадает. Это сохраняет 💡
      // mehanic'у без leak о existence privately-held nodes.
      const targetPersons = suggestions.map((s) => s.targetPerson);
      const visibleTargets = await store.filterLegacyPersonsByGraphVisibility(
        targetPersons,
        req.auth.user.id,
        db,
      );
      const visibleTargetIds = new Set(visibleTargets.map((p) => p.id));
      const visibleSuggestions = suggestions.filter((s) =>
        visibleTargetIds.has(s.targetPerson.id),
      );

      res.json({
        suggestions: visibleSuggestions.map((suggestion) => ({
          sourcePersonId: suggestion.sourcePersonId,
          sourceTreeId: suggestion.sourceTreeId,
          targetPersonId: suggestion.targetPersonId,
          targetTreeId: suggestion.targetTreeId,
          targetTreeName: suggestion.targetTreeName,
          targetPerson: mapPerson(suggestion.targetPerson),
          score: suggestion.score,
          confidence: suggestion.confidence,
          reasons: suggestion.reasons,
        })),
      });
    },
  );

  // Confirm a 💡-suggested match: link both persons under one
  // PersonIdentity. From this point on, identity propagation
  // (Phase 1.1) keeps the canonical fields in sync. Caller passes
  // the target via {targetTreeId, targetPersonId} on the body —
  // we verify they have access to the target tree before linking
  // (otherwise an attacker could probe for IDs).
  app.post(
    "/v1/trees/:treeId/persons/:personId/link-identity",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) return;
      const targetTreeIdRaw = req.body?.targetTreeId;
      const targetPersonIdRaw = req.body?.targetPersonId;
      const targetTreeId =
        typeof targetTreeIdRaw === "string" ? targetTreeIdRaw.trim() : "";
      const targetPersonId =
        typeof targetPersonIdRaw === "string" ? targetPersonIdRaw.trim() : "";
      if (!targetTreeId || !targetPersonId) {
        res.status(400).json({
          message: "Нужны targetTreeId и targetPersonId",
        });
        return;
      }
      // Auth: verify the user can access the target tree too.
      const targetTree = await requireTreeAccess(req, res, targetTreeId);
      if (!targetTree) return;

      // Phase 3.2 (DECISIONS.md ответ C): identity link = merge,
      // требует двустороннего merge-consent. Source side — viewer
      // обычно owner или granted; target side — может быть claimed
      // someone else'ом, и без consent'а grant'нуть слияние нельзя.
      const sourceCtx = await requireGraphPersonEdit(
        req,
        res,
        tree.id,
        req.params.personId,
        "merge-consent",
      );
      if (!sourceCtx) return;
      const targetCtx = await requireGraphPersonEdit(
        req,
        res,
        targetTree.id,
        targetPersonId,
        "merge-consent",
      );
      if (!targetCtx) return;

      try {
        const result = await store.linkPersonsByIdentity({
          sourceTreeId: tree.id,
          sourcePersonId: req.params.personId,
          targetTreeId: targetTree.id,
          targetPersonId,
          actorId: req.auth.user.id,
        });
        if (!result) {
          res.status(404).json({message: "Карточки не найдены"});
          return;
        }
        res.json({
          identityId: result.identityId,
          source: mapPerson(result.sourcePerson),
          target: mapPerson(result.targetPerson),
        });
      } catch (error) {
        if (error?.message === "CONFLICTING_IDENTITIES") {
          res.status(409).json({
            message:
              "Эти карточки уже связаны с разными identityId — сначала объедините их через merge.",
          });
          return;
        }
        throw error;
      }
    },
  );

  // Снять привязку юзера от person record. Используется владельцем
  // дерева когда инвайт-ссылка случайно прилетела на чужой слот
  // (например, юзер тапнул не ту карточку при «поделиться»). Имя,
  // гендер и фото остаются — после additive-фикса в linkPersonToUser
  // их и так не должны были перезаписать.
  app.delete(
    "/v1/trees/:treeId/persons/:personId/user-link",
    requireAuth,
    async (req, res) => {
      const result = await store.unlinkUserFromPerson({
        treeId: req.params.treeId,
        personId: req.params.personId,
        actorId: req.auth.user.id,
      });
      if (result === null) {
        res.status(404).json({message: "Дерево не найдено"});
        return;
      }
      if (result === undefined) {
        res.status(404).json({message: "Человек не найден в дереве"});
        return;
      }
      if (result === false) {
        res.status(403).json({
          message: "Только владелец дерева может отвязывать пользователей",
        });
        return;
      }
      res.json({person: mapPerson(result)});
    },
  );

  // Dismiss a 💡 suggestion — the user said "these are different
  // people". We record the per-user dismissal so the same
  // suggestion doesn't keep surfacing.
  app.post(
    "/v1/trees/:treeId/persons/:personId/dismiss-suggestion",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) return;
      const targetPersonIdRaw = req.body?.targetPersonId;
      const targetPersonId =
        typeof targetPersonIdRaw === "string" ? targetPersonIdRaw.trim() : "";
      if (!targetPersonId) {
        res.status(400).json({message: "Нужен targetPersonId"});
        return;
      }
      await store.dismissIdentitySuggestion({
        userId: req.auth.user.id,
        sourcePersonId: req.params.personId,
        dismissedTargetPersonId: targetPersonId,
      });
      res.status(204).send();
    },
  );

  // ── Phase 1.3: identity-field conflicts ─────────────────────────────
  // List unresolved conflicts where the linked person on THIS
  // tree was about to be overwritten by propagation but had a
  // local edit. Drives the ⚠️ badge on the canvas. Tree-scoped
  // (one HTTP call covers every visible card) — the per-person
  // shape is achievable client-side via group-by.
  // Phase 6.3: per-branch "Эта неделя в семье" digest.
  // Aggregates upcoming birthdays + memorial anniversaries +
  // recent posts + newly-added persons for the branch. Computed
  // on read so the response always reflects the latest state
  // without a background indexer.
  app.get(
    "/v1/trees/:treeId/digest",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) return;
      const requestedDays = Number(req.query.days || 7);
      const days = Number.isFinite(requestedDays) && requestedDays > 0
        ? Math.min(Math.floor(requestedDays), 31)
        : 7;
      const digest = await store.getBranchDigest({
        treeId: tree.id,
        days,
        viewerUserId: req.auth.user.id,
      });
      if (!digest) {
        res.status(404).json({message: "Ветка не найдена"});
        return;
      }
      res.json({digest});
    },
  );

  app.get(
    "/v1/trees/:treeId/conflicts",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) return;
      const conflicts = await store.listIdentityConflicts({
        userId: req.auth.user.id,
        treeId: tree.id,
      });
      res.json({conflicts});
    },
  );

  // Resolve one conflict. `choice: "keep"` — target value wins,
  // mark row resolved and let the propagator mute future passes
  // for this exact (sourceValue, targetValue) pair.
  // `choice: "overwrite"` — source value wins, write it onto the
  // target person and refresh lastPropagatedFields so the next
  // pass sees a clean snapshot.
  app.post(
    "/v1/trees/:treeId/conflicts/:conflictId/resolve",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) return;
      const choiceRaw = req.body?.choice;
      const choice = typeof choiceRaw === "string" ? choiceRaw.trim() : "";
      if (choice !== "keep" && choice !== "overwrite") {
        res.status(400).json({
          message: "choice должен быть 'keep' или 'overwrite'",
        });
        return;
      }
      try {
        const result = await store.resolveIdentityConflict({
          conflictId: req.params.conflictId,
          choice,
          actorId: req.auth.user.id,
        });
        if (!result) {
          res.status(404).json({message: "Конфликт не найден"});
          return;
        }
        // The conflict could live on a tree the user CAN access
        // but isn't the one in :treeId — verify they match so a
        // copy-pasted route doesn't accidentally resolve a row
        // on a different tree (the underlying store call already
        // checked access; this is a stricter guard for the
        // route's contract — :treeId names the affected tree).
        if (result.conflict.targetTreeId !== tree.id) {
          res.status(404).json({message: "Конфликт не найден"});
          return;
        }
        res.json({
          conflict: result.conflict,
          person: result.person ? mapPerson(result.person) : null,
        });
      } catch (error) {
        if (error?.message === "FORBIDDEN") {
          res.status(403).json({message: "Нет доступа к целевому дереву"});
          return;
        }
        if (error?.message === "INVALID_CHOICE") {
          res.status(400).json({
            message: "choice должен быть 'keep' или 'overwrite'",
          });
          return;
        }
        throw error;
      }
    },
  );

  // Step 2 selection-mode: bulk-copy a set of persons from one tree
  // to another, AND bridge any relations between the imported set
  // (or between an imported person and someone already in the
  // target tree via shared identityId — e.g. the user themselves).
  // Returns the created persons + the relations that landed.
  // Idempotent: re-running with the same selection doesn't duplicate
  // rows on either side.
  app.post(
    "/v1/trees/:treeId/persons/import",
    requireAuth,
    async (req, res) => {
      const targetTree = await requireTreeAccess(req, res, req.params.treeId);
      if (!targetTree) return;

      const sourceTreeIdRaw = req.body?.sourceTreeId;
      const sourceTreeId =
        typeof sourceTreeIdRaw === "string" && sourceTreeIdRaw.trim()
          ? sourceTreeIdRaw.trim()
          : null;
      if (!sourceTreeId) {
        res.status(400).json({message: "Нужен sourceTreeId"});
        return;
      }
      const sourceTree = await requireTreeAccess(req, res, sourceTreeId);
      if (!sourceTree) return;
      if (sourceTree.id === targetTree.id) {
        res.status(400).json({
          message: "Источник и цель должны быть разными ветками",
        });
        return;
      }

      const sourcePersonIdsGuard = enforceArrayCap(
        req.body?.sourcePersonIds,
        {
          // 64 covers any realistic lasso bulk action without
          // letting an over-eager client request a million-row
          // copy in a single POST.
          max: 64,
          itemValidator: (raw) =>
              enforceTextLimit(raw, {
                max: 64,
                allowMultiline: false,
                fieldName: "sourcePersonId",
              }),
          fieldName: "sourcePersonIds",
        },
      );
      if (!sourcePersonIdsGuard.ok) {
        res.status(sourcePersonIdsGuard.status).json({
          message: sourcePersonIdsGuard.message,
        });
        return;
      }

      const result = await store.bulkImportPersonsToTree({
        sourceTreeId: sourceTree.id,
        sourcePersonIds: sourcePersonIdsGuard.value,
        targetTreeId: targetTree.id,
        actorId: req.auth.user.id,
      });

      if (!result) {
        res.status(404).json({message: "Дерево не найдено"});
        return;
      }

      res.status(201).json({
        persons: result.persons.map(mapPerson),
        relations: result.relations,
      });
    },
  );

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

    // Phase 0 cross-tree picker: optional `sourcePersonId` on the
    // body lets the client say "this is the same human as person
    // X on one of my other trees". The store enforces access (the
    // source must live in a tree the caller can reach), so a
    // forged ID can't leak data — it's just dropped. We pass the
    // raw value through; the store does the access check.
    const sourcePersonIdRaw = req.body?.sourcePersonId;
    const sourcePersonId =
      typeof sourcePersonIdRaw === "string" && sourcePersonIdRaw.trim()
        ? sourcePersonIdRaw.trim()
        : null;

    const person = await store.createPerson({
      treeId: tree.id,
      creatorId: req.auth.user.id,
      userId: requestedUserId || null,
      personData: req.body || {},
      sourcePersonId,
    });

    if (!person) {
      res.status(404).json({message: "Семейное дерево не найдено"});
      return;
    }

    await dispatchTreeMutation({
      treeId: tree.id,
      kind: "person_added",
      actorUserId: req.auth.user.id,
    });

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

      // SPEED-9 B: переиспользуем снимок requireTreeAccess, если он
      // есть (федеративное дерево) — 2 _read() на запрос → 1.
      const person = await store.findPerson(
        tree.id,
        req.params.personId,
        req.storeSnapshot || null,
      );
      if (!person) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      res.json({person: mapPerson(person)});
    },
  );

  app.get(
    "/v1/trees/:treeId/persons/:personId/dossier",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const dossier = await buildPersonDossierPayload({
        treeId: tree.id,
        personId: req.params.personId,
        viewerUserId: req.auth.user.id,
      });
      if (!dossier) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      res.json({dossier});
    },
  );

  app.patch(
    "/v1/trees/:treeId/persons/:personId",
    requireAuth,
    async (req, res) => {
      // Phase 3.2: layered owner-model gate. Anonymous (graphPerson.userId
      // === null) — allowed для tree-creator/member (collaborative
      // editorial); claimed — только owner или active grant per "edit".
      const ctx = await requireGraphPersonEdit(
        req,
        res,
        req.params.treeId,
        req.params.personId,
        "edit",
      );
      if (!ctx) return;
      const {tree} = ctx;

      const person = await store.updatePerson(
        tree.id,
        req.params.personId,
        req.body || {},
        req.auth.user.id,
      );
      if (!person) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      // Phase 1.1 identity propagation: if the update fanned out to
      // other person records that share the same identityId
      // (typically: the same human entered into a different tree
      // by the same user via the cross-tree picker), the store
      // attaches a `_propagatedTo: [{treeId, personId}, ...]`
      // hint. We surface it in the response so the Flutter client
      // can invalidate the affected trees' caches without
      // refetching everything.
      const propagatedTo = Array.isArray(person._propagatedTo)
        ? person._propagatedTo
        : [];

      const responsePayload = {
        person: mapPerson(person),
      };
      if (propagatedTo.length > 0) {
        responsePayload.identityPropagation = {affected: propagatedTo};
      }

      await dispatchTreeMutation({
        treeId: req.params.treeId,
        kind: "person_updated",
        actorUserId: req.auth.user.id,
      });

      res.json(responsePayload);
    },
  );

  app.post(
    "/v1/trees/:treeId/persons/:personId/profile-contributions",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      const contribution = await store.createProfileContribution({
        treeId: tree.id,
        personId: req.params.personId,
        authorUserId: req.auth.user.id,
        message: req.body?.message,
        fields: req.body?.fields,
      });
      if (contribution === null) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }
      if (contribution === false) {
        res.status(403).json({
          message: "Пользователь не принимает предложения по профилю.",
        });
        return;
      }
      if (contribution === undefined) {
        res.status(400).json({message: "Нет данных для предложения правки"});
        return;
      }

      const author = await store.findUserById(req.auth.user.id);
      res.status(201).json({
        contribution: mapProfileContribution({
          ...contribution,
          authorDisplayName:
            author?.profile?.displayName || author?.email || "Пользователь",
          authorPhotoUrl: author?.profile?.photoUrl || null,
        }),
      });
    },
  );

  app.delete(
    "/v1/trees/:treeId/persons/:personId",
    requireAuth,
    async (req, res) => {
      // Phase 3.2: soft-delete scope. Anonymous person — tree-access
      // достаточен; claimed — только owner или grant per "soft-delete".
      const ctx = await requireGraphPersonEdit(
        req,
        res,
        req.params.treeId,
        req.params.personId,
        "soft-delete",
      );
      if (!ctx) return;
      const {tree} = ctx;

      const deleted = await store.deletePerson(
        tree.id,
        req.params.personId,
        req.auth.user.id,
      );
      if (!deleted) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      await dispatchTreeMutation({
        treeId: tree.id,
        kind: "person_deleted",
        actorUserId: req.auth.user.id,
      });

      res.status(204).send();
    },
  );

  app.post(
    "/v1/trees/:treeId/persons/:personId/media",
    requireAuth,
    async (req, res) => {
      // Phase 3.2: media upload — edit scope (фото канонически
      // мигрируют в graphPerson через identity propagation).
      const ctx = await requireGraphPersonEdit(
        req,
        res,
        req.params.treeId,
        req.params.personId,
        "edit",
      );
      if (!ctx) return;
      const {tree} = ctx;

      const url =
        req.body?.url || req.body?.mediaUrl || req.body?.photoUrl || null;
      if (!url) {
        res.status(400).json({message: "Нужен url media-файла"});
        return;
      }

      const result = await store.addPersonMedia({
        treeId: tree.id,
        personId: req.params.personId,
        actorId: req.auth.user.id,
        media: req.body || {},
      });
      if (!result) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }

      res.status(201).json({
        person: mapPerson(result.person),
        media: result.media,
        // Phase 1.1 photo propagation: list of {treeId, personId}
        // pairs the change fanned out to. Flutter client uses
        // this to invalidate graph snapshots on the affected
        // trees so the UI doesn't stay stale.
        propagatedTo: result.propagatedTo || [],
      });
    },
  );

  app.patch(
    "/v1/trees/:treeId/persons/:personId/media/:mediaId",
    requireAuth,
    async (req, res) => {
      const ctx = await requireGraphPersonEdit(
        req,
        res,
        req.params.treeId,
        req.params.personId,
        "edit",
      );
      if (!ctx) return;
      const {tree} = ctx;

      const result = await store.updatePersonMedia({
        treeId: tree.id,
        personId: req.params.personId,
        mediaId: req.params.mediaId,
        actorId: req.auth.user.id,
        updates: req.body || {},
      });
      if (result === null) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }
      if (result === false) {
        res.status(404).json({message: "Media элемент не найден"});
        return;
      }

      res.json({
        person: mapPerson(result.person),
        media: result.media,
        propagatedTo: result.propagatedTo || [],
      });
    },
  );

  app.delete(
    "/v1/trees/:treeId/persons/:personId/media/:mediaId",
    requireAuth,
    async (req, res) => {
      const ctx = await requireGraphPersonEdit(
        req,
        res,
        req.params.treeId,
        req.params.personId,
        "edit",
      );
      if (!ctx) return;
      const {tree} = ctx;

      // Clients that cached person data before real UUIDs were added may send
      // a synthetic ID like "photo-1". Fall back to URL-based lookup in that case.
      const fallbackUrl = String(req.body?.url || req.query?.url || "").trim();
      const result = await store.deletePersonMedia({
        treeId: tree.id,
        personId: req.params.personId,
        mediaId: req.params.mediaId,
        fallbackUrl: fallbackUrl || null,
        actorId: req.auth.user.id,
      });
      if (result === null) {
        res.status(404).json({message: "Человек не найден"});
        return;
      }
      if (result === false) {
        res.status(404).json({message: "Media элемент не найден"});
        return;
      }

      res.json({
        person: mapPerson(result.person),
        deletedMediaId: result.deletedMedia?.id || req.params.mediaId,
        propagatedTo: result.propagatedTo || [],
      });
    },
  );

  app.get("/v1/trees/:treeId/history", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    const personId = String(req.query.personId || "").trim() || null;
    const type = String(req.query.type || "").trim() || null;
    const actorId = String(req.query.actorId || "").trim() || null;
    const records = await store.listTreeChangeRecords(tree.id, {
      personId,
      type,
      actorId,
    });

    res.json({
      records: records.map(mapTreeChangeRecord),
    });
  });

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

  app.get("/v1/trees/:treeId/graph", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    // SPEED-9 B: переиспользуем снимок requireTreeAccess, если он есть
    // (федеративное дерево) — 2 _read() на запрос → 1.
    const snapshot = await store.getTreeGraphSnapshot(tree.id, {
      viewerUserId: req.auth.user.id,
      db: req.storeSnapshot || null,
    });
    if (!snapshot) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }

    res.json({
      snapshot: mapTreeGraphSnapshot(snapshot),
    });
  });

  // Phase 4 chunk 1: extended network slice. BFS от viewer'а через
  // identity-граф в radius'е maxHops (clamp 2..4 == privacy fence),
  // privacy gate per-target. См. PHASE-4-PROPOSAL.md §3.1.
  //
  // 60s TTL in-memory cache per cache key. Без invalidation — Phase 4
  // — view layer, не edit canvas; edit чужих nodes идёт через my-only
  // через grants. 60s stale window acceptable (DECISIONS.md 2026-05-12,
  // nice-to-have #2).
  const extendedNetworkCache = new Map();
  const EXTENDED_NETWORK_TTL_MS = 60_000;
  app.get(
    "/v1/trees/:treeId/extended-network",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      // Defensive parsing: clamp maxHops к 2..4 (server doubles down
      // на store-side clamp).
      const maxHopsRaw = Number(req.query.maxHops);
      const maxHops = Number.isFinite(maxHopsRaw)
        ? Math.max(2, Math.min(4, Math.floor(maxHopsRaw)))
        : 4;
      const includeAnonymous = req.query.includeAnonymous !== "false";
      const branchIdsRaw = String(req.query.branchIds || "").trim();
      const branchIds = branchIdsRaw
        ? branchIdsRaw.split(",").map((s) => s.trim()).filter(Boolean)
        : null;

      const cacheKey = `${tree.id}:${req.auth.user.id}:${maxHops}:${includeAnonymous}:${branchIdsRaw || "*"}`;
      const cached = extendedNetworkCache.get(cacheKey);
      if (cached && cached.expiresAt > Date.now()) {
        res.json({slice: cached.slice});
        return;
      }

      const slice = await store.getExtendedNetworkSlice({
        viewerUserId: req.auth.user.id,
        treeId: tree.id,
        maxHops,
        includeAnonymous,
        branchIds,
      });
      if (!slice) {
        res.status(404).json({message: "Дерево не найдено"});
        return;
      }
      if (slice.error === "NOT_TREE_MEMBER") {
        // requireTreeAccess уже гейтит, но defensive — store
        // double-checks. 403 здесь не должен случиться в healthy
        // flow.
        res.status(403).json({message: "Нет доступа к этому дереву"});
        return;
      }

      extendedNetworkCache.set(cacheKey, {
        slice,
        expiresAt: Date.now() + EXTENDED_NETWORK_TTL_MS,
      });
      // Garbage collect старые entries раз в N requests'ов. Простая
      // protection от unbounded memory growth — production scenario
      // у нас тестовые users, OK.
      if (extendedNetworkCache.size > 200) {
        const now = Date.now();
        for (const [key, value] of extendedNetworkCache.entries()) {
          if (value.expiresAt <= now) extendedNetworkCache.delete(key);
        }
      }
      res.json({slice});
    },
  );

  app.post("/v1/trees/:treeId/relations", requireAuth, async (req, res) => {
    const tree = await requireTreeAccess(req, res, req.params.treeId);
    if (!tree) {
      return;
    }

    // Phase 3.2 (DECISIONS.md 2026-05-10 follow-up): relation creation
    // — tree-level STRUCTURAL операция (по Артёмовой Q1: «семьи
    // строят дерево совместно»), не editorial mutation на каких-либо
    // конкретных persons. Tree-access достаточен. Защита от
    // identity-merge vandalism (link Alice к чужой бабушке как
    // identity) идёт через отдельный POST /link-identity с двойным
    // merge-consent. POST /relations пишет только parent/child/
    // sibling/spouse rib, не объединяет identity.
    const {
      person1Id,
      person2Id,
      relation1to2,
      relation2to1,
      customRelationLabel1to2,
      customRelationLabel2to1,
      isConfirmed,
      marriageDate,
      divorceDate,
      parentSetId,
      parentSetType,
      isPrimaryParentSet,
      unionId,
      unionType,
      unionStatus,
    } =
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
      customRelationLabel1to2:
        customRelationLabel1to2 === undefined || customRelationLabel1to2 === null
          ? customRelationLabel1to2
          : String(customRelationLabel1to2),
      customRelationLabel2to1:
        customRelationLabel2to1 === undefined || customRelationLabel2to1 === null
          ? customRelationLabel2to1
          : String(customRelationLabel2to1),
      isConfirmed: isConfirmed !== false,
      marriageDate:
        marriageDate === undefined || marriageDate === null
          ? marriageDate
          : String(marriageDate),
      divorceDate:
        divorceDate === undefined || divorceDate === null
          ? divorceDate
          : String(divorceDate),
      parentSetId:
        parentSetId === undefined || parentSetId === null
          ? parentSetId
          : String(parentSetId),
      parentSetType:
        parentSetType === undefined || parentSetType === null
          ? parentSetType
          : String(parentSetType),
      isPrimaryParentSet,
      unionId:
        unionId === undefined || unionId === null ? unionId : String(unionId),
      unionType:
        unionType === undefined || unionType === null
          ? unionType
          : String(unionType),
      unionStatus:
        unionStatus === undefined || unionStatus === null
          ? unionStatus
          : String(unionStatus),
      createdBy: req.auth.user.id,
    });

    if (!relation) {
      res.status(404).json({
        message: "Один или оба человека не найдены в дереве",
      });
      return;
    }

    await dispatchTreeMutation({
      treeId: tree.id,
      kind: "relation_added",
      actorUserId: req.auth.user.id,
    });

    res.status(201).json({relation: mapRelation(relation)});
  });

  app.delete(
    "/v1/trees/:treeId/relations/:relationId",
    requireAuth,
    async (req, res) => {
      const tree = await requireTreeAccess(req, res, req.params.treeId);
      if (!tree) {
        return;
      }

      // Phase 3.2 (DECISIONS.md follow-up): relation deletion — то же
      // tree-level structural operation как create, без edit-gate на
      // отдельные persons. Tree-access достаточен; collaborative
      // adjustment родственных связей не блокируется claim'нутостью.
      const deletedRelation = await store.deleteRelation(
        tree.id,
        req.params.relationId,
        req.auth.user.id,
      );
      if (!deletedRelation) {
        res.status(404).json({message: "Связь не найдена"});
        return;
      }

      await dispatchTreeMutation({
        treeId: tree.id,
        kind: "relation_deleted",
        actorUserId: req.auth.user.id,
      });

      res.status(204).send();
    },
  );
}

module.exports = {
  registerTreeRoutes,
};
