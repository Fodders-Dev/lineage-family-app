const webPush = require("web-push");

class PushGateway {
  constructor({
    store,
    logger = console,
    config = {},
    webPushClient = webPush,
  }) {
    this.store = store;
    this.logger = logger;
    this.config = {
      publicAppUrl: String(config.publicAppUrl || "https://rodnya-tree.ru"),
      webPushPublicKey: String(config.webPushPublicKey || "").trim(),
      webPushPrivateKey: String(config.webPushPrivateKey || "").trim(),
      webPushSubject: String(
        config.webPushSubject || "https://rodnya-tree.ru",
      ).trim(),
      webPushEnabled: Boolean(
        config.webPushEnabled ||
            (config.webPushPublicKey && config.webPushPrivateKey),
      ),
    };
    this.webPushClient = webPushClient;

    if (this.config.webPushEnabled) {
      this.webPushClient.setVapidDetails(
        this.config.webPushSubject,
        this.config.webPushPublicKey,
        this.config.webPushPrivateKey,
      );
    }
  }

  async dispatchNotification(notification) {
    const devices = await this.store.listPushDevices(notification.userId);
    const deliveries = [];

    for (const device of devices) {
      const delivery = await this.store.createPushDelivery({
        notificationId: notification.id,
        userId: notification.userId,
        deviceId: device.id,
        provider: device.provider,
        status: "queued",
      });

      deliveries.push(delivery);
      this.logger.info?.(
        `[lineage-backend] queued push delivery ${delivery.id} for ${device.provider}:${device.platform}`,
      );

      await this._deliverNotification(notification, device, delivery);
    }

    return deliveries;
  }

  async _deliverNotification(notification, device, delivery) {
    if (device.provider === "webpush") {
      await this._deliverWebPush(notification, device, delivery);
      return;
    }

    if (device.provider === "rustore") {
      this.logger.info?.(
        `[lineage-backend] rustore push delivery ${delivery.id} queued until vendor adapter is configured`,
      );
      return;
    }
  }

  async _deliverWebPush(notification, device, delivery) {
    if (!this.config.webPushEnabled) {
      await this.store.updatePushDelivery(delivery.id, {
        status: "queued",
        lastError: "webpush_not_configured",
      });
      return;
    }

    let subscription;
    try {
      subscription = JSON.parse(device.token);
    } catch (error) {
      await this.store.updatePushDelivery(delivery.id, {
        status: "failed",
        lastError: `invalid_webpush_subscription:${error.message}`,
      });
      return;
    }

    const payload = JSON.stringify({
      title: notification.title || "Родня",
      body: notification.body || "",
      tag: notification.id,
      payload: JSON.stringify({
        id: notification.id,
        type: notification.type,
        data: notification.data || {},
      }),
      url: this._notificationUrl(notification),
    });

    try {
      const response = await this.webPushClient.sendNotification(
        subscription,
        payload,
      );
      await this.store.updatePushDelivery(delivery.id, {
        status: "sent",
        deliveredAt: new Date().toISOString(),
        responseCode: Number(response?.statusCode || 201),
        lastError: null,
      });
    } catch (error) {
      await this.store.updatePushDelivery(delivery.id, {
        status: "failed",
        lastError: error?.message || String(error),
        responseCode: Number(error?.statusCode || 0) || null,
      });
    }
  }

  _notificationUrl(notification) {
    const baseUrl = String(this.config.publicAppUrl || "https://rodnya-tree.ru")
      .replace(/\/$/, "");
    const payload = encodeURIComponent(
      JSON.stringify({
        id: notification.id,
        type: notification.type,
        data: notification.data || {},
      }),
    );
    return `${baseUrl}/?notificationPayload=${payload}#/notifications`;
  }
}

module.exports = {
  PushGateway,
};
