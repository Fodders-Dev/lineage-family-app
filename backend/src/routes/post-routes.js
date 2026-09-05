const {
  enforceTextLimit,
  enforceArrayCap,
} = require("../input-guards");

function registerPostRoutes(
  app,
  {
    store,
    requireAuth,
    requireTreeAccess,
    composeDisplayName,
    mapPost,
    mapComment,
    createAndDispatchNotification,
    pushGateway,
  },
) {
  app.get("/v1/posts/search", requireAuth, async (req, res) => {
    const query = String(req.query.q || req.query.query || "").trim();
    const treeId = String(req.query.treeId || "").trim() || null;
    const limit = Number.parseInt(String(req.query.limit || "50"), 10) || 50;

    if (treeId) {
      const tree = await requireTreeAccess(req, res, treeId);
      if (!tree) {
        return;
      }
    }

    if (query.length === 0) {
      res.json([]);
      return;
    }

    const posts = await store.searchPosts({
      userId: req.auth.user.id,
      query,
      treeId,
      limit,
    });
    const payload = await Promise.all(
      posts.map(async (post) => {
        const comments = await store.listPostComments(post.id);
        return mapPost(post, comments.length);
      }),
    );
    res.json(payload);
  });

  app.get("/v1/posts", requireAuth, async (req, res) => {
    const treeId = String(req.query.treeId || "").trim() || null;
    const authorId = String(req.query.authorId || "").trim() || null;
    const scope = String(req.query.scope || "").trim() || null;

    if (treeId) {
      const tree = await requireTreeAccess(req, res, treeId);
      if (!tree) {
        return;
      }
    }

    const accessibleTrees = await store.listUserTrees(req.auth.user.id);
    const accessibleTreeIds = new Set(accessibleTrees.map((tree) => tree.id));
    const posts = await store.listPosts({
      treeId,
      authorId,
      scope,
      viewerUserId: req.auth.user.id,
    });
    // Audience model: a post is accessible if its primary tree OR
    // any of its multi-branch fan-out targets is accessible to the
    // viewer. Earlier this only checked `post.treeId`, which silently
    // dropped posts where the viewer belonged to a secondary branch
    // but not the primary one — see _canUserViewCirclePost for the
    // matching fix at the visibility layer.
    const visiblePosts = posts.filter((post) => {
      if (accessibleTreeIds.has(post.treeId)) return true;
      const branchIds = Array.isArray(post.branchIds) ? post.branchIds : [];
      return branchIds.some((branchId) => accessibleTreeIds.has(branchId));
    });

    // S2: курсорная пагинация — строго аддитивно. Без `limit` старые
    // клиенты получают прежний формат (массив всех постов). С `limit`
    // ответ — {posts, nextCursor}; cursor = "createdAt|id" последнего
    // поста страницы. Вставка новых постов курсор не ломает: он
    // указывает в прошлое, а сортировка createdAt+id стабильна.
    const limitRaw = String(req.query.limit || "").trim();
    const parsedLimit = Number(limitRaw);
    const limit =
      limitRaw && Number.isFinite(parsedLimit) && parsedLimit > 0
        ? Math.min(Math.floor(parsedLimit), 100)
        : null;

    if (limit === null) {
      // SPEED-9 D: один _read() на всю страницу вместо одного на
      // каждый пост (Promise.all(...listPostComments...) ниже делал
      // K независимых _read() для K видимых постов).
      const commentsByPost = await store.listPostCommentsForPosts(
        visiblePosts.map((post) => post.id),
      );
      const payload = visiblePosts.map((post) =>
        mapPost(post, (commentsByPost.get(post.id) || []).length),
      );
      res.json(payload);
      return;
    }

    let pageSource = visiblePosts;
    const before = String(req.query.before || "").trim();
    if (before) {
      // "|" не встречается ни в ISO-датах, ни в uuid — безопасный
      // разделитель; курсор без "|" трактуем как голый createdAt.
      const separatorIndex = before.lastIndexOf("|");
      const beforeCreatedAt =
        separatorIndex === -1 ? before : before.slice(0, separatorIndex);
      const beforeId =
        separatorIndex === -1 ? "" : before.slice(separatorIndex + 1);
      pageSource = visiblePosts.filter((post) => {
        const createdAt = String(post.createdAt || "");
        const byCreatedAt = createdAt.localeCompare(beforeCreatedAt);
        if (byCreatedAt !== 0) {
          return byCreatedAt < 0; // строго старее курсора
        }
        return String(post.id || "").localeCompare(beforeId) < 0;
      });
    }

    const page = pageSource.slice(0, limit);
    const lastPost = page[page.length - 1] || null;
    const nextCursor =
      pageSource.length > limit && lastPost
        ? `${lastPost.createdAt}|${lastPost.id}`
        : null;

    // SPEED-9 D: тот же батч, что и в ветке без limit — один _read()
    // на страницу вместо одного на каждый пост страницы.
    const commentsByPost = await store.listPostCommentsForPosts(
      page.map((post) => post.id),
    );
    const pagePayload = page.map((post) =>
      mapPost(post, (commentsByPost.get(post.id) || []).length),
    );
    res.json({posts: pagePayload, nextCursor});
  });

  app.post("/v1/posts", requireAuth, async (req, res) => {
    const treeId = String(req.body?.treeId || "").trim();

    // Post body — bigger cap than chat (long-form), still bounded.
    // 32 KB is roomy enough for a journal-length entry but keeps the
    // home feed query payloads predictable.
    const contentGuard = enforceTextLimit(req.body?.content, {
      max: 32_768,
      allowEmpty: true,
      fieldName: "content",
    });
    if (!contentGuard.ok) {
      res.status(contentGuard.status).json({message: contentGuard.message});
      return;
    }
    const content = contentGuard.value;

    // Cap photo carousel — 30 photos covers any realistic post and
    // 30 × 100 KB thumbnail-cache budget on clients stays under 3 MB.
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

    const isPublic = req.body?.isPublic === true;
    const scopeType = String(req.body?.scopeType || "wholeTree").trim();
    const circleId = String(req.body?.circleId || "").trim() || null;
    // Идемпотентный ключ от клиента (очередь фоновой публикации шлёт свой
    // стабильный localId): повтор после таймаута/обрыва не задваивает пост.
    const clientRequestId =
      String(req.body?.clientRequestId || "").trim().slice(0, 120) || null;

    // Phase 3.4 multi-branch posts. Optional `branchIds: [string]`
    // on the body lets the author publish a post into several
    // branches at once (e.g. one family photo into "Моя кровь"
    // AND "Семья жены"). The store enforces that every branchId
    // is in a tree the author can access — anything else is
    // dropped silently. The primary `treeId` from the URL is
    // always implicit in the audience.
    let branchIds = null;
    if (Array.isArray(req.body?.branchIds)) {
      const branchIdsGuard = enforceArrayCap(req.body.branchIds, {
        // Tight cap — multi-branch is a deliberate fan-out, not a
        // billing-channel-style broadcast. 16 covers any realistic
        // family/circle combo without becoming a spam vector.
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
        res.status(branchIdsGuard.status).json({message: branchIdsGuard.message});
        return;
      }
      branchIds = branchIdsGuard.value;
    }

    // Anchor persons cap — same logic as message attachments.
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

    const post = await store.createPost({
      treeId: tree.id,
      branchIds,
      authorId: req.auth.user.id,
      authorName,
      authorPhotoUrl: req.auth.user.profile?.photoUrl || null,
      content,
      imageUrls,
      isPublic,
      scopeType,
      anchorPersonIds: normalizedAnchorPersonIds,
      circleId,
      clientRequestId,
    });

    if (post === false) {
      res.status(400).json({message: "Пост не должен быть пустым"});
      return;
    }
    if (!post) {
      res.status(404).json({message: "Дерево не найдено"});
      return;
    }

    // Audience-mode fan-out: every member of every branch the post
    // landed in (minus the author) gets a `post_created` row +
    // realtime + push. Goes through `createAndDispatchNotification`
    // — the same helper chat / call invites use — so push gateway
    // delivery (RuStore on Android, web-push on browsers) is no
    // longer skipped. Without this the inbox row was created but
    // the phone never beeped, which was the user-reported bug.
    if (
      typeof createAndDispatchNotification === "function" &&
      post._deduplicated !== true
    ) {
      try {
        const audienceUserIds = await store.resolvePostAudienceUserIds(
          post.id,
        );
        const snippet = post.content
          ? post.content.slice(0, 120).trim()
          : (Array.isArray(post.imageUrls) && post.imageUrls.length > 0
              ? "Новое фото"
              : "");
        const branchIdsForData =
          Array.isArray(post.branchIds) && post.branchIds.length > 0
            ? post.branchIds
            : [post.treeId].filter(Boolean);
        for (const recipientId of audienceUserIds) {
          await createAndDispatchNotification({
            userId: recipientId,
            type: "post_created",
            title: `${authorName} опубликовал`,
            body: snippet,
            data: {
              postId: post.id,
              authorId: req.auth.user.id,
              branchIds: branchIdsForData,
            },
          });
        }
      } catch (error) {
        // Notification fan-out is best-effort: a network blip on
        // RuStore must not roll back the post itself. Log and
        // move on — the post is already in the feed.
        console.warn("post creation notification fan-out failed", error);
      }
    }

    res.status(201).json(mapPost(post, 0));
  });

  app.delete("/v1/posts/:postId", requireAuth, async (req, res) => {
    const post = await store.findPost(req.params.postId);
    if (!post) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, post.treeId);
    if (!tree) {
      return;
    }

    const deleted = await store.deletePost(req.params.postId, req.auth.user.id);
    if (deleted === false) {
      res.status(403).json({message: "Можно удалять только свои публикации"});
      return;
    }

    res.status(204).send();
  });

  app.post("/v1/posts/:postId/reactions", requireAuth, async (req, res) => {
    const post = await store.findPost(req.params.postId);
    if (!post) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, post.treeId);
    if (!tree) {
      return;
    }

    const emoji = String(req.body?.emoji || "").trim();
    if (!emoji) {
      res.status(400).json({message: "Нужна реакция"});
      return;
    }

    const result = await store.togglePostReaction({
      postId: req.params.postId,
      userId: req.auth.user.id,
      emoji,
    });
    if (result === null) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }
    if (result === "INVALID_EMOJI") {
      res.status(400).json({message: "Нужна реакция"});
      return;
    }

    if (result.added) {
      // Notify the post author. coalesces with any earlier unread
      // post_reaction from the same actor so spam-tapping the picker
      // doesn't fan out into a wall of inbox entries.
      try {
        const actorName =
          req.auth.user.profile?.displayName ||
          composeDisplayName(req.auth.user.profile) ||
          req.auth.user.email ||
          null;
        const snippet = (post.content || "").trim().slice(0, 96);
        const reactionNotification = await store.addPostReactionNotification(
          {
            postId: post.id,
            postAuthorId: post.authorId,
            actorUserId: req.auth.user.id,
            actorName,
            emoji,
            postSnippet: snippet,
          },
        );
        // Push fan-out for reactions: addPostReactionNotification
        // creates the inbox row (with coalesce semantics) but does
        // not reach the push gateway, since the store layer has no
        // access to it. Hop through the gateway here so the
        // recipient's phone actually beeps.
        if (reactionNotification && pushGateway) {
          try {
            await pushGateway.dispatchNotification(reactionNotification);
          } catch (pushError) {
            console.warn("post reaction push dispatch failed", pushError);
          }
        }
      } catch (error) {
        // Notification is best-effort — don't fail the reaction if the
        // notification write hits a transient error.
        console.warn("post reaction notification failed", error);
      }
    }

    res.json({
      postId: result.postId,
      reactions: result.reactions,
      added: result.added === true,
    });
  });

  app.post(
    "/v1/posts/:postId/comments/:commentId/reactions",
    requireAuth,
    async (req, res) => {
      const post = await store.findPost(req.params.postId);
      if (!post) {
        res.status(404).json({message: "Публикация не найдена"});
        return;
      }

      const tree = await requireTreeAccess(req, res, post.treeId);
      if (!tree) {
        return;
      }

      const emoji = String(req.body?.emoji || "").trim();
      if (!emoji) {
        res.status(400).json({message: "Нужна реакция"});
        return;
      }

      const result = await store.togglePostCommentReaction({
        postId: req.params.postId,
        commentId: req.params.commentId,
        userId: req.auth.user.id,
        emoji,
      });
      if (result === null) {
        res.status(404).json({message: "Комментарий не найден"});
        return;
      }
      if (result === "INVALID_EMOJI") {
        res.status(400).json({message: "Нужна реакция"});
        return;
      }

      if (result.added) {
        try {
          const comments = await store.listPostComments(req.params.postId);
          const targetComment = comments.find(
            (c) => c.id === req.params.commentId,
          );
          if (targetComment) {
            const actorName =
              req.auth.user.profile?.displayName ||
              composeDisplayName(req.auth.user.profile) ||
              req.auth.user.email ||
              null;
            const snippet = (targetComment.content || "").trim().slice(0, 96);
            const commentReactionNotification =
                await store.addCommentReactionNotification({
                  postId: targetComment.postId,
                  commentId: targetComment.id,
                  commentAuthorId: targetComment.authorId,
                  actorUserId: req.auth.user.id,
                  actorName,
                  emoji,
                  commentSnippet: snippet,
                });
            if (commentReactionNotification && pushGateway) {
              try {
                await pushGateway.dispatchNotification(
                    commentReactionNotification);
              } catch (pushError) {
                console.warn(
                    "comment reaction push dispatch failed",
                    pushError);
              }
            }
          }
        } catch (error) {
          console.warn("comment reaction notification failed", error);
        }
      }

      res.json({
        commentId: result.commentId,
        postId: result.postId,
        reactions: result.reactions,
        added: result.added === true,
      });
    },
  );

  app.post("/v1/posts/:postId/like", requireAuth, async (req, res) => {
    const post = await store.findPost(req.params.postId);
    if (!post) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, post.treeId);
    if (!tree) {
      return;
    }

    const updated = await store.togglePostLike(req.params.postId, req.auth.user.id);
    const comments = await store.listPostComments(req.params.postId);
    res.json(mapPost(updated, comments.length));
  });

  app.get("/v1/posts/:postId/comments", requireAuth, async (req, res) => {
    const post = await store.findPost(req.params.postId);
    if (!post) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, post.treeId);
    if (!tree) {
      return;
    }

    const comments = await store.listPostComments(req.params.postId);
    res.json(comments.map(mapComment));
  });

  app.post("/v1/posts/:postId/comments", requireAuth, async (req, res) => {
    const post = await store.findPost(req.params.postId);
    if (!post) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }

    const tree = await requireTreeAccess(req, res, post.treeId);
    if (!tree) {
      return;
    }

    const rawParentCommentId =
      typeof req.body?.parentCommentId === "string"
        ? req.body.parentCommentId.trim()
        : null;
    const parentCommentId =
      rawParentCommentId && rawParentCommentId.length > 0
        ? rawParentCommentId
        : null;

    // Cap comment body. 4 KB matches what most social apps enforce
    // for inline comments (TG / IG cap around 2-4 KB) — anything
    // longer almost certainly belongs in a top-level post.
    const commentGuard = enforceTextLimit(req.body?.content, {
      max: 4096,
      fieldName: "content",
    });
    if (!commentGuard.ok) {
      res.status(commentGuard.status).json({message: commentGuard.message});
      return;
    }

    const actorName =
      req.auth.user.profile?.displayName ||
      composeDisplayName(req.auth.user.profile) ||
      req.auth.user.email ||
      "Аноним";

    const comment = await store.addPostComment({
      postId: req.params.postId,
      authorId: req.auth.user.id,
      authorName: actorName,
      authorPhotoUrl: req.auth.user.profile?.photoUrl || null,
      content: commentGuard.value,
      parentCommentId,
    });

    if (comment === false) {
      res.status(400).json({message: "Комментарий не должен быть пустым"});
      return;
    }
    if (comment === null) {
      res.status(404).json({message: "Публикация не найдена"});
      return;
    }

    // If we landed under a parent comment, ping its author. We resolve the
    // parent on the saved comment (not the request body) because the store
    // climbs nested replies up to the canonical top-level parent.
    if (comment.parentCommentId) {
      try {
        const parent = await store.findPostComment({
          postId: req.params.postId,
          commentId: comment.parentCommentId,
        });
        if (parent && parent.authorId) {
          const snippet = String(comment.content || "").slice(0, 140);
          const replyNotification = await store.addCommentReplyNotification({
            postId: req.params.postId,
            parentCommentId: parent.id,
            parentCommentAuthorId: parent.authorId,
            replyCommentId: comment.id,
            actorUserId: req.auth.user.id,
            actorName,
            replySnippet: snippet,
          });
          if (replyNotification && pushGateway) {
            try {
              await pushGateway.dispatchNotification(replyNotification);
            } catch (pushError) {
              // eslint-disable-next-line no-console
              console.warn(
                  "[posts] comment reply push dispatch failed",
                  pushError);
            }
          }
        }
      } catch (error) {
        // Don't fail the comment write on a notification hiccup — the
        // user-visible action succeeded; this is best-effort fan-out.
        // eslint-disable-next-line no-console
        console.warn("[posts] comment reply notification failed", error);
      }
    }

    res.status(201).json(mapComment(comment));
  });

  app.delete(
    "/v1/posts/:postId/comments/:commentId",
    requireAuth,
    async (req, res) => {
      const post = await store.findPost(req.params.postId);
      if (!post) {
        res.status(404).json({message: "Публикация не найдена"});
        return;
      }

      const tree = await requireTreeAccess(req, res, post.treeId);
      if (!tree) {
        return;
      }

      const deleted = await store.deletePostComment({
        postId: req.params.postId,
        commentId: req.params.commentId,
        actorUserId: req.auth.user.id,
      });
      if (deleted === null) {
        res.status(404).json({message: "Комментарий не найден"});
        return;
      }
      if (deleted === false) {
        res
          .status(403)
          .json({message: "Недостаточно прав для удаления комментария"});
        return;
      }

      res.status(204).send();
    },
  );
}

module.exports = {
  registerPostRoutes,
};
