const webPush = require("web-push");

class PushGateway {
  constructor({
    store,
    logger = console,
    config = {},
    webPushClient = webPush,
    httpClient = globalThis.fetch?.bind(globalThis),
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
      rustorePushProjectId: String(config.rustorePushProjectId || "").trim(),
      rustorePushServiceToken: String(
        config.rustorePushServiceToken || "",
      ).trim(),
      rustorePushApiBaseUrl: String(
        config.rustorePushApiBaseUrl || "https://vkpns.rustore.ru",
      ).replace(/\/+$/, ""),
      rustorePushEnabled: Boolean(
        config.rustorePushEnabled ||
          (config.rustorePushProjectId && config.rustorePushServiceToken),
      ),
    };
    this.webPushClient = webPushClient;
    this.httpClient = httpClient;

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
      await this._deliverRustorePush(notification, device, delivery);
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

  async _deliverRustorePush(notification, device, delivery) {
    if (!this.config.rustorePushEnabled) {
      await this.store.updatePushDelivery(delivery.id, {
        status: "queued",
        lastError: "rustore_not_configured",
      });
      return;
    }

    if (typeof this.httpClient !== "function") {
      await this.store.updatePushDelivery(delivery.id, {
        status: "failed",
        lastError: "rustore_http_client_unavailable",
      });
      return;
    }

    const requestBody = {
      message: {
        token: String(device.token || "").trim(),
        notification: {
          title: notification.title || "Родня",
          body: notification.body || "",
        },
        data: this._buildRustoreDataPayload(notification),
      },
    };
    const requestUrl = `${this.config.rustorePushApiBaseUrl}/v1/projects/${encodeURIComponent(this.config.rustorePushProjectId)}/messages:send`;

    try {
      const response = await this.httpClient(requestUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.config.rustorePushServiceToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(requestBody),
      });

      if (response.ok) {
        await this.store.updatePushDelivery(delivery.id, {
          status: "sent",
          deliveredAt: new Date().toISOString(),
          responseCode: Number(response.status || 200),
          lastError: null,
        });
        return;
      }

      const responseText = await this._safeReadResponse(response);
      await this.store.updatePushDelivery(delivery.id, {
        status: "failed",
        lastError: responseText || `rustore_http_${response.status || 0}`,
        responseCode: Number(response.status || 0) || null,
      });
    } catch (error) {
      await this.store.updatePushDelivery(delivery.id, {
        status: "failed",
        lastError: error?.message || String(error),
      });
    }
  }

  _buildRustoreDataPayload(notification) {
    const payload = {
      notificationId: notification.id,
      type: notification.type || "generic",
      payload: JSON.stringify({
        id: notification.id,
        type: notification.type,
        data: notification.data || {},
      }),
    };

    for (const [key, value] of Object.entries(notification.data || {})) {
      if (value == null) {
        continue;
      }
      payload[String(key)] =
        typeof value === "string" ? value : JSON.stringify(value);
    }

    return payload;
  }

  async _safeReadResponse(response) {
    if (!response || typeof response.text !== "function") {
      return "";
    }

    try {
      return String(await response.text()).trim();
    } catch (_) {
      return "";
    }
  }
}

module.exports = {
  PushGateway,
};
