function registerStoryRoutes(
  app,
  {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapStory,
    pushGateway,
  },
) {
  app.get("/v1/stories", requireAuth, async (req, res) => {
    const treeId = String(req.query.treeId || "").trim() || null;
    const authorId = String(req.query.authorId || "").trim() || null;

    if (treeId) {
      const tree = await requireTreeAccess(req, res, treeId);
      if (!tree) {
        return;
      }
    }

    const accessibleTrees = await store.listUserTrees(req.auth.user.id);
    const accessibleTreeIds = new Set(accessibleTrees.map((tree) => tree.id));
    // SPEED-9 B: переиспользуем снимок requireTreeAccess, если он есть
    // (федеративное дерево, treeId задан) — 2 _read() на запрос → 1.
    const stories = await store.listStories({
      treeId,
      authorId,
      viewerUserId: req.auth.user.id,
      db: req.storeSnapshot || null,
    });
    const visibleStories = stories.filter((story) =>
      accessibleTreeIds.has(story.treeId),
    );

    res.json(visibleStories.map(mapStory));
  });

  app.post("/v1/stories", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();
    const type = String(req.body?.type || "text").trim();
    const text = req.body?.text;
    const mediaUrl = req.body?.mediaUrl;
    const thumbnailUrl = req.body?.thumbnailUrl;
    const expiresAt = req.body?.expiresAt;
    const circleId = String(req.body?.circleId || "").trim() || null;
    const scopeType = String(req.body?.scopeType || "wholeTree").trim();
    const anchorPersonIds = Array.isArray(req.body?.anchorPersonIds)
      ? req.body.anchorPersonIds
      : [];

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

    const story = await store.createStory({
      treeId: tree.id,
      authorId: req.auth.user.id,
      authorName:
        req.auth.user.profile?.displayName ||
        composeDisplayName(req.auth.user.profile) ||
        req.auth.user.email ||
        "Аноним",
      authorPhotoUrl: req.auth.user.profile?.photoUrl || null,
      type,
      text,
      mediaUrl,
      thumbnailUrl,
      expiresAt,
      circleId,
      scopeType,
      anchorPersonIds,
    });

    if (story === false) {
      res.status(400).json({
        message: "Story должна содержать текст или media в зависимости от типа",
      });
      return;
    }
    if (!story) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }

    res.status(201).json(mapStory(story));
  });

  app.post("/v1/stories/:storyId/view", requireAuth, async (req, res) => {
    const story = await store.findStory(req.params.storyId);
    if (!story) {
      res.status(404).json({message: "Story не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, story.treeId);
    if (!tree) {
      return;
    }

    const updatedStory = await store.markStoryViewed(
      req.params.storyId,
      req.auth.user.id,
    );
    if (!updatedStory) {
      res.status(404).json({message: "Story не найдена"});
      return;
    }

    res.json(mapStory(updatedStory));
  });

  app.post("/v1/stories/:storyId/reactions", requireAuth, async (req, res) => {
    const story = await store.findStory(req.params.storyId);
    if (!story) {
      res.status(404).json({message: "Story не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, story.treeId);
    if (!tree) {
      return;
    }

    const emoji = String(req.body?.emoji || "").trim();
    if (!emoji) {
      res.status(400).json({message: "Нужна реакция"});
      return;
    }

    const result = await store.toggleStoryReaction({
      storyId: req.params.storyId,
      userId: req.auth.user.id,
      emoji,
    });
    if (result === null) {
      res.status(404).json({message: "Story не найдена"});
      return;
    }
    if (result === "INVALID_EMOJI") {
      res.status(400).json({message: "Нужна реакция"});
      return;
    }

    if (result.added) {
      try {
        const actorName =
          req.auth.user.profile?.displayName ||
          composeDisplayName(req.auth.user.profile) ||
          req.auth.user.email ||
          null;
        const snippet = (story.text || "").trim().slice(0, 96);
        const storyReactionNotification =
            await store.addStoryReactionNotification({
              storyId: story.id,
              storyAuthorId: result.authorId,
              actorUserId: req.auth.user.id,
              actorName,
              emoji,
              storySnippet: snippet,
            });
        if (storyReactionNotification && pushGateway) {
          try {
            await pushGateway.dispatchNotification(
                storyReactionNotification);
          } catch (pushError) {
            console.warn(
                "story reaction push dispatch failed", pushError);
          }
        }
      } catch (error) {
        console.warn("story reaction notification failed", error);
      }
    }

    res.json({
      storyId: result.storyId,
      reactions: result.reactions,
      added: result.added === true,
    });
  });

  app.delete("/v1/stories/:storyId", requireAuth, async (req, res) => {
    const story = await store.findStory(req.params.storyId);
    if (!story) {
      res.status(404).json({message: "Story не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, story.treeId);
    if (!tree) {
      return;
    }

    const deletedStory = await store.deleteStory(req.params.storyId, req.auth.user.id);
    if (deletedStory === false) {
      res.status(403).json({message: "Можно удалять только свои stories"});
      return;
    }
    if (!deletedStory) {
      res.status(404).json({message: "Story не найдена"});
      return;
    }

    res.status(204).send();
  });
}

module.exports = {
  registerStoryRoutes,
};
