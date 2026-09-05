// SPEED-9 A: _syncGraphFromLegacy switched from linear .find() scans
// (O(N²) over persons×graphPersons + relations×(graphRelations+persons))
// to Map-indexed lookups built once per pass (see store.js
// _buildGraphSyncIndex + docs/speed_measurement.md SPEED-9).
//
// This file proves the optimized store.js code produces a result
// BYTE-IDENTICAL to a frozen copy of the pre-optimization algorithm
// (referenceSyncGraphFromLegacy below — a faithful, unmodified copy of
// the old nested-.find() implementation), on a fixture deliberately
// designed to exercise every branch the analysis flagged as risky:
//   - duplicate legacyPersons sharing one identityId across two trees
//     (must collapse onto one graphPerson with two branchPersonViews)
//   - a legacy person with NO graphPerson yet (create path)
//   - a legacy person whose graphPerson already exists with STALE
//     canonical fields (update path)
//   - a legacy person whose branchPersonView is missing even though
//     its graphPerson already exists (view-create-on-top-of-existing)
//   - a relation resolved via the _resolveGraphPersonIdForLegacy
//     FALLBACK path (legacy person already hard-deleted, graphPerson
//     still remembers it via legacyPersonIds)
//   - two relations processed in the SAME pass where the FIRST one's
//     type-label edit shifts an existing graphRelation's dedup key,
//     and the SECOND one (a fresh, not-yet-linked duplicate) must
//     then dedup-match against the NEW key — the one scenario where a
//     naive "index built once, never touched again" optimization
//     would silently diverge from the live-scan original.
//
// Existing regression coverage (graph-sync.test.js, branch-include-
// rules.test.js) stays untouched and green — this file is additive.

const test = require("node:test");
const assert = require("node:assert/strict");

const crypto = require("node:crypto");

const {FileStore, EMPTY_DB} = require("../src/store");
const {
  GRAPH_PERSON_CANONICAL_FIELDS,
  buildGraphRelationDedupKey,
} = require("../src/migration-utils");

function normalizeNullableString(value) {
  const trimmed = String(value ?? "").trim();
  return trimmed.length > 0 ? trimmed : null;
}

function nowIso() {
  return new Date().toISOString();
}

function makeStoreStub() {
  return Object.create(FileStore.prototype);
}

// branchPersonView.id is crypto.randomUUID() in BOTH the reference and
// the real store.js code — real randomness would make deepEqual fail
// on id alone even when everything else matches. Stub randomUUID with
// a resettable counter shared by whichever run is active; resetting it
// before each of the two runs (reference, then actual) reproduces the
// same id sequence for both AS LONG AS the two implementations create
// views in the same relative order — which is exactly the property
// under test, so a real behavioral divergence still shows up as a
// mismatch (either in id sequence position or in the surrounding
// fields), not as a false pass.
function withDeterministicUuids(fn) {
  const original = crypto.randomUUID;
  let counter = 0;
  crypto.randomUUID = () => `det-uuid-${counter++}`;
  try {
    return fn();
  } finally {
    crypto.randomUUID = original;
  }
}

function freshDb() {
  return structuredClone(EMPTY_DB);
}

// ── Frozen reference implementation (pre-SPEED-9, unmodified) ──────
// Exact copy of the nested-.find() algorithm that shipped before
// 05.09.2026 — kept here ONLY as a comparison baseline, never touched
// again once this test is written.

function referenceSyncTreeToBranch(db, tree) {
  if (!tree) return;
  if (!Array.isArray(db.branches)) db.branches = [];
  const memberIds = Array.isArray(tree.memberIds)
    ? [...tree.memberIds]
    : Array.isArray(tree.members)
      ? [...tree.members]
      : [];
  let branch = db.branches.find((b) => b.id === tree.id);
  if (!branch) {
    branch = {
      id: tree.id,
      legacyTreeId: tree.id,
      ownerId: tree.creatorId,
      name: tree.name,
      description: tree.description || "",
      isPrivate: tree.isPrivate !== false,
      kind: tree.kind || "family",
      includeRules: {
        type: "manual",
        manualPersonIds: [],
        anchorPersonId: null,
        maxHops: 5,
      },
      memberIds,
      publicSlug: tree.publicSlug || null,
      isCertified: tree.isCertified === true,
      certificationNote: tree.certificationNote || null,
      createdAt: tree.createdAt,
      updatedAt: tree.updatedAt,
      deletedAt: null,
    };
    db.branches.push(branch);
    return;
  }
  branch.name = tree.name;
  branch.description = tree.description || "";
  branch.isPrivate = tree.isPrivate !== false;
  branch.kind = tree.kind || "family";
  branch.memberIds = memberIds;
  branch.publicSlug = tree.publicSlug || null;
  branch.isCertified = tree.isCertified === true;
  branch.certificationNote = tree.certificationNote || null;
  branch.updatedAt = tree.updatedAt;
  branch.deletedAt = null;
  if (!branch.includeRules || typeof branch.includeRules !== "object") {
    branch.includeRules = {
      type: "manual",
      manualPersonIds: [],
      anchorPersonId: null,
      maxHops: 5,
    };
  } else {
    branch.includeRules.anchorPersonId ??= null;
    branch.includeRules.maxHops ??= 5;
    if (!Array.isArray(branch.includeRules.manualPersonIds)) {
      branch.includeRules.manualPersonIds = [];
    }
  }
}

function referenceSyncPersonToGraph(db, legacyPerson) {
  if (!legacyPerson) return;
  if (!Array.isArray(db.graphPersons)) db.graphPersons = [];
  if (!Array.isArray(db.branchPersonViews)) db.branchPersonViews = [];
  if (!Array.isArray(db.branches)) db.branches = [];

  const identityId = normalizeNullableString(legacyPerson.identityId);
  if (!identityId) {
    return;
  }

  let graphPerson = db.graphPersons.find((g) => g.id === identityId);
  if (!graphPerson) {
    graphPerson = {
      id: identityId,
      createdBy: legacyPerson.creatorId || null,
      createdAt: legacyPerson.createdAt,
      updatedAt: legacyPerson.updatedAt,
      version: 0,
      deletedAt: null,
      hardDeleteScheduledAt: null,
      deletedByUserId: null,
      mergedInto: null,
      userId: legacyPerson.userId || null,
      legacyPersonIds: [legacyPerson.id],
      contactPrivacy: "owner-only",
      isPublic: false,
      source: "manual",
      visibility: "connected-via-blood-graph",
      visibilityOverride: false,
    };
    for (const field of GRAPH_PERSON_CANONICAL_FIELDS) {
      graphPerson[field] = legacyPerson[field] ?? null;
    }
    db.graphPersons.push(graphPerson);
  } else {
    let canonicalChanged = false;
    for (const field of GRAPH_PERSON_CANONICAL_FIELDS) {
      const next = legacyPerson[field] ?? null;
      const cur = graphPerson[field] ?? null;
      if (JSON.stringify(next) !== JSON.stringify(cur)) {
        graphPerson[field] =
          next === null || next === undefined ? null : structuredClone(next);
        canonicalChanged = true;
      }
    }
    if (canonicalChanged) {
      graphPerson.version = (graphPerson.version || 0) + 1;
      graphPerson.updatedAt = legacyPerson.updatedAt;
    }
    if (!Array.isArray(graphPerson.legacyPersonIds)) {
      graphPerson.legacyPersonIds = [];
    }
    if (!graphPerson.legacyPersonIds.includes(legacyPerson.id)) {
      graphPerson.legacyPersonIds.push(legacyPerson.id);
    }
    if (!graphPerson.userId && legacyPerson.userId) {
      graphPerson.userId = legacyPerson.userId;
    }
    if (graphPerson.deletedAt) {
      graphPerson.deletedAt = null;
      graphPerson.hardDeleteScheduledAt = null;
      graphPerson.deletedByUserId = null;
    }
    graphPerson.visibility ??= "connected-via-blood-graph";
    graphPerson.visibilityOverride ??= false;
    graphPerson.hardDeleteScheduledAt ??= null;
    graphPerson.deletedByUserId ??= null;
  }

  let view = db.branchPersonViews.find(
    (v) => v.branchId === legacyPerson.treeId && v.personId === graphPerson.id,
  );
  if (!view) {
    view = {
      id: crypto.randomUUID(),
      branchId: legacyPerson.treeId,
      personId: graphPerson.id,
      label: null,
      photoOverride: null,
      notes: legacyPerson.notes ?? null,
      familySummary: legacyPerson.familySummary ?? null,
      bio: legacyPerson.bio ?? null,
      visibility: legacyPerson.visibility ?? null,
      legacyPersonId: legacyPerson.id,
      createdAt: legacyPerson.createdAt,
      updatedAt: legacyPerson.updatedAt,
    };
    db.branchPersonViews.push(view);
  } else {
    view.notes = legacyPerson.notes ?? null;
    view.familySummary = legacyPerson.familySummary ?? null;
    view.bio = legacyPerson.bio ?? null;
    view.visibility = legacyPerson.visibility ?? null;
    view.updatedAt = legacyPerson.updatedAt;
    if (!view.legacyPersonId) view.legacyPersonId = legacyPerson.id;
  }

  const branch = db.branches.find((b) => b.id === legacyPerson.treeId);
  if (branch) {
    if (!branch.includeRules || typeof branch.includeRules !== "object") {
      branch.includeRules = {type: "manual", manualPersonIds: []};
    }
    if (!Array.isArray(branch.includeRules.manualPersonIds)) {
      branch.includeRules.manualPersonIds = [];
    }
    if (!branch.includeRules.manualPersonIds.includes(graphPerson.id)) {
      branch.includeRules.manualPersonIds.push(graphPerson.id);
      branch.updatedAt = legacyPerson.updatedAt;
    }
  }
}

function referenceResolveGraphPersonIdForLegacy(db, legacyPersonId) {
  if (!legacyPersonId) return null;
  const legacyPerson = (db.persons || []).find((p) => p.id === legacyPersonId);
  if (legacyPerson) {
    const identityId = normalizeNullableString(legacyPerson.identityId);
    if (identityId) return identityId;
  }
  const fromGraph = (db.graphPersons || []).find(
    (g) =>
      Array.isArray(g.legacyPersonIds) &&
      g.legacyPersonIds.includes(legacyPersonId),
  );
  return fromGraph ? fromGraph.id : null;
}

function referenceSyncRelationToGraph(db, legacyRelation) {
  if (!legacyRelation) return;
  if (!Array.isArray(db.graphRelations)) db.graphRelations = [];
  const p1g = referenceResolveGraphPersonIdForLegacy(
    db,
    legacyRelation.person1Id,
  );
  const p2g = referenceResolveGraphPersonIdForLegacy(
    db,
    legacyRelation.person2Id,
  );
  if (!p1g || !p2g) return;

  const dedupKey = buildGraphRelationDedupKey(p1g, p2g, legacyRelation);
  let graphRelation = db.graphRelations.find((entry) => {
    if (
      Array.isArray(entry.legacyRelationIds) &&
      entry.legacyRelationIds.includes(legacyRelation.id)
    ) {
      return true;
    }
    return (
      buildGraphRelationDedupKey(entry.person1Id, entry.person2Id, entry) ===
      dedupKey
    );
  });

  const nowTs = nowIso();
  if (!graphRelation) {
    graphRelation = {
      id: legacyRelation.id,
      person1Id: p1g,
      person2Id: p2g,
      relation1to2: legacyRelation.relation1to2,
      relation2to1: legacyRelation.relation2to1,
      isConfirmed: legacyRelation.isConfirmed === true,
      createdBy: legacyRelation.createdBy || null,
      createdAt: legacyRelation.createdAt || nowTs,
      updatedAt: legacyRelation.updatedAt || nowTs,
      version: 0,
      deletedAt: null,
      marriageDate: legacyRelation.marriageDate || null,
      divorceDate: legacyRelation.divorceDate || null,
      customRelationLabel1to2: legacyRelation.customRelationLabel1to2 || null,
      customRelationLabel2to1: legacyRelation.customRelationLabel2to1 || null,
      parentSetId: legacyRelation.parentSetId || null,
      parentSetType: legacyRelation.parentSetType || null,
      isPrimaryParentSet:
        typeof legacyRelation.isPrimaryParentSet === "boolean"
          ? legacyRelation.isPrimaryParentSet
          : null,
      unionId: legacyRelation.unionId || null,
      unionType: legacyRelation.unionType || null,
      unionStatus: legacyRelation.unionStatus || null,
      legacyRelationIds: [legacyRelation.id],
      legacyTreeIds: legacyRelation.treeId ? [legacyRelation.treeId] : [],
    };
    db.graphRelations.push(graphRelation);
    return;
  }

  graphRelation.relation1to2 = legacyRelation.relation1to2;
  graphRelation.relation2to1 = legacyRelation.relation2to1;
  graphRelation.isConfirmed = legacyRelation.isConfirmed === true;
  graphRelation.updatedAt = legacyRelation.updatedAt || nowTs;
  graphRelation.marriageDate = legacyRelation.marriageDate || null;
  graphRelation.divorceDate = legacyRelation.divorceDate || null;
  graphRelation.customRelationLabel1to2 =
    legacyRelation.customRelationLabel1to2 || null;
  graphRelation.customRelationLabel2to1 =
    legacyRelation.customRelationLabel2to1 || null;
  graphRelation.parentSetId = legacyRelation.parentSetId || null;
  graphRelation.parentSetType = legacyRelation.parentSetType || null;
  graphRelation.isPrimaryParentSet =
    typeof legacyRelation.isPrimaryParentSet === "boolean"
      ? legacyRelation.isPrimaryParentSet
      : null;
  graphRelation.unionId = legacyRelation.unionId || null;
  graphRelation.unionType = legacyRelation.unionType || null;
  graphRelation.unionStatus = legacyRelation.unionStatus || null;
  if (graphRelation.deletedAt) graphRelation.deletedAt = null;
  if (!Array.isArray(graphRelation.legacyRelationIds)) {
    graphRelation.legacyRelationIds = [];
  }
  if (!graphRelation.legacyRelationIds.includes(legacyRelation.id)) {
    graphRelation.legacyRelationIds.push(legacyRelation.id);
  }
  if (!Array.isArray(graphRelation.legacyTreeIds)) {
    graphRelation.legacyTreeIds = [];
  }
  if (
    legacyRelation.treeId &&
    !graphRelation.legacyTreeIds.includes(legacyRelation.treeId)
  ) {
    graphRelation.legacyTreeIds.push(legacyRelation.treeId);
  }
  graphRelation.version = (graphRelation.version || 0) + 1;
}

function referenceSyncGraphFromLegacy(db) {
  if (!db || typeof db !== "object") return;
  if (!Array.isArray(db.graphPersons)) db.graphPersons = [];
  if (!Array.isArray(db.branchPersonViews)) db.branchPersonViews = [];
  if (!Array.isArray(db.branches)) db.branches = [];
  if (!Array.isArray(db.graphRelations)) db.graphRelations = [];

  const trees = Array.isArray(db.trees) ? db.trees : [];
  const persons = Array.isArray(db.persons) ? db.persons : [];
  const relations = Array.isArray(db.relations) ? db.relations : [];

  for (const tree of trees) {
    referenceSyncTreeToBranch(db, tree);
  }

  const liveLegacyPersonIds = new Set();
  const liveIdentityIds = new Set();
  for (const person of persons) {
    liveLegacyPersonIds.add(person.id);
    const identityId = normalizeNullableString(person.identityId);
    if (identityId) liveIdentityIds.add(identityId);
    referenceSyncPersonToGraph(db, person);
  }

  const liveRelationIds = new Set();
  for (const relation of relations) {
    liveRelationIds.add(relation.id);
    referenceSyncRelationToGraph(db, relation);
  }

  db.branchPersonViews = db.branchPersonViews.filter(
    (view) =>
      !view.legacyPersonId || liveLegacyPersonIds.has(view.legacyPersonId),
  );

  for (const graphPerson of db.graphPersons) {
    if (liveIdentityIds.has(graphPerson.id)) {
      if (graphPerson.deletedAt) graphPerson.deletedAt = null;
      continue;
    }
    if (!graphPerson.deletedAt) {
      graphPerson.deletedAt = nowIso();
    }
  }

  const identitiesByBranch = new Map();
  for (const person of persons) {
    const identityId = normalizeNullableString(person.identityId);
    if (!identityId) continue;
    if (!identitiesByBranch.has(person.treeId)) {
      identitiesByBranch.set(person.treeId, new Set());
    }
    identitiesByBranch.get(person.treeId).add(identityId);
  }
  for (const branch of db.branches) {
    const ids = branch.includeRules?.manualPersonIds;
    if (!Array.isArray(ids)) continue;
    const allowed = identitiesByBranch.get(branch.id);
    if (!allowed) {
      if (ids.length > 0) {
        branch.includeRules.manualPersonIds = [];
      }
      continue;
    }
    branch.includeRules.manualPersonIds = ids.filter((gid) =>
      allowed.has(gid),
    );
  }

  for (const graphRelation of db.graphRelations) {
    if (!Array.isArray(graphRelation.legacyRelationIds)) {
      graphRelation.legacyRelationIds = [];
    }
    const filtered = graphRelation.legacyRelationIds.filter((rid) =>
      liveRelationIds.has(rid),
    );
    if (filtered.length !== graphRelation.legacyRelationIds.length) {
      graphRelation.legacyRelationIds = filtered;
    }
    if (filtered.length === 0 && !graphRelation.deletedAt) {
      graphRelation.deletedAt = nowIso();
    } else if (filtered.length > 0 && graphRelation.deletedAt) {
      graphRelation.deletedAt = null;
    }
  }

  const liveTreeIds = new Set(trees.map((t) => t.id));
  for (const branch of db.branches) {
    if (!liveTreeIds.has(branch.id) && !branch.deletedAt) {
      branch.deletedAt = nowIso();
    }
  }
}

// ── Fixture builder ─────────────────────────────────────────────────
// Deliberately exercises: cross-tree identity collapse, create-path,
// update-path (stale canonical fields), view-created-on-existing-
// graphPerson, the _resolveGraphPersonIdForLegacy fallback (deleted
// legacy person still tracked via graphPerson.legacyPersonIds), and
// the dedup-key-shifts-mid-pass relation scenario.
function buildFixture() {
  const db = freshDb();
  const T0 = "2026-01-01T00:00:00.000Z";
  const T1 = "2026-02-01T00:00:00.000Z";

  db.trees = [
    {
      id: "t1",
      creatorId: "u1",
      name: "Дерево 1",
      isPrivate: true,
      memberIds: ["u1"],
      createdAt: T0,
      updatedAt: T0,
    },
    {
      id: "t2",
      creatorId: "u2",
      name: "Дерево 2",
      isPrivate: true,
      memberIds: ["u2"],
      createdAt: T0,
      updatedAt: T0,
    },
  ];

  db.persons = [
    // Дубли по identityId на РАЗНЫХ деревьях — должны схлопнуться в
    // один graphPerson с двумя branchPersonViews.
    {
      id: "p-shared-a",
      treeId: "t1",
      identityId: "identity-shared",
      name: "Общий Предок",
      createdAt: T0,
      updatedAt: T0,
    },
    {
      id: "p-shared-b",
      treeId: "t2",
      identityId: "identity-shared",
      name: "Общий Предок",
      createdAt: T0,
      updatedAt: T0,
    },
    // Совсем новый person — graphPerson ещё не существует (create).
    {
      id: "p-new",
      treeId: "t1",
      identityId: "identity-new",
      name: "Новый Человек",
      birthDate: "1990-05-05",
      createdAt: T0,
      updatedAt: T0,
    },
    // graphPerson УЖЕ существует, но с устаревшими каноническими
    // полями — должен обновиться (update path, version++).
    {
      id: "p-existing",
      treeId: "t1",
      identityId: "identity-existing",
      name: "Обновлённое Имя",
      birthDate: "1970-01-01",
      createdAt: T0,
      updatedAt: T1,
    },
    // Пара для relation dedup-key-shift сценария.
    {
      id: "p-a",
      treeId: "t1",
      identityId: "identity-a",
      name: "Персона А",
      createdAt: T0,
      updatedAt: T0,
    },
    {
      id: "p-b",
      treeId: "t1",
      identityId: "identity-b",
      name: "Персона Б",
      createdAt: T0,
      updatedAt: T0,
    },
  ];

  // Пред-существующий graphPerson с УСТАРЕВШИМИ полями для p-existing
  // (name/birthDate должны обновиться при синхронизации).
  db.graphPersons = [
    {
      id: "identity-existing",
      createdBy: "u1",
      createdAt: T0,
      updatedAt: T0,
      version: 0,
      deletedAt: null,
      hardDeleteScheduledAt: null,
      deletedByUserId: null,
      mergedInto: null,
      userId: null,
      legacyPersonIds: ["p-existing"],
      contactPrivacy: "owner-only",
      isPublic: false,
      source: "manual",
      visibility: "connected-via-blood-graph",
      visibilityOverride: false,
      name: "Старое Имя",
      birthDate: null,
    },
    // graphPerson для person1Id/person2Id разрешаемых через identity-a/b
    // не предсоздаём — пройдут create-путь при синхронизации persons.
    // graphPerson для УЖЕ УДАЛЁННОГО legacy person — только через
    // legacyPersonIds, сама persons-запись отсутствует в db.persons.
    {
      id: "identity-ghost",
      createdBy: "u1",
      createdAt: T0,
      updatedAt: T0,
      version: 0,
      deletedAt: null,
      hardDeleteScheduledAt: null,
      deletedByUserId: null,
      mergedInto: null,
      userId: null,
      legacyPersonIds: ["p-ghost"],
      contactPrivacy: "owner-only",
      isPublic: false,
      source: "manual",
      visibility: "connected-via-blood-graph",
      visibilityOverride: false,
      name: "Призрак",
    },
  ];

  // branchPersonView для p-existing НЕ создан заранее — тест должен
  // создать его поверх уже существующего graphPerson (view-create-on-
  // existing-graphPerson путь).
  db.branchPersonViews = [];

  // Ветка t1 уже существует с частично заполненным manualPersonIds —
  // проверяем ветку "existing branch" в auto-extend include rule.
  db.branches = [
    {
      id: "t1",
      legacyTreeId: "t1",
      ownerId: "u1",
      name: "Дерево 1",
      description: "",
      isPrivate: true,
      kind: "family",
      includeRules: {
        type: "manual",
        manualPersonIds: ["identity-shared"],
        anchorPersonId: null,
        maxHops: 5,
      },
      memberIds: ["u1"],
      publicSlug: null,
      isCertified: false,
      certificationNote: null,
      createdAt: T0,
      updatedAt: T0,
      deletedAt: null,
    },
  ];

  // graphRelation G уже существует для пары (identity-a, identity-b)
  // с типом partner/partner, привязана к legacyRelationIds=["rel-1"].
  // rel-1 САМА поменяет тип на spouse/spouse в этом проходе — дедуп-
  // ключ G должен сдвинуться. rel-2 — ОТДЕЛЬНАЯ, ещё не связанная
  // relation с ТЕМ ЖЕ типом spouse/spouse между той же парой: должна
  // задедуплицироваться в G по НОВОМУ (post-update) ключу, а не
  // создать вторую graphRelation-дублёр.
  db.graphRelations = [
    {
      id: "rel-1",
      person1Id: "identity-a",
      person2Id: "identity-b",
      relation1to2: "partner",
      relation2to1: "partner",
      isConfirmed: true,
      createdBy: "u1",
      createdAt: T0,
      updatedAt: T0,
      version: 0,
      deletedAt: null,
      marriageDate: null,
      divorceDate: null,
      customRelationLabel1to2: null,
      customRelationLabel2to1: null,
      parentSetId: null,
      parentSetType: null,
      isPrimaryParentSet: null,
      unionId: null,
      unionType: null,
      unionStatus: null,
      legacyRelationIds: ["rel-1"],
      legacyTreeIds: ["t1"],
    },
  ];

  db.relations = [
    {
      id: "rel-1",
      treeId: "t1",
      person1Id: "p-a",
      person2Id: "p-b",
      relation1to2: "spouse",
      relation2to1: "spouse",
      isConfirmed: true,
      createdBy: "u1",
      createdAt: T0,
      updatedAt: T1,
    },
    {
      id: "rel-2",
      treeId: "t1",
      person1Id: "p-a",
      person2Id: "p-b",
      relation1to2: "spouse",
      relation2to1: "spouse",
      isConfirmed: true,
      createdBy: "u1",
      createdAt: T1,
      updatedAt: T1,
    },
    // Ссылается на уже удалённый legacy person (p-ghost отсутствует в
    // db.persons) — резолвится ТОЛЬКО через graphPerson.legacyPersonIds
    // (fallback-путь _resolveGraphPersonIdForLegacy).
    {
      id: "rel-ghost",
      treeId: "t1",
      person1Id: "p-ghost",
      person2Id: "p-new",
      relation1to2: "parent",
      relation2to1: "child",
      isConfirmed: true,
      createdBy: "u1",
      createdAt: T0,
      updatedAt: T0,
    },
  ];

  return db;
}

test(
  "SPEED-9 A: индексированный _syncGraphFromLegacy даёт результат, побайтово идентичный дореформенному алгоритму (дубли identityId, create+update path, dedup-key сдвиг mid-pass, fallback-резолв удалённого person)",
  (t) => {
    t.mock.timers.enable({apis: ["Date"]});

    const referenceDb = buildFixture();
    withDeterministicUuids(() => referenceSyncGraphFromLegacy(referenceDb));

    const store = makeStoreStub();
    const actualDb = buildFixture();
    withDeterministicUuids(() => store._syncGraphFromLegacy(actualDb));

    // Прямое сравнение снапшотов — если оптимизация разошлась с
    // оригиналом ХОТЬ ГДЕ-ТО (создание, обновление, дедуп, resurrect,
    // include-rules, dedup-key-сдвиг), assert.deepEqual это поймает.
    assert.deepEqual(
      actualDb.graphPersons,
      referenceDb.graphPersons,
      "graphPersons разошлись",
    );
    assert.deepEqual(
      actualDb.branchPersonViews,
      referenceDb.branchPersonViews,
      "branchPersonViews разошлись",
    );
    assert.deepEqual(actualDb.branches, referenceDb.branches, "branches разошлись");
    assert.deepEqual(
      actualDb.graphRelations,
      referenceDb.graphRelations,
      "graphRelations разошлись",
    );

    // Дополнительные точечные проверки — чтобы падение было понятным,
    // а не просто "снапшоты разные".
    const sharedGraphPersons = actualDb.graphPersons.filter(
      (g) => g.id === "identity-shared",
    );
    assert.equal(sharedGraphPersons.length, 1, "дубли по identityId не схлопнулись");
    const sharedViews = actualDb.branchPersonViews.filter(
      (v) => v.personId === "identity-shared",
    );
    assert.equal(sharedViews.length, 2, "обе branchPersonView для общего предка должны быть на месте");

    const existingGraphPerson = actualDb.graphPersons.find(
      (g) => g.id === "identity-existing",
    );
    assert.equal(existingGraphPerson.name, "Обновлённое Имя");
    assert.equal(existingGraphPerson.birthDate, "1970-01-01");
    assert.equal(existingGraphPerson.version, 1, "canonical-обновление должно бампнуть version");

    const existingView = actualDb.branchPersonViews.find(
      (v) => v.legacyPersonId === "p-existing",
    );
    assert.ok(existingView, "view для p-existing должен быть создан поверх существующего graphPerson");

    // Дедуп-сдвиг: обе relation (rel-1, rel-2) должны схлопнуться в
    // ОДНУ graphRelation с ОБНОВЛЁННЫМ типом spouse/spouse — не в две
    // отдельные записи.
    const abRelations = actualDb.graphRelations.filter(
      (g) => g.person1Id === "identity-a" && g.person2Id === "identity-b",
    );
    assert.equal(abRelations.length, 1, "rel-1/rel-2 должны были задедуплицироваться в одну graphRelation");
    assert.equal(abRelations[0].relation1to2, "spouse");
    assert.deepEqual(
      [...abRelations[0].legacyRelationIds].sort(),
      ["rel-1", "rel-2"],
      "обе legacy relation должны быть привязаны к единой graphRelation",
    );

    // rel-ghost резолвится через fallback (p-ghost отсутствует в
    // db.persons, но identity-ghost помнит его через legacyPersonIds).
    const ghostRelation = actualDb.graphRelations.find(
      (g) => g.id === "rel-ghost",
    );
    assert.ok(ghostRelation, "rel-ghost должна была резолвиться через fallback-путь");
    assert.equal(ghostRelation.person1Id, "identity-ghost");
    assert.equal(ghostRelation.person2Id, "identity-new");

    t.mock.timers.reset();
  },
);

test(
  "SPEED-9 A: повторный проход остаётся идемпотентным после индексации (стабильные id, без дублей и без пересоздания записей)",
  (t) => {
    // Идемпотентность здесь — в том же смысле, что и у существующего
    // "_syncGraphFromLegacy is idempotent" в graph-sync.test.js:
    // стабильные id, отсутствие дублей/пересоздания строк. НЕ "нулевой
    // дрейф каждого поля" — у _syncRelationToGraph update-ветка И ДО
    // SPEED-9 безусловно бампает graphRelation.version на КАЖДЫЙ вызов
    // (даже когда ни одно поле фактически не поменялось — это
    // до-существующее поведение оригинального алгоритма, не
    // регрессия индексации; см. version у rel-1/rel-ghost ниже).
    t.mock.timers.enable({apis: ["Date"]});
    const store = makeStoreStub();
    const db = buildFixture();

    store._syncGraphFromLegacy(db);
    const firstPass = structuredClone(db);
    store._syncGraphFromLegacy(db);
    store._syncGraphFromLegacy(db);

    assert.equal(db.graphPersons.length, firstPass.graphPersons.length);
    assert.equal(db.branchPersonViews.length, firstPass.branchPersonViews.length);
    assert.equal(db.branches.length, firstPass.branches.length);
    assert.equal(db.graphRelations.length, firstPass.graphRelations.length);

    // Стабильные id — повторные проходы НЕ подменяют строки.
    assert.deepEqual(
      db.graphPersons.map((g) => g.id).sort(),
      firstPass.graphPersons.map((g) => g.id).sort(),
    );
    assert.deepEqual(
      db.branchPersonViews.map((v) => v.id).sort(),
      firstPass.branchPersonViews.map((v) => v.id).sort(),
    );
    assert.deepEqual(
      db.graphRelations.map((g) => g.id).sort(),
      firstPass.graphRelations.map((g) => g.id).sort(),
    );

    // Поля, у которых update-ветка условна (canonicalChanged), ДЕЙСТВИТЕЛЬНО
    // не дрейфуют повторно — только version-бамп на graphRelation дрейфует
    // (задокументированная до-существующая особенность, не эта задача).
    for (const graphPerson of db.graphPersons) {
      const before = firstPass.graphPersons.find((g) => g.id === graphPerson.id);
      assert.equal(graphPerson.version, before.version, `graphPerson ${graphPerson.id} version не должен дрейфовать`);
    }
    for (const view of db.branchPersonViews) {
      const before = firstPass.branchPersonViews.find((v) => v.id === view.id);
      assert.deepEqual(view, before, `branchPersonView ${view.id} не должен меняться на повторном проходе`);
    }

    t.mock.timers.reset();
  },
);
