// Phase E4: «Опрос» (Poll) CRUD + voting. Cloned from gathering-routes.js
// — same auth + tree-access + circle-visibility + multi-branch fan-out,
// swapping the event fields for poll fields (question / options /
// allowMultiple / closesAt). Voting (POST /:id/respond) mirrors the RSVP
// upsert. Scope: create + list + read + respond + delete.

const {
  enforceTextLimit,
  enforceArrayCap,
} = require("../input-guards");

function registerPollRoutes(
  app,
  {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapPoll,
    createAndDispatchNotification,
    pushGateway,
  },
) {
  app.get("/v1/polls", requireAuth, async (req, res) => {
    const treeId = String(req.query.treeId || "").trim() || null;
    // null treeId = audience mode (all accessible circles) — the feed's
    // «Все» tab, mirroring /v1/posts. Only gate on tree access when a
    // specific circle is requested; the accessibleTreeIds filter below
    // already scopes the aggregate to what the viewer is allowed to see,
    // and store.listPolls skips its branch filter when treeId is null.
    if (treeId) {
      const tree = await requireTreeAccess(req, res, treeId);
      if (!tree) {
        return;
      }
    }

    const accessibleTrees = await store.listUserTrees(req.auth.user.id);
    const accessibleTreeIds = new Set(accessibleTrees.map((entry) => entry.id));
    // SPEED-9 B: переиспользуем снимок requireTreeAccess, если он есть
    // (федеративное дерево, treeId задан) — 2 _read() на запрос → 1.
    const polls = await store.listPolls({
      treeId,
      viewerUserId: req.auth.user.id,
      db: req.storeSnapshot || null,
    });
    const visible = polls.filter((poll) => {
      if (accessibleTreeIds.has(poll.treeId)) return true;
      const branchIds = Array.isArray(poll.branchIds) ? poll.branchIds : [];
      return branchIds.some((branchId) => accessibleTreeIds.has(branchId));
    });

    res.json(visible.map(mapPoll));
  });

  app.get("/v1/polls/:pollId", requireAuth, async (req, res) => {
    const poll = await store.findPoll(req.params.pollId);
    if (!poll) {
      res.status(404).json({message: "Опрос не найден"});
      return;
    }

    const tree = await requireTreeAccess(req, res, poll.treeId);
    if (!tree) {
      return;
    }

    res.json(mapPoll(poll));
  });

  app.post("/v1/polls", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();

    const questionGuard = enforceTextLimit(req.body?.question, {
      max: 512,
      fieldName: "question",
    });
    if (!questionGuard.ok) {
      res.status(questionGuard.status).json({message: questionGuard.message});
      return;
    }
    const question = questionGuard.value;

    // Options: an array of texts, ≥ 2 non-empty after trimming.
    if (!Array.isArray(req.body?.options)) {
      res.status(400).json({message: "Нужны варианты ответа"});
      return;
    }
    const optionsGuard = enforceArrayCap(req.body.options, {
      max: 10,
      itemValidator: (raw) =>
          enforceTextLimit(raw, {
            max: 256,
            allowEmpty: true,
            fieldName: "option",
          }),
      fieldName: "options",
    });
    if (!optionsGuard.ok) {
      res.status(optionsGuard.status).json({message: optionsGuard.message});
      return;
    }
    const options = optionsGuard.value
      .map((value) => String(value || "").trim())
      .filter(Boolean);
    if (options.length < 2) {
      res.status(400).json({message: "Нужно минимум два варианта ответа"});
      return;
    }

    const allowMultiple = req.body?.allowMultiple === true;

    const closesAtGuard = enforceTextLimit(req.body?.closesAt, {
      max: 64,
      allowMultiline: false,
      allowEmpty: true,
      fieldName: "closesAt",
    });
    if (!closesAtGuard.ok) {
      res.status(closesAtGuard.status).json({message: closesAtGuard.message});
      return;
    }
    const closesAt = closesAtGuard.value || null;

    const scopeType = String(req.body?.scopeType || "wholeTree").trim();
    const circleId = String(req.body?.circleId || "").trim() || null;

    // Multi-branch fan-out (mirror posts/gatherings).
    let branchIds = null;
    if (Array.isArray(req.body?.branchIds)) {
      const branchIdsGuard = enforceArrayCap(req.body.branchIds, {
        max: 16,
        itemValidator: (raw) =>
            enforceTextLimit(raw, {
              max: 64,
              allowMultiline: false,
              fieldName: "branchId",
            }),
        fieldName: "branchIds",
      });
      if (!branchIdsGuard.ok) {
        res
          .status(branchIdsGuard.status)
          .json({message: branchIdsGuard.message});
        return;
      }
      branchIds = branchIdsGuard.value;
    }

    const anchorsGuard = enforceArrayCap(req.body?.anchorPersonIds, {
      max: 100,
      itemValidator: (raw) =>
          enforceTextLimit(raw, {
            max: 64,
            allowMultiline: false,
            fieldName: "anchorPersonId",
          }),
      fieldName: "anchorPersonIds",
    });
    if (!anchorsGuard.ok) {
      res.status(anchorsGuard.status).json({message: anchorsGuard.message});
      return;
    }
    const anchorPersonIds = anchorsGuard.value;

    // Photo carousel — same cap as posts / gatherings.
    const imageUrlsGuard = enforceArrayCap(req.body?.imageUrls, {
      max: 30,
      itemValidator: (raw) =>
          enforceTextLimit(raw, {
            max: 2048,
            fieldName: "imageUrl",
          }),
      fieldName: "imageUrls",
    });
    if (!imageUrlsGuard.ok) {
      res.status(imageUrlsGuard.status).json({message: imageUrlsGuard.message});
      return;
    }
    const imageUrls = imageUrlsGuard.value;

    if (!treeId) {
      res.status(400).json({message: "Нужен treeId"});
      return;
    }

    const tree = await requireTreeAccess(req, res, treeId);
    if (!tree) {
      return;
    }

    if (circleId) {
      const circle = await store.findCircle(tree.id, circleId);
      if (!circle) {
        res.status(400).json({message: "Круг не найден"});
        return;
      }
    }

    const treePersons = await store.listPersons(tree.id);
    const validPersonIds = new Set(treePersons.map((person) => person.id));
    const normalizedAnchorPersonIds = anchorPersonIds
      .map((value) => String(value || "").trim())
      .filter((value) => validPersonIds.has(value));

    const authorName =
      req.auth.user.profile?.displayName ||
      composeDisplayName(req.auth.user.profile) ||
      req.auth.user.email ||
      "Аноним";

    const poll = await store.createPoll({
      treeId: tree.id,
      branchIds,
      authorId: req.auth.user.id,
      authorName,
      authorPhotoUrl: req.auth.user.profile?.photoUrl || null,
      question,
      options,
      allowMultiple,
      closesAt,
      imageUrls,
      scopeType,
      anchorPersonIds: normalizedAnchorPersonIds,
      circleId,
    });

    if (poll === false) {
      res.status(400).json({message: "Нужен вопрос и минимум два варианта"});
      return;
    }
    if (!poll) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }

    // Audience-mode fan-out: poll_created to every branch member (minus
    // the author), mirroring gathering_created.
    if (typeof createAndDispatchNotification === "function") {
      try {
        const audienceUserIds = await store.resolvePollAudienceUserIds(
          poll.id,
        );
        const branchIdsForData =
          Array.isArray(poll.branchIds) && poll.branchIds.length > 0
            ? poll.branchIds
            : [poll.treeId].filter(Boolean);
        for (const recipientId of audienceUserIds) {
          await createAndDispatchNotification({
            userId: recipientId,
            type: "poll_created",
            title: `${authorName} создал опрос`,
            body: poll.question.slice(0, 120),
            data: {
              pollId: poll.id,
              authorId: req.auth.user.id,
              branchIds: branchIdsForData,
            },
          });
        }
      } catch (error) {
        console.warn("poll creation notification fan-out failed", error);
      }
    }

    res.status(201).json(mapPoll(poll));
  });

  app.post("/v1/polls/:pollId/respond", requireAuth, async (req, res) => {
    const poll = await store.findPoll(req.params.pollId);
    if (!poll) {
      res.status(404).json({message: "Опрос не найден"});
      return;
    }

    const tree = await requireTreeAccess(req, res, poll.treeId);
    if (!tree) {
      return;
    }

    if (!Array.isArray(req.body?.optionIds)) {
      res.status(400).json({message: "Нужны варианты ответа"});
      return;
    }
    const optionIdsGuard = enforceArrayCap(req.body.optionIds, {
      max: 10,
      allowEmpty: false,
      itemValidator: (raw) =>
          enforceTextLimit(raw, {
            max: 64,
            allowMultiline: false,
            fieldName: "optionId",
          }),
      fieldName: "optionIds",
    });
    if (!optionIdsGuard.ok) {
      res.status(optionIdsGuard.status).json({message: optionIdsGuard.message});
      return;
    }
    const optionIds = optionIdsGuard.value;

    // Every chosen option must exist on the poll.
    const validIds = new Set(
      (Array.isArray(poll.options) ? poll.options : []).map((o) => o.id),
    );
    if (!optionIds.every((id) => validIds.has(id))) {
      res.status(400).json({message: "Некорректный вариант ответа"});
      return;
    }

    const updated = await store.submitPollResponse({
      pollId: req.params.pollId,
      userId: req.auth.user.id,
      optionIds,
    });
    if (!updated) {
      res.status(404).json({message: "Опрос не найден"});
      return;
    }

    // Notify the poll author on every vote (skip self), mirroring the
    // gathering RSVP fan-out.
    if (typeof createAndDispatchNotification === "function" &&
        updated.authorId &&
        updated.authorId !== req.auth.user.id) {
      try {
        const responderName =
          req.auth.user.profile?.displayName ||
          composeDisplayName(req.auth.user.profile) ||
          req.auth.user.email ||
          "Кто-то";
        await createAndDispatchNotification({
          userId: updated.authorId,
          type: "poll_response",
          title: `${responderName} ответил в опросе`,
          body: updated.question,
          data: {
            pollId: updated.id,
            fromUserId: req.auth.user.id,
          },
        });
      } catch (error) {
        console.warn("poll response notification failed", error);
      }
    }

    res.json(mapPoll(updated));
  });

  app.delete("/v1/polls/:pollId", requireAuth, async (req, res) => {
    const poll = await store.findPoll(req.params.pollId);
    if (!poll) {
      res.status(404).json({message: "Опрос не найден"});
      return;
    }

    const tree = await requireTreeAccess(req, res, poll.treeId);
    if (!tree) {
      return;
    }

    const deleted = await store.deletePoll(req.params.pollId, req.auth.user.id);
    if (deleted === false) {
      res.status(403).json({message: "Можно удалять только свои опросы"});
      return;
    }

    res.status(204).send();
  });
}

module.exports = {
  registerPollRoutes,
};
