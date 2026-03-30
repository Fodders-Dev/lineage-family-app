const {WebSocketServer} = require("ws");

class RealtimeHub {
  constructor({store, logger = console}) {
    this.store = store;
    this.logger = logger;
    this.userSockets = new Map();
    this.wss = null;
  }

  attach(server) {
    this.wss = new WebSocketServer({
      server,
      path: "/v1/realtime",
    });

    this.wss.on("connection", async (socket, request) => {
      let userId = null;

      try {
        const url = new URL(request.url, "http://127.0.0.1");
        const token = String(url.searchParams.get("accessToken") || "").trim();

        if (!token) {
          socket.close(4401, "Missing access token");
          return;
        }

        const session = await this.store.findSession(token);
        if (!session) {
          socket.close(4401, "Session not found");
          return;
        }

        const user = await this.store.findUserById(session.userId);
        if (!user) {
          socket.close(4401, "User not found");
          return;
        }

        await this.store.touchSession(token);
        userId = user.id;
        this._registerSocket(userId, socket);

        socket.send(
          JSON.stringify({
            type: "connection.ready",
            userId,
            connectedAt: new Date().toISOString(),
          }),
        );

        socket.on("close", () => {
          this._unregisterSocket(userId, socket);
        });

        socket.on("error", (error) => {
          this.logger.warn?.("[lineage-backend] realtime socket error", error);
          this._unregisterSocket(userId, socket);
        });
      } catch (error) {
        this.logger.warn?.("[lineage-backend] realtime connection failed", error);
        socket.close(1011, "Realtime initialization failed");
      }
    });
  }

  publishToUser(userId, payload) {
    const sockets = this.userSockets.get(userId);
    if (!sockets || sockets.size === 0) {
      return;
    }

    const serializedPayload = JSON.stringify(payload);
    for (const socket of sockets) {
      if (socket.readyState === socket.OPEN) {
        socket.send(serializedPayload);
      }
    }
  }

  _registerSocket(userId, socket) {
    const sockets = this.userSockets.get(userId) || new Set();
    sockets.add(socket);
    this.userSockets.set(userId, sockets);
  }

  _unregisterSocket(userId, socket) {
    if (!userId) {
      return;
    }

    const sockets = this.userSockets.get(userId);
    if (!sockets) {
      return;
    }

    sockets.delete(socket);
    if (sockets.size == 0) {
      this.userSockets.delete(userId);
    }
  }
}

module.exports = {
  RealtimeHub,
};
