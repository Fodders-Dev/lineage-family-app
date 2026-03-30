class PushGateway {
  constructor({store, logger = console}) {
    this.store = store;
    this.logger = logger;
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
    }

    return deliveries;
  }
}

module.exports = {
  PushGateway,
};
