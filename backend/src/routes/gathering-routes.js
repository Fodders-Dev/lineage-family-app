// Phase E1: «Встреча» (Gathering) CRUD. Form cloned from
// post-routes.js — same auth + tree-access + circle-visibility +
// multi-branch fan-out, swapping the post body for event fields
// (title / start / end / place). Scope: create + list + read + delete.
// RSVP (E3), polls (E4/E5), reminders, recurring, edit are out of E1.

const {
  enforceTextLimit,
  enforceArrayCap,
  enforceNonNegativeInt,
} = require("../input-guards");

function registerGatheringRoutes(
  app,
  {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapGathering,
    createAndDispatchNotification,
    pushGateway,
  },
) {
  app.get("/v1/gatherings", requireAuth, async (req, res) => {
    const treeId = String(req.query.treeId || "").trim() || null;
    if (!treeId) {
      res.status(400).json({message: "Нужен treeId"});
      return;
    }

    const tree = await requireTreeAccess(req, res, treeId);
    if (!tree) {
      return;
    }

    const accessibleTrees = await store.listUserTrees(req.auth.user.id);
    const accessibleTreeIds = new Set(accessibleTrees.map((entry) => entry.id));
    // SPEED-9 B: переиспользуем снимок requireTreeAccess, если он есть
    // (федеративное дерево) — 2 _read() на запрос → 1.
    const gatherings = await store.listGatherings({
      treeId,
      viewerUserId: req.auth.user.id,
      db: req.storeSnapshot || null,
    });
    // Same audience model as posts: visible if the primary tree OR any
    // multi-branch fan-out target is accessible to the viewer.
    const visible = gatherings.filter((gathering) => {
      if (accessibleTreeIds.has(gathering.treeId)) return true;
      const branchIds = Array.isArray(gathering.branchIds)
        ? gathering.branchIds
        : [];
      return branchIds.some((branchId) => accessibleTreeIds.has(branchId));
    });

    res.json(visible.map(mapGathering));
  });

  app.get("/v1/gatherings/:gatheringId", requireAuth, async (req, res) => {
    const gathering = await store.findGathering(req.params.gatheringId);
    if (!gathering) {
      res.status(404).json({message: "Встреча не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, gathering.treeId);
    if (!tree) {
      return;
    }

    res.json(mapGathering(gathering));
  });

  app.post("/v1/gatherings", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();

    // Single-line title — required.
    const titleGuard = enforceTextLimit(req.body?.title, {
      max: 256,
      allowMultiline: false,
      fieldName: "title",
    });
    if (!titleGuard.ok) {
      res.status(titleGuard.status).json({message: titleGuard.message});
      return;
    }
    const title = titleGuard.value;

    const descriptionGuard = enforceTextLimit(req.body?.description, {
      max: 8192,
      allowEmpty: true,
      fieldName: "description",
    });
    if (!descriptionGuard.ok) {
      res
        .status(descriptionGuard.status)
        .json({message: descriptionGuard.message});
      return;
    }
    const description = descriptionGuard.value || null;

    // startAt is required (an ISO timestamp string). endAt optional.
    const startAtGuard = enforceTextLimit(req.body?.startAt, {
      max: 64,
      allowMultiline: false,
      fieldName: "startAt",
    });
    if (!startAtGuard.ok) {
      res.status(startAtGuard.status).json({message: startAtGuard.message});
      return;
    }
    const startAt = startAtGuard.value;

    const endAtGuard = enforceTextLimit(req.body?.endAt, {
      max: 64,
      allowMultiline: false,
      allowEmpty: true,
      fieldName: "endAt",
    });
    if (!endAtGuard.ok) {
      res.status(endAtGuard.status).json({message: endAtGuard.message});
      return;
    }
    const endAt = endAtGuard.value || null;

    const placeGuard = enforceTextLimit(req.body?.place, {
      max: 512,
      allowEmpty: true,
      fieldName: "place",
    });
    if (!placeGuard.ok) {
      res.status(placeGuard.status).json({message: placeGuard.message});
      return;
    }
    const place = placeGuard.value || null;

    const isAllDay = req.body?.isAllDay === true;
    const scopeType = String(req.body?.scopeType || "wholeTree").trim();
    const circleId = String(req.body?.circleId || "").trim() || null;

    // Multi-branch fan-out (mirror posts). Store drops branchIds the
    // author can't access.
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

    // Photo carousel — same cap as posts (30 × 2 KB URLs).
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

    const gathering = await store.createGathering({
      treeId: tree.id,
      branchIds,
      authorId: req.auth.user.id,
      authorName,
      authorPhotoUrl: req.auth.user.profile?.photoUrl || null,
      title,
      description,
      startAt,
      endAt,
      isAllDay,
      place,
      imageUrls,
      scopeType,
      anchorPersonIds: normalizedAnchorPersonIds,
      circleId,
    });

    if (gathering === false) {
      res.status(400).json({message: "Нужны название и дата встречи"});
      return;
    }
    if (!gathering) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }

    // Audience-mode fan-out: every member of every branch the gathering
    // landed in (minus the author) gets a `gathering_created` row +
    // realtime + push, via the same helper posts/calls use.
    if (typeof createAndDispatchNotification === "function") {
      try {
        const audienceUserIds = await store.resolveGatheringAudienceUserIds(
          gathering.id,
        );
        const branchIdsForData =
          Array.isArray(gathering.branchIds) && gathering.branchIds.length > 0
            ? gathering.branchIds
            : [gathering.treeId].filter(Boolean);
        for (const recipientId of audienceUserIds) {
          await createAndDispatchNotification({
            userId: recipientId,
            type: "gathering_created",
            title: `${authorName} зовёт на встречу`,
            body: gathering.title.slice(0, 120),
            data: {
              gatheringId: gathering.id,
              authorId: req.auth.user.id,
              branchIds: branchIdsForData,
            },
          });
        }
      } catch (error) {
        // Best-effort — a push hiccup must not roll back the gathering.
        console.warn("gathering creation notification fan-out failed", error);
      }
    }

    res.status(201).json(mapGathering(gathering));
  });

  app.post(
    "/v1/gatherings/:gatheringId/rsvp",
    requireAuth,
    async (req, res) => {
      const gathering = await store.findGathering(req.params.gatheringId);
      if (!gathering) {
        res.status(404).json({message: "Встреча не найдена"});
        return;
      }

      const tree = await requireTreeAccess(req, res, gathering.treeId);
      if (!tree) {
        return;
      }

      const status = String(req.body?.status || "").trim();
      if (status !== "yes" && status !== "maybe" && status !== "no") {
        res.status(400).json({message: "Некорректный статус ответа"});
        return;
      }

      // headcount: optional extra people the responder brings (besides
      // themselves). Non-negative, capped so a typo can't claim a stadium.
      let headcount = 0;
      if (req.body?.headcount != null) {
        const guard = enforceNonNegativeInt(req.body.headcount, {
          max: 100,
          fieldName: "headcount",
        });
        if (!guard.ok) {
          res.status(guard.status).json({message: guard.message});
          return;
        }
        headcount = guard.value;
      }

      // note: optional short free text ("приедем после обеда").
      let note = null;
      if (req.body?.note != null) {
        const noteGuard = enforceTextLimit(req.body.note, {
          max: 280,
          allowEmpty: true,
          fieldName: "note",
        });
        if (!noteGuard.ok) {
          res.status(noteGuard.status).json({message: noteGuard.message});
          return;
        }
        note = noteGuard.value === "" ? null : noteGuard.value;
      }

      const updated = await store.setGatheringRsvp({
        gatheringId: req.params.gatheringId,
        userId: req.auth.user.id,
        status,
        headcount,
        note,
      });
      if (!updated) {
        res.status(404).json({message: "Встреча не найдена"});
        return;
      }

      // Notify the organizer on every change (skip self-RSVP), mirroring
      // the post-reaction fan-out.
      if (typeof createAndDispatchNotification === "function" &&
          updated.authorId &&
          updated.authorId !== req.auth.user.id) {
        try {
          const responderName =
            req.auth.user.profile?.displayName ||
            composeDisplayName(req.auth.user.profile) ||
            req.auth.user.email ||
            "Кто-то";
          const statusLabel = status === "yes"
              ? "идёт"
              : status === "maybe"
                  ? "под вопросом"
                  : "не идёт";
          await createAndDispatchNotification({
            userId: updated.authorId,
            type: "gathering_rsvp",
            title: `${responderName}: ${statusLabel}`,
            body: updated.title,
            data: {
              gatheringId: updated.id,
              fromUserId: req.auth.user.id,
              status,
            },
          });
        } catch (error) {
          console.warn("gathering rsvp notification failed", error);
        }
      }

      res.json(mapGathering(updated));
    },
  );

  app.delete("/v1/gatherings/:gatheringId", requireAuth, async (req, res) => {
    const gathering = await store.findGathering(req.params.gatheringId);
    if (!gathering) {
      res.status(404).json({message: "Встреча не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, gathering.treeId);
    if (!tree) {
      return;
    }

    const deleted = await store.deleteGathering(
      req.params.gatheringId,
      req.auth.user.id,
    );
    if (deleted === false) {
      res.status(403).json({message: "Можно удалять только свои встречи"});
      return;
    }

    res.status(204).send();
  });
}

module.exports = {
  registerGatheringRoutes,
};
