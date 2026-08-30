function registerNotificationRoutes(
  app,
  {store, requireAuth, mapNotification, realtimeHub},
) {
  app.get("/v1/notifications", requireAuth, async (req, res) => {
    const status = req.query.status ? String(req.query.status) : null;
    const limit = Math.min(
      Math.max(1, Number.parseInt(String(req.query.limit || "50"), 10) || 50),
      200,
    );

    // Аддитивная курсорная пагинация: наличие параметра cursor (даже
    // пустого) включает страничный формат {notifications, nextCursor};
    // без него — легаси-массив, старые клиенты ничего не замечают.
    if (req.query.cursor !== undefined) {
      const page = await store.listNotificationsPage(req.auth.user.id, {
        status,
        limit,
        cursor: String(req.query.cursor || "").trim() || null,
      });
      res.json({
        notifications: page.notifications.map(mapNotification),
        nextCursor: page.nextCursor,
      });
      return;
    }

    const notifications = await store.listNotifications(req.auth.user.id, {
      status,
      limit,
    });

    res.json({
      notifications: notifications.map(mapNotification),
    });
  });

  app.get("/v1/notifications/unread-count", requireAuth, async (req, res) => {
    const totalUnread = await store.countUnreadNotifications(req.auth.user.id);
    res.json({totalUnread});
  });

  app.post(
    "/v1/notifications/:notificationId/read",
    requireAuth,
    async (req, res) => {
      const notification = await store.markNotificationRead(
        req.params.notificationId,
        req.auth.user.id,
      );
      if (!notification) {
        res.status(404).json({message: "Уведомление не найдено"});
        return;
      }

      res.json({
        notification: mapNotification(notification),
      });
    },
  );

  // «Прочитать всё» одним запросом: раньше клиент лупил N поштучных
  // POST /read — N сетевых раундтрипов (а до SPEED-7 ещё и N блоб-RMW).
  app.post("/v1/notifications/read-all", requireAuth, async (req, res) => {
    const marked = await store.markAllNotificationsRead(req.auth.user.id);
    if (marked > 0 && realtimeHub?.publishToUser) {
      // Бамп bell-badge на остальных устройствах (паттерн chat-routes).
      realtimeHub.publishToUser(req.auth.user.id, {
        type: "notification.bulk-read",
        scope: "all",
        count: marked,
      });
    }
    res.json({marked});
  });
}

module.exports = {
  registerNotificationRoutes,
};
