// SPEED-10 (docs/speed_measurement.md): бенчмарк-харнесс горячих
// GET-путей бёрста входа поверх FileStore напрямую (без HTTP) — метод
// SPEED-8c/8d/9. Меряет ОДИНОЧНЫЙ вызов (median из N) и «бёрст»
// (несколько маршрутов параллельно через Promise.all, повторено M раз).
//
// НИКОГДА не коммитить рядом файлы с данными — backend/.scratch/ в
// .gitignore, этот файл сам данных не содержит и принимает путь к
// копии блоба аргументом.
//
// Запуск:
//   node backend/tool/speed10_bench.js --db <путь-к-блобу.json> \
//     --tree <treeId> --viewer <userId> --owner <userId> \
//     [--augment] [--augment-out <путь>] [--iterations 20] \
//     [--burst-repeats 12] [--out <путь-к-json-отчёту>] [--label after]
//
// --augment: прод-копия, с которой велась эта работа, содержала 0
// историй/встреч (см. docs/speed_measurement.md, SPEED-10) — без
// синтетики listStories/listGatherings профилировались бы на пустом
// массиве. Флаг создаёт РАБОЧУЮ копию (--augment-out, по умолчанию
// рядом с --db) и добавляет в неё N синтетических историй/встреч/
// опросов через сами store.createStory/createGathering/createPoll
// (не руками — гарантирует валидную форму записи), автор — owner,
// зритель — viewer (разные люди, чтобы не сработал ранний выход
// authorId === viewerUserId в _canUserViewCircleContent).

const fs = require("node:fs");
const path = require("node:path");

const {FileStore} = require("../src/store");

function parseArgs(argv) {
  const args = {
    augment: false,
    iterations: 20,
    burstRepeats: 12,
    syntheticCount: 24,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--db") args.db = argv[++i];
    else if (token === "--tree") args.tree = argv[++i];
    else if (token === "--viewer") args.viewer = argv[++i];
    else if (token === "--owner") args.owner = argv[++i];
    else if (token === "--augment") args.augment = true;
    else if (token === "--augment-out") args.augmentOut = argv[++i];
    else if (token === "--iterations") args.iterations = Number(argv[++i]);
    else if (token === "--burst-repeats") args.burstRepeats = Number(argv[++i]);
    else if (token === "--synthetic-count") args.syntheticCount = Number(argv[++i]);
    else if (token === "--out") args.out = argv[++i];
    else if (token === "--label") args.label = argv[++i];
  }
  if (!args.db || !args.tree || !args.viewer || !args.owner) {
    throw new Error(
      "usage: speed10_bench.js --db <path> --tree <id> --viewer <id> --owner <id> [--augment] [...]",
    );
  }
  return args;
}

function median(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
}

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function nowMs() {
  return Number(process.hrtime.bigint()) / 1e6;
}

async function buildAugmentedCopy({db, tree, owner, viewer, syntheticCount, augmentOut}) {
  const outPath = augmentOut || db.replace(/\.json$/, "") + ".augmented.json";
  fs.copyFileSync(db, outPath);
  const store = new FileStore(outPath);
  await store.initialize();

  for (let i = 0; i < syntheticCount; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await store.createStory({
      treeId: tree,
      authorId: owner,
      authorName: "SPEED-10 синтетика",
      type: "text",
      text: `Синтетическая история #${i} для замера SPEED-10`,
    });
    // eslint-disable-next-line no-await-in-loop
    await store.createGathering({
      treeId: tree,
      authorId: owner,
      authorName: "SPEED-10 синтетика",
      title: `Сбор семьи #${i}`,
      startAt: new Date(Date.now() + i * 3600_000).toISOString(),
    });
    // eslint-disable-next-line no-await-in-loop
    await store.createPoll({
      treeId: tree,
      authorId: owner,
      authorName: "SPEED-10 синтетика",
      question: `Синтетический опрос #${i}`,
      options: ["Да", "Нет"],
    });
  }

  return outPath;
}

function buildRoutes(store, {tree, viewer, owner}) {
  return {
    persons: () => store.listPersons(tree),
    graph: () => store.getTreeGraphSnapshot(tree, {viewerUserId: viewer}),
    stories: () => store.listStories({treeId: tree, viewerUserId: viewer}),
    gatherings: () => store.listGatherings({treeId: tree, viewerUserId: viewer}),
    polls: () => store.listPolls({treeId: tree, viewerUserId: viewer}),
    mergeProposalsPending: () => store.listPendingMergeProposalsForUser(owner),
    onboardingState: () => store.getOnboardingState({userId: viewer}),
  };
}

async function measureSingle(routes, iterations) {
  const results = {};
  for (const [name, fn] of Object.entries(routes)) {
    const samples = [];
    for (let i = 0; i < iterations; i += 1) {
      const started = nowMs();
      // eslint-disable-next-line no-await-in-loop
      await fn();
      samples.push(nowMs() - started);
    }
    results[name] = {
      medianMs: round(median(samples)),
      minMs: round(Math.min(...samples)),
      maxMs: round(Math.max(...samples)),
    };
  }
  return results;
}

async function measureBurst(routes, repeats) {
  const names = Object.keys(routes);
  const wallSamples = [];
  const perCallSamples = Object.fromEntries(names.map((name) => [name, []]));

  for (let i = 0; i < repeats; i += 1) {
    const wallStart = nowMs();
    // eslint-disable-next-line no-await-in-loop
    await Promise.all(
      names.map(async (name) => {
        const started = nowMs();
        await routes[name]();
        perCallSamples[name].push(nowMs() - started);
      }),
    );
    wallSamples.push(nowMs() - wallStart);
  }

  const perCall = {};
  for (const name of names) {
    perCall[name] = {
      medianMs: round(median(perCallSamples[name])),
      maxMs: round(Math.max(...perCallSamples[name])),
    };
  }
  return {
    wallMedianMs: round(median(wallSamples)),
    wallMaxMs: round(Math.max(...wallSamples)),
    perCall,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let dbPath = args.db;
  if (args.augment) {
    dbPath = await buildAugmentedCopy({
      db: args.db,
      tree: args.tree,
      owner: args.owner,
      viewer: args.viewer,
      syntheticCount: args.syntheticCount,
      augmentOut: args.augmentOut,
    });
    process.stderr.write(`[speed10_bench] augmented copy: ${dbPath}\n`);
  }

  const store = new FileStore(dbPath);
  await store.initialize();
  const routes = buildRoutes(store, {tree: args.tree, viewer: args.viewer, owner: args.owner});

  process.stderr.write(`[speed10_bench] warming up...\n`);
  await Promise.all(Object.values(routes).map((fn) => fn()));

  process.stderr.write(`[speed10_bench] single-call (median of ${args.iterations})...\n`);
  const single = await measureSingle(routes, args.iterations);

  process.stderr.write(`[speed10_bench] burst (${Object.keys(routes).length} routes x ${args.burstRepeats} repeats)...\n`);
  const burst = await measureBurst(routes, args.burstRepeats);

  const report = {
    label: args.label || null,
    dbPath: path.basename(dbPath),
    tree: args.tree,
    at: new Date().toISOString(),
    single,
    burst,
  };

  const text = JSON.stringify(report, null, 2);
  if (args.out) {
    fs.writeFileSync(args.out, text, "utf8");
    process.stderr.write(`[speed10_bench] report written to ${args.out}\n`);
  }
  // eslint-disable-next-line no-console
  console.log(text);
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exitCode = 1;
});
