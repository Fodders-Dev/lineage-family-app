// Замер скорости отправки: бёрст N сообщений между двумя одноразовыми
// аккаунтами на проде, клиентский send-to-ack по каждому; серверная разбивка
// access/persist/ack собирается отдельно из journalctl ([send-timing]).
// Аккаунты удаляются в конце. Протокол и интерпретация: docs/speed_measurement.md
// и skill /measure-send-speed. Запуск: node tool/measure_send_speed.mjs [N=20]
const API = "https://api.rodnya-tree.ru";
const N = Number(process.env.N || 20);
const ts = Date.now();

async function call(path, {method = "GET", token, body} = {}) {
  const started = Date.now();
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      ...(token ? {authorization: `Bearer ${token}`} : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const ms = Date.now() - started;
  let payload = null;
  try { payload = await res.json(); } catch {}
  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status}: ${JSON.stringify(payload).slice(0, 200)}`);
  }
  return {payload, ms, status: res.status};
}

function pct(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

const main = async () => {
  const mk = async (tag) => {
    const email = `speed6-${tag}-${ts}@example.com`;
    const {payload} = await call("/v1/auth/register", {
      method: "POST",
      body: {email, password: `Speed6!${ts}`, displayName: `Замер ${tag}`},
    });
    const token = payload?.accessToken || payload?.session?.accessToken || payload?.token;
    const userId = payload?.user?.id || payload?.userId || payload?.session?.userId;
    if (!token || !userId) throw new Error(`register ${tag}: no token/userId in ${JSON.stringify(payload).slice(0, 300)}`);
    return {email, token, userId};
  };

  const a = await mk("a");
  const b = await mk("b");
  console.log(`accounts: ${a.userId} / ${b.userId}`);

  const {payload: chatPayload} = await call("/v1/chats/direct", {
    method: "POST", token: a.token, body: {otherUserId: b.userId},
  });
  const chatId = chatPayload?.chatId || chatPayload?.chat?.id;
  if (!chatId) throw new Error("no chatId");
  console.log(`chat: ${chatId}`);

  const lat = [];
  for (let i = 0; i < N; i++) {
    const {ms} = await call(`/v1/chats/${chatId}/messages`, {
      method: "POST",
      token: i % 2 ? b.token : a.token,
      body: {
        text: `замер ${i + 1}/${N} · ${ts}`,
        clientMessageId: `speed6-${ts}-${i}`,
      },
    });
    lat.push(ms);
    process.stdout.write(`${ms}ms `);
  }
  console.log();

  const sorted = [...lat].sort((x, y) => x - y);
  console.log(`client send-to-ack over ${N}: p50=${pct(sorted, 50)}ms p95=${pct(sorted, 95)}ms min=${sorted[0]}ms max=${sorted[sorted.length - 1]}ms`);

  for (const acc of [a, b]) {
    try {
      await call("/v1/auth/account", {method: "DELETE", token: acc.token});
      console.log(`deleted ${acc.email}`);
    } catch (e) {
      console.log(`cleanup FAILED for ${acc.email}: ${e.message}`);
    }
  }
};

main().catch((e) => { console.error("FATAL:", e.message); process.exit(1); });
