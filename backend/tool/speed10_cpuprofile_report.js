// SPEED-10 (docs/speed_measurement.md): агрегатор .cpuprofile (формат
// V8 CPU profiler, как из `node --cpu-prof`) — печатает top-N функций
// по SELF-времени (busy time внутри самой функции, без учёта вызванных
// ею дочерних узлов). Метод как в SPEED-8c/8d (`node --cpu-prof`, ручной
// разбор). Не содержит и не печатает данные профиля — только имена
// функций/файлов из СВОЕГО ЖЕ кода (store.js, identity-matcher.js) и
// цифры self-time.
//
// Запуск: node backend/tool/speed10_cpuprofile_report.js <файл.cpuprofile> [--top 15]

const fs = require("node:fs");

function parseArgs(argv) {
  const args = {top: 15};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--top") args.top = Number(argv[++i]);
    else if (!args.file) args.file = token;
  }
  if (!args.file) {
    throw new Error("usage: speed10_cpuprofile_report.js <file.cpuprofile> [--top N]");
  }
  return args;
}

function shortUrl(url) {
  if (!url) return "(native)";
  const marker = "/backend/";
  const idx = url.lastIndexOf(marker);
  if (idx >= 0) return url.slice(idx + 1);
  return url.split(/[\\/]/).pop();
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const profile = JSON.parse(fs.readFileSync(args.file, "utf8"));
  const nodesById = new Map(profile.nodes.map((node) => [node.id, node]));

  // hitCount is V8's own self-time sample counter per node — самый
  // прямой источник self-time без ручного пересчёта timeDeltas.
  const selfByKey = new Map();
  let totalHits = 0;
  for (const node of profile.nodes) {
    const hitCount = node.hitCount || 0;
    totalHits += hitCount;
    if (hitCount === 0) continue;
    const cf = node.callFrame || {};
    const name = cf.functionName || "(anonymous)";
    const file = shortUrl(cf.url);
    const key = `${name} — ${file}:${cf.lineNumber != null ? cf.lineNumber + 1 : "?"}`;
    selfByKey.set(key, (selfByKey.get(key) || 0) + hitCount);
  }

  const sampleIntervalUs = profile.timeDeltas && profile.timeDeltas.length
    ? (profile.endTime - profile.startTime) / profile.samples.length
    : 1000;

  const rows = Array.from(selfByKey.entries())
    .sort((left, right) => right[1] - left[1])
    .slice(0, args.top)
    .map(([key, hits]) => ({
      key,
      hits,
      selfMs: Math.round((hits * sampleIntervalUs) / 1000),
      pct: totalHits ? Math.round((hits / totalHits) * 1000) / 10 : 0,
    }));

  const totalMs = Math.round(((profile.endTime - profile.startTime) || 0) / 1000);
  // eslint-disable-next-line no-console
  console.log(`Профиль: ${args.file}`);
  // eslint-disable-next-line no-console
  console.log(`Общая длительность записи: ${totalMs} мс, сэмплов: ${profile.samples.length}\n`);
  // eslint-disable-next-line no-console
  console.log("self%  self(мс)  функция — файл:строка");
  for (const row of rows) {
    // eslint-disable-next-line no-console
    console.log(`${String(row.pct).padStart(5)}  ${String(row.selfMs).padStart(8)}  ${row.key}`);
  }
}

main();
