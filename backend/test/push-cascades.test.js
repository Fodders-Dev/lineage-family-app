// Каскады pushDeliveries, не покрытые нигде (разведкарта SPEED-7):
// - logout/revoke сессии (unbindPushDevicesForSession) уносит deliveries
//   отвязанных устройств;
// - FCM 404/UNREGISTERED прунит устройство и его deliveries
//   (_pruneStaleDevice — телефон переустановил приложение, токен умер);
// - deleteUser уносит устройства и deliveries юзера (GDPR).
// Всё на FileStore (дефолт api-уровня); табличная Postgres-сторона покрыта
// в postgres-notification-tables.test.js.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const {FileStore} = require("../src/store");
const {PushGateway} = require("../src/push-gateway");

async function buildStore() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rodnya-pushcas-"));
  const store = new FileStore(path.join(tempDir, "dev-db.json"));
  await store.initialize();
  const cleanup = async () => {
    await fs.rm(tempDir, {recursive: true, force: true}).catch(() => {});
  };
  return {store, cleanup};
}

async function seedUserWithDevice(store, {sessionPublicId = "sess-1"} = {}) {
  const user = await store.createUser({
    email: `push-${Math.random().toString(36).slice(2)}@rodnya.app`,
    password: "Test-Password-123!",
    displayName: "Пушевой",
  });
  const device = await store.registerPushDevice({
    userId: user.id,
    provider: "fcm",
    token: `tok-${Math.random().toString(36).slice(2)}`,
    platform: "android",
    sessionPublicId,
  });
  const notification = await store.createNotification({
    userId: user.id,
    type: "generic",
    title: "Тест",
    body: "-",
  });
  const delivery = await store.createPushDelivery({
    notificationId: notification.id,
    userId: user.id,
    deviceId: device.id,
    provider: "fcm",
  });
  return {user, device, notification, delivery};
}

test("logout-сессии каскадом уносит deliveries отвязанных устройств", async () => {
  const {store, cleanup} = await buildStore();
  try {
    const a = await seedUserWithDevice(store, {sessionPublicId: "sess-a"});
    // Второе устройство ДРУГОЙ сессии того же юзера — переживает.
    const otherDevice = await store.registerPushDevice({
      userId: a.user.id,
      provider: "webpush",
      token: "tok-other",
      platform: "web",
      sessionPublicId: "sess-b",
    });
    const surviving = await store.createPushDelivery({
      notificationId: a.notification.id,
      userId: a.user.id,
      deviceId: otherDevice.id,
      provider: "webpush",
    });

    const removed = await store.unbindPushDevicesForSession({
      userId: a.user.id,
      sessionPublicId: "sess-a",
    });
    assert.deepEqual(removed.map((entry) => entry.id), [a.device.id]);

    const deliveries = await store.listPushDeliveries(a.user.id, {limit: 10});
    assert.deepEqual(
      deliveries.map((entry) => entry.id),
      [surviving.id],
      "deliveries отвязанного устройства удалены, чужая сессия цела",
    );
  } finally {
    await cleanup();
  }
});

test("FCM 404 прунит устройство и каскадом его deliveries", async () => {
  const {store, cleanup} = await buildStore();
  try {
    const a = await seedUserWithDevice(store);
    // fcmSender инжектится конструктором (fcmPushEnabled вычисляется из
    // него там же); сетевой край — httpClient с 404 UNREGISTERED.
    const gateway = new PushGateway({
      store,
      config: {},
      fcmSender: {
        isEnabled: true,
        sendUrl: "https://fcm.test/v1/projects/x/messages:send",
        getAccessToken: async () => "oauth-token",
      },
      httpClient: async () => ({
        ok: false,
        status: 404,
        text: async () => JSON.stringify({error: {status: "NOT_FOUND"}}),
      }),
    });

    await gateway._deliverFcmPush(
      {userId: a.user.id, title: "t", body: "b", data: {}, type: "generic"},
      a.device,
      a.delivery,
    );

    const devices = await store.listPushDevices(a.user.id);
    assert.deepEqual(devices, [], "мёртвое устройство вычищено");
    const deliveries = await store.listPushDeliveries(a.user.id, {limit: 10});
    assert.deepEqual(
      deliveries,
      [],
      "deliveries мёртвого устройства ушли каскадом (включая текущую)",
    );
  } finally {
    await cleanup();
  }
});

test("deleteUser уносит устройства и deliveries юзера (GDPR)", async () => {
  const {store, cleanup} = await buildStore();
  try {
    const a = await seedUserWithDevice(store);
    const b = await seedUserWithDevice(store);

    await store.deleteUser(a.user.id);

    assert.deepEqual(await store.listPushDevices(a.user.id), []);
    assert.deepEqual(await store.listPushDeliveries(a.user.id, {limit: 10}), []);
    // Чужие данные не задеты.
    assert.equal((await store.listPushDevices(b.user.id)).length, 1);
    assert.equal(
      (await store.listPushDeliveries(b.user.id, {limit: 10})).length,
      1,
    );
  } finally {
    await cleanup();
  }
});
