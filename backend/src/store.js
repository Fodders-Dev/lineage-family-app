const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const {
  describeMessagePreview,
  normalizeMessageAttachments,
  normalizeReplyReference,
} = require("./chat-utils");
const {
  normalizedBirthYear,
  scorePersonPair,
  findCrossTreeIdentitySuggestions,
  normalizePersonForScoring,
  scoreNormalizedPersons,
} = require("./identity-matcher");
const {
  GRAPH_PERSON_CANONICAL_FIELDS,
  backfillPersonIdentities,
  buildGraphRelationDedupKey,
  migrateTreesToGraphAndBranches,
} = require("./migration-utils");

const PROFILE_CONTRIBUTION_POLICIES = new Set([
  "disabled",
  "suggestions",
]);

const PROFILE_SUGGESTION_FIELDS = Object.freeze([
  "firstName",
  "lastName",
  "middleName",
  "maidenName",
  "photoUrl",
  "gender",
  "birthDate",
  "birthPlace",
  "countryName",
  "city",
  "bio",
  "familyStatus",
  "aboutFamily",
  "education",
  "work",
  "hometown",
  "languages",
  "values",
  "religion",
  "interests",
]);

const EMPTY_DB = {
  users: [],
  sessions: [],
  authHandoffs: [],
  passwordResetTokens: [],
  // Phase 1.2 voltage-indicator matcher: per-user records of
  // suggestion dismissals so the 💡 indicator doesn't keep
  // re-suggesting pairs the user already said "no, these are
  // different people" about.
  dismissedIdentitySuggestions: [],
  // Phase 1.3 edit-time conflict surfacing: rows recorded by
  // `_propagateIdentityFields` when it would have overwritten a
  // value the user had locally edited on the target tree
  // between propagations. The user resolves each row via
  // /v1/trees/:treeId/conflicts/:conflictId/resolve as either
  // `keep` (target wins, source change ignored on this side)
  // or `overwrite` (source wins, target overwritten).
  identityFieldConflicts: [],
  // Phase 3.1 unified-graph collections. The legacy trees /
  // persons / relations are kept as the read source until the
  // back-compat layer is wired in 3.1c — these new collections
  // are populated by the one-shot migration in
  // migration-utils.migrateTreesToGraphAndBranches and serve as
  // the source of truth from then on.
  // graphPersons: one node per real human, identity-merged from
  //   the legacy persons + personIdentities pair. Carries the
  //   canonical identity-propagation fields (name, dates, photo).
  // graphRelations: deduplicated parent/child/spouse edges
  //   between graphPersons (legacy per-tree duplicates collapsed
  //   to one row per canonical pair+type).
  // branches: per-user filter slice over the graph + automatic
  //   social circle for the per-branch feed. Replaces the legacy
  //   `trees` notion of "container of people" with "named view
  //   over the global graph". `legacyTreeId` keeps the back-
  //   reference so existing /v1/trees/:treeId routes can resolve
  //   the matching branch.
  // branchPersonViews: per-(branch, person) editorial annotation
  //   — notes / familySummary / bio / visibility / per-branch
  //   label override. Splits "what is this human" (graphPerson)
  //   from "how does this branch present them" (this row).
  graphPersons: [],
  graphRelations: [],
  branches: [],
  branchPersonViews: [],
  // Phase 3.1 owner-model: explicit grants from a graphPerson's
  // owner to other users for `edit` / `merge-consent` / `soft-delete`
  // scopes. Default: only the owner (graphPerson.userId or
  // graphPerson.createdBy) can mutate. Auto-extension by hops was
  // explicitly rejected in DECISIONS.md (2026-05-10 ответ C) — every
  // additional editor has to be granted access by the owner.
  graphPersonEditGrants: [],
  // One-shot migration ledger: tracks which schema migrations have
  // already run so re-reads on startup don't redo idempotent work.
  // Phase 3.1 sets `treesToGraph: "complete-v2"` once the new
  // per-field highest-completeness migration has built the graph
  // collections from the legacy ones. The legacy "complete" value
  // marks an old v1 migration whose canonical-picking was record-
  // level (claimed user → updatedAt); v1 snapshots get re-built
  // automatically on next startup so they pick up the new logic.
  migrationStatus: {},
  trees: [],
  // Phase B (federated семьи): 5 collections per ENTITY-DESIGN.md.
  // `семьи` (singular: семья) — explicit group entity wrapping a tree
  // с multi-member roles (owner/editor/viewer). One-tree-per-семья
  // invariant per ENTITY-DESIGN §3.1. Per-семья membership table —
  // source of truth для access control, replaces tree.memberIds[] +
  // tree.creatorId как primary mechanism (legacy fields preserved
  // через dual-write compat shim в Week 3).
  // Hidden persons — per-user opaque filter, не mutates tree.
  // Invitations + browse tokens mirror Phase 6.5 kinshipChecks state
  // machine pattern.
  semyi: [],
  semyaMembers: [],
  semyaMemberHiddenPersons: [],
  semyaInvitations: [],
  semyaBrowseTokens: [],
  persons: [],
  // Ship Q4a (2026-05-28): soft-delete snapshot collection. Path 2
  // from PHASE-Q4A-SOFT-DELETE-DESIGN (ec12804) — separate
  // collection чтобы 95 db.persons read sites остаются untouched
  // by construction. Hard-delete job sweeps этот set per
  // hardDeleteScheduledAt + earliestHardDelete (3h floor) gates.
  deletedPersons: [],
  // Ship Q4a (2026-05-28, Ship 30b): same pattern для posts.
  // Snapshot captures post + comments + reactions для full restore.
  deletedPosts: [],
  // Profile Phase 1 (2026-05-28): article-style biography entity.
  // One row per person — ordered content blocks (paragraph / header /
  // photo / gallery / audio / quote / divider). Separate collection
  // (NOT a person field) — keeps existing 95 db.persons read sites
  // untouched. Per-block authorUserId = multi-author attribution;
  // full history reuses treeChangeRecords (type `article.*`). Media
  // referenced by url (no media table — mirrors photoGallery).
  profileArticles: [],
  personIdentities: [],
  personAttributes: [],
  circles: [],
  circleMembers: [],
  mergeProposals: [],
  identityClaims: [],
  relations: [],
  chats: [],
  chatDrafts: [],
  chatPins: [],
  calls: [],
  messages: [],
  messageReactions: [],
  relationRequests: [],
  // Phase 6 BFS «мы родственники?» bilateral consent flow.
  // Different semantic от relationRequests (invite-to-tree).
  // DECISIONS.md 2026-05-13: kinshipChecks naming + state-based
  // idempotency.
  kinshipChecks: [],
  // Phase 6 wizard progress per-user. State-based idempotency
  // gate для /onboarding/seed.
  onboardingStates: [],
  treeInvitations: [],
  treeChangeRecords: [],
  notifications: [],
  posts: [],
  // Phase E1: «Встреча» (Gathering) — family event invitations. Mirrors
  // posts (circle-on-tree audience, multi-branch fan-out). RSVP rows
  // land here in E3; create+delete only in E1.
  gatherings: [],
  // Phase E4: «Опрос» (Poll) — mirrors gatherings (same audience model);
  // carries options + per-user responses (votes).
  polls: [],
  stories: [],
  comments: [],
  postReactions: [],
  postCommentReactions: [],
  storyReactions: [],
  reports: [],
  blocks: [],
  profileContributions: [],
  pushDevices: [],
  pushDeliveries: [],
  clientDiagnostics: [],
  // Phase 3.6: audit log для hard-delete background job. Каждая запись
  // фиксирует physically deleted entity (entityType, entityId,
  // deletedAt, scheduledAt, hardDeletedAt, runId). Self-prune: записи
  // старше 90 дней удаляются тем же job на следующем runs (DECISIONS.md
  // 2026-05-18 «Phase 3.6 hard-delete background job»).
  hardDeleteAudit: [],
  // Last successful (non-dry, non-paused) run timestamp. Persisted
  // чтобы `setInterval` пережил backend restarts: startup checks
  // elapsed since `hardDeleteLastRunAt`, schedules catch-up через
  // 60s если interval уже истёк. `null` = job ни разу не успешно
  // не отработал на этом state.
  hardDeleteLastRunAt: null,
};

function normalizeDbState(parsed) {
  return {
    users: Array.isArray(parsed?.users) ? parsed.users : [],
    sessions: Array.isArray(parsed?.sessions) ? parsed.sessions : [],
    authHandoffs: Array.isArray(parsed?.authHandoffs) ? parsed.authHandoffs : [],
    passwordResetTokens: Array.isArray(parsed?.passwordResetTokens)
      ? parsed.passwordResetTokens
      : [],
    dismissedIdentitySuggestions: Array.isArray(
      parsed?.dismissedIdentitySuggestions,
    )
      ? parsed.dismissedIdentitySuggestions
      : [],
    identityFieldConflicts: Array.isArray(parsed?.identityFieldConflicts)
      ? parsed.identityFieldConflicts
      : [],
    graphPersons: Array.isArray(parsed?.graphPersons) ? parsed.graphPersons : [],
    graphRelations: Array.isArray(parsed?.graphRelations)
      ? parsed.graphRelations
      : [],
    branches: Array.isArray(parsed?.branches) ? parsed.branches : [],
    branchPersonViews: Array.isArray(parsed?.branchPersonViews)
      ? parsed.branchPersonViews
      : [],
    graphPersonEditGrants: Array.isArray(parsed?.graphPersonEditGrants)
      ? parsed.graphPersonEditGrants
      : [],
    migrationStatus:
      parsed?.migrationStatus && typeof parsed.migrationStatus === "object"
        ? parsed.migrationStatus
        : {},
    trees: Array.isArray(parsed?.trees) ? parsed.trees : [],
    // Phase B федеративные семьи. Backend identifiers ASCII
    // transliterated (semyi / semyaMembers) — JSON tooling +
    // codepaths comfortable c Latin keys. UI text + docs continue
    // c Cyrillic «семья». См. ENTITY-DESIGN.md §1.
    semyi: Array.isArray(parsed?.semyi) ? parsed.semyi : [],
    semyaMembers: Array.isArray(parsed?.semyaMembers)
      ? parsed.semyaMembers
      : [],
    semyaMemberHiddenPersons: Array.isArray(parsed?.semyaMemberHiddenPersons)
      ? parsed.semyaMemberHiddenPersons
      : [],
    semyaInvitations: Array.isArray(parsed?.semyaInvitations)
      ? parsed.semyaInvitations
      : [],
    semyaBrowseTokens: Array.isArray(parsed?.semyaBrowseTokens)
      ? parsed.semyaBrowseTokens
      : [],
    persons: Array.isArray(parsed?.persons) ? parsed.persons : [],
    // Ship Q4a (2026-05-28): backwards-compat — older data files
    // without deletedPersons field treated as empty.
    deletedPersons: Array.isArray(parsed?.deletedPersons)
      ? parsed.deletedPersons
      : [],
    // Ship Q4a (2026-05-28, Ship 30b): same для deletedPosts.
    deletedPosts: Array.isArray(parsed?.deletedPosts)
      ? parsed.deletedPosts
      : [],
    profileArticles: Array.isArray(parsed?.profileArticles)
      ? parsed.profileArticles
      : [],
    personIdentities: Array.isArray(parsed?.personIdentities)
      ? parsed.personIdentities
      : [],
    personAttributes: Array.isArray(parsed?.personAttributes)
      ? parsed.personAttributes
      : [],
    circles: Array.isArray(parsed?.circles) ? parsed.circles : [],
    circleMembers: Array.isArray(parsed?.circleMembers)
      ? parsed.circleMembers
      : [],
    mergeProposals: Array.isArray(parsed?.mergeProposals)
      ? parsed.mergeProposals
      : [],
    identityClaims: Array.isArray(parsed?.identityClaims)
      ? parsed.identityClaims
      : [],
    relations: Array.isArray(parsed?.relations) ? parsed.relations : [],
    chats: Array.isArray(parsed?.chats) ? parsed.chats : [],
    chatDrafts: Array.isArray(parsed?.chatDrafts) ? parsed.chatDrafts : [],
    chatPins: Array.isArray(parsed?.chatPins) ? parsed.chatPins : [],
    calls: Array.isArray(parsed?.calls)
      ? parsed.calls.map((entry) => normalizeStoredCall(entry)).filter(Boolean)
      : [],
    messages: Array.isArray(parsed?.messages) ? parsed.messages : [],
    messageReactions: Array.isArray(parsed?.messageReactions)
      ? parsed.messageReactions
      : [],
    relationRequests: Array.isArray(parsed?.relationRequests)
      ? parsed.relationRequests
      : [],
    kinshipChecks: Array.isArray(parsed?.kinshipChecks)
      ? parsed.kinshipChecks
      : [],
    onboardingStates: Array.isArray(parsed?.onboardingStates)
      ? parsed.onboardingStates
      : [],
    treeInvitations: Array.isArray(parsed?.treeInvitations)
      ? parsed.treeInvitations
      : [],
    treeChangeRecords: Array.isArray(parsed?.treeChangeRecords)
      ? parsed.treeChangeRecords
      : [],
    notifications: Array.isArray(parsed?.notifications)
      ? parsed.notifications
      : [],
    posts: Array.isArray(parsed?.posts) ? parsed.posts : [],
    // Phase E1: backwards-compat — older data files without the
    // gatherings field load as empty.
    gatherings: Array.isArray(parsed?.gatherings) ? parsed.gatherings : [],
    // Phase E4: same backwards-compat for polls.
    polls: Array.isArray(parsed?.polls) ? parsed.polls : [],
    stories: Array.isArray(parsed?.stories) ? parsed.stories : [],
    comments: Array.isArray(parsed?.comments) ? parsed.comments : [],
    postReactions: Array.isArray(parsed?.postReactions)
      ? parsed.postReactions
      : [],
    postCommentReactions: Array.isArray(parsed?.postCommentReactions)
      ? parsed.postCommentReactions
      : [],
    storyReactions: Array.isArray(parsed?.storyReactions)
      ? parsed.storyReactions
      : [],
    reports: Array.isArray(parsed?.reports) ? parsed.reports : [],
    blocks: Array.isArray(parsed?.blocks) ? parsed.blocks : [],
    profileContributions: Array.isArray(parsed?.profileContributions)
      ? parsed.profileContributions
      : [],
    pushDevices: Array.isArray(parsed?.pushDevices) ? parsed.pushDevices : [],
    pushDeliveries: Array.isArray(parsed?.pushDeliveries)
      ? parsed.pushDeliveries
      : [],
    clientDiagnostics: Array.isArray(parsed?.clientDiagnostics)
      ? parsed.clientDiagnostics
      : [],
    // Phase 3.6 hard-delete job artifacts. Default empty / null
    // preserves backward compat — old snapshots без этих полей
    // подхватятся прозрачно (см. EMPTY_DB).
    hardDeleteAudit: Array.isArray(parsed?.hardDeleteAudit)
      ? parsed.hardDeleteAudit
      : [],
    hardDeleteLastRunAt:
      typeof parsed?.hardDeleteLastRunAt === "string"
        ? parsed.hardDeleteLastRunAt
        : null,
  };
}

function nowIso() {
  return new Date().toISOString();
}

// Compare two values for one of the identity-propagation fields.
// `photoGallery` is an array — JSON-snapshot equality matches the
// existing propagation skip-rule (see `_propagateIdentityFields`)
// so reordering with the same content doesn't count as a change.
// Other fields are scalars; reference/value equality is enough.
function valuesEqualForPropagation(field, a, b) {
  if (field === "photoGallery") {
    return JSON.stringify(a || []) === JSON.stringify(b || []);
  }
  return a === b;
}

// Phase 6.3: parse a date-string (YYYY-MM-DD or full ISO) and
// return the next anniversary inside the next [now, now+horizonDays]
// window, or null when the date is invalid / the anniversary is
// outside the window. Birthday for living people, death anniversary
// for memorials — same logic, different fields.
function computeUpcomingAnniversary(rawDate, now, horizonDays) {
  if (!rawDate) return null;
  const parsed = new Date(rawDate);
  if (Number.isNaN(parsed.getTime())) return null;
  // Take month + day from the original date but anchor to the
  // current year. If that anniversary is already in the past for
  // this calendar year, push to next year.
  const month = parsed.getUTCMonth();
  const day = parsed.getUTCDate();
  const todayUtc = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()),
  );
  let anniversary = new Date(
    Date.UTC(now.getUTCFullYear(), month, day),
  );
  if (anniversary.getTime() < todayUtc.getTime()) {
    anniversary = new Date(
      Date.UTC(now.getUTCFullYear() + 1, month, day),
    );
  }
  const daysUntil = Math.round(
    (anniversary.getTime() - todayUtc.getTime()) / 86400_000,
  );
  if (daysUntil > horizonDays) return null;
  const yearsSince =
    anniversary.getUTCFullYear() - parsed.getUTCFullYear();
  return {
    date: anniversary,
    daysUntil,
    yearsSince,
  };
}

// ── Phase 4: blood-relation classification ────────────────────────────
// `parent` / `child` / `sibling` are the three edges the BFS engine
// walks to find consanguinity paths. step-/adopted-/in-law variants
// are NOT blood — they connect family but not DNA — and are
// deliberately excluded so "найти родство" stays meaningful.
function canonicalBloodType(rawType) {
  switch (String(rawType || "").toLowerCase().trim()) {
    case "parent":
      return "parent";
    case "child":
      return "child";
    case "sibling":
      return "sibling";
    default:
      return null;
  }
}

// Mirror of a blood type — used when one side of a legacy relation
// row was stored without a relation2to1 value. The existing tree
// code in `_buildBranchVisiblePersonIds` (line ~12420) does the
// same fallback via `relationMirror`; doing it here keeps the
// blood-graph in sync with what the rest of the backend already
// considers "family" for that record.
function mirrorBloodType(rawType) {
  const canonical = canonicalBloodType(rawType);
  if (canonical === "parent") return "child";
  if (canonical === "child") return "parent";
  if (canonical === "sibling") return "sibling";
  return null;
}

// Russian relationship label generator. Takes the edge sequence
// produced by the BFS (e.g. ["parent","sibling","child"]) and the
// target person's gender, returns a human label + degree. Handles
// the common direct-line / sibling / cousin patterns; falls back
// to a neutral "родственник" for shapes we don't classify yet
// (zigzag paths through marriage etc., though the engine doesn't
// produce those today since spouse edges aren't in the graph).
function describeBloodRelation(edges, gender) {
  // Edge semantics: each edge label is the role of the TARGET side
  // (the person we're walking TO).
  // - "parent" edge means I went TO a parent (going UP — towards
  //   ancestor).
  // - "child" edge means I went TO a child (going DOWN — towards
  //   descendant).
  // - "sibling" edge stays lateral.
  // Matches the convention in _buildBranchVisiblePersonIds.
  let up = 0;
  let hasSibling = false;
  let down = 0;
  let i = 0;
  while (i < edges.length && edges[i] === "parent") {
    up++;
    i++;
  }
  if (i < edges.length && edges[i] === "sibling") {
    hasSibling = true;
    i++;
  }
  while (i < edges.length && edges[i] === "child") {
    down++;
    i++;
  }
  if (i !== edges.length) {
    // Unusual shape — e.g. child-parent-child traversal that
    // would imply spouse edges. We don't traverse those, but
    // be defensive in case future code surfaces such paths.
    return {label: "Родственник", degree: edges.length};
  }

  const isFemale = String(gender || "").toLowerCase() === "female";

  // Direct ancestor line.
  if (!hasSibling && down === 0 && up > 0) {
    if (up === 1) return {label: isFemale ? "мама" : "папа", degree: 1};
    if (up === 2) return {label: isFemale ? "бабушка" : "дедушка", degree: 2};
    if (up === 3)
      return {label: isFemale ? "прабабушка" : "прадедушка", degree: 3};
    const prefix = "пра".repeat(up - 2);
    return {
      label: `${prefix}${isFemale ? "бабушка" : "дедушка"}`,
      degree: up,
    };
  }

  // Direct descendant line.
  if (!hasSibling && up === 0 && down > 0) {
    if (down === 1) return {label: isFemale ? "дочь" : "сын", degree: 1};
    if (down === 2)
      return {label: isFemale ? "внучка" : "внук", degree: 2};
    if (down === 3)
      return {label: isFemale ? "правнучка" : "правнук", degree: 3};
    const prefix = "пра".repeat(down - 2);
    return {
      label: `${prefix}${isFemale ? "внучка" : "внук"}`,
      degree: down,
    };
  }

  // Pure sibling.
  if (hasSibling && up === 0 && down === 0) {
    return {label: isFemale ? "сестра" : "брат", degree: 1};
  }

  // Sibling-of-ancestor: uncle / aunt and their elders.
  if (hasSibling && up >= 1 && down === 0) {
    if (up === 1) return {label: isFemale ? "тётя" : "дядя", degree: 2};
    if (up === 2) {
      return {
        label: isFemale ? "двоюродная бабушка" : "двоюродный дедушка",
        degree: 3,
      };
    }
    const prefix = "пра".repeat(up - 1);
    return {
      label: `${prefix}${isFemale ? "тётя" : "дядя"}`,
      degree: up + 1,
    };
  }

  // Descendant-of-sibling: nephew / niece and their juniors.
  if (hasSibling && up === 0 && down >= 1) {
    if (down === 1) {
      return {label: isFemale ? "племянница" : "племянник", degree: 2};
    }
    if (down === 2) {
      return {
        label: isFemale ? "внучатая племянница" : "внучатый племянник",
        degree: 3,
      };
    }
    const prefix = "пра".repeat(down - 1);
    return {
      label: `${prefix}${isFemale ? "племянница" : "племянник"}`,
      degree: down + 1,
    };
  }

  // Cousin family: ancestor → sibling → descendant.
  if (hasSibling && up >= 1 && down >= 1) {
    const cousinDegree = Math.min(up, down);
    const removed = Math.abs(up - down);
    const cousinPrefixOptions = [
      "двоюродный",
      "троюродный",
      "четвероюродный",
      "пятиюродный",
      "шестиюродный",
    ];
    const cousinPrefix =
      cousinPrefixOptions[cousinDegree - 1] || `${cousinDegree + 1}-юродный`;
    if (removed === 0) {
      return {
        label: `${cousinPrefix} ${isFemale ? "сестра" : "брат"}`,
        degree: up + down + 1,
      };
    }
    if (up > down) {
      return {
        label: `${cousinPrefix} ${isFemale ? "тётя" : "дядя"}`,
        degree: up + down + 1,
      };
    }
    return {
      label: `${cousinPrefix} ${isFemale ? "племянница" : "племянник"}`,
      degree: up + down + 1,
    };
  }

  return {label: "Родственник", degree: edges.length};
}

const SESSION_TOUCH_MIN_INTERVAL_MS = 60_000;

function normalizeOptionalIsoTimestamp(value) {
  const rawValue = String(value || "").trim();
  if (!rawValue) {
    return null;
  }

  const parsedDate = new Date(rawValue);
  if (Number.isNaN(parsedDate.getTime())) {
    return null;
  }

  return parsedDate.toISOString();
}

function isExpiredAt(value, referenceTimeMs = Date.now()) {
  const normalizedValue = normalizeOptionalIsoTimestamp(value);
  if (!normalizedValue) {
    return false;
  }
  return new Date(normalizedValue).getTime() <= referenceTimeMs;
}

function createProfileNote({title, content}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    title: String(title || "").trim(),
    content: String(content || "").trim(),
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function createNotificationRecord({
  userId,
  type,
  title,
  body,
  data = {},
  silent = false,
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    userId,
    type: String(type || "generic"),
    title: String(title || "").trim(),
    body: String(body || "").trim(),
    data: data && typeof data === "object" ? structuredClone(data) : {},
    // Phase 6.5+: silent notifications carry data-only signals
    // (e.g. `tree_mutated` для auto-refresh). Client filters эти
    // на foreground display path; push gateway propagates flag в
    // payload так что service worker / device handlers могут skip
    // banner. Default false — backwards-compat для all existing
    // dispatch callers.
    silent: silent === true,
    createdAt: timestamp,
    readAt: null,
  };
}

function createPostRecord({
  treeId,
  branchIds = null,
  authorId,
  authorName,
  authorPhotoUrl = null,
  content,
  imageUrls = [],
  isPublic = false,
  scopeType = "wholeTree",
  anchorPersonIds = [],
  circleId = null,
  clientRequestId = null,
}) {
  const timestamp = nowIso();
  // Phase 3.4: a post lives in one or more branches. Default is
  // the single legacy tree id (back-compat with old clients that
  // only know treeId), but callers can pass an explicit branchIds
  // array to publish a post into multiple branches at once
  // (e.g. one family photo published to "Моя кровь" AND
  // "Семья жены" so both feeds show it without copies).
  const normalizedBranchIds = Array.isArray(branchIds)
    ? Array.from(
        new Set(
          branchIds
            .map((value) => normalizeNullableString(value))
            .filter(Boolean),
        ),
      )
    : [];
  if (normalizedBranchIds.length === 0 && treeId) {
    normalizedBranchIds.push(treeId);
  }
  return {
    id: crypto.randomUUID(),
    treeId,
    branchIds: normalizedBranchIds,
    authorId,
    authorName: String(authorName || "Аноним").trim() || "Аноним",
    authorPhotoUrl: normalizeNullableString(authorPhotoUrl),
    content: String(content || "").trim(),
    imageUrls: Array.from(
      new Set(
        (Array.isArray(imageUrls) ? imageUrls : [])
          .map((value) => String(value || "").trim())
          .filter(Boolean),
      ),
    ),
    createdAt: timestamp,
    updatedAt: timestamp,
    likedBy: [],
    isPublic: isPublic === true,
    scopeType: scopeType === "branches" ? "branches" : "wholeTree",
    anchorPersonIds: normalizeParticipantIds(anchorPersonIds),
    circleId: normalizeNullableString(circleId),
    // Идемпотентный ключ публикации (см. createPost): по нему повтор того
    // же запроса от того же автора схлопывается в уже созданный пост.
    clientRequestId: normalizeNullableString(clientRequestId),
  };
}

// Phase E1: a «Встреча» (Gathering) — a family-event invitation. Mirrors
// createPostRecord field-for-field where they overlap (treeId, branchIds,
// author*, scopeType, anchorPersonIds, circleId) so the same circle-on-
// tree audience + multi-branch fan-out machinery applies. Event-specific
// fields: title, description, startAt/endAt (ISO strings), isAllDay,
// place (free text). rsvps stays empty until E3.
function createGatheringRecord({
  treeId,
  branchIds = null,
  authorId,
  authorName,
  authorPhotoUrl = null,
  title,
  description = null,
  startAt = null,
  endAt = null,
  isAllDay = false,
  place = null,
  imageUrls = [],
  scopeType = "wholeTree",
  anchorPersonIds = [],
  circleId = null,
}) {
  const timestamp = nowIso();
  const normalizedBranchIds = Array.isArray(branchIds)
    ? Array.from(
        new Set(
          branchIds
            .map((value) => normalizeNullableString(value))
            .filter(Boolean),
        ),
      )
    : [];
  if (normalizedBranchIds.length === 0 && treeId) {
    normalizedBranchIds.push(treeId);
  }
  return {
    id: crypto.randomUUID(),
    treeId,
    branchIds: normalizedBranchIds,
    authorId,
    authorName: String(authorName || "Аноним").trim() || "Аноним",
    authorPhotoUrl: normalizeNullableString(authorPhotoUrl),
    title: String(title || "").trim(),
    description: normalizeNullableString(description),
    startAt: normalizeNullableString(startAt),
    endAt: normalizeNullableString(endAt),
    isAllDay: isAllDay === true,
    place: normalizeNullableString(place),
    // Dedup + trim, same as createPostRecord.
    imageUrls: Array.from(
      new Set(
        (Array.isArray(imageUrls) ? imageUrls : [])
          .map((value) => String(value || "").trim())
          .filter(Boolean),
      ),
    ),
    scopeType: scopeType === "branches" ? "branches" : "wholeTree",
    anchorPersonIds: normalizeParticipantIds(anchorPersonIds),
    circleId: normalizeNullableString(circleId),
    createdAt: timestamp,
    updatedAt: timestamp,
    rsvps: [], // Phase E3.
  };
}

// Phase E4: «Опрос» (Poll). Mirrors createGatheringRecord for the shared
// audience fields (treeId/branchIds/author*/scopeType/anchorPersonIds/
// circleId) + imageUrls (dedup-trim like posts). Poll-specific: question,
// options (each normalised to {id, text}, empties dropped), allowMultiple,
// closesAt. responses (votes) stay empty until someone votes.
function createPollRecord({
  treeId,
  branchIds = null,
  authorId,
  authorName,
  authorPhotoUrl = null,
  question,
  options = [],
  allowMultiple = false,
  closesAt = null,
  imageUrls = [],
  scopeType = "wholeTree",
  anchorPersonIds = [],
  circleId = null,
}) {
  const timestamp = nowIso();
  const normalizedBranchIds = Array.isArray(branchIds)
    ? Array.from(
        new Set(
          branchIds
            .map((value) => normalizeNullableString(value))
            .filter(Boolean),
        ),
      )
    : [];
  if (normalizedBranchIds.length === 0 && treeId) {
    normalizedBranchIds.push(treeId);
  }
  const normalizedOptions = (Array.isArray(options) ? options : [])
    .map((option) => {
      // Accept a bare string or {text} — keep any existing id.
      const text =
        typeof option === "string" ? option : String(option?.text || "");
      return {id: option?.id, text: text.trim()};
    })
    .filter((option) => option.text.length > 0)
    .map((option) => ({
      id: normalizeNullableString(option.id) || crypto.randomUUID(),
      text: option.text,
    }));
  return {
    id: crypto.randomUUID(),
    treeId,
    branchIds: normalizedBranchIds,
    authorId,
    authorName: String(authorName || "Аноним").trim() || "Аноним",
    authorPhotoUrl: normalizeNullableString(authorPhotoUrl),
    question: String(question || "").trim(),
    options: normalizedOptions,
    allowMultiple: allowMultiple === true,
    closesAt: normalizeNullableString(closesAt),
    imageUrls: Array.from(
      new Set(
        (Array.isArray(imageUrls) ? imageUrls : [])
          .map((value) => String(value || "").trim())
          .filter(Boolean),
      ),
    ),
    scopeType: scopeType === "branches" ? "branches" : "wholeTree",
    anchorPersonIds: normalizeParticipantIds(anchorPersonIds),
    circleId: normalizeNullableString(circleId),
    createdAt: timestamp,
    updatedAt: timestamp,
    responses: [], // Phase E4 votes.
  };
}

function defaultCircleId(treeId, kind) {
  return `circle:${treeId}:${kind}`;
}

const AUTO_CIRCLE_KINDS = new Set([
  "descendants_of",
  "ancestors_of",
  "pair",
]);

function normalizeCircleKind(kind) {
  const normalizedKind = String(kind || "custom").trim().toLowerCase();
  if (
    normalizedKind === "all_tree" ||
    normalizedKind === "favorites" ||
    AUTO_CIRCLE_KINDS.has(normalizedKind)
  ) {
    return normalizedKind;
  }
  return "custom";
}

function isAutoCircleKind(kind) {
  return AUTO_CIRCLE_KINDS.has(normalizeCircleKind(kind));
}

function autoCircleId({treeId, kind, anchorPersonId = null, anchorPersonIds = []}) {
  const normalizedKind = normalizeCircleKind(kind);
  if (normalizedKind === "descendants_of" || normalizedKind === "ancestors_of") {
    return `circle:${treeId}:${normalizedKind}:${normalizeNullableString(anchorPersonId)}`;
  }
  if (normalizedKind === "pair") {
    return `circle:${treeId}:pair:${buildSortedIdKey(anchorPersonIds)}`;
  }
  return defaultCircleId(treeId, normalizedKind);
}

function createCircleRecord({
  treeId,
  name,
  description = null,
  kind = "custom",
  createdBy = null,
  id = null,
  anchorPersonId = null,
  anchorPersonIds = [],
}) {
  const normalizedKind = normalizeCircleKind(kind);
  const normalizedAnchorPersonId = normalizeNullableString(anchorPersonId);
  const normalizedAnchorPersonIds = normalizeParticipantIds(anchorPersonIds);
  const timestamp = nowIso();
  return {
    id:
      normalizeNullableString(id) ||
      (normalizedKind === "custom"
        ? crypto.randomUUID()
        : autoCircleId({
            treeId,
            kind: normalizedKind,
            anchorPersonId: normalizedAnchorPersonId,
            anchorPersonIds: normalizedAnchorPersonIds,
          })),
    treeId,
    kind: normalizedKind,
    name:
      String(
        name ||
          (normalizedKind === "favorites"
            ? "Избранные"
            : normalizedKind === "all_tree"
              ? "Всё дерево"
              : "Новый круг"),
      ).trim() || "Новый круг",
    description: normalizeNullableString(description),
    createdBy: normalizeNullableString(createdBy),
    isSystem: normalizedKind !== "custom",
    anchorPersonId: normalizedAnchorPersonId,
    anchorPersonIds: normalizedAnchorPersonIds,
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function ensureDefaultCirclesForTree(db, treeOrTreeId) {
  const tree =
    typeof treeOrTreeId === "string"
      ? db.trees.find((entry) => entry.id === treeOrTreeId)
      : treeOrTreeId;
  const treeId = normalizeNullableString(tree?.id || treeOrTreeId);
  if (!treeId) {
    return {changed: false, allTreeCircle: null, favoritesCircle: null};
  }

  db.circles = Array.isArray(db.circles) ? db.circles : [];
  db.circleMembers = Array.isArray(db.circleMembers) ? db.circleMembers : [];

  let changed = false;
  let allTreeCircle = db.circles.find(
    (entry) => entry.treeId === treeId && entry.kind === "all_tree",
  );
  if (!allTreeCircle) {
    allTreeCircle = createCircleRecord({
      treeId,
      kind: "all_tree",
      name: "Всё дерево",
      createdBy: tree?.creatorId || null,
      id: defaultCircleId(treeId, "all_tree"),
    });
    db.circles.push(allTreeCircle);
    changed = true;
  }

  let favoritesCircle = db.circles.find(
    (entry) => entry.treeId === treeId && entry.kind === "favorites",
  );
  if (!favoritesCircle) {
    favoritesCircle = createCircleRecord({
      treeId,
      kind: "favorites",
      name: "Избранные",
      createdBy: tree?.creatorId || null,
      id: defaultCircleId(treeId, "favorites"),
    });
    db.circles.push(favoritesCircle);
    changed = true;
  }

  return {changed, allTreeCircle, favoritesCircle};
}

function ensureDefaultCirclesForAllTrees(db) {
  let changed = false;
  for (const tree of Array.isArray(db.trees) ? db.trees : []) {
    const result = ensureDefaultCirclesForTree(db, tree);
    changed = changed || result.changed;
  }
  return changed;
}

function normalizeCircleMemberIdentityIds(db, treeId, identityIds = []) {
  const allowedIdentityIds = new Set(
    (Array.isArray(db.persons) ? db.persons : [])
      .filter((person) => person.treeId === treeId)
      .map((person) => normalizeNullableString(person.identityId))
      .filter(Boolean),
  );
  return Array.from(
    new Set(
      (Array.isArray(identityIds) ? identityIds : [])
        .map((value) => normalizeNullableString(value))
        .filter((value) => value && allowedIdentityIds.has(value)),
    ),
  );
}

function circlePersonDisplayName(person) {
  return String(person?.name || "").trim() || "Без имени";
}

function addMapSetValue(map, key, value) {
  if (!key || !value) {
    return;
  }
  if (!map.has(key)) {
    map.set(key, new Set());
  }
  map.get(key).add(value);
}

function collectReachablePersonIds(startPersonId, adjacency) {
  const start = normalizeNullableString(startPersonId);
  if (!start) {
    return new Set();
  }

  const result = new Set([start]);
  const queue = [start];
  while (queue.length > 0) {
    const current = queue.shift();
    for (const next of adjacency.get(current) || []) {
      if (result.has(next)) {
        continue;
      }
      result.add(next);
      queue.push(next);
    }
  }
  return result;
}

// Авто-кругам от бэкфилла идентичностей нужно одно: identityId у людей ЭТОГО
// дерева (membership кругов считается по person.identityId). Сам
// backfillPersonIdentities хэширует ВСЕ persons+identities базы (stableSerialize
// + sha256, дважды) — вызываемый на каждое дерево из ensureCirclesForAllTrees
// он давал 77% CPU GET /posts при неизменных данных. Поэтому зовём его только
// когда у дерева реально есть человек без идентичности.
function treeHasPersonsWithoutIdentity(db, treeId) {
  return (Array.isArray(db.persons) ? db.persons : []).some(
    (person) =>
      person.treeId === treeId && !normalizeNullableString(person.identityId),
  );
}

function identityIdsForPersonIds(db, treeId, personIds) {
  const personsById = new Map(
    (Array.isArray(db.persons) ? db.persons : [])
      .filter((person) => person.treeId === treeId)
      .map((person) => [person.id, person]),
  );
  const identityIds = normalizeParticipantIds(personIds)
    .map((personId) => normalizeNullableString(personsById.get(personId)?.identityId))
    .filter(Boolean);
  return normalizeCircleMemberIdentityIds(db, treeId, identityIds);
}

function buildAutoCircleSpec({
  db,
  treeId,
  kind,
  name,
  description,
  personIds,
  anchorPersonId = null,
  anchorPersonIds = [],
  createdBy = null,
}) {
  const normalizedKind = normalizeCircleKind(kind);
  const normalizedPersonIds = normalizeParticipantIds(personIds);
  if (!isAutoCircleKind(normalizedKind) || normalizedPersonIds.length < 2) {
    return null;
  }

  const normalizedAnchorPersonId = normalizeNullableString(anchorPersonId);
  const normalizedAnchorPersonIds = normalizeParticipantIds(anchorPersonIds);
  const id = autoCircleId({
    treeId,
    kind: normalizedKind,
    anchorPersonId: normalizedAnchorPersonId,
    anchorPersonIds: normalizedAnchorPersonIds,
  });
  const identityIds = identityIdsForPersonIds(db, treeId, normalizedPersonIds);
  if (identityIds.length === 0) {
    return null;
  }

  return {
    id,
    treeId,
    kind: normalizedKind,
    name,
    description,
    personIds: normalizedPersonIds,
    identityIds,
    anchorPersonId: normalizedAnchorPersonId,
    anchorPersonIds: normalizedAnchorPersonIds,
    createdBy,
  };
}

function buildAutoCircleSpecsForTree(db, tree) {
  const treeId = normalizeNullableString(tree?.id || tree);
  if (!treeId) {
    return new Map();
  }

  const persons = (Array.isArray(db.persons) ? db.persons : []).filter(
    (person) => person.treeId === treeId,
  );
  const personsById = new Map(persons.map((person) => [person.id, person]));
  const treeRelations = (Array.isArray(db.relations) ? db.relations : []).filter(
    (relation) => relation.treeId === treeId,
  );
  const childrenByParentId = new Map();
  const parentsByChildId = new Map();

  for (const relation of treeRelations) {
    const parentId = parentIdFromRelation(relation);
    const childId = childIdFromRelation(relation);
    if (!personsById.has(parentId) || !personsById.has(childId)) {
      continue;
    }
    addMapSetValue(childrenByParentId, parentId, childId);
    addMapSetValue(parentsByChildId, childId, parentId);
  }

  const specs = new Map();
  const addSpec = (spec) => {
    if (spec) {
      specs.set(spec.id, spec);
    }
  };

  for (const person of persons) {
    const descendants = collectReachablePersonIds(person.id, childrenByParentId);
    if (descendants.size > 1) {
      addSpec(
        buildAutoCircleSpec({
          db,
          treeId,
          kind: "descendants_of",
          name: `Ветка: ${circlePersonDisplayName(person)}`,
          description: "Автоматически: человек и его потомки",
          personIds: Array.from(descendants),
          anchorPersonId: person.id,
          createdBy: tree.creatorId || null,
        }),
      );
    }

    const ancestors = collectReachablePersonIds(person.id, parentsByChildId);
    if (ancestors.size > 1) {
      addSpec(
        buildAutoCircleSpec({
          db,
          treeId,
          kind: "ancestors_of",
          name: `Предки: ${circlePersonDisplayName(person)}`,
          description: "Автоматически: человек и его предки",
          personIds: Array.from(ancestors),
          anchorPersonId: person.id,
          createdBy: tree.creatorId || null,
        }),
      );
    }
  }

  for (const relation of treeRelations) {
    if (!isSpouseLikeRelation(relation)) {
      continue;
    }
    const left = personsById.get(relation.person1Id);
    const right = personsById.get(relation.person2Id);
    if (!left || !right) {
      continue;
    }

    const pairPersonIds = new Set([left.id, right.id]);
    for (const candidate of treeRelations) {
      const parentId = parentIdFromRelation(candidate);
      const childId = childIdFromRelation(candidate);
      if (pairPersonIds.has(parentId) && personsById.has(childId)) {
        pairPersonIds.add(childId);
      }
    }

    const anchorPersonIds = normalizeParticipantIds([left.id, right.id]);
    addSpec(
      buildAutoCircleSpec({
        db,
        treeId,
        kind: "pair",
        name: `${circlePersonDisplayName(left)} + ${circlePersonDisplayName(right)}`,
        description: "Автоматически: пара и дети",
        personIds: Array.from(pairPersonIds),
        anchorPersonIds,
        createdBy: tree.creatorId || null,
      }),
    );
  }

  return specs;
}

function ensureAutoCirclesForTree(db, treeOrTreeId) {
  const tree =
    typeof treeOrTreeId === "string"
      ? db.trees.find((entry) => entry.id === treeOrTreeId)
      : treeOrTreeId;
  const treeId = normalizeNullableString(tree?.id || treeOrTreeId);
  if (!treeId) {
    return {changed: false};
  }

  db.circles = Array.isArray(db.circles) ? db.circles : [];
  db.circleMembers = Array.isArray(db.circleMembers) ? db.circleMembers : [];
  let changed = treeHasPersonsWithoutIdentity(db, treeId)
    ? backfillPersonIdentities(db).changed
    : false;
  const specs = buildAutoCircleSpecsForTree(db, tree);
  const desiredIds = new Set(specs.keys());
  const removedCircleIds = new Set();

  db.circles = db.circles.filter((circle) => {
    if (circle.treeId !== treeId || !isAutoCircleKind(circle.kind)) {
      return true;
    }
    if (desiredIds.has(circle.id)) {
      return true;
    }
    removedCircleIds.add(circle.id);
    changed = true;
    return false;
  });

  if (removedCircleIds.size > 0) {
    db.circleMembers = db.circleMembers.filter(
      (entry) =>
        entry.treeId !== treeId || !removedCircleIds.has(entry.circleId),
    );
  }

  for (const spec of specs.values()) {
    let circle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === spec.id,
    );
    if (!circle) {
      circle = createCircleRecord({
        treeId,
        kind: spec.kind,
        name: spec.name,
        description: spec.description,
        createdBy: spec.createdBy,
        id: spec.id,
        anchorPersonId: spec.anchorPersonId,
        anchorPersonIds: spec.anchorPersonIds,
      });
      db.circles.push(circle);
      changed = true;
    } else {
      const timestamp = nowIso();
      const updates = {
        kind: spec.kind,
        name: spec.name,
        description: normalizeNullableString(spec.description),
        createdBy: normalizeNullableString(circle.createdBy || spec.createdBy),
        isSystem: true,
        anchorPersonId: normalizeNullableString(spec.anchorPersonId),
      };
      for (const [key, value] of Object.entries(updates)) {
        if (circle[key] !== value) {
          circle[key] = value;
          changed = true;
          circle.updatedAt = timestamp;
        }
      }
      if (!sameNormalizedIds(circle.anchorPersonIds, spec.anchorPersonIds)) {
        circle.anchorPersonIds = normalizeParticipantIds(spec.anchorPersonIds);
        circle.updatedAt = timestamp;
        changed = true;
      }
    }

    const currentIdentityIds = db.circleMembers
      .filter((entry) => entry.treeId === treeId && entry.circleId === spec.id)
      .map((entry) => normalizeNullableString(entry.identityId))
      .filter(Boolean);
    if (!sameNormalizedIds(currentIdentityIds, spec.identityIds)) {
      const timestamp = nowIso();
      db.circleMembers = db.circleMembers.filter(
        (entry) => !(entry.treeId === treeId && entry.circleId === spec.id),
      );
      for (const identityId of spec.identityIds) {
        db.circleMembers.push({
          id: crypto.randomUUID(),
          treeId,
          circleId: spec.id,
          identityId,
          createdAt: timestamp,
          updatedAt: timestamp,
        });
      }
      circle.updatedAt = timestamp;
      changed = true;
    }
  }

  return {changed};
}

function ensureCirclesForTree(db, treeOrTreeId) {
  const defaults = ensureDefaultCirclesForTree(db, treeOrTreeId);
  const autoCircles = ensureAutoCirclesForTree(db, treeOrTreeId);
  return {
    ...defaults,
    changed: defaults.changed || autoCircles.changed,
  };
}

function ensureCirclesForAllTrees(db) {
  let changed = false;
  for (const tree of Array.isArray(db.trees) ? db.trees : []) {
    const result = ensureCirclesForTree(db, tree);
    changed = changed || result.changed;
  }
  return changed;
}

function normalizeStoryType(type) {
  const normalizedType = String(type || "text").trim().toLowerCase();
  if (normalizedType === "image" || normalizedType === "video") {
    return normalizedType;
  }
  return "text";
}

function createStoryRecord({
  treeId,
  authorId,
  authorName,
  authorPhotoUrl = null,
  type = "text",
  text = null,
  mediaUrl = null,
  thumbnailUrl = null,
  expiresAt = null,
  circleId = null,
  scopeType = "wholeTree",
  anchorPersonIds = [],
}) {
  const createdAt = nowIso();
  const normalizedExpiresAt =
    normalizeOptionalIsoTimestamp(expiresAt) ||
    new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const normalizedScope =
    String(scopeType || "wholeTree").trim() === "branches"
      ? "branches"
      : "wholeTree";
  const normalizedAnchorIds = Array.isArray(anchorPersonIds)
    ? anchorPersonIds
        .map((id) => String(id || "").trim())
        .filter(Boolean)
    : [];
  return {
    id: crypto.randomUUID(),
    treeId,
    authorId,
    authorName: String(authorName || "Аноним").trim() || "Аноним",
    authorPhotoUrl: normalizeNullableString(authorPhotoUrl),
    type: normalizeStoryType(type),
    text: normalizeNullableString(text),
    mediaUrl: normalizeNullableString(mediaUrl),
    thumbnailUrl: normalizeNullableString(thumbnailUrl),
    circleId: normalizeNullableString(circleId),
    scopeType: normalizedScope,
    anchorPersonIds: normalizedAnchorIds,
    createdAt,
    updatedAt: createdAt,
    expiresAt: normalizedExpiresAt,
    viewedBy: [],
  };
}

function createCommentRecord({
  postId,
  authorId,
  authorName,
  authorPhotoUrl = null,
  content,
  parentCommentId = null,
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    postId,
    authorId,
    authorName: String(authorName || "Аноним").trim() || "Аноним",
    authorPhotoUrl: normalizeNullableString(authorPhotoUrl),
    content: String(content || "").trim(),
    createdAt: timestamp,
    updatedAt: timestamp,
    likedBy: [],
    // Two-level threading: top-level comments have parentCommentId === null,
    // replies carry the id of the top-level comment they belong to. We keep
    // the model flat (no replies-to-replies) so the UI never needs more than
    // one indent level — same model Twitter / Instagram converged on.
    parentCommentId: parentCommentId
      ? String(parentCommentId).trim() || null
      : null,
  };
}

function createPushDeviceRecord({
  userId,
  provider,
  token,
  platform = "unknown",
  sessionPublicId = null,
  instanceId = null,
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    userId,
    provider: String(provider || "unknown").trim(),
    token: String(token || "").trim(),
    platform: String(platform || "unknown").trim(),
    sessionPublicId: normalizeOptionalString(sessionPublicId, 32),
    instanceId: normalizeOptionalString(instanceId, 80),
    createdAt: timestamp,
    updatedAt: timestamp,
    lastSeenAt: timestamp,
  };
}

/// SPEED-7: вычислимый ключ коалесинга уведомления. Единая точка правды
/// для обоих сторов: FileStore схлопывает по нему в массиве, PostgresStore —
/// SELECT'ом по колонке coalesce_key (индекс user_id+coalesce_key), той же
/// функцией ключ заполняется при INSERT и в бут-миграции. Пустая строка =
/// тип без коалесинга. Сравнение полей — через строкование (id всегда
/// строки-uuid; прежние строгие === для них эквивалентны).
function encodeNotificationCursor(createdAt, id) {
  return Buffer.from(`${createdAt}|${id}`, "utf8").toString("base64url");
}

function decodeNotificationCursor(rawCursor) {
  const normalized = String(rawCursor || "").trim();
  if (!normalized) return null;
  try {
    const decoded = Buffer.from(normalized, "base64url").toString("utf8");
    const separatorIndex = decoded.lastIndexOf("|");
    if (separatorIndex <= 0) return null;
    return {
      createdAt: decoded.slice(0, separatorIndex),
      id: decoded.slice(separatorIndex + 1),
    };
  } catch (_) {
    return null;
  }
}

function computeNotificationCoalesceKey(notification) {
  const record = notification || {};
  const type = String(record.type || "").trim();
  const data = record.data && typeof record.data === "object" ? record.data : {};
  const part = (value) => String(value ?? "").trim();
  switch (type) {
    case "story_reaction":
      return `${type}|${part(data.storyId)}|${part(data.actorUserId)}`;
    case "post_reaction":
      return `${type}|${part(data.postId)}|${part(data.actorUserId)}`;
    case "comment_reaction":
      return `${type}|${part(data.commentId)}|${part(data.actorUserId)}`;
    case "comment_reply":
      return `${type}|${part(data.parentCommentId)}|${part(data.actorUserId)}`;
    case "merge_proposal":
    case "identity_claim":
      return `${type}|${part(data.proposalId)}|${part(data.claimId)}`;
    default:
      return "";
  }
}

/// SPEED-7: «план» коалесцирующего уведомления — guard'ы, ключ и оба
/// исхода (бамп существующей unread-записи / создание новой) описаны
/// ДАННЫМИ, чтобы массивная (FileStore) и табличная (PostgresStore)
/// реализации _applyNotificationCoalescePlan не дублировали тексты.
function buildStoryReactionNotificationPlan({
  storyId,
  storyAuthorId,
  actorUserId,
  actorName,
  emoji,
  storySnippet,
}) {
  if (
    !storyAuthorId ||
    !actorUserId ||
    String(storyAuthorId).trim() === String(actorUserId).trim()
  ) {
    return null;
  }
  return {
    userId: storyAuthorId,
    type: "story_reaction",
    keyData: {storyId, actorUserId},
    patchExisting(existing) {
      existing.data = {...existing.data, emoji};
      existing.body = `${actorName || "Кто-то"} отреагировал ${emoji}`;
    },
    buildRecord() {
      return createNotificationRecord({
        userId: storyAuthorId,
        type: "story_reaction",
        title: actorName
          ? `${actorName} отреагировал ${emoji}`
          : `Реакция ${emoji} на историю`,
        body: storySnippet || "",
        data: {storyId, actorUserId, emoji},
      });
    },
  };
}

function buildPostReactionNotificationPlan({
  postId,
  postAuthorId,
  actorUserId,
  actorName,
  emoji,
  postSnippet,
}) {
  if (
    !postAuthorId ||
    !actorUserId ||
    String(postAuthorId).trim() === String(actorUserId).trim()
  ) {
    return null;
  }
  return {
    userId: postAuthorId,
    type: "post_reaction",
    keyData: {postId, actorUserId},
    patchExisting(existing) {
      existing.data = {...existing.data, emoji};
      existing.body = `${actorName || "Кто-то"} отреагировал ${emoji}`;
    },
    buildRecord() {
      return createNotificationRecord({
        userId: postAuthorId,
        type: "post_reaction",
        title: actorName
          ? `${actorName} отреагировал ${emoji}`
          : `Новая реакция ${emoji}`,
        body: postSnippet || "",
        data: {postId, actorUserId, emoji},
      });
    },
  };
}

function buildCommentReactionNotificationPlan({
  postId,
  commentId,
  commentAuthorId,
  actorUserId,
  actorName,
  emoji,
  commentSnippet,
}) {
  if (
    !commentAuthorId ||
    !actorUserId ||
    String(commentAuthorId).trim() === String(actorUserId).trim()
  ) {
    return null;
  }
  return {
    userId: commentAuthorId,
    type: "comment_reaction",
    keyData: {commentId, actorUserId},
    patchExisting(existing) {
      existing.data = {...existing.data, emoji};
      existing.body = `${actorName || "Кто-то"} отреагировал ${emoji}`;
    },
    buildRecord() {
      return createNotificationRecord({
        userId: commentAuthorId,
        type: "comment_reaction",
        title: actorName
          ? `${actorName} отреагировал ${emoji}`
          : `Новая реакция ${emoji}`,
        body: commentSnippet || "",
        data: {postId, commentId, actorUserId, emoji},
      });
    },
  };
}

function buildCommentReplyNotificationPlan({
  postId,
  parentCommentId,
  parentCommentAuthorId,
  replyCommentId,
  actorUserId,
  actorName,
  replySnippet,
}) {
  if (
    !parentCommentAuthorId ||
    !actorUserId ||
    String(parentCommentAuthorId).trim() === String(actorUserId).trim()
  ) {
    return null;
  }
  const trimmedSnippet = String(replySnippet || "").trim();
  return {
    userId: parentCommentAuthorId,
    type: "comment_reply",
    keyData: {parentCommentId, actorUserId},
    patchExisting(existing) {
      existing.data = {...existing.data, replyCommentId};
      existing.body = trimmedSnippet || existing.body || "";
    },
    buildRecord() {
      return createNotificationRecord({
        userId: parentCommentAuthorId,
        type: "comment_reply",
        title: actorName
          ? `${actorName} ответил на ваш комментарий`
          : "Новый ответ на комментарий",
        body: trimmedSnippet,
        data: {postId, parentCommentId, replyCommentId, actorUserId},
      });
    },
  };
}

function createPushDeliveryRecord({
  notificationId,
  userId,
  deviceId,
  provider,
  status = "queued",
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    notificationId,
    userId,
    deviceId,
    provider: String(provider || "unknown").trim(),
    status: String(status || "queued").trim(),
    createdAt: timestamp,
    updatedAt: timestamp,
    deliveredAt: null,
    lastError: null,
    responseCode: null,
  };
}

function createReportRecord({
  reporterId,
  targetType,
  targetId,
  reason,
  details = null,
  metadata = {},
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    reporterId,
    targetType: String(targetType || "").trim(),
    targetId: String(targetId || "").trim(),
    reason: String(reason || "other").trim() || "other",
    details: normalizeNullableString(details),
    metadata: metadata && typeof metadata === "object" ? structuredClone(metadata) : {},
    status: "pending",
    resolutionNote: null,
    resolvedAt: null,
    resolvedBy: null,
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function createBlockRecord({
  blockerId,
  blockedUserId,
  reason = null,
  metadata = {},
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    blockerId,
    blockedUserId,
    reason: normalizeNullableString(reason),
    metadata: metadata && typeof metadata === "object" ? structuredClone(metadata) : {},
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function normalizeParticipantIds(participantIds) {
  return Array.from(
    new Set(
      (Array.isArray(participantIds) ? participantIds : [])
        .map((value) => String(value || "").trim())
        .filter(Boolean),
    ),
  ).sort((left, right) => left.localeCompare(right));
}

function deriveSessionPublicId(token, instanceId = "") {
  const normalizedToken = String(token || "").trim();
  if (!normalizedToken) {
    return "";
  }
  const normalizedInstanceId = String(instanceId || "").trim();
  const hasher = crypto.createHash("sha256").update(normalizedToken);
  if (normalizedInstanceId) {
    hasher.update(":");
    hasher.update(normalizedInstanceId);
  }
  return hasher.digest("base64url").slice(0, 22);
}

function normalizeOptionalString(value, maxLength = 80) {
  const normalized = String(value ?? "").trim();
  if (!normalized) {
    return null;
  }
  if (Number.isFinite(maxLength) && maxLength > 0 && normalized.length > maxLength) {
    return normalized.slice(0, maxLength);
  }
  return normalized;
}

function normalizeSessionDeviceContext(context = {}) {
  const source = context && typeof context === "object" ? context : {};
  return {
    instanceId: normalizeOptionalString(source.instanceId, 80),
    deviceName: normalizeOptionalString(source.deviceName, 80),
    platform: normalizeOptionalString(source.platform, 40),
    // Additive alongside platform/appVersion — old sessions/clients simply
    // lack it, callers already treat every field here as nullable.
    osVersion: normalizeOptionalString(source.osVersion, 40),
    appVersion: normalizeOptionalString(source.appVersion, 40),
  };
}

function buildCallParticipantIdentity(userId, sessionPublicId) {
  const normalizedUserId = String(userId || "").trim();
  const normalizedSessionId = String(sessionPublicId || "").trim();
  if (!normalizedUserId) {
    return "";
  }
  if (!normalizedSessionId) {
    return normalizedUserId;
  }
  return `${normalizedUserId}#${normalizedSessionId}`;
}

function normalizeChatMessageCall(value) {
  if (!value || typeof value !== "object") {
    return null;
  }
  const callId = String(value.callId || "").trim();
  if (!callId) {
    return null;
  }
  const allowedStates = new Set([
    "ringing",
    "active",
    "ended",
    "rejected",
    "cancelled",
    "missed",
    "failed",
  ]);
  const rawState = String(value.state || "").trim().toLowerCase();
  const state = allowedStates.has(rawState) ? rawState : "ended";
  const mediaModeRaw = String(value.mediaMode || "").trim().toLowerCase();
  const mediaMode = mediaModeRaw === "video" ? "video" : "audio";
  const durationCandidate = Number(value.durationMs);
  const durationMs = Number.isFinite(durationCandidate) && durationCandidate > 0
    ? Math.floor(durationCandidate)
    : null;
  const initiatorId = String(value.initiatorId || "").trim() || null;
  const direction = value.direction === "incoming" ? "incoming" : "outgoing";
  return {
    callId,
    state,
    mediaMode,
    durationMs,
    initiatorId,
    direction,
  };
}

function parseCallParticipantIdentity(identity) {
  const normalized = String(identity || "").trim();
  if (!normalized) {
    return {userId: "", sessionPublicId: ""};
  }
  const hashIndex = normalized.indexOf("#");
  if (hashIndex < 0) {
    return {userId: normalized, sessionPublicId: ""};
  }
  return {
    userId: normalized.slice(0, hashIndex),
    sessionPublicId: normalized.slice(hashIndex + 1),
  };
}

function collectMediaUrl(urlSet, value) {
  const normalizedValue = String(value || "").trim();
  if (normalizedValue) {
    urlSet.add(normalizedValue);
  }
}

function collectMessageMediaUrls(urlSet, message) {
  const attachments = normalizeMessageAttachments(message);
  for (const attachment of attachments) {
    collectMediaUrl(urlSet, attachment?.url);
    collectMediaUrl(urlSet, attachment?.thumbnailUrl);
  }

  if (Array.isArray(message?.mediaUrls)) {
    for (const mediaUrl of message.mediaUrls) {
      collectMediaUrl(urlSet, mediaUrl);
    }
  }

  collectMediaUrl(urlSet, message?.imageUrl);
}

function collectOwnedMediaUrlsForUser(db, userId) {
  const ownedMediaUrls = new Set();
  const user = db.users.find((entry) => entry.id === userId);
  collectMediaUrl(ownedMediaUrls, user?.profile?.photoUrl);

  for (const person of db.persons) {
    if (person.userId === userId) {
      collectMediaUrl(ownedMediaUrls, person.photoUrl);
      collectMediaUrl(ownedMediaUrls, person.primaryPhotoUrl);
      if (Array.isArray(person.photoGallery)) {
        for (const mediaEntry of person.photoGallery) {
          collectMediaUrl(ownedMediaUrls, mediaEntry?.url);
          collectMediaUrl(ownedMediaUrls, mediaEntry?.thumbnailUrl);
        }
      }
    }
  }

  for (const post of db.posts) {
    if (post.authorId !== userId) {
      continue;
    }
    collectMediaUrl(ownedMediaUrls, post.authorPhotoUrl);
    if (Array.isArray(post.imageUrls)) {
      for (const imageUrl of post.imageUrls) {
        collectMediaUrl(ownedMediaUrls, imageUrl);
      }
    }
  }

  for (const story of db.stories) {
    if (story.authorId !== userId) {
      continue;
    }
    collectMediaUrl(ownedMediaUrls, story.authorPhotoUrl);
    collectMediaUrl(ownedMediaUrls, story.mediaUrl);
    collectMediaUrl(ownedMediaUrls, story.thumbnailUrl);
  }

  for (const comment of db.comments) {
    if (comment.authorId === userId) {
      collectMediaUrl(ownedMediaUrls, comment.authorPhotoUrl);
    }
  }

  for (const message of db.messages) {
    if (message.senderId === userId) {
      collectMessageMediaUrls(ownedMediaUrls, message);
    }
  }

  return Array.from(ownedMediaUrls);
}

function createChatRecord({
  id = null,
  type = "direct",
  participantIds = [],
  title = null,
  photoUrl = null,
  createdBy = null,
  treeId = null,
  branchRootPersonIds = [],
}) {
  const timestamp = nowIso();
  return {
    id: id || crypto.randomUUID(),
    type: String(type || "direct").trim() || "direct",
    participantIds: normalizeParticipantIds(participantIds),
    title: normalizeNullableString(title),
    photoUrl: normalizeNullableString(photoUrl),
    createdBy: normalizeNullableString(createdBy),
    treeId: normalizeNullableString(treeId),
    branchRootPersonIds: normalizeParticipantIds(branchRootPersonIds),
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function parseDirectParticipantsFromChatId(chatId) {
  const participants = String(chatId || "")
    .split("_")
    .map((value) => value.trim())
    .filter(Boolean);

  return participants.length === 2 ? normalizeParticipantIds(participants) : [];
}

function normalizeCallMediaMode(value) {
  return String(value || "").trim().toLowerCase() === "video"
    ? "video"
    : "audio";
}

function normalizeCallState(value) {
  const normalizedState = String(value || "").trim().toLowerCase();
  switch (normalizedState) {
    case "ringing":
    case "active":
    case "rejected":
    case "cancelled":
    case "ended":
    case "missed":
    case "failed":
      return normalizedState;
    default:
      return "ringing";
  }
}

function isCallTerminalState(state) {
  return (
    state === "rejected" ||
    state === "cancelled" ||
    state === "ended" ||
    state === "missed" ||
    state === "failed"
  );
}

function isCallBusyState(state) {
  return state === "ringing" || state === "active";
}

function normalizeCallSession(session) {
  if (!session || typeof session !== "object") {
    return null;
  }

  const roomName = String(session.roomName || "").trim();
  const url = String(session.url || "").trim();
  const token = String(session.token || "").trim();
  const participantIdentity = String(session.participantIdentity || "").trim();
  if (!roomName || !url || !token || !participantIdentity) {
    return null;
  }

  return {
    roomName,
    url,
    token,
    participantIdentity,
    participantName: normalizeNullableString(session.participantName),
    createdAt: normalizeOptionalIsoTimestamp(session.createdAt) || nowIso(),
  };
}

function normalizeCallSessionMap(value) {
  if (!value || typeof value !== "object") {
    return {};
  }

  return Object.entries(value).reduce((accumulator, [userId, session]) => {
    const normalizedUserId = String(userId || "").trim();
    const normalizedSession = normalizeCallSession(session);
    if (normalizedUserId && normalizedSession) {
      accumulator[normalizedUserId] = normalizedSession;
    }
    return accumulator;
  }, {});
}

// Group late-join: who has joined the call and on which device session, as
// {userId -> sessionPublicId}. Replaces the scalar acceptedBy* (which only
// ever tracked the FIRST accepter); the scalars are kept filled by the first
// joiner for back-compat with in-flight records and old clients.
function normalizeJoinedSessionMap(value) {
  if (!value || typeof value !== "object") {
    return {};
  }

  return Object.entries(value).reduce((accumulator, [userId, sessionId]) => {
    const normalizedUserId = String(userId || "").trim();
    const normalizedSessionId = normalizeNullableString(sessionId);
    if (normalizedUserId && normalizedSessionId) {
      accumulator[normalizedUserId] = normalizedSessionId;
    }
    return accumulator;
  }, {});
}

function normalizeNonNegativeInteger(value, fallback = 0) {
  const normalizedFallback =
    Number.isFinite(Number(fallback)) && Number(fallback) >= 0
      ? Math.floor(Number(fallback))
      : 0;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return normalizedFallback;
  }
  return Math.floor(parsed);
}

function normalizeNullableDurationMs(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return null;
  }
  return Math.floor(parsed);
}

function normalizeCallMetrics(value) {
  const source = value && typeof value === "object" ? value : {};
  return {
    acceptLatencyMs: normalizeNullableDurationMs(source.acceptLatencyMs),
    roomJoinFailureCount: normalizeNonNegativeInteger(
      source.roomJoinFailureCount,
    ),
    reconnectCount: normalizeNonNegativeInteger(source.reconnectCount),
    connectedParticipantIds: normalizeParticipantIds(
      source.connectedParticipantIds,
    ),
    lastRoomJoinFailureReason: normalizeNullableString(
      source.lastRoomJoinFailureReason,
    ),
    lastWebhookEvent: normalizeNullableString(source.lastWebhookEvent),
  };
}

function createCallRecord({
  chatId,
  initiatorId,
  recipientId,
  participantIds = null,
  mediaMode,
  originatedBySessionId = null,
}) {
  const timestamp = nowIso();
  const normalizedParticipantIds = normalizeParticipantIds(
    participantIds || [initiatorId, recipientId],
  );
  const normalizedRecipientId =
    normalizeNullableString(recipientId) ||
    normalizedParticipantIds.find((participantId) => participantId !== initiatorId) ||
    "";
  return {
    id: `call_${crypto.randomUUID()}`,
    chatId,
    initiatorId,
    recipientId: normalizedRecipientId,
    participantIds: normalizedParticipantIds,
    mediaMode: normalizeCallMediaMode(mediaMode),
    state: "ringing",
    roomName: null,
    sessionByUserId: {},
    joinedSessionByUserId: {},
    originatedBySessionId: normalizeNullableString(originatedBySessionId),
    acceptedByUserId: null,
    acceptedBySessionId: null,
    createdAt: timestamp,
    updatedAt: timestamp,
    acceptedAt: null,
    endedAt: null,
    endedReason: null,
    metrics: normalizeCallMetrics(null),
  };
}

function normalizeStoredCall(call) {
  if (!call || typeof call !== "object") {
    return null;
  }

  const initiatorId = String(call.initiatorId || "").trim();
  const recipientId = String(call.recipientId || "").trim();
  const chatId = String(call.chatId || "").trim();
  if (!initiatorId || !recipientId || !chatId) {
    return null;
  }

  return {
    id: String(call.id || `call_${crypto.randomUUID()}`),
    chatId,
    initiatorId,
    recipientId,
    participantIds: normalizeParticipantIds(
      call.participantIds || [initiatorId, recipientId],
    ),
    mediaMode: normalizeCallMediaMode(call.mediaMode),
    state: normalizeCallState(call.state),
    roomName: normalizeNullableString(call.roomName),
    sessionByUserId: normalizeCallSessionMap(call.sessionByUserId),
    joinedSessionByUserId: normalizeJoinedSessionMap(call.joinedSessionByUserId),
    originatedBySessionId: normalizeNullableString(call.originatedBySessionId),
    acceptedByUserId: normalizeNullableString(call.acceptedByUserId),
    acceptedBySessionId: normalizeNullableString(call.acceptedBySessionId),
    createdAt: normalizeOptionalIsoTimestamp(call.createdAt) || nowIso(),
    updatedAt: normalizeOptionalIsoTimestamp(call.updatedAt) || nowIso(),
    acceptedAt: normalizeOptionalIsoTimestamp(call.acceptedAt),
    endedAt: normalizeOptionalIsoTimestamp(call.endedAt),
    endedReason: normalizeNullableString(call.endedReason),
    metrics: normalizeCallMetrics(call.metrics),
  };
}

function sameNormalizedIds(left, right) {
  const normalizedLeft = normalizeParticipantIds(left);
  const normalizedRight = normalizeParticipantIds(right);
  if (normalizedLeft.length !== normalizedRight.length) {
    return false;
  }

  return normalizedLeft.every((value, index) => value === normalizedRight[index]);
}

function isSpouseLikeRelation(relation) {
  return (
    relation?.relation1to2 === "spouse" ||
    relation?.relation2to1 === "spouse" ||
    relation?.relation1to2 === "partner" ||
    relation?.relation2to1 === "partner"
  );
}

function parentIdFromRelation(relation) {
  if (
    relation?.relation1to2 === "parent" ||
    relation?.relation2to1 === "child"
  ) {
    return relation.person1Id;
  }
  if (
    relation?.relation2to1 === "parent" ||
    relation?.relation1to2 === "child"
  ) {
    return relation.person2Id;
  }
  return null;
}

function childIdFromRelation(relation) {
  if (
    relation?.relation1to2 === "parent" ||
    relation?.relation2to1 === "child"
  ) {
    return relation.person2Id;
  }
  if (
    relation?.relation2to1 === "parent" ||
    relation?.relation1to2 === "child"
  ) {
    return relation.person1Id;
  }
  return null;
}

const PARENT_SET_TYPES = new Set([
  "biological",
  "adoptive",
  "foster",
  "guardian",
  "step",
  "unknown",
]);

const BLOOD_PARENT_SET_TYPES = new Set(["biological", "unknown"]);

const UNION_TYPES = new Set([
  "spouse",
  "partner",
  "friend",
  "single",
  "other",
]);

const UNION_STATUSES = new Set(["current", "past", "ended_by_death"]);

function buildSortedIdKey(values) {
  return (Array.isArray(values) ? values : [])
    .map((value) => String(value || "").trim())
    .filter(Boolean)
    .sort((left, right) => left.localeCompare(right))
    .join(":");
}

function extractSurnameFromName(name) {
  const parts = String(name || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  if (parts.length === 0) {
    return null;
  }
  return parts[0];
}

function normalizeParentSetType(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return PARENT_SET_TYPES.has(normalized) ? normalized : "biological";
}

function isBloodParentSetType(value) {
  return BLOOD_PARENT_SET_TYPES.has(normalizeParentSetType(value));
}

function normalizeUnionType(value, {relationType = null} = {}) {
  const normalized = String(value || "").trim().toLowerCase();
  if (UNION_TYPES.has(normalized)) {
    return normalized;
  }

  const normalizedRelationType = String(relationType || "")
    .trim()
    .toLowerCase();
  if (normalizedRelationType === "spouse" || normalizedRelationType === "ex_spouse") {
    return "spouse";
  }
  if (normalizedRelationType === "partner" || normalizedRelationType === "ex_partner") {
    return "partner";
  }
  if (normalizedRelationType === "friend") {
    return "friend";
  }

  return "other";
}

function normalizeUnionStatus(value, {relationType = null, divorceDate = null} = {}) {
  const normalized = String(value || "").trim().toLowerCase();
  if (UNION_STATUSES.has(normalized)) {
    return normalized;
  }

  const normalizedRelationType = String(relationType || "")
    .trim()
    .toLowerCase();
  if (
    normalizedRelationType === "ex_spouse" ||
    normalizedRelationType === "ex_partner" ||
    normalizeOptionalIsoTimestamp(divorceDate)
  ) {
    return "past";
  }

  return "current";
}

function relationTypeForPerson(relation, personId) {
  const normalizedPersonId = String(personId || "").trim();
  if (!normalizedPersonId) {
    return null;
  }
  if (String(relation?.person1Id || "").trim() === normalizedPersonId) {
    return String(relation?.relation1to2 || "").trim() || null;
  }
  if (String(relation?.person2Id || "").trim() === normalizedPersonId) {
    return String(relation?.relation2to1 || "").trim() || null;
  }
  return null;
}

function relationCustomLabelForPerson(relation, personId) {
  const normalizedPersonId = String(personId || "").trim();
  if (!normalizedPersonId) {
    return null;
  }
  if (String(relation?.person1Id || "").trim() === normalizedPersonId) {
    return normalizeNullableString(relation?.customRelationLabel1to2);
  }
  if (String(relation?.person2Id || "").trim() === normalizedPersonId) {
    return normalizeNullableString(relation?.customRelationLabel2to1);
  }
  return null;
}

function isUnionRelationType(relationType) {
  switch (String(relationType || "").trim().toLowerCase()) {
    case "spouse":
    case "partner":
    case "friend":
    case "ex_spouse":
    case "ex_partner":
      return true;
    default:
      return false;
  }
}

function isUnionRelation(relation) {
  return (
    isUnionRelationType(relation?.relation1to2) ||
    isUnionRelationType(relation?.relation2to1)
  );
}

function isBloodDirectRelationType(relationType, parentSetType = null) {
  switch (String(relationType || "").trim().toLowerCase()) {
    case "parent":
    case "child":
      return isBloodParentSetType(parentSetType);
    case "sibling":
    case "cousin":
    case "uncle":
    case "aunt":
    case "nephew":
    case "niece":
    case "nibling":
    case "grandparent":
    case "grandchild":
    case "greatgrandparent":
    case "greatgrandchild":
      return true;
    default:
      return false;
  }
}

function isCurrentUnionRelation(relation) {
  if (!isUnionRelation(relation)) {
    return false;
  }
  return normalizeUnionStatus(relation?.unionStatus, {
    relationType: relation?.relation1to2 || relation?.relation2to1,
    divorceDate: relation?.divorceDate,
  }) === "current";
}

function buildLinkedPersonCanonicalPatchFromProfile(profile = {}) {
  const displayName = composeDisplayNameFromProfile(profile);
  const photoState = normalizePersonPhotoGallery([], {
    photoUrl: profile.photoUrl,
    primaryPhotoUrl: profile.photoUrl,
  });

  return {
    name: displayName || null,
    maidenName: normalizeNullableString(profile.maidenName),
    photoUrl: photoState.photoUrl,
    primaryPhotoUrl: photoState.primaryPhotoUrl,
    gender: String(profile.gender || "unknown").trim() || "unknown",
    birthDate: normalizeIsoDate(profile.birthDate),
    birthPlace: normalizeNullableString(profile.birthPlace),
  };
}

// Phase 3.4-prep (DECISIONS.md 2026-05-10 Q3/Q4): валидирует и
// применяет incoming `includeRules` поверх существующих rules
// branch'а. Не перетирает manualPersonIds на blood/descendants/
// ancestors (stash для возможного rollback на manual). Validation:
//   - type ∈ {manual, blood-from-me, descendants-of, ancestors-of}
//   - maxHops 1..20 (default 5 если invalid/missing)
//   - anchorPersonId — string или null
// Возвращает true если что-то реально изменилось, false если no-op.
const VALID_INCLUDE_RULE_TYPES = new Set([
  "manual",
  "blood-from-me",
  "descendants-of",
  "ancestors-of",
]);

function applyIncludeRulesToBranch(branch, incoming) {
  if (!branch || !incoming || typeof incoming !== "object") {
    return false;
  }
  const before = JSON.stringify(branch.includeRules || {});

  if (
    !branch.includeRules ||
    typeof branch.includeRules !== "object"
  ) {
    branch.includeRules = {
      type: "manual",
      manualPersonIds: [],
      anchorPersonId: null,
      maxHops: 5,
    };
  }
  const next = branch.includeRules;

  // Type validation (DECISIONS.md 2026-05-10 fix-1):
  //   - missing / null / empty → silent default (caller relies on
  //     existing type, или `_syncTreeToBranch` initialize'нул "manual").
  //     Это backward-compat для legacy callers без includeRules.
  //   - explicit non-empty но не-allowed → throw INVALID_RULE_TYPE.
  //     Malformed value = client-bug, должен surface'иться 400'ой,
  //     не silent fallback'ом.
  if (incoming.type !== undefined && incoming.type !== null) {
    const requestedType = String(incoming.type).trim();
    if (requestedType !== "") {
      if (!VALID_INCLUDE_RULE_TYPES.has(requestedType)) {
        throw new Error("INVALID_RULE_TYPE");
      }
      next.type = requestedType;
    }
  }

  if (incoming.anchorPersonId === null) {
    next.anchorPersonId = null;
  } else if (typeof incoming.anchorPersonId === "string") {
    const trimmed = incoming.anchorPersonId.trim();
    next.anchorPersonId = trimmed || null;
  }

  // maxHops — continuous int с clamp 1..20 (не throw на out-of-range,
  // в отличие от type). DECISIONS.md fix-2: out-of-range — это
  // valid input behavior, не client-bug; sanity-bound и идём дальше.
  if (Number.isFinite(incoming.maxHops)) {
    const clamped = Math.max(1, Math.min(20, Math.floor(incoming.maxHops)));
    next.maxHops = clamped;
  } else if (next.maxHops === undefined || next.maxHops === null) {
    next.maxHops = 5;
  }

  if (Array.isArray(incoming.manualPersonIds)) {
    next.manualPersonIds = Array.from(
      new Set(incoming.manualPersonIds.filter(Boolean)),
    );
  } else if (!Array.isArray(next.manualPersonIds)) {
    next.manualPersonIds = [];
  }

  return JSON.stringify(next) !== before;
}

function applyCanonicalProfileToPerson(person, profile = {}, {
  touchUpdatedAt = true,
  // `additive: true` — никогда не перезатирать уже существующие поля
  // person (name, gender, birthDate, ...). Только заполнять пустые.
  // Используется при `linkPersonToUser`, чтобы вход нового юзера в
  // чужой существующий слот в дереве НЕ переписывал генеалогические
  // данные, проставленные владельцем дерева.
  //
  // Bug-репорт: «приглашённый Степа стал отцом, фото мамы». Корень —
  // ссылка-приглашение указывала на мамин personId, мамин слот не
  // имел userId, linkPersonToUser принял его, и без additive — затёр
  // мамино имя на «Моздуков Степка» и её гендер на male, из-за чего
  // движок отношений переписал её роль с «Мама» на «Папа». Photo
  // выжило случайно — у Степы в профиле не было своего фото.
  //
  // `additive: false` (по умолчанию для совместимости с
  // buildCanonicalPersonView) — старое поведение полного оверлея,
  // нужно для render-only вызовов на клонированных person'ах.
  additive = false,
} = {}) {
  if (!person || !profile || typeof profile !== "object") {
    return person;
  }

  const patch = buildLinkedPersonCanonicalPatchFromProfile(profile);
  const fillIfEmpty = (current, candidate) => {
    if (!additive) return candidate;
    const trimmed = current === null || current === undefined
      ? ""
      : String(current).trim();
    if (trimmed.length > 0) return current;
    return candidate;
  };

  if (patch.name) {
    person.name = fillIfEmpty(person.name, patch.name);
  }
  person.maidenName = fillIfEmpty(person.maidenName, patch.maidenName);
  if (patch.photoUrl) {
    person.photoUrl = fillIfEmpty(person.photoUrl, patch.photoUrl);
    person.primaryPhotoUrl = fillIfEmpty(
      person.primaryPhotoUrl,
      patch.primaryPhotoUrl,
    );
  }
  person.gender = fillIfEmpty(person.gender, patch.gender);
  person.birthDate = fillIfEmpty(person.birthDate, patch.birthDate);
  person.birthPlace = fillIfEmpty(person.birthPlace, patch.birthPlace);
  if (touchUpdatedAt) {
    person.updatedAt = nowIso();
  }
  return person;
}

// SPEED-10: `usersById` — опциональная карта id→user (buildUsersByIdMap),
// построенная ОДИН раз вызывающим циклом (listPersons и т.п.), вместо
// db.users.find(...) на КАЖДОГО person — было O(persons_в_дереве ×
// users_всего) на listPersons, см. docs/speed_measurement.md SPEED-10.
// Без параметра — прежнее поведение, честный .find() (searchPersonsForUser
// и fallback внутри _buildPersonViewFromGraph зовут одиночно, карту строить
// ради одного person незачем).
function buildCanonicalPersonView(db, person, {
  touchUpdatedAt = false,
  usersById = null,
} = {}) {
  const personView = structuredClone(person);
  if (!personView?.userId) {
    return personView;
  }

  const user = usersById
    ? usersById.get(String(personView.userId || "").trim())
    : db.users.find((entry) => entry.id === personView.userId);
  if (!user?.profile) {
    return personView;
  }

  return applyCanonicalProfileToPerson(personView, user.profile, {
    touchUpdatedAt,
  });
}

function buildBranchVisiblePersonIds(persons, relations, branchRootPersonId) {
  const normalizedRootId = String(branchRootPersonId || "").trim();
  if (!normalizedRootId) {
    return new Set();
  }
  const treeId = Array.isArray(persons) && persons.length > 0 ? persons[0]?.treeId : null;
  if (!treeId) {
    return new Set([normalizedRootId]);
  }
  const snapshot = buildTreeGraphSnapshot({
    treeId,
    persons,
    relations,
    viewerPersonId: null,
  });
  const branchBlock = chooseBranchBlockForPerson(snapshot, normalizedRootId);
  return new Set(branchBlock?.memberPersonIds || [normalizedRootId]);
}

function relationMirror(relationType) {
  switch (String(relationType || "other")) {
    case "parent":
      return "child";
    case "child":
      return "parent";
    case "spouse":
      return "spouse";
    case "partner":
      return "partner";
    case "sibling":
      return "sibling";
    case "cousin":
      return "cousin";
    case "uncle":
      return "nibling";
    case "aunt":
      return "nibling";
    case "nephew":
      return "uncle";
    case "niece":
      return "aunt";
    case "nibling":
      return "uncle";
    case "grandparent":
      return "grandchild";
    case "grandchild":
      return "grandparent";
    case "greatGrandparent":
      return "greatGrandchild";
    case "greatGrandchild":
      return "greatGrandparent";
    case "parentInLaw":
      return "childInLaw";
    case "childInLaw":
      return "parentInLaw";
    case "siblingInLaw":
      return "siblingInLaw";
    case "inlaw":
      return "inlaw";
    case "stepparent":
      return "stepchild";
    case "stepchild":
      return "stepparent";
    case "ex_spouse":
      return "ex_spouse";
    case "ex_partner":
      return "ex_partner";
    case "friend":
      return "friend";
    case "colleague":
      return "colleague";
    default:
      return "other";
  }
}

function genderAwareWord(gender, {
  male,
  female,
  neutral,
}) {
  const normalizedGender = String(gender || "").trim().toLowerCase();
  if (normalizedGender === "male" && male) {
    return male;
  }
  if (normalizedGender === "female" && female) {
    return female;
  }
  return neutral || male || female || "";
}

function normalizeGenderValue(gender) {
  return String(gender || "").trim().toLowerCase();
}

function isMaleGender(gender) {
  return normalizeGenderValue(gender) === "male";
}

function isFemaleGender(gender) {
  return normalizeGenderValue(gender) === "female";
}

function addMapSetValue(map, key, value) {
  const normalizedKey = String(key || "").trim();
  const normalizedValue = String(value || "").trim();
  if (!normalizedKey || !normalizedValue) {
    return;
  }
  if (!map.has(normalizedKey)) {
    map.set(normalizedKey, new Set());
  }
  map.get(normalizedKey).add(normalizedValue);
}

function getMapSetValues(map, key) {
  return Array.from(map.get(String(key || "").trim()) || []);
}

function hasMapSetValue(map, key, value) {
  return Boolean(map.get(String(key || "").trim())?.has(String(value || "").trim()));
}

function describeDirectRelationLabel({
  relationType,
  gender = "unknown",
  parentSetType = "biological",
  unionStatus = null,
}) {
  let normalizedRelationType = String(relationType || "").trim().toLowerCase();
  const normalizedParentSetType = normalizeParentSetType(parentSetType);
  // B2: статус союза 'past' на примитивном spouse/partner → метка
  // бывшего союза (тип в пикере остаётся текущим; «бывший» — свойство
  // союза). ended_by_death НЕ превращаем в «бывший»: смерть завершает
  // союз, но по-русски это не «расстались». ex_spouse/ex_partner и так
  // попадут в нужную ветку switch.
  if (String(unionStatus || "").trim().toLowerCase() === "past") {
    if (normalizedRelationType === "spouse") {
      normalizedRelationType = "ex_spouse";
    } else if (normalizedRelationType === "partner") {
      normalizedRelationType = "ex_partner";
    }
  }

  if (normalizedRelationType === "parent") {
    if (normalizedParentSetType === "adoptive") {
      return "Приемный родитель";
    }
    if (normalizedParentSetType === "guardian") {
      return "Опекун";
    }
    if (normalizedParentSetType === "foster") {
      return "Приемный родитель";
    }
    if (normalizedParentSetType === "step") {
      return genderAwareWord(gender, {
        male: "Отчим",
        female: "Мачеха",
        neutral: "Сводный родитель",
      });
    }
    return genderAwareWord(gender, {
      male: "Отец",
      female: "Мать",
      neutral: "Родитель",
    });
  }

  if (normalizedRelationType === "child") {
    if (normalizedParentSetType === "adoptive") {
      return "Приемный ребенок";
    }
    if (normalizedParentSetType === "guardian") {
      return "Подопечный";
    }
    if (normalizedParentSetType === "foster") {
      return "Приемный ребенок";
    }
    if (normalizedParentSetType === "step") {
      return genderAwareWord(gender, {
        male: "Пасынок",
        female: "Падчерица",
        neutral: "Сводный ребенок",
      });
    }
    return genderAwareWord(gender, {
      male: "Сын",
      female: "Дочь",
      neutral: "Ребенок",
    });
  }

  switch (normalizedRelationType) {
    case "sibling":
      return genderAwareWord(gender, {
        male: "Брат",
        female: "Сестра",
        neutral: "Сиблинг",
      });
    case "spouse":
      return genderAwareWord(gender, {
        male: "Муж",
        female: "Жена",
        neutral: "Супруг",
      });
    case "partner":
      return "Партнер";
    case "ex_spouse":
      return genderAwareWord(gender, {
        male: "Бывший муж",
        female: "Бывшая жена",
        neutral: "Бывший супруг",
      });
    case "ex_partner":
      return genderAwareWord(gender, {
        male: "Бывший партнёр",
        female: "Бывшая партнёрша",
        neutral: "Бывший партнёр",
      });
    case "friend":
      return "Друг";
    case "stepparent":
      return genderAwareWord(gender, {
        male: "Отчим",
        female: "Мачеха",
        neutral: "Сводный родитель",
      });
    case "stepchild":
      return genderAwareWord(gender, {
        male: "Пасынок",
        female: "Падчерица",
        neutral: "Сводный ребенок",
      });
    case "grandparent":
      return genderAwareWord(gender, {
        male: "Дедушка",
        female: "Бабушка",
        neutral: "Прародитель",
      });
    case "grandchild":
      return genderAwareWord(gender, {
        male: "Внук",
        female: "Внучка",
        neutral: "Внук/внучка",
      });
    case "uncle":
      return genderAwareWord(gender, {
        male: "Дядя",
        female: "Тетя",
        neutral: "Дядя/тетя",
      });
    case "aunt":
      return genderAwareWord(gender, {
        male: "Дядя",
        female: "Тетя",
        neutral: "Дядя/тетя",
      });
    case "nephew":
    case "niece":
    case "nibling":
      return genderAwareWord(gender, {
        male: "Племянник",
        female: "Племянница",
        neutral: "Племянник/племянница",
      });
    case "cousin":
      return genderAwareWord(gender, {
        male: "Двоюродный брат",
        female: "Двоюродная сестра",
        neutral: "Двоюродный родственник",
      });
    case "parentInLaw":
      return genderAwareWord(gender, {
        male: "Родитель супруга",
        female: "Родительница супруга",
        neutral: "Родитель супруга",
      });
    case "childInLaw":
      return genderAwareWord(gender, {
        male: "Зять",
        female: "Невестка",
        neutral: "Родня по браку",
      });
    case "siblingInLaw":
      return genderAwareWord(gender, {
        male: "Брат супруга",
        female: "Сестра супруга",
        neutral: "Сиблинг супруга",
      });
    case "inlaw":
      return "Родня по браку";
    case "colleague":
      return "Коллега";
    default:
      return "Родственник";
  }
}

function buildPathSummary(pathPersonIds, peopleById) {
  const labels = (Array.isArray(pathPersonIds) ? pathPersonIds : [])
    .map((personId) => {
      const person = peopleById.get(personId);
      return String(person?.name || "").trim() || personId;
    })
    .filter(Boolean);
  return labels.join(" -> ");
}

function collectAncestorDepths(startPersonId, parentsByChild) {
  const depths = new Map();
  const queue = [{personId: startPersonId, depth: 0}];

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current) {
      continue;
    }
    const previousDepth = depths.get(current.personId);
    if (previousDepth !== undefined && previousDepth <= current.depth) {
      continue;
    }
    depths.set(current.personId, current.depth);
    for (const parentId of parentsByChild.get(current.personId) || []) {
      queue.push({
        personId: parentId,
        depth: current.depth + 1,
      });
    }
  }

  return depths;
}

function ordinalCousinLabel(degree) {
  switch (degree) {
    case 1:
      return "Двоюродный";
    case 2:
      return "Троюродный";
    case 3:
      return "Четвероюродный";
    default:
      return "Дальний";
  }
}

function ordinalCousinPrefix(degree, gender) {
  switch (degree) {
    case 1:
      return genderAwareWord(gender, {
        male: "Двоюродный",
        female: "Двоюродная",
        neutral: "Двоюродный",
      });
    case 2:
      return genderAwareWord(gender, {
        male: "Троюродный",
        female: "Троюродная",
        neutral: "Троюродный",
      });
    case 3:
      return genderAwareWord(gender, {
        male: "Четвероюродный",
        female: "Четвероюродная",
        neutral: "Четвероюродный",
      });
    default:
      return genderAwareWord(gender, {
        male: "Дальний",
        female: "Дальняя",
        neutral: "Дальний",
      });
  }
}

function buildAncestorLabel(depth, gender) {
  if (depth === 1) {
    return genderAwareWord(gender, {
      male: "Отец",
      female: "Мать",
      neutral: "Родитель",
    });
  }
  if (depth === 2) {
    return genderAwareWord(gender, {
      male: "Дедушка",
      female: "Бабушка",
      neutral: "Прародитель",
    });
  }
  if (depth === 3) {
    return genderAwareWord(gender, {
      male: "Прадедушка",
      female: "Прабабушка",
      neutral: "Предок",
    });
  }
  return "Предок";
}

function buildDescendantLabel(depth, gender) {
  if (depth === 1) {
    return genderAwareWord(gender, {
      male: "Сын",
      female: "Дочь",
      neutral: "Ребенок",
    });
  }
  if (depth === 2) {
    return genderAwareWord(gender, {
      male: "Внук",
      female: "Внучка",
      neutral: "Внук/внучка",
    });
  }
  if (depth === 3) {
    return genderAwareWord(gender, {
      male: "Правнук",
      female: "Правнучка",
      neutral: "Правнук/правнучка",
    });
  }
  return "Потомок";
}

function buildUncleAuntLabel(gender, prefix = null) {
  const value = genderAwareWord(gender, {
    male: "дядя",
    female: "тетя",
    neutral: "дядя/тетя",
  });
  if (!prefix) {
    return value.charAt(0).toUpperCase() + value.slice(1);
  }
  return `${prefix} ${value}`.trim();
}

function buildNephewNieceLabel(gender, prefix = null) {
  const value = genderAwareWord(gender, {
    male: "племянник",
    female: "племянница",
    neutral: "племянник/племянница",
  });
  if (!prefix) {
    return value.charAt(0).toUpperCase() + value.slice(1);
  }
  return `${prefix} ${value}`.trim();
}

function buildGrandUncleAuntLabel(gender) {
  return genderAwareWord(gender, {
    male: "Двоюродный дедушка",
    female: "Двоюродная бабушка",
    neutral: "Двоюродный дедушка/бабушка",
  });
}

function buildGrandNephewNieceLabel(gender) {
  return genderAwareWord(gender, {
    male: "Внучатый племянник",
    female: "Внучатая племянница",
    neutral: "Внучатый племянник/племянница",
  });
}

function buildCousinOlderGenerationLabel(cousinDegree, gender) {
  const prefix = ordinalCousinPrefix(cousinDegree, gender);
  return genderAwareWord(gender, {
    male: `${prefix} дядя`,
    female: `${prefix} тетя`,
    neutral: `${prefix} дядя/тетя`,
  });
}

function buildCousinYoungerGenerationLabel(cousinDegree, gender) {
  const prefix = ordinalCousinPrefix(cousinDegree, gender);
  return genderAwareWord(gender, {
    male: `${prefix} племянник`,
    female: `${prefix} племянница`,
    neutral: `${prefix} племянник/племянница`,
  });
}

function buildBloodRelationshipLabel({
  viewerDepth,
  targetDepth,
  targetGender,
}) {
  if (viewerDepth === 0 && targetDepth === 0) {
    return "Это вы";
  }

  if (targetDepth === 0 && viewerDepth > 0) {
    return buildAncestorLabel(viewerDepth, targetGender);
  }

  if (viewerDepth === 0 && targetDepth > 0) {
    return buildDescendantLabel(targetDepth, targetGender);
  }

  if (viewerDepth === 1 && targetDepth === 1) {
    return genderAwareWord(targetGender, {
      male: "Брат",
      female: "Сестра",
      neutral: "Сиблинг",
    });
  }

  if (viewerDepth === 1 && targetDepth === 2) {
    return genderAwareWord(targetGender, {
      male: "Племянник",
      female: "Племянница",
      neutral: "Племянник/племянница",
    });
  }

  if (viewerDepth === 1 && targetDepth === 3) {
    return buildGrandNephewNieceLabel(targetGender);
  }

  if (viewerDepth === 2 && targetDepth === 1) {
    return buildUncleAuntLabel(targetGender);
  }

  if (viewerDepth === 3 && targetDepth === 1) {
    return buildGrandUncleAuntLabel(targetGender);
  }

  if (viewerDepth > 1 && targetDepth > 1) {
    const cousinDegree = Math.min(viewerDepth, targetDepth) - 1;
    const removed = Math.abs(viewerDepth - targetDepth);
    if (removed === 0) {
      return `${ordinalCousinPrefix(cousinDegree, targetGender)} ${genderAwareWord(targetGender, {
        male: "брат",
        female: "сестра",
        neutral: "родственник",
      })}`.trim();
    }
    if (removed === 1) {
      if (viewerDepth < targetDepth) {
        return buildCousinYoungerGenerationLabel(cousinDegree, targetGender);
      }
      return buildCousinOlderGenerationLabel(cousinDegree, targetGender);
    }
  }

  return "Кровный родственник";
}

function computeBloodRelationshipDescriptor(
  viewerPersonId,
  targetPersonId,
  bloodParentsByChild,
  peopleById,
) {
  if (!viewerPersonId || !targetPersonId) {
    return null;
  }

  const viewerAncestors = collectAncestorDepths(viewerPersonId, bloodParentsByChild);
  const targetAncestors = collectAncestorDepths(targetPersonId, bloodParentsByChild);
  let bestMatch = null;

  for (const [ancestorId, viewerDepth] of viewerAncestors.entries()) {
    if (!targetAncestors.has(ancestorId)) {
      continue;
    }
    const targetDepth = targetAncestors.get(ancestorId);
    const candidate = {
      ancestorId,
      viewerDepth,
      targetDepth,
      totalDepth: viewerDepth + targetDepth,
      maxDepth: Math.max(viewerDepth, targetDepth),
    };
    if (
      !bestMatch ||
      candidate.totalDepth < bestMatch.totalDepth ||
      (candidate.totalDepth === bestMatch.totalDepth &&
        candidate.maxDepth < bestMatch.maxDepth)
    ) {
      bestMatch = candidate;
    }
  }

  if (!bestMatch) {
    return null;
  }

  const target = peopleById.get(targetPersonId);
  return {
    ancestorId: bestMatch.ancestorId,
    isBlood: true,
    label: buildBloodRelationshipLabel({
      viewerDepth: bestMatch.viewerDepth,
      targetDepth: bestMatch.targetDepth,
      targetGender: target?.gender,
    }),
    viewerDepth: bestMatch.viewerDepth,
    targetDepth: bestMatch.targetDepth,
  };
}

function collectBloodSiblingIds(personId, bloodParentsByChild, bloodChildrenByParent) {
  const siblingIds = new Set();
  for (const parentId of getMapSetValues(bloodParentsByChild, personId)) {
    for (const childId of getMapSetValues(bloodChildrenByParent, parentId)) {
      if (childId !== personId) {
        siblingIds.add(childId);
      }
    }
  }
  return Array.from(siblingIds);
}

function collectKnownSiblingIds(
  personId,
  bloodParentsByChild,
  bloodChildrenByParent,
  siblingsByPerson,
) {
  const siblingIds = new Set(
    collectBloodSiblingIds(personId, bloodParentsByChild, bloodChildrenByParent),
  );
  for (const siblingId of getMapSetValues(siblingsByPerson, personId)) {
    if (siblingId !== personId) {
      siblingIds.add(siblingId);
    }
  }
  return Array.from(siblingIds);
}

function buildParentInLawLabel({spouseGender, targetGender}) {
  if (isFemaleGender(spouseGender)) {
    return genderAwareWord(targetGender, {
      male: "Тесть",
      female: "Теща",
      neutral: "Родитель жены",
    });
  }
  if (isMaleGender(spouseGender)) {
    return genderAwareWord(targetGender, {
      male: "Свекор",
      female: "Свекровь",
      neutral: "Родитель мужа",
    });
  }
  return genderAwareWord(targetGender, {
    male: "Родитель супруга",
    female: "Родительница супруга",
    neutral: "Родитель супруга",
  });
}

function buildSiblingInLawLabel({spouseGender, targetGender}) {
  if (isFemaleGender(spouseGender)) {
    return genderAwareWord(targetGender, {
      male: "Шурин",
      female: "Свояченица",
      neutral: "Родня жены",
    });
  }
  if (isMaleGender(spouseGender)) {
    return genderAwareWord(targetGender, {
      male: "Деверь",
      female: "Золовка",
      neutral: "Родня мужа",
    });
  }
  return genderAwareWord(targetGender, {
    male: "Брат супруга",
    female: "Сестра супруга",
    neutral: "Сиблинг супруга",
  });
}

function buildChildInLawLabel(targetGender) {
  return genderAwareWord(targetGender, {
    male: "Зять",
    female: "Невестка",
    neutral: "Родня по браку",
  });
}

function buildMatchmakerLabel(targetGender) {
  return genderAwareWord(targetGender, {
    male: "Сват",
    female: "Сватья",
    neutral: "Сват",
  });
}

function buildAffinalInheritedLabel(baseLabel, targetGender) {
  const normalizedLabel = String(baseLabel || "").trim().toLowerCase();
  if (!normalizedLabel) {
    return null;
  }
  if (
    normalizedLabel === "дядя" ||
    normalizedLabel === "тетя" ||
    normalizedLabel.startsWith("двоюродный дяд") ||
    normalizedLabel.startsWith("двоюродная тет")
  ) {
    if (normalizedLabel.startsWith("двоюрод")) {
      return buildCousinOlderGenerationLabel(1, targetGender);
    }
    return buildUncleAuntLabel(targetGender);
  }
  if (
    normalizedLabel.startsWith("двоюродный дед") ||
    normalizedLabel.startsWith("двоюродная баб")
  ) {
    return buildGrandUncleAuntLabel(targetGender);
  }
  return null;
}

function computeAffinityRelationshipDescriptor({
  viewerPersonId,
  targetPersonId,
  peopleById,
  parentsByChild,
  childrenByParent,
  bloodParentsByChild,
  bloodChildrenByParent,
  currentUnionPartnersByPerson,
  siblingsByPerson,
}) {
  const viewer = peopleById.get(viewerPersonId);
  const target = peopleById.get(targetPersonId);
  if (!viewer || !target) {
    return null;
  }

  const viewerPartners = getMapSetValues(currentUnionPartnersByPerson, viewerPersonId);
  for (const spouseId of viewerPartners) {
    const spouse = peopleById.get(spouseId);
    if (!spouse) {
      continue;
    }
    if (hasMapSetValue(parentsByChild, spouseId, targetPersonId)) {
      return {
        label: buildParentInLawLabel({
          spouseGender: spouse.gender,
          targetGender: target.gender,
        }),
        isBlood: false,
      };
    }

    const spouseSiblingIds = collectKnownSiblingIds(
      spouseId,
      bloodParentsByChild,
      bloodChildrenByParent,
      siblingsByPerson,
    );
    if (spouseSiblingIds.includes(targetPersonId)) {
      return {
        label: buildSiblingInLawLabel({
          spouseGender: spouse.gender,
          targetGender: target.gender,
        }),
        isBlood: false,
      };
    }

    if (
      hasMapSetValue(childrenByParent, spouseId, targetPersonId) &&
      !hasMapSetValue(childrenByParent, viewerPersonId, targetPersonId)
    ) {
      return {
        label: describeDirectRelationLabel({
          relationType: "stepchild",
          gender: target.gender,
          parentSetType: "step",
        }),
        isBlood: false,
      };
    }

    for (const spouseSiblingId of spouseSiblingIds) {
      const spouseSibling = peopleById.get(spouseSiblingId);
      if (!spouseSibling) {
        continue;
      }
      if (
        hasMapSetValue(currentUnionPartnersByPerson, spouseSiblingId, targetPersonId) &&
        isMaleGender(target.gender) &&
        isFemaleGender(spouseSibling.gender)
      ) {
        return {
          label: "Свояк",
          isBlood: false,
        };
      }
    }
  }

  for (const parentId of getMapSetValues(parentsByChild, viewerPersonId)) {
    if (
      hasMapSetValue(currentUnionPartnersByPerson, parentId, targetPersonId) &&
      !hasMapSetValue(parentsByChild, viewerPersonId, targetPersonId)
    ) {
      return {
        label: describeDirectRelationLabel({
          relationType: "stepparent",
          gender: target.gender,
          parentSetType: "step",
        }),
        isBlood: false,
      };
    }
  }

  for (const childId of getMapSetValues(childrenByParent, viewerPersonId)) {
    if (hasMapSetValue(currentUnionPartnersByPerson, childId, targetPersonId)) {
      return {
        label: buildChildInLawLabel(target.gender),
        isBlood: false,
      };
    }

    for (const childPartnerId of getMapSetValues(currentUnionPartnersByPerson, childId)) {
      if (
        childPartnerId !== viewerPersonId &&
        hasMapSetValue(parentsByChild, childPartnerId, targetPersonId)
      ) {
        return {
          label: buildMatchmakerLabel(target.gender),
          isBlood: false,
        };
      }
    }
  }

  for (const siblingId of collectKnownSiblingIds(
    viewerPersonId,
    bloodParentsByChild,
    bloodChildrenByParent,
    siblingsByPerson,
  )) {
    if (hasMapSetValue(currentUnionPartnersByPerson, siblingId, targetPersonId)) {
      return {
        label: buildChildInLawLabel(target.gender),
        isBlood: false,
      };
    }
  }

  for (const partnerId of getMapSetValues(currentUnionPartnersByPerson, targetPersonId)) {
    const partnerBloodDescriptor = computeBloodRelationshipDescriptor(
      viewerPersonId,
      partnerId,
      bloodParentsByChild,
      peopleById,
    );
    const inheritedLabel = buildAffinalInheritedLabel(
      partnerBloodDescriptor?.label,
      target.gender,
    );
    if (inheritedLabel) {
      return {
        label: inheritedLabel,
        isBlood: false,
      };
    }
  }

  return null;
}

function relationTypeAlongPath(directRelations, fromPersonId, toPersonId) {
  const relation = directRelations.get(buildSortedIdKey([fromPersonId, toPersonId]));
  if (!relation) {
    return null;
  }
  return String(relationTypeForPerson(relation, toPersonId) || "")
    .trim()
    .toLowerCase() || null;
}

function buildSparsePathRelationshipDescriptor({
  targetPersonId,
  primaryPathPersonIds,
  directRelations,
  peopleById,
}) {
  if (!Array.isArray(primaryPathPersonIds) || primaryPathPersonIds.length < 2) {
    return null;
  }

  const target = peopleById.get(String(targetPersonId || "").trim());
  if (!target) {
    return null;
  }

  const edgeTypes = [];
  for (let index = 0; index < primaryPathPersonIds.length - 1; index += 1) {
    const relationType = relationTypeAlongPath(
      directRelations,
      primaryPathPersonIds[index],
      primaryPathPersonIds[index + 1],
    );
    if (!relationType) {
      return null;
    }
    edgeTypes.push(relationType);
  }

  if (edgeTypes.length === 2 && edgeTypes[0] === "parent" && edgeTypes[1] === "sibling") {
    return {
      label: buildUncleAuntLabel(target.gender),
      isBlood: true,
    };
  }

  if (
    edgeTypes.length === 3 &&
    edgeTypes[0] === "parent" &&
    edgeTypes[1] === "sibling" &&
    edgeTypes[2] === "child"
  ) {
    return {
      label: genderAwareWord(target.gender, {
        male: "Двоюродный брат",
        female: "Двоюродная сестра",
        neutral: "Двоюродный родственник",
      }),
      isBlood: true,
    };
  }

  if (
    edgeTypes.length === 2 &&
    edgeTypes[0] === "sibling" &&
    edgeTypes[1] === "child"
  ) {
    return {
      label: buildNephewNieceLabel(target.gender),
      isBlood: true,
    };
  }

  if (
    edgeTypes.length === 3 &&
    edgeTypes[0] === "sibling" &&
    edgeTypes[1] === "child" &&
    edgeTypes[2] === "child"
  ) {
    return {
      label: buildGrandNephewNieceLabel(target.gender),
      isBlood: true,
    };
  }

  if (
    edgeTypes.length === 3 &&
    edgeTypes[0] === "parent" &&
    edgeTypes[1] === "parent" &&
    edgeTypes[2] === "sibling"
  ) {
    return {
      label: buildGrandUncleAuntLabel(target.gender),
      isBlood: true,
    };
  }

  const lastEdgeType = edgeTypes[edgeTypes.length - 1];
  const olderGenerationChain = edgeTypes.slice(0, -1);
  if (
    isUnionRelationType(lastEdgeType) &&
    olderGenerationChain.length >= 2 &&
    olderGenerationChain[olderGenerationChain.length - 1] === "sibling" &&
    olderGenerationChain.slice(0, -1).every((relationType) => relationType === "parent")
  ) {
    const parentDepth = olderGenerationChain.length - 1;
    if (parentDepth === 1) {
      return {
        label: buildUncleAuntLabel(target.gender),
        isBlood: false,
      };
    }
    if (parentDepth === 2) {
      return {
        label: buildGrandUncleAuntLabel(target.gender),
        isBlood: false,
      };
    }
  }

  return null;
}

function buildFamilyUnitLabel({adultIds, peopleById}) {
  const adults = (Array.isArray(adultIds) ? adultIds : [])
    .map((personId) => peopleById.get(personId))
    .filter(Boolean);

  if (adults.length === 0) {
    return "Семья";
  }

  const surnames = Array.from(
    new Set(
      adults
        .map((person) => extractSurnameFromName(person.name))
        .filter(Boolean),
    ),
  );
  if (surnames.length === 1) {
    return `Ветка ${surnames[0]}`;
  }

  if (adults.length === 1) {
    return `Семья ${adults[0].name}`;
  }

  return `Семья ${adults[0].name} и ${adults[1].name}`;
}

function buildBranchLabel({rootUnit, peopleById}) {
  if (!rootUnit) {
    return "Семья";
  }
  return buildFamilyUnitLabel({
    adultIds: rootUnit.adultIds,
    peopleById,
  });
}

function comparePathCost(left, right) {
  if (!left && !right) {
    return 0;
  }
  if (!left) {
    return 1;
  }
  if (!right) {
    return -1;
  }
  if (left.nonBlood !== right.nonBlood) {
    return left.nonBlood - right.nonBlood;
  }
  if (left.length !== right.length) {
    return left.length - right.length;
  }
  return left.pastUnion - right.pastUnion;
}

function buildTraversalGraph(relations) {
  const adjacency = new Map();
  const parentsByChild = new Map();
  const bloodParentsByChild = new Map();
  const childrenByParent = new Map();
  const bloodChildrenByParent = new Map();
  const currentUnionPartnersByPerson = new Map();
  const anyUnionPartnersByPerson = new Map();
  const siblingsByPerson = new Map();
  const directRelations = new Map();

  for (const relation of Array.isArray(relations) ? relations : []) {
    const pairKey = buildSortedIdKey([relation.person1Id, relation.person2Id]);
    if (pairKey) {
      directRelations.set(pairKey, relation);
    }

    const parentId = parentIdFromRelation(relation);
    const childId = childIdFromRelation(relation);
    if (parentId && childId) {
      addMapSetValue(parentsByChild, childId, parentId);
      addMapSetValue(childrenByParent, parentId, childId);
      if (isBloodParentSetType(relation.parentSetType)) {
        addMapSetValue(bloodParentsByChild, childId, parentId);
        addMapSetValue(bloodChildrenByParent, parentId, childId);
      }
      if (!adjacency.has(parentId)) {
        adjacency.set(parentId, []);
      }
      if (!adjacency.has(childId)) {
        adjacency.set(childId, []);
      }
      adjacency.get(parentId).push({
        toId: childId,
        kind: "child",
        isBlood: isBloodParentSetType(relation.parentSetType),
        isPast: false,
      });
      adjacency.get(childId).push({
        toId: parentId,
        kind: "parent",
        isBlood: isBloodParentSetType(relation.parentSetType),
        isPast: false,
      });
    }

    if (isUnionRelation(relation)) {
      const normalizedUnionStatus = normalizeUnionStatus(relation.unionStatus, {
        relationType: relation.relation1to2 || relation.relation2to1,
        divorceDate: relation.divorceDate,
      });
      const isPast = normalizedUnionStatus !== "current";
      addMapSetValue(anyUnionPartnersByPerson, relation.person1Id, relation.person2Id);
      addMapSetValue(anyUnionPartnersByPerson, relation.person2Id, relation.person1Id);
      if (!isPast) {
        addMapSetValue(currentUnionPartnersByPerson, relation.person1Id, relation.person2Id);
        addMapSetValue(currentUnionPartnersByPerson, relation.person2Id, relation.person1Id);
      }
      if (!adjacency.has(relation.person1Id)) {
        adjacency.set(relation.person1Id, []);
      }
      if (!adjacency.has(relation.person2Id)) {
        adjacency.set(relation.person2Id, []);
      }
      adjacency.get(relation.person1Id).push({
        toId: relation.person2Id,
        kind: "union",
        isBlood: false,
        isPast,
      });
      adjacency.get(relation.person2Id).push({
        toId: relation.person1Id,
        kind: "union",
        isBlood: false,
        isPast,
      });
    }

    if (
      String(relation.relation1to2 || "").trim().toLowerCase() === "sibling" &&
      String(relation.relation2to1 || "").trim().toLowerCase() === "sibling"
    ) {
      addMapSetValue(siblingsByPerson, relation.person1Id, relation.person2Id);
      addMapSetValue(siblingsByPerson, relation.person2Id, relation.person1Id);
      if (!adjacency.has(relation.person1Id)) {
        adjacency.set(relation.person1Id, []);
      }
      if (!adjacency.has(relation.person2Id)) {
        adjacency.set(relation.person2Id, []);
      }
      adjacency.get(relation.person1Id).push({
        toId: relation.person2Id,
        kind: "sibling",
        isBlood: true,
        isPast: false,
      });
      adjacency.get(relation.person2Id).push({
        toId: relation.person1Id,
        kind: "sibling",
        isBlood: true,
        isPast: false,
      });
    }
  }

  return {
    adjacency,
    parentsByChild,
    bloodParentsByChild,
    childrenByParent,
    bloodChildrenByParent,
    currentUnionPartnersByPerson,
    anyUnionPartnersByPerson,
    siblingsByPerson,
    directRelations,
  };
}

function buildBestPathIndex(startPersonId, adjacency) {
  const costs = new Map();
  const pathCounts = new Map();
  const predecessors = new Map();
  costs.set(startPersonId, {
    nonBlood: 0,
    length: 0,
    pastUnion: 0,
  });
  pathCounts.set(startPersonId, 1);
  const pending = [{
    personId: startPersonId,
    cost: {
      nonBlood: 0,
      length: 0,
      pastUnion: 0,
    },
  }];

  while (pending.length > 0) {
    pending.sort((left, right) => comparePathCost(left.cost, right.cost));
    const current = pending.shift();
    if (!current) {
      continue;
    }
    const previousBest = costs.get(current.personId);
    if (previousBest && comparePathCost(current.cost, previousBest) > 0) {
      continue;
    }

    for (const edge of adjacency.get(current.personId) || []) {
      const nextCost = {
        nonBlood: current.cost.nonBlood + (edge.isBlood ? 0 : 1),
        length: current.cost.length + 1,
        pastUnion: current.cost.pastUnion + (edge.isPast ? 1 : 0),
      };
      const existingCost = costs.get(edge.toId);
      const comparison = comparePathCost(nextCost, existingCost);
      if (comparison < 0 || existingCost === undefined) {
        costs.set(edge.toId, nextCost);
        if (edge.toId !== startPersonId) {
          predecessors.set(edge.toId, current.personId);
        }
        pathCounts.set(edge.toId, pathCounts.get(current.personId) || 1);
        pending.push({
          personId: edge.toId,
          cost: nextCost,
        });
      } else if (comparison === 0) {
        pathCounts.set(
          edge.toId,
          (pathCounts.get(edge.toId) || 0) + (pathCounts.get(current.personId) || 1),
        );
      }
    }
  }

  return {
    costs,
    pathCounts,
    predecessors,
  };
}

function reconstructPersonPath(targetPersonId, predecessors) {
  const path = [];
  const seen = new Set();
  let currentId = targetPersonId;
  while (currentId && !seen.has(currentId)) {
    path.unshift(currentId);
    seen.add(currentId);
    currentId = predecessors.get(currentId);
  }
  return path;
}

function normalizeTreeGraph(treeId, persons = [], relations = []) {
  const normalizedPeople = (Array.isArray(persons) ? persons : [])
    .filter((person) => person.treeId === treeId)
    .map((person) => structuredClone(person));
  const normalizedRelations = (Array.isArray(relations) ? relations : [])
    .filter((relation) => relation.treeId === treeId)
    .map((relation) => {
      const normalizedRelation = structuredClone(relation);
      const normalizedParentId = parentIdFromRelation(normalizedRelation);
      const normalizedChildId = childIdFromRelation(normalizedRelation);
      if (normalizedParentId && normalizedChildId) {
        normalizedRelation.parentSetType = normalizeParentSetType(
          normalizedRelation.parentSetType,
        );
        normalizedRelation.parentSetId =
          normalizeNullableString(normalizedRelation.parentSetId) || null;
        normalizedRelation.isPrimaryParentSet =
          normalizedRelation.isPrimaryParentSet !== false;
      } else {
        normalizedRelation.parentSetType = null;
        normalizedRelation.parentSetId = null;
        normalizedRelation.isPrimaryParentSet = null;
      }

      if (isUnionRelation(normalizedRelation)) {
        const relationType =
          normalizedRelation.relation1to2 || normalizedRelation.relation2to1;
        normalizedRelation.unionType = normalizeUnionType(
          normalizedRelation.unionType,
          {relationType},
        );
        normalizedRelation.unionStatus = normalizeUnionStatus(
          normalizedRelation.unionStatus,
          {
            relationType,
            divorceDate: normalizedRelation.divorceDate,
          },
        );
        normalizedRelation.unionId =
          normalizeNullableString(normalizedRelation.unionId) ||
          `union:${treeId}:${buildSortedIdKey([
            normalizedRelation.person1Id,
            normalizedRelation.person2Id,
          ])}:${normalizedRelation.unionType}:${normalizedRelation.unionStatus}`;
      } else {
        normalizedRelation.unionType = null;
        normalizedRelation.unionStatus = null;
        normalizedRelation.unionId = null;
      }

      return normalizedRelation;
    });

  const relationGroups = new Map();
  for (const relation of normalizedRelations) {
    const childId = childIdFromRelation(relation);
    if (!childId) {
      continue;
    }
    const groupKey = `${childId}:${relation.parentSetType}`;
    if (!relationGroups.has(groupKey)) {
      relationGroups.set(groupKey, []);
    }
    relationGroups.get(groupKey).push(relation);
  }

  for (const [groupKey, groupRelations] of relationGroups.entries()) {
    const [childId, parentSetType] = groupKey.split(":");
    const explicitIds = Array.from(
      new Set(
        groupRelations
          .map((relation) => normalizeNullableString(relation.parentSetId))
          .filter(Boolean),
      ),
    );

    if (explicitIds.length === 0) {
      const uniqueParentIds = Array.from(
        new Set(groupRelations.map((relation) => parentIdFromRelation(relation)).filter(Boolean)),
      );
      if (uniqueParentIds.length <= 2) {
        const sharedId = `ps:${treeId}:${childId}:${parentSetType}:primary`;
        for (const relation of groupRelations) {
          relation.parentSetId = sharedId;
          relation.isPrimaryParentSet = true;
        }
      } else {
        let index = 0;
        for (const relation of groupRelations) {
          index += 1;
          relation.parentSetId = `ps:${treeId}:${childId}:${parentSetType}:${index}`;
          relation.isPrimaryParentSet = index === 1;
        }
      }
      continue;
    }

    const primaryId =
      groupRelations.find((relation) => relation.isPrimaryParentSet)?.parentSetId ||
      explicitIds[0];
    const primaryParentIds = new Set(
      groupRelations
        .filter((relation) => relation.parentSetId === primaryId)
        .map((relation) => parentIdFromRelation(relation))
        .filter(Boolean),
    );
    let generatedIndex = explicitIds.length;
    for (const relation of groupRelations) {
      if (relation.parentSetId) {
        relation.isPrimaryParentSet = relation.parentSetId === primaryId;
        continue;
      }
      const parentId = parentIdFromRelation(relation);
      if (primaryParentIds.has(parentId) || primaryParentIds.size < 2) {
        relation.parentSetId = primaryId;
        relation.isPrimaryParentSet = true;
        if (parentId) {
          primaryParentIds.add(parentId);
        }
      } else {
        generatedIndex += 1;
        relation.parentSetId =
          `ps:${treeId}:${childId}:${parentSetType}:${generatedIndex}`;
        relation.isPrimaryParentSet = false;
      }
    }
  }

  return {
    people: normalizedPeople,
    relations: normalizedRelations,
  };
}

function buildDisplayTreeRelations(treeId, relations = []) {
  const normalizedRelations = (Array.isArray(relations) ? relations : []).map((relation) =>
    structuredClone(relation),
  );
  const anyUnionPartnersByPerson = new Map();
  const primaryParentGroups = new Map();
  const childIdsByParentAndType = new Map();
  const existingParentRelationKeys = new Set();

  for (const relation of normalizedRelations) {
    if (isUnionRelation(relation)) {
      addMapSetValue(anyUnionPartnersByPerson, relation.person1Id, relation.person2Id);
      addMapSetValue(anyUnionPartnersByPerson, relation.person2Id, relation.person1Id);
    }

    const parentId = parentIdFromRelation(relation);
    const childId = childIdFromRelation(relation);
    if (!parentId || !childId) {
      continue;
    }
    const normalizedParentSetType = normalizeParentSetType(relation.parentSetType);
    existingParentRelationKeys.add(`${parentId}:${childId}:${normalizedParentSetType}`);
    if (relation.isPrimaryParentSet === false || !isBloodParentSetType(normalizedParentSetType)) {
      continue;
    }
    const groupKey = `${childId}:${normalizedParentSetType}`;
    if (!primaryParentGroups.has(groupKey)) {
      primaryParentGroups.set(groupKey, []);
    }
    primaryParentGroups.get(groupKey).push(relation);
    addMapSetValue(
      childIdsByParentAndType,
      `${parentId}:${normalizedParentSetType}`,
      childId,
    );
  }

  const inferredRelations = [];
  for (const groupRelations of primaryParentGroups.values()) {
    const uniqueParentIds = Array.from(
      new Set(groupRelations.map((relation) => parentIdFromRelation(relation)).filter(Boolean)),
    );
    if (uniqueParentIds.length !== 1) {
      continue;
    }

    const knownParentId = uniqueParentIds[0];
    const childId = childIdFromRelation(groupRelations[0]);
    const parentSetType = normalizeParentSetType(groupRelations[0].parentSetType);
    if (!knownParentId || !childId || !parentSetType) {
      continue;
    }

    const candidateSupport = new Map();
    for (const siblingChildId of getMapSetValues(
      childIdsByParentAndType,
      `${knownParentId}:${parentSetType}`,
    )) {
      if (siblingChildId === childId) {
        continue;
      }
      const siblingRelations =
        primaryParentGroups.get(`${siblingChildId}:${parentSetType}`) || [];
      const siblingParentIds = Array.from(
        new Set(
          siblingRelations
            .map((relation) => parentIdFromRelation(relation))
            .filter(Boolean),
        ),
      );
      if (siblingParentIds.length !== 2 || !siblingParentIds.includes(knownParentId)) {
        continue;
      }
      const candidateParentId = siblingParentIds.find((id) => id !== knownParentId);
      if (
        !candidateParentId ||
        !hasMapSetValue(anyUnionPartnersByPerson, knownParentId, candidateParentId)
      ) {
        continue;
      }
      candidateSupport.set(
        candidateParentId,
        (candidateSupport.get(candidateParentId) || 0) + 1,
      );
    }

    if (candidateSupport.size !== 1) {
      continue;
    }
    const [[candidateParentId]] = Array.from(candidateSupport.entries());
    const inferredKey = `${candidateParentId}:${childId}:${parentSetType}`;
    if (existingParentRelationKeys.has(inferredKey)) {
      continue;
    }

    const templateRelation = groupRelations[0];
    inferredRelations.push({
      ...structuredClone(templateRelation),
      id: `inferred:${treeId}:${candidateParentId}:${childId}:${parentSetType}`,
      person1Id: candidateParentId,
      person2Id: childId,
      relation1to2: "parent",
      relation2to1: "child",
      isConfirmed: true,
      customRelationLabel1to2: null,
      customRelationLabel2to1: null,
      parentSetType,
      parentSetId: templateRelation.parentSetId,
      isPrimaryParentSet: true,
      unionType: null,
      unionStatus: null,
      unionId: null,
      inferredDisplayOnly: true,
    });
    existingParentRelationKeys.add(inferredKey);
  }

  return [...normalizedRelations, ...inferredRelations];
}

function buildFamilyUnits(treeId, persons = [], relations = []) {
  const normalizedGraph = normalizeTreeGraph(treeId, persons, relations);
  const displayRelations = buildDisplayTreeRelations(
    treeId,
    normalizedGraph.relations,
  );
  const peopleById = new Map(
    normalizedGraph.people.map((person) => [String(person.id || "").trim(), person]),
  );
  const familyUnits = [];
  const representedUnionIds = new Set();
  const parentSetGroups = new Map();

  for (const relation of displayRelations) {
    const parentId = parentIdFromRelation(relation);
    const childId = childIdFromRelation(relation);
    if (!parentId || !childId || !relation.parentSetId) {
      continue;
    }
    if (!parentSetGroups.has(relation.parentSetId)) {
      parentSetGroups.set(relation.parentSetId, {
        id: relation.parentSetId,
        parentSetType: relation.parentSetType,
        isPrimaryParentSet: relation.isPrimaryParentSet !== false,
        adultIds: new Set(),
        childIds: new Set(),
        relationIds: new Set(),
      });
    }
    const group = parentSetGroups.get(relation.parentSetId);
    group.adultIds.add(parentId);
    group.childIds.add(childId);
    group.relationIds.add(relation.id);
    if (relation.isPrimaryParentSet === false) {
      group.isPrimaryParentSet = false;
    }
  }

  const mergedParentFamilyGroups = new Map();

  for (const group of parentSetGroups.values()) {
    const adultIds = Array.from(group.adultIds).sort((left, right) =>
      left.localeCompare(right),
    );
    const childIds = Array.from(group.childIds).sort((left, right) =>
      left.localeCompare(right),
    );
    const matchingUnion = adultIds.length >= 2
      ? displayRelations.find((relation) => {
          return (
            relation.unionId &&
            buildSortedIdKey([relation.person1Id, relation.person2Id]) ===
              buildSortedIdKey(adultIds)
          );
        })
      : null;
    const mergeKey = [
      buildSortedIdKey(adultIds),
      matchingUnion?.unionId || `single:${buildSortedIdKey(adultIds)}`,
      normalizeParentSetType(group.parentSetType),
      group.isPrimaryParentSet ? "primary" : "secondary",
    ].join("|");

    if (!mergedParentFamilyGroups.has(mergeKey)) {
      mergedParentFamilyGroups.set(mergeKey, {
        rootParentSetIds: new Set(),
        adultIds: new Set(),
        childIds: new Set(),
        relationIds: new Set(),
        unionId: matchingUnion?.unionId || null,
        unionType:
          matchingUnion?.unionType || (adultIds.length > 1 ? "other" : "single"),
        unionStatus: matchingUnion?.unionStatus || "current",
        parentSetType: group.parentSetType,
        isPrimaryParentSet: group.isPrimaryParentSet,
      });
    }

    const mergedGroup = mergedParentFamilyGroups.get(mergeKey);
    mergedGroup.rootParentSetIds.add(group.id);
    for (const adultId of adultIds) {
      mergedGroup.adultIds.add(adultId);
    }
    for (const childId of childIds) {
      mergedGroup.childIds.add(childId);
    }
    for (const relationId of group.relationIds) {
      mergedGroup.relationIds.add(relationId);
    }
  }

  for (const mergedGroup of mergedParentFamilyGroups.values()) {
    const adultIds = Array.from(mergedGroup.adultIds).sort((left, right) =>
      left.localeCompare(right),
    );
    const childIds = Array.from(mergedGroup.childIds).sort((left, right) =>
      left.localeCompare(right),
    );
    const relationIds = Array.from(mergedGroup.relationIds).sort((left, right) =>
      left.localeCompare(right),
    );
    const rootParentSetIds = Array.from(mergedGroup.rootParentSetIds).sort(
      (left, right) => left.localeCompare(right),
    );
    const rootParentSetId = rootParentSetIds[0] || null;

    if (mergedGroup.unionId) {
      representedUnionIds.add(mergedGroup.unionId);
    }

    familyUnits.push({
      id:
        rootParentSetIds.length <= 1
          ? `family:${rootParentSetId}`
          : `family:merged:${treeId}:${buildSortedIdKey(rootParentSetIds)}`,
      rootParentSetId,
      adultIds,
      childIds,
      relationIds,
      unionId: mergedGroup.unionId,
      unionType: mergedGroup.unionType,
      unionStatus: mergedGroup.unionStatus,
      parentSetType: mergedGroup.parentSetType,
      isPrimaryParentSet: mergedGroup.isPrimaryParentSet,
      label: buildFamilyUnitLabel({adultIds, peopleById}),
    });
  }

  for (const relation of displayRelations) {
    if (!isUnionRelation(relation) || !relation.unionId) {
      continue;
    }
    if (representedUnionIds.has(relation.unionId)) {
      continue;
    }
    representedUnionIds.add(relation.unionId);
    const adultIds = [relation.person1Id, relation.person2Id].sort((left, right) =>
      left.localeCompare(right),
    );
    familyUnits.push({
      id: `family:${relation.unionId}`,
      rootParentSetId: null,
      adultIds,
      childIds: [],
      relationIds: [relation.id],
      unionId: relation.unionId,
      unionType: relation.unionType,
      unionStatus: relation.unionStatus,
      parentSetType: null,
      isPrimaryParentSet: false,
      label: buildFamilyUnitLabel({adultIds, peopleById}),
    });
  }

  const coveredPersonIds = new Set(
    familyUnits.flatMap((unit) => [...unit.adultIds, ...unit.childIds]),
  );
  for (const person of normalizedGraph.people) {
    if (coveredPersonIds.has(person.id)) {
      continue;
    }
    familyUnits.push({
      id: `family:solo:${person.id}`,
      rootParentSetId: null,
      adultIds: [person.id],
      childIds: [],
      relationIds: [],
      unionId: null,
      unionType: "single",
      unionStatus: "current",
      parentSetType: null,
      isPrimaryParentSet: false,
      label: buildFamilyUnitLabel({
        adultIds: [person.id],
        peopleById,
      }),
    });
  }

  return familyUnits;
}

function buildGenerationRows(persons, relations, familyUnits) {
  const normalizedPersons = Array.isArray(persons) ? persons : [];
  const normalizedRelations = Array.isArray(relations) ? relations : [];
  const parentsByChild = new Map();
  const siblingIdsByPerson = new Map();

  for (const relation of normalizedRelations) {
    if (
      String(relation.relation1to2 || "").trim().toLowerCase() === "sibling" &&
      String(relation.relation2to1 || "").trim().toLowerCase() === "sibling"
    ) {
      addMapSetValue(siblingIdsByPerson, relation.person1Id, relation.person2Id);
      addMapSetValue(siblingIdsByPerson, relation.person2Id, relation.person1Id);
    }

    const parentId = parentIdFromRelation(relation);
    const childId = childIdFromRelation(relation);
    if (!parentId || !childId || relation.isPrimaryParentSet === false) {
      continue;
    }
    if (!parentsByChild.has(childId)) {
      parentsByChild.set(childId, new Set());
    }
    parentsByChild.get(childId).add(parentId);
  }

  const levels = new Map();
  const visiting = new Set();
  const resolveLevel = (personId) => {
    if (levels.has(personId)) {
      return levels.get(personId);
    }
    if (visiting.has(personId)) {
      return 0;
    }
    visiting.add(personId);
    const parents = Array.from(parentsByChild.get(personId) || []);
    const level =
      parents.length === 0
        ? 0
        : Math.max(...parents.map((parentId) => resolveLevel(parentId))) + 1;
    visiting.delete(personId);
    levels.set(personId, level);
    return level;
  };

  for (const person of normalizedPersons) {
    resolveLevel(person.id);
  }

  const normalizedFamilyUnits = Array.isArray(familyUnits) ? familyUnits : [];
  const maxIterations = normalizedPersons.length + normalizedFamilyUnits.length + 8;
  let changed = true;
  let iteration = 0;
  while (changed && iteration < maxIterations) {
    changed = false;
    iteration += 1;

    for (const unit of normalizedFamilyUnits) {
      const adultIds = (Array.isArray(unit?.adultIds) ? unit.adultIds : []).filter(Boolean);
      const childIds = (Array.isArray(unit?.childIds) ? unit.childIds : []).filter(Boolean);
      if (adultIds.length === 0 && childIds.length === 0) {
        continue;
      }

      let desiredAdultLevel = null;
      if (childIds.length > 0) {
        desiredAdultLevel = Math.max(
          0,
          Math.min(...childIds.map((personId) => levels.get(personId) ?? 0)) - 1,
        );
      } else if (adultIds.length > 0) {
        desiredAdultLevel = Math.max(
          ...adultIds.map((personId) => levels.get(personId) ?? 0),
        );
      }

      if (desiredAdultLevel !== null) {
        for (const adultId of adultIds) {
          if ((levels.get(adultId) ?? 0) !== desiredAdultLevel) {
            levels.set(adultId, desiredAdultLevel);
            changed = true;
          }
        }
      }

      if (desiredAdultLevel !== null && childIds.length > 0) {
        const desiredChildLevel = desiredAdultLevel + 1;
        for (const childId of childIds) {
          if ((levels.get(childId) ?? 0) !== desiredChildLevel) {
            levels.set(childId, desiredChildLevel);
            changed = true;
          }
        }
      }
    }

    for (const [personId, siblingIds] of siblingIdsByPerson.entries()) {
      const targetLevel = Math.max(
        levels.get(personId) ?? 0,
        ...Array.from(siblingIds).map((siblingId) => levels.get(siblingId) ?? 0),
      );
      if ((levels.get(personId) ?? 0) !== targetLevel) {
        levels.set(personId, targetLevel);
        changed = true;
      }
      for (const siblingId of siblingIds) {
        if ((levels.get(siblingId) ?? 0) !== targetLevel) {
          levels.set(siblingId, targetLevel);
          changed = true;
        }
      }
    }
  }

  const minLevel = Math.min(0, ...Array.from(levels.values()));
  if (minLevel < 0) {
    for (const [personId, level] of levels.entries()) {
      levels.set(personId, level - minLevel);
    }
  }

  const maxLevel = Math.max(0, ...Array.from(levels.values()));
  const rows = [];
  for (let row = 0; row <= maxLevel; row += 1) {
    const personIds = normalizedPersons
      .filter((person) => levels.get(person.id) === row)
      .map((person) => person.id);
    const familyUnitIds = (Array.isArray(familyUnits) ? familyUnits : [])
      .filter((unit) =>
        unit.adultIds.some((personId) => personIds.includes(personId)) ||
        unit.childIds.some((personId) => personIds.includes(personId)),
      )
      .map((unit) => unit.id);
    let label = `Поколение ${row + 1}`;
    if (maxLevel === 0) {
      label = "Семья";
    } else if (row === 0) {
      label = "Старшее поколение";
    } else if (row === maxLevel) {
      label = "Младшее поколение";
    }
    rows.push({
      row,
      label,
      personIds,
      familyUnitIds: Array.from(new Set(familyUnitIds)),
    });
  }

  return rows;
}

function describeParentSetTypeLabelRu(parentSetType) {
  switch (normalizeParentSetType(parentSetType)) {
    case "biological":
      return "биологические родители";
    case "adoptive":
      return "усыновители";
    case "foster":
      return "приемная семья";
    case "guardian":
      return "опекуны";
    case "step":
      return "неродные родители";
    case "unknown":
      return "родители";
    default:
      return "родители";
  }
}

function buildGraphWarnings({
  persons = [],
  relations = [],
  familyUnits = [],
}) {
  const normalizedPersons = Array.isArray(persons) ? persons : [];
  const normalizedRelations = Array.isArray(relations) ? relations : [];
  const normalizedFamilyUnits = Array.isArray(familyUnits) ? familyUnits : [];
  const peopleById = new Map(
    normalizedPersons.map((person) => [String(person.id || "").trim(), person]),
  );
  const warnings = [];
  const emittedWarningIds = new Set();
  const pushWarning = (warning) => {
    const warningId = String(warning?.id || "").trim();
    if (!warningId || emittedWarningIds.has(warningId)) {
      return;
    }
    emittedWarningIds.add(warningId);
    warnings.push({
      id: warningId,
      code: String(warning.code || "").trim() || "graph_warning",
      severity: String(warning.severity || "").trim() || "warning",
      message: String(warning.message || "").trim() || "Дерево требует проверки.",
      hint: normalizeNullableString(warning.hint),
      personIds: Array.from(
        new Set((Array.isArray(warning.personIds) ? warning.personIds : []).filter(Boolean)),
      ),
      familyUnitIds: Array.from(
        new Set(
          (Array.isArray(warning.familyUnitIds) ? warning.familyUnitIds : []).filter(Boolean),
        ),
      ),
      relationIds: Array.from(
        new Set((Array.isArray(warning.relationIds) ? warning.relationIds : []).filter(Boolean)),
      ),
    });
  };

  const primaryParentGroups = new Map();
  for (const relation of normalizedRelations) {
    const parentId = parentIdFromRelation(relation);
    const childId = childIdFromRelation(relation);
    if (!parentId || !childId || relation.isPrimaryParentSet === false) {
      continue;
    }
    const normalizedParentSetType = normalizeParentSetType(relation.parentSetType) || "unknown";
    const normalizedParentSetId =
      normalizeNullableString(relation.parentSetId) ||
      `implicit:${childId}:${normalizedParentSetType}`;
    const groupKey = `${childId}:${normalizedParentSetType}`;
    if (!primaryParentGroups.has(groupKey)) {
      primaryParentGroups.set(groupKey, new Map());
    }
    const groupEntries = primaryParentGroups.get(groupKey);
    if (!groupEntries.has(normalizedParentSetId)) {
      groupEntries.set(normalizedParentSetId, {
        parentIds: new Set(),
        relationIds: new Set(),
      });
    }
    const groupEntry = groupEntries.get(normalizedParentSetId);
    groupEntry.parentIds.add(parentId);
    groupEntry.relationIds.add(relation.id);
  }

  for (const [groupKey, groupEntries] of primaryParentGroups.entries()) {
    if (groupEntries.size <= 1) {
      continue;
    }
    const [childId, parentSetType] = groupKey.split(":");
    const childName =
      peopleById.get(childId)?.name || peopleById.get(childId)?.displayName || childId;
    const allParentIds = [];
    const allRelationIds = [];
    const parentSetIds = new Set(groupEntries.keys());
    for (const entry of groupEntries.values()) {
      allParentIds.push(...Array.from(entry.parentIds));
      allRelationIds.push(...Array.from(entry.relationIds));
    }
    const familyUnitIds = normalizedFamilyUnits
      .filter((unit) => unit.rootParentSetId && parentSetIds.has(unit.rootParentSetId))
      .map((unit) => unit.id);
    pushWarning({
      id: `warning:primary-parent-set:${groupKey}`,
      code: "multiple_primary_parent_sets",
      severity: "warning",
      message: `У ${childName} несколько основных наборов родителей (${describeParentSetTypeLabelRu(
        parentSetType,
      )}).`,
      hint: "Оставьте только один основной набор, а остальные связи переведите в дополнительные.",
      personIds: [childId, ...allParentIds],
      familyUnitIds,
      relationIds: allRelationIds,
    });
  }

  // auto_repaired_parent_link was previously generated for every inferred
  // parent-child link.  The inference itself is correct (we deduce the missing
  // second parent from sibling evidence), so surfacing it as a warning is
  // confusing and actionable only in edge cases.  Users who want to review or
  // override auto-inferred links can do so in the tree editor where all
  // relations are visible.  The warning block is intentionally removed here.

  const pairRelations = new Map();
  for (const relation of normalizedRelations) {
    const leftId = String(relation.person1Id || "").trim();
    const rightId = String(relation.person2Id || "").trim();
    if (!leftId || !rightId) {
      continue;
    }
    const pairKey = buildSortedIdKey([leftId, rightId]);
    if (!pairRelations.has(pairKey)) {
      pairRelations.set(pairKey, []);
    }
    pairRelations.get(pairKey).push(relation);
  }

  const relationCategoryForWarning = (relation) => {
    if (parentIdFromRelation(relation) && childIdFromRelation(relation)) {
      return "parentChild";
    }
    if (isUnionRelation(relation)) {
      return "union";
    }
    if (relation?.relation1to2 === "sibling" || relation?.relation2to1 === "sibling") {
      return "sibling";
    }
    return null;
  };

  for (const [pairKey, pairEntries] of pairRelations.entries()) {
    const categories = new Set(
      pairEntries.map(relationCategoryForWarning).filter(Boolean),
    );
    if (categories.size <= 1) {
      continue;
    }
    const [personAId, personBId] = pairKey.split(":");
    const personAName =
      peopleById.get(personAId)?.name || peopleById.get(personAId)?.displayName || personAId;
    const personBName =
      peopleById.get(personBId)?.name || peopleById.get(personBId)?.displayName || personBId;
    pushWarning({
      id: `warning:conflicting-direct-links:${pairKey}`,
      code: "conflicting_direct_links",
      severity: "warning",
      message: `Между ${personAName} и ${personBName} есть конфликтующие прямые связи.`,
      hint: "Для одной пары людей оставьте только один прямой тип связи: родитель, сиблинг или союз.",
      personIds: [personAId, personBId],
      relationIds: pairEntries.map((relation) => relation.id),
      familyUnitIds: normalizedFamilyUnits
        .filter((unit) =>
          unit.adultIds.includes(personAId) ||
          unit.adultIds.includes(personBId) ||
          unit.childIds.includes(personAId) ||
          unit.childIds.includes(personBId),
        )
        .map((unit) => unit.id),
    });
  }

  return warnings;
}

function resolveBranchBlocks(treeId, persons = [], relations = [], familyUnits = null) {
  const normalizedGraph = normalizeTreeGraph(treeId, persons, relations);
  const resolvedFamilyUnits = Array.isArray(familyUnits)
    ? familyUnits
    : buildFamilyUnits(treeId, normalizedGraph.people, normalizedGraph.relations);
  const peopleById = new Map(
    normalizedGraph.people.map((person) => [String(person.id || "").trim(), person]),
  );
  const adultUnitsByPersonId = new Map();

  for (const unit of resolvedFamilyUnits) {
    for (const adultId of unit.adultIds) {
      if (!adultUnitsByPersonId.has(adultId)) {
        adultUnitsByPersonId.set(adultId, []);
      }
      adultUnitsByPersonId.get(adultId).push(unit.id);
    }
  }

  return resolvedFamilyUnits.map((rootUnit) => {
    const visitedUnitIds = new Set([rootUnit.id]);
    const memberPersonIds = new Set([...rootUnit.adultIds, ...rootUnit.childIds]);
    const queue = [rootUnit.id];

    while (queue.length > 0) {
      const currentUnitId = queue.shift();
      const currentUnit = resolvedFamilyUnits.find((unit) => unit.id === currentUnitId);
      if (!currentUnit) {
        continue;
      }
      for (const childId of currentUnit.childIds) {
        memberPersonIds.add(childId);
        for (const descendantUnitId of adultUnitsByPersonId.get(childId) || []) {
          if (visitedUnitIds.has(descendantUnitId)) {
            continue;
          }
          visitedUnitIds.add(descendantUnitId);
          queue.push(descendantUnitId);
          const descendantUnit = resolvedFamilyUnits.find((unit) => unit.id === descendantUnitId);
          for (const adultId of descendantUnit?.adultIds || []) {
            memberPersonIds.add(adultId);
          }
          for (const descendantChildId of descendantUnit?.childIds || []) {
            memberPersonIds.add(descendantChildId);
          }
        }
      }
    }

    return {
      id: `branch:${rootUnit.id}`,
      rootUnitId: rootUnit.id,
      label: buildBranchLabel({rootUnit, peopleById}),
      memberPersonIds: Array.from(memberPersonIds).sort((left, right) =>
        left.localeCompare(right),
      ),
    };
  });
}

function chooseBranchBlockForPerson(snapshot, personId) {
  if (!snapshot || !personId) {
    return null;
  }

  const normalizedPersonId = String(personId || "").trim();
  const familyUnits = Array.isArray(snapshot.familyUnits) ? snapshot.familyUnits : [];
  const branchBlocks = Array.isArray(snapshot.branchBlocks) ? snapshot.branchBlocks : [];
  const candidateUnit =
    familyUnits.find((unit) => unit.adultIds.includes(normalizedPersonId)) ||
    familyUnits.find(
      (unit) =>
        unit.childIds.includes(normalizedPersonId) && unit.isPrimaryParentSet === true,
    ) ||
    familyUnits.find((unit) => unit.childIds.includes(normalizedPersonId)) ||
    familyUnits.find((unit) => unit.adultIds.includes(normalizedPersonId));
  if (!candidateUnit) {
    return null;
  }
  return (
    branchBlocks.find((branchBlock) => branchBlock.rootUnitId === candidateUnit.id) ||
    null
  );
}

function computeViewerKinships(treeId, persons = [], relations = [], viewerPersonId = null) {
  const normalizedViewerId = String(viewerPersonId || "").trim();
  if (!normalizedViewerId) {
    return [];
  }

  const normalizedGraph = normalizeTreeGraph(treeId, persons, relations);
  const peopleById = new Map(
    normalizedGraph.people.map((person) => [String(person.id || "").trim(), person]),
  );
  if (!peopleById.has(normalizedViewerId)) {
    return [];
  }

  const traversal = buildTraversalGraph(normalizedGraph.relations);
  const pathIndex = buildBestPathIndex(normalizedViewerId, traversal.adjacency);
  const descriptors = [];

  for (const person of normalizedGraph.people) {
    const personId = String(person.id || "").trim();
    if (!personId) {
      continue;
    }

    if (personId === normalizedViewerId) {
      descriptors.push({
        personId,
        primaryRelationLabel: "Это вы",
        isBlood: true,
        alternatePathCount: 0,
        pathSummary: person.name || personId,
        primaryPathPersonIds: [personId],
      });
      continue;
    }

    const directRelation =
      traversal.directRelations.get(buildSortedIdKey([normalizedViewerId, personId])) || null;
    const bloodDescriptor = computeBloodRelationshipDescriptor(
      normalizedViewerId,
      personId,
      traversal.bloodParentsByChild,
      peopleById,
    );
    const affinityDescriptor = computeAffinityRelationshipDescriptor({
      viewerPersonId: normalizedViewerId,
      targetPersonId: personId,
      peopleById,
      parentsByChild: traversal.parentsByChild,
      childrenByParent: traversal.childrenByParent,
      bloodParentsByChild: traversal.bloodParentsByChild,
      bloodChildrenByParent: traversal.bloodChildrenByParent,
      currentUnionPartnersByPerson: traversal.currentUnionPartnersByPerson,
      siblingsByPerson: traversal.siblingsByPerson,
    });
    let primaryRelationLabel = null;
    let isBlood = false;

    if (directRelation) {
      const customDirectLabel = relationCustomLabelForPerson(directRelation, personId);
      const relationType = relationTypeForPerson(directRelation, personId);
      if (customDirectLabel) {
        primaryRelationLabel = customDirectLabel;
        isBlood = false;
      } else if (relationType && relationType !== "other") {
        const shouldPreferAffinityLabel =
          relationType === "parentInLaw" ||
          relationType === "childInLaw" ||
          relationType === "siblingInLaw" ||
          relationType === "inlaw";
        primaryRelationLabel = shouldPreferAffinityLabel
          ? affinityDescriptor?.label || describeDirectRelationLabel({
              relationType,
              gender: person.gender,
              parentSetType: directRelation.parentSetType,
              unionStatus: directRelation.unionStatus,
            })
          : describeDirectRelationLabel({
              relationType,
              gender: person.gender,
              parentSetType: directRelation.parentSetType,
              // B2: бывший союз → метка «бывший муж/жена» вместо текущей.
              unionStatus: directRelation.unionStatus,
            });
        isBlood = isBloodDirectRelationType(
          relationType,
          directRelation.parentSetType,
        );
      }
    }

    if (!primaryRelationLabel && bloodDescriptor?.label) {
      primaryRelationLabel = bloodDescriptor.label;
      isBlood = bloodDescriptor.isBlood;
    }

    if (!primaryRelationLabel && affinityDescriptor?.label) {
      primaryRelationLabel = affinityDescriptor.label;
      isBlood = false;
    }

    const bestCost = pathIndex.costs.get(personId) || null;
    const primaryPathPersonIds = reconstructPersonPath(
      personId,
      pathIndex.predecessors,
    );
    const alternatePathCount = Math.max(
      0,
      (pathIndex.pathCounts.get(personId) || 1) - 1,
    );
    if (!primaryRelationLabel && primaryPathPersonIds.length > 1) {
      const sparsePathDescriptor = buildSparsePathRelationshipDescriptor({
        targetPersonId: personId,
        primaryPathPersonIds,
        directRelations: traversal.directRelations,
        peopleById,
      });
      if (sparsePathDescriptor?.label) {
        primaryRelationLabel = sparsePathDescriptor.label;
        isBlood = sparsePathDescriptor.isBlood === true;
      }
    }
    if (!primaryRelationLabel && bestCost) {
      primaryRelationLabel =
        bestCost.nonBlood === 0 ? "Кровный родственник" : "Родня по браку";
      isBlood = bestCost.nonBlood === 0;
    }

    if (!primaryRelationLabel) {
      continue;
    }

    descriptors.push({
      personId,
      primaryRelationLabel,
      isBlood,
      alternatePathCount,
      pathSummary: buildPathSummary(primaryPathPersonIds, peopleById),
      primaryPathPersonIds,
    });
  }

  return descriptors;
}

function buildTreeGraphSnapshot({
  treeId,
  persons = [],
  relations = [],
  viewerPersonId = null,
}) {
  const normalizedGraph = normalizeTreeGraph(treeId, persons, relations);
  const displayRelations = buildDisplayTreeRelations(
    treeId,
    normalizedGraph.relations,
  );
  const familyUnits = buildFamilyUnits(
    treeId,
    normalizedGraph.people,
    displayRelations,
  );
  const branchBlocks = resolveBranchBlocks(
    treeId,
    normalizedGraph.people,
    displayRelations,
    familyUnits,
  );
  const generationRows = buildGenerationRows(
    normalizedGraph.people,
    displayRelations,
    familyUnits,
  );
  const warnings = buildGraphWarnings({
    persons: normalizedGraph.people,
    relations: displayRelations,
    familyUnits,
  });

  return {
    treeId,
    viewerPersonId: String(viewerPersonId || "").trim() || null,
    people: normalizedGraph.people,
    relations: displayRelations,
    familyUnits,
    viewerDescriptors: computeViewerKinships(
      treeId,
      normalizedGraph.people,
      displayRelations,
      viewerPersonId,
    ),
    branchBlocks,
    generationRows,
    warnings,
  };
}

function fullNameFromPersonInput(person = {}) {
  const parts = [person.lastName, person.firstName, person.middleName]
    .map((value) => String(value || "").trim())
    .filter(Boolean);

  if (parts.length > 0) {
    return parts.join(" ");
  }

  return String(person.name || "").trim();
}

function composeDisplayNameFromProfile(profile = {}) {
  return fullNameFromPersonInput({
    firstName: profile.firstName,
    lastName: profile.lastName,
    middleName: profile.middleName,
    name: profile.displayName,
  });
}

function normalizeNullableString(value) {
  const normalized = String(value || "").trim();
  return normalized ? normalized : null;
}

function createChatDraftRecord({userId, chatId, text}) {
  const timestamp = nowIso();
  return {
    userId: String(userId || "").trim(),
    chatId: String(chatId || "").trim(),
    text: String(text || ""),
    updatedAt: timestamp,
  };
}

function createChatPinRecord({chatId, message, pinnedBy}) {
  const attachments = normalizeMessageAttachments(message);
  return {
    chatId: String(chatId || "").trim(),
    messageId: String(message?.id || "").trim(),
    senderId: String(message?.senderId || "").trim(),
    senderName: String(message?.senderName || "Участник").trim() || "Участник",
    text: String(message?.text || ""),
    attachmentCount: attachments.length,
    pinnedAt: nowIso(),
    pinnedBy: String(pinnedBy || "").trim(),
  };
}

const PERSON_VISIBILITIES = new Set([
  "private",
  "tree",
  "cross-tree",
  "public",
]);

const PERSON_ATTRIBUTE_FIELDS = Object.freeze([
  "name",
  "photo",
  "birthDate",
  "birthYear",
  "places",
  "contacts",
  "notes",
  "relations",
]);

function defaultPersonVisibility({deathDate = null, isAlive = true} = {}) {
  if (normalizeNullableString(deathDate) || isAlive === false) {
    return "tree";
  }
  return "private";
}

function normalizePersonVisibility(value, fallback = "private") {
  const normalized = String(value || "").trim().toLowerCase();
  if (PERSON_VISIBILITIES.has(normalized)) {
    return normalized;
  }
  return PERSON_VISIBILITIES.has(fallback) ? fallback : "private";
}

function defaultAttributeVisibility(field, person = {}) {
  const personDefault = normalizePersonVisibility(
    person.visibility,
    defaultPersonVisibility(person),
  );
  if (field === "contacts") {
    return "private";
  }
  if (personDefault === "public" || personDefault === "cross-tree") {
    return field === "name" || field === "birthYear" || field === "relations"
      ? "cross-tree"
      : "tree";
  }
  return personDefault;
}

function extractBirthYear(value) {
  const normalized = normalizeIsoDate(value);
  return normalized ? normalized.slice(0, 4) : null;
}

function safeMergePersonPreview(person, {contextLabel = null, ownership = "other"} = {}) {
  return {
    name: String(person?.name || "Без имени").trim() || "Без имени",
    birthYear: normalizedBirthYear(person?.birthDate),
    contextLabel: normalizeNullableString(contextLabel),
    // A-copy: чья это карточка — для бейджа «Ваша / Общая / Карточка
    // <имя>», чтобы зритель видел, что ничего чужого не поглощается.
    ownership: ownership === "own" || ownership === "shared" ? ownership : "other",
  };
}

function personStewardUserIds(db, person) {
  const tree = db.trees.find((entry) => entry.id === person?.treeId);
  return normalizeParticipantIds([
    person?.userId,
    person?.creatorId,
    tree?.creatorId,
  ]);
}

function identityStewardUserIds(db, identity = {}) {
  const personIds = normalizeParticipantIds(identity.personIds);
  const stewards = [
    identity.claimedByUserId,
    identity.userId,
    ...(Array.isArray(identity.stewardUserIds) ? identity.stewardUserIds : []),
  ];
  for (const personId of personIds) {
    const person = db.persons.find((entry) => entry.id === personId);
    stewards.push(...personStewardUserIds(db, person));
  }
  return normalizeParticipantIds(stewards);
}

function normalizeProfileContributionPolicy(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return PROFILE_CONTRIBUTION_POLICIES.has(normalized)
    ? normalized
    : "suggestions";
}

function normalizePrimaryTrustedChannel(value) {
  const normalized = normalizeAuthProvider(value);
  if (
    normalized === "google" ||
    normalized === "telegram" ||
    normalized === "vk" ||
    normalized === "max"
  ) {
    return normalized;
  }
  return null;
}

function resolvePersonFamilySummary(person = {}) {
  return (
    normalizeNullableString(person.familySummary) ||
    normalizeNullableString(person.notes) ||
    normalizeNullableString(person.bio)
  );
}

function normalizeProfileContributionFields(fields = {}) {
  if (!fields || typeof fields !== "object" || Array.isArray(fields)) {
    return {};
  }

  const normalized = {};
  for (const fieldName of PROFILE_SUGGESTION_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(fields, fieldName)) {
      continue;
    }

    switch (fieldName) {
      case "birthDate":
        normalized[fieldName] = normalizeIsoDate(fields[fieldName]);
        break;
      case "photoUrl":
        normalized[fieldName] = normalizeNullableString(fields[fieldName]);
        break;
      default:
        normalized[fieldName] = normalizeNullableString(fields[fieldName]) || "";
        break;
    }
  }

  return normalized;
}

function normalizeCountryDialCode(value) {
  const digits = String(value || "").replace(/\D+/g, "");
  return digits ? `+${digits}` : null;
}

function normalizePhoneNumber(value, countryCode = null) {
  const rawValue = String(value || "").trim();
  if (!rawValue) {
    return null;
  }

  const hasLeadingPlus = rawValue.startsWith("+");
  let digits = rawValue.replace(/\D+/g, "");
  if (!digits) {
    return null;
  }

  const normalizedCountryCode = normalizeCountryDialCode(countryCode);
  const countryDigits = normalizedCountryCode
    ? normalizedCountryCode.replace(/\D+/g, "")
    : "";

  if (hasLeadingPlus) {
    return `+${digits}`;
  }

  if (digits.length === 11 && digits.startsWith("8")) {
    digits = `7${digits.slice(1)}`;
  }

  if (digits.length === 10 && countryDigits) {
    digits = `${countryDigits}${digits}`;
  }

  if (digits.length <= 6) {
    return null;
  }

  return `+${digits}`;
}

const SUPPORTED_AUTH_PROVIDERS = new Set([
  "password",
  "google",
  "telegram",
  "vk",
  "max",
]);

function normalizeAuthProvider(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return SUPPORTED_AUTH_PROVIDERS.has(normalized) ? normalized : null;
}

function createPasswordAuthIdentity(email, timestamp = nowIso()) {
  const normalizedEmail = normalizeNullableString(email)?.toLowerCase();
  if (!normalizedEmail) {
    return null;
  }

  return {
    provider: "password",
    providerUserId: normalizedEmail,
    linkedAt: timestamp,
    lastUsedAt: timestamp,
    email: normalizedEmail,
    phoneNumber: null,
    normalizedPhoneNumber: null,
    displayName: null,
    metadata: {},
  };
}

function createAuthHandoffRecord({
  type,
  payload = {},
  userId = null,
  expiresAt = null,
}) {
  const createdAt = nowIso();
  const normalizedExpiresAt =
    normalizeOptionalIsoTimestamp(expiresAt) ||
    new Date(Date.now() + 10 * 60 * 1000).toISOString();
  return {
    code: crypto.randomBytes(24).toString("hex"),
    type: normalizeNullableString(type),
    userId: normalizeNullableString(userId),
    payload:
      payload && typeof payload === "object" ? structuredClone(payload) : {},
    createdAt,
    expiresAt: normalizedExpiresAt,
  };
}

function normalizeAuthIdentityRecord(identity) {
  const provider = normalizeAuthProvider(identity?.provider);
  const rawProviderUserId = String(identity?.providerUserId || "").trim();
  if (!provider || !rawProviderUserId) {
    return null;
  }

  const normalizedEmail = normalizeNullableString(identity?.email)?.toLowerCase();
  const phoneNumber = normalizeNullableString(identity?.phoneNumber);
  const normalizedPhoneNumber = normalizePhoneNumber(
    identity?.normalizedPhoneNumber || phoneNumber,
  );
  const providerUserId =
    provider === "password" && normalizedEmail
      ? normalizedEmail
      : rawProviderUserId;

  return {
    provider,
    providerUserId,
    linkedAt: normalizeOptionalIsoTimestamp(identity?.linkedAt) || nowIso(),
    lastUsedAt: normalizeOptionalIsoTimestamp(identity?.lastUsedAt),
    email: normalizedEmail,
    phoneNumber,
    normalizedPhoneNumber,
    displayName: normalizeNullableString(identity?.displayName),
    metadata:
      identity?.metadata && typeof identity.metadata === "object"
        ? structuredClone(identity.metadata)
        : {},
  };
}

function listAuthIdentitiesForUser(user) {
  const identities = [];
  const seenKeys = new Set();

  const addIdentity = (identity) => {
    const normalizedIdentity = normalizeAuthIdentityRecord(identity);
    if (!normalizedIdentity) {
      return;
    }

    const identityKey =
      `${normalizedIdentity.provider}:${normalizedIdentity.providerUserId}`;
    if (seenKeys.has(identityKey)) {
      return;
    }

    seenKeys.add(identityKey);
    identities.push(normalizedIdentity);
  };

  if (Array.isArray(user?.authIdentities)) {
    for (const identity of user.authIdentities) {
      addIdentity(identity);
    }
  }

  if (user?.passwordHash && user?.email) {
    addIdentity(createPasswordAuthIdentity(user.email, user.createdAt || nowIso()));
  }

  return identities.sort((left, right) => {
    if (left.provider === "password" && right.provider !== "password") {
      return -1;
    }
    if (right.provider === "password" && left.provider !== "password") {
      return 1;
    }
    return String(left.linkedAt).localeCompare(String(right.linkedAt));
  });
}

function deriveProviderIdsForUser(user) {
  const providerIds = Array.isArray(user?.providerIds)
    ? user.providerIds
      .map((value) => normalizeAuthProvider(value))
      .filter(Boolean)
    : [];

  for (const identity of listAuthIdentitiesForUser(user)) {
    providerIds.push(identity.provider);
  }

  if (user?.passwordHash) {
    providerIds.push("password");
  }

  return Array.from(new Set(providerIds));
}

function cloneUserWithAuthState(user) {
  const clonedUser = structuredClone(user);
  clonedUser.authIdentities = listAuthIdentitiesForUser(clonedUser);
  clonedUser.providerIds = deriveProviderIdsForUser(clonedUser);
  return clonedUser;
}

function normalizeIsoDate(value) {
  if (!value) {
    return null;
  }

  const parsed = new Date(String(value));
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }

  return parsed.toISOString();
}

// F5: точность даты — «знаю только год». Хранение остаётся ISO-датой
// (01.01.года), правда живёт во флаге; всё, кроме «yearOnly», схлопываем
// в дефолт «exact», чтобы мусор с клиента не плодил третьи состояния.
function normalizeDatePrecision(value) {
  return String(value || "").trim() === "yearOnly" ? "yearOnly" : "exact";
}

function createTreeInvitationRecord({
  treeId,
  userId,
  addedBy = null,
  relationToTree = null,
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    treeId,
    userId,
    role: "pending",
    addedAt: timestamp,
    addedBy,
    acceptedAt: null,
    relationToTree: normalizeNullableString(relationToTree),
  };
}

function normalizePersonMediaType(type, contentType = null) {
  const normalizedType = String(type || "").trim().toLowerCase();
  if (normalizedType === "image" || normalizedType === "video") {
    return normalizedType;
  }

  const normalizedContentType = String(contentType || "")
    .trim()
    .toLowerCase();
  if (normalizedContentType.startsWith("video/")) {
    return "video";
  }

  return "image";
}

function normalizePersonPhotoGallery(photoGallery, {
  photoUrl = null,
  primaryPhotoUrl = null,
} = {}) {
  const entries = [];
  const seenIds = new Set();
  const seenUrls = new Set();

  const addEntry = (rawEntry) => {
    if (typeof rawEntry === "string") {
      rawEntry = {url: rawEntry};
    }

    if (!rawEntry || typeof rawEntry !== "object") {
      return;
    }

    const normalizedUrl = normalizeNullableString(rawEntry.url);
    if (!normalizedUrl || seenUrls.has(normalizedUrl)) {
      return;
    }

    let mediaId = normalizeNullableString(rawEntry.id);
    if (mediaId && seenIds.has(mediaId)) {
      mediaId = null;
    }
    if (!mediaId) {
      mediaId = crypto.randomUUID();
    }

    seenIds.add(mediaId);
    seenUrls.add(normalizedUrl);

    const createdAt =
      normalizeOptionalIsoTimestamp(rawEntry.createdAt) || nowIso();
    const updatedAt =
      normalizeOptionalIsoTimestamp(rawEntry.updatedAt) || createdAt;

    entries.push({
      id: mediaId,
      url: normalizedUrl,
      thumbnailUrl: normalizeNullableString(rawEntry.thumbnailUrl),
      type: normalizePersonMediaType(
        rawEntry.type || rawEntry.mediaType,
        rawEntry.contentType,
      ),
      contentType: normalizeNullableString(rawEntry.contentType),
      caption: normalizeNullableString(rawEntry.caption),
      createdAt,
      updatedAt,
      isPrimary: rawEntry.isPrimary === true,
    });
  };

  if (Array.isArray(photoGallery)) {
    for (const entry of photoGallery) {
      addEntry(entry);
    }
  }

  const requestedPrimary =
    normalizeNullableString(primaryPhotoUrl) ||
    normalizeNullableString(photoUrl) ||
    entries.find((entry) => entry.isPrimary === true)?.url ||
    null;

  if (requestedPrimary && !seenUrls.has(requestedPrimary)) {
    addEntry({url: requestedPrimary, isPrimary: true});
  }

  const resolvedPrimary =
    requestedPrimary && seenUrls.has(requestedPrimary)
      ? requestedPrimary
      : entries[0]?.url || null;

  if (resolvedPrimary) {
    const primaryIndex = entries.findIndex((entry) => entry.url === resolvedPrimary);
    if (primaryIndex > 0) {
      const [primaryEntry] = entries.splice(primaryIndex, 1);
      entries.unshift(primaryEntry);
    }
  }

  for (const entry of entries) {
    entry.isPrimary = resolvedPrimary !== null && entry.url === resolvedPrimary;
  }

  return {
    primaryPhotoUrl: resolvedPrimary,
    photoUrl: resolvedPrimary,
    photoGallery: entries,
  };
}

// SPEED-8b: общие для блоба и таблиц правила ретенции.
function stripTreeChangeRecordDetails(record, {cutoffTs, dryRun = false}) {
  if (!record || typeof record !== "object") return false;
  if (typeof record.type === "string" && record.type.startsWith("article.")) {
    return false;
  }
  const createdTs = record.createdAt ? Date.parse(record.createdAt) : NaN;
  if (!Number.isFinite(createdTs) || createdTs >= cutoffTs) return false;
  const details = record.details;
  if (!details || typeof details !== "object") return false;
  let stripped = false;
  for (const heavyKey of ["before", "after", "mergedFrom"]) {
    if (Object.prototype.hasOwnProperty.call(details, heavyKey)) {
      if (!dryRun) delete details[heavyKey];
      stripped = true;
    }
  }
  return stripped;
}

function isHardDeleteAuditEntryExpired(entry, cutoffTs) {
  const hardDeletedTs = entry?.hardDeletedAt
    ? Date.parse(entry.hardDeletedAt)
    : NaN;
  return Number.isFinite(hardDeletedTs) && hardDeletedTs < cutoffTs;
}

function createTreeChangeRecord({
  treeId,
  actorId = null,
  type,
  personId = null,
  personIds = [],
  relationId = null,
  mediaId = null,
  details = {},
}) {
  const normalizedPersonIds = Array.from(
    new Set(
      [
        personId,
        ...(Array.isArray(personIds) ? personIds : []),
      ]
        .map((value) => String(value || "").trim())
        .filter(Boolean),
    ),
  );

  return {
    id: crypto.randomUUID(),
    treeId,
    actorId: normalizeNullableString(actorId),
    type: String(type || "unknown").trim() || "unknown",
    personId: normalizeNullableString(personId) || normalizedPersonIds[0] || null,
    personIds: normalizedPersonIds,
    relationId: normalizeNullableString(relationId),
    mediaId: normalizeNullableString(mediaId),
    createdAt: nowIso(),
    details:
      details && typeof details === "object" ? structuredClone(details) : {},
  };
}

// ===== Profile Phase 1 (2026-05-28): article-block helpers =====
//
// Blocks are validated-but-flexible: the store enforces the per-type
// content shape (so the entity stays stable across Phases 2-6) but
// stores the normalized object as-is. Media referenced by url —
// there is no media table (mirrors photoGallery). Inline rich text +
// родственник-mentions use structured spans so mention display names
// can auto-sync from personId at render time (proposal §4.9).

const ARTICLE_BLOCK_TYPES = Object.freeze([
  "paragraph",
  "header",
  "photo",
  "gallery",
  "audio",
  "quote",
  "divider",
]);

// Normalize one inline span inside a paragraph block. Drops malformed
// spans rather than throwing — a stray span shouldn't reject a whole
// save. Recognized: plain text, родственник-mention (personId ref +
// fallbackText for offline render), external link.
function normalizeArticleSpan(rawSpan) {
  if (typeof rawSpan === "string") {
    return rawSpan ? {text: rawSpan} : null;
  }
  if (!rawSpan || typeof rawSpan !== "object") return null;
  const type = normalizeNullableString(rawSpan.type);
  if (type === "mention") {
    const personId = normalizeNullableString(rawSpan.personId);
    if (!personId) return null;
    return {
      type: "mention",
      personId,
      fallbackText: String(rawSpan.fallbackText || rawSpan.text || "").trim(),
    };
  }
  if (type === "link") {
    const href = normalizeNullableString(rawSpan.href);
    if (!href) return null;
    return {
      type: "link",
      href,
      text: String(rawSpan.text || href).trim(),
    };
  }
  // Plain text span (default).
  const text = typeof rawSpan.text === "string" ? rawSpan.text : "";
  return {text};
}

function normalizeArticleSpans(rawSpans) {
  if (!Array.isArray(rawSpans)) return [];
  return rawSpans.map(normalizeArticleSpan).filter(Boolean);
}

function normalizeArticleMediaItem(rawItem) {
  if (typeof rawItem === "string") {
    rawItem = {url: rawItem};
  }
  if (!rawItem || typeof rawItem !== "object") return null;
  const url = normalizeNullableString(rawItem.url);
  if (!url) return null;
  const accuracy = normalizeNullableString(rawItem.dateTakenAccuracy);
  return {
    url,
    thumbnailUrl: normalizeNullableString(rawItem.thumbnailUrl),
    caption: normalizeNullableString(rawItem.caption),
    dateTaken: normalizeOptionalIsoTimestamp(rawItem.dateTaken) || null,
    dateTakenAccuracy:
      accuracy === "exact" || accuracy === "year" || accuracy === "decade"
        ? accuracy
        : null,
  };
}

// Validate + normalize content for a block type. Throws
// INVALID_BLOCK_TYPE / INVALID_BLOCK_CONTENT (mapped to 400 in routes).
function normalizeArticleBlockContent(type, rawContent) {
  const normalizedType = normalizeNullableString(type);
  if (!normalizedType || !ARTICLE_BLOCK_TYPES.includes(normalizedType)) {
    throw new Error("INVALID_BLOCK_TYPE");
  }
  const content =
    rawContent && typeof rawContent === "object" ? rawContent : {};

  switch (normalizedType) {
    case "paragraph":
      return {spans: normalizeArticleSpans(content.spans)};
    case "header": {
      const level = Number(content.level);
      return {
        text: String(content.text || "").trim(),
        level: level === 1 ? 1 : 2,
      };
    }
    case "photo": {
      const item = normalizeArticleMediaItem(content);
      if (!item) throw new Error("INVALID_BLOCK_CONTENT");
      return item;
    }
    case "gallery": {
      const items = Array.isArray(content.items)
        ? content.items.map(normalizeArticleMediaItem).filter(Boolean)
        : [];
      if (items.length === 0) throw new Error("INVALID_BLOCK_CONTENT");
      return {items};
    }
    case "audio": {
      const url = normalizeNullableString(content.url);
      if (!url) throw new Error("INVALID_BLOCK_CONTENT");
      const durationSec = Number(content.durationSec);
      return {
        url,
        durationSec:
          Number.isFinite(durationSec) && durationSec > 0
            ? Math.round(durationSec)
            : null,
        transcript: normalizeNullableString(content.transcript),
      };
    }
    case "quote":
      return {
        text: String(content.text || "").trim(),
        attribution: normalizeNullableString(content.attribution),
      };
    case "divider":
    default:
      return {};
  }
}

function createArticleBlockRecord({type, content, actorUserId}) {
  const createdAt = nowIso();
  const author = normalizeNullableString(actorUserId);
  return {
    id: crypto.randomUUID(),
    type: normalizeNullableString(type),
    content: normalizeArticleBlockContent(type, content),
    createdByUserId: author,
    authorUserId: author,
    createdAt,
    updatedAt: createdAt,
  };
}

function buildPersonRecord({
  treeId,
  creatorId,
  userId = null,
  identityId = null,
  personData = {},
}) {
  const createdAt = nowIso();
  const birthDate = normalizeIsoDate(personData.birthDate);
  const deathDate = normalizeIsoDate(personData.deathDate);
  const familySummary = resolvePersonFamilySummary(personData);
  const photoState = normalizePersonPhotoGallery(personData.photoGallery, {
    photoUrl: personData.photoUrl,
    primaryPhotoUrl: personData.primaryPhotoUrl,
  });

  return {
    id: crypto.randomUUID(),
    treeId,
    userId,
    identityId: normalizeNullableString(identityId),
    name: fullNameFromPersonInput(personData),
    maidenName: normalizeNullableString(personData.maidenName),
    photoUrl: photoState.photoUrl,
    primaryPhotoUrl: photoState.primaryPhotoUrl,
    photoGallery: photoState.photoGallery,
    gender: String(personData.gender || "unknown"),
    birthDate,
    // F5: «знаю только год» — дата хранится как 01.01.года, точность
    // отдельным флагом.
    birthDatePrecision: normalizeDatePrecision(personData.birthDatePrecision),
    birthPlace: normalizeNullableString(personData.birthPlace),
    deathDate,
    deathDatePrecision: normalizeDatePrecision(personData.deathDatePrecision),
    deathPlace: normalizeNullableString(personData.deathPlace),
    familySummary,
    bio: normalizeNullableString(personData.bio),
    isAlive: deathDate === null,
    visibility: normalizePersonVisibility(
      personData.visibility,
      defaultPersonVisibility({deathDate, isAlive: deathDate === null}),
    ),
    creatorId,
    createdAt,
    updatedAt: createdAt,
    notes: normalizeNullableString(personData.notes),
  };
}

// Phase 0 cross-tree picker: when a user picks an existing relative
// from one of their other trees, the new person record on the
// target tree pre-fills any fields the caller didn't supply with
// values from the source. Caller-supplied fields always win — we
// only fill blanks. This is a CONSERVATIVE merge: we only forward
// fields that describe the human (name, birth, photos, gender),
// never tree-local stuff (visibility, notes), since those are a
// per-tree editorial decision.
function mergePersonDataFromSource(personData, sourcePerson) {
  if (!sourcePerson) {
    return personData;
  }
  const merged = {...personData};

  function fillIfBlank(field) {
    const supplied = merged[field];
    const isBlank =
      supplied === undefined ||
      supplied === null ||
      (typeof supplied === "string" && supplied.trim() === "");
    if (isBlank && sourcePerson[field] != null && sourcePerson[field] !== "") {
      merged[field] = sourcePerson[field];
    }
  }

  // Source persons store a composed `name` (no separate firstName /
  // lastName / middleName), so forwarding the composed name is the
  // correct fallback — fullNameFromPersonInput consumes either form.
  const callerProvidedAnyNamePart =
    Boolean(merged.firstName) ||
    Boolean(merged.lastName) ||
    Boolean(merged.middleName) ||
    Boolean(merged.name);
  if (!callerProvidedAnyNamePart && sourcePerson.name) {
    merged.name = sourcePerson.name;
  }

  fillIfBlank("maidenName");
  fillIfBlank("gender");
  fillIfBlank("birthDate");
  // F5: точность даты едет вместе с датой из карточки-источника.
  if (merged.birthDate === sourcePerson.birthDate) {
    fillIfBlank("birthDatePrecision");
  }
  fillIfBlank("birthPlace");
  fillIfBlank("deathDate");
  if (merged.deathDate === sourcePerson.deathDate) {
    fillIfBlank("deathDatePrecision");
  }
  fillIfBlank("deathPlace");
  fillIfBlank("photoUrl");
  fillIfBlank("primaryPhotoUrl");
  if (
    !merged.photoGallery &&
    Array.isArray(sourcePerson.photoGallery) &&
    sourcePerson.photoGallery.length > 0
  ) {
    merged.photoGallery = sourcePerson.photoGallery;
  }

  return merged;
}

function createPersonIdentityRecord({
  id = crypto.randomUUID(),
  userId = null,
  personIds = [],
} = {}) {
  const createdAt = nowIso();
  const normalizedUserId = normalizeNullableString(userId);
  return {
    id,
    userId: normalizedUserId,
    claimedByUserId: normalizedUserId,
    primaryPersonId: normalizeParticipantIds(personIds)[0] || null,
    personIds: normalizeParticipantIds(personIds),
    isLiving: true,
    isPublicDiscoverable: false,
    stewardUserIds: normalizedUserId ? [normalizedUserId] : [],
    mergedInto: null,
    createdAt,
    updatedAt: createdAt,
  };
}

function createPersonAttributeRecord({
  identityId,
  field,
  value = null,
  sourcePersonId = null,
  sourceUserId = null,
  visibility = "private",
  confidence = 1,
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    identityId,
    field,
    value,
    sourcePersonId: normalizeNullableString(sourcePersonId),
    sourceUserId: normalizeNullableString(sourceUserId),
    confidence: Number.isFinite(Number(confidence)) ? Number(confidence) : 1,
    visibility: normalizePersonVisibility(visibility),
    status: "active",
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function personAttributeValue(person, field) {
  switch (field) {
    case "name":
      return normalizeNullableString(person?.name);
    case "photo":
      return normalizeNullableString(person?.primaryPhotoUrl || person?.photoUrl);
    case "birthDate":
      return normalizeNullableString(person?.birthDate);
    case "birthYear":
      return extractBirthYear(person?.birthDate);
    case "places":
      return normalizeNullableString(
        [person?.birthPlace, person?.deathPlace].filter(Boolean).join(" · "),
      );
    case "contacts":
      return normalizeNullableString(person?.userId);
    case "notes":
      return normalizeNullableString(
        person?.familySummary || person?.notes || person?.bio,
      );
    case "relations":
      return normalizeNullableString(person?.treeId);
    default:
      return null;
  }
}

function upsertPersonAttributesForPerson(db, person, sourceUserId = null) {
  if (!person?.identityId) {
    return false;
  }
  db.personAttributes = Array.isArray(db.personAttributes)
    ? db.personAttributes
    : [];

  let changed = false;
  for (const field of PERSON_ATTRIBUTE_FIELDS) {
    const value = personAttributeValue(person, field);
    const existing = db.personAttributes.find(
      (entry) =>
        entry.identityId === person.identityId &&
        entry.sourcePersonId === person.id &&
        entry.field === field &&
        entry.status !== "archived",
    );
    if (!value && !existing) {
      continue;
    }

    const visibility = existing?.visibility || defaultAttributeVisibility(field, person);
    if (!existing) {
      db.personAttributes.push(
        createPersonAttributeRecord({
          identityId: person.identityId,
          field,
          value,
          sourcePersonId: person.id,
          sourceUserId: sourceUserId || person.creatorId || person.userId,
          visibility,
        }),
      );
      changed = true;
      continue;
    }

    if (existing.value !== value || existing.visibility !== visibility) {
      existing.value = value;
      existing.visibility = normalizePersonVisibility(visibility);
      existing.updatedAt = nowIso();
      changed = true;
    }
  }
  return changed;
}

function pickPersonValue(currentValue, fallbackValue) {
  if (currentValue === null || currentValue === undefined) {
    return fallbackValue ?? currentValue;
  }

  if (typeof currentValue === "string" && currentValue.trim().length === 0) {
    return fallbackValue ?? currentValue;
  }

  return currentValue;
}

function relationDedupKey(relation) {
  const leftId = String(relation.person1Id || "");
  const rightId = String(relation.person2Id || "");
  const leftToRight = String(relation.relation1to2 || "other");
  const rightToLeft = String(relation.relation2to1 || "other");

  if (leftId <= rightId) {
    return `${relation.treeId}:${leftId}:${rightId}:${leftToRight}:${rightToLeft}`;
  }

  return `${relation.treeId}:${rightId}:${leftId}:${rightToLeft}:${leftToRight}`;
}

// scrypt is memory-hard by design — that's why it's a good password
// KDF, but the synchronous variant blocks the Node event loop for
// 100-200 ms on commodity hardware. Under any concurrent login load
// `scryptSync` would queue every other request behind the hash. The
// async variant runs on Node's libuv thread pool and lets the loop
// keep handling other connections. Wrap it once so the rest of the
// auth path stays a clean async/await chain.
function hashPasswordAsync(
  password,
  salt = crypto.randomBytes(16).toString("hex"),
) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, (err, derivedKey) => {
      if (err) {
        reject(err);
        return;
      }
      resolve({
        salt,
        passwordHash: derivedKey.toString("hex"),
      });
    });
  });
}

// Sync wrapper kept for migration code paths that already run inside
// a transaction and can't easily go async. New code should prefer
// `hashPasswordAsync`.
function hashPassword(password, salt = crypto.randomBytes(16).toString("hex")) {
  const derivedKey = crypto.scryptSync(password, salt, 64).toString("hex");
  return {
    salt,
    passwordHash: derivedKey,
  };
}

function verifyPasswordAsync(password, user) {
  if (!user?.passwordHash || !user?.passwordSalt) {
    return Promise.resolve(false);
  }

  return new Promise((resolve, reject) => {
    crypto.scrypt(password, user.passwordSalt, 64, (err, derivedKey) => {
      if (err) {
        reject(err);
        return;
      }
      const userHash = Buffer.from(user.passwordHash, "hex");
      // timingSafeEqual REQUIRES same-length buffers — guard so a
      // malformed stored hash can't crash the auth path. Different
      // lengths obviously don't match anyway.
      if (derivedKey.length !== userHash.length) {
        resolve(false);
        return;
      }
      resolve(crypto.timingSafeEqual(derivedKey, userHash));
    });
  });
}

function verifyPassword(password, user) {
  if (!user?.passwordHash || !user?.passwordSalt) {
    return false;
  }

  const derivedKey = crypto
    .scryptSync(password, user.passwordSalt, 64)
    .toString("hex");

  return crypto.timingSafeEqual(
    Buffer.from(derivedKey, "hex"),
    Buffer.from(user.passwordHash, "hex"),
  );
}

// Static dummy salt + zero-buffer hash used when authenticate() is
// called against an email that doesn't exist. Without it the no-user
// path returns in microseconds while the user-found path takes
// hundreds of ms for scrypt — the timing difference lets an attacker
// enumerate which emails are registered. Running a real scrypt against
// this constant salt takes the same time as a real verify, and
// timingSafeEqual keeps even that comparison constant-time. The
// result is always discarded; we never resolve `true`.
const _dummyAuthSalt = "rodnya-fake-salt-for-timing-equalization-only";
const _dummyAuthHash = Buffer.alloc(64);
function dummyVerifyForTimingParity(password) {
  return new Promise((resolve) => {
    crypto.scrypt(password, _dummyAuthSalt, 64, (err, derivedKey) => {
      if (err) {
        resolve(false);
        return;
      }
      try {
        crypto.timingSafeEqual(derivedKey, _dummyAuthHash);
      } catch (_) {
        // Ignore — only here for timing parity.
      }
      resolve(false);
    });
  });
}

// B3 (ревью): _materializeInferredParentLinks УДАЛЁН. Он персистил
// sibling-выведенные родительские связи как реальные biological-записи на
// каждой мутации (по всем деревьям), используя любой союз (friend/ex/past)
// мимо B3-гардов — это корраптило сводные семьи (записывало постороннего
// биологическим родителем ребёнка из прошлого союза). Вывод остаётся
// display-only в buildDisplayTreeRelations; как факт его не фиксируем.

function insertDescendingLimited(items, entry, compareEntries, limit) {
  if (!Number.isFinite(limit) || limit <= 0) {
    return;
  }

  let insertIndex = items.findIndex(
    (existingEntry) => compareEntries(entry, existingEntry) < 0,
  );
  if (insertIndex < 0) {
    insertIndex = items.length;
  }

  if (insertIndex >= limit && items.length >= limit) {
    return;
  }

  items.splice(insertIndex, 0, entry);
  if (items.length > limit) {
    items.length = limit;
  }
}

function compareChatMessagesDescending(left, right) {
  const timestampCompare = String(right?.timestamp || "").localeCompare(
    String(left?.timestamp || ""),
  );
  if (timestampCompare !== 0) {
    return timestampCompare;
  }

  return String(right?.id || "").localeCompare(String(left?.id || ""));
}

function normalizeChatSearchQuery(value) {
  return String(value || "")
    .trim()
    .toLocaleLowerCase("ru-RU")
    .split(/\s+/)
    .map((term) => term.trim())
    .filter(Boolean)
    .slice(0, 8);
}

function normalizeSearchText(value) {
  return String(value || "").toLocaleLowerCase("ru-RU");
}

function chatMessageSearchHaystack(message) {
  const attachmentText = normalizeMessageAttachments(message)
    .map((attachment) =>
      [
        attachment.fileName,
        attachment.mimeType,
        attachment.presentation === "voice_note" ? "голосовое" : "",
      ]
        .map((value) => String(value || "").trim())
        .filter(Boolean)
        .join(" "),
    )
    .filter(Boolean)
    .join(" ");
  return normalizeSearchText(
    [message?.text, message?.senderName, attachmentText]
      .map((value) => String(value || "").trim())
      .filter(Boolean)
      .join("\n"),
  );
}

function buildChatSearchSnippet(message, terms) {
  const text = String(message?.text || "").trim();
  const fallback = normalizeMessageAttachments(message).some(
    (attachment) => attachment.presentation === "voice_note",
  )
    ? "Голосовое сообщение"
    : String(message?.senderName || "Сообщение").trim();
  const source = text || fallback;
  if (!source) {
    return "";
  }

  const normalizedSource = normalizeSearchText(source);
  const firstIndex = terms
    .map((term) => normalizedSource.indexOf(term))
    .filter((index) => index >= 0)
    .sort((left, right) => left - right)[0];
  if (!Number.isFinite(firstIndex)) {
    return source.length > 180 ? `${source.slice(0, 179).trimEnd()}…` : source;
  }

  const start = Math.max(0, firstIndex - 70);
  const end = Math.min(source.length, firstIndex + 110);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < source.length ? "…" : "";
  return `${prefix}${source.slice(start, end).trim()}${suffix}`;
}

function normalizeReactionEmoji(value) {
  const emoji = String(value || "").trim();
  if (!emoji) {
    return null;
  }
  return Array.from(emoji).slice(0, 16).join("");
}

function ensureMessageReactions(db) {
  db.messageReactions = Array.isArray(db.messageReactions)
    ? db.messageReactions
    : [];
  return db.messageReactions;
}

function ensureChatPins(db) {
  db.chatPins = Array.isArray(db.chatPins) ? db.chatPins : [];
  return db.chatPins;
}

function aggregateMessageReactions(db, messageId) {
  const normalizedMessageId = String(messageId || "").trim();
  if (!normalizedMessageId) {
    return [];
  }

  const grouped = new Map();
  for (const reaction of ensureMessageReactions(db)) {
    if (String(reaction?.messageId || "").trim() !== normalizedMessageId) {
      continue;
    }
    const emoji = normalizeReactionEmoji(reaction?.emoji);
    const userId = String(reaction?.userId || "").trim();
    if (!emoji || !userId) {
      continue;
    }
    const existing = grouped.get(emoji) || {
      emoji,
      userIds: [],
      count: 0,
    };
    if (!existing.userIds.includes(userId)) {
      existing.userIds.push(userId);
      existing.count = existing.userIds.length;
    }
    grouped.set(emoji, existing);
  }

  return Array.from(grouped.values()).sort((left, right) =>
    String(left.emoji || "").localeCompare(String(right.emoji || "")),
  );
}

function attachMessageReactions(db, message) {
  const clone = structuredClone(message);
  clone.reactions = aggregateMessageReactions(db, clone.id);
  return clone;
}

// Posts and comments share the reaction shape with chat messages but
// live in separate pools so unrelated chat-side logic (delivery /
// read-receipts / push) can't cross over by accident.

function ensurePostReactions(db) {
  db.postReactions = Array.isArray(db.postReactions) ? db.postReactions : [];
  return db.postReactions;
}

function ensurePostCommentReactions(db) {
  db.postCommentReactions = Array.isArray(db.postCommentReactions)
    ? db.postCommentReactions
    : [];
  return db.postCommentReactions;
}

function _aggregateReactionsByKey(entries, keyField, targetId) {
  const normalizedTarget = String(targetId || "").trim();
  if (!normalizedTarget) {
    return [];
  }
  const grouped = new Map();
  for (const reaction of entries) {
    if (String(reaction?.[keyField] || "").trim() !== normalizedTarget) {
      continue;
    }
    const emoji = normalizeReactionEmoji(reaction?.emoji);
    const userId = String(reaction?.userId || "").trim();
    if (!emoji || !userId) {
      continue;
    }
    const existing = grouped.get(emoji) || {
      emoji,
      userIds: [],
      count: 0,
    };
    if (!existing.userIds.includes(userId)) {
      existing.userIds.push(userId);
      existing.count = existing.userIds.length;
    }
    grouped.set(emoji, existing);
  }
  return Array.from(grouped.values()).sort((left, right) =>
    String(left.emoji || "").localeCompare(String(right.emoji || "")),
  );
}

function aggregatePostReactions(db, postId) {
  return _aggregateReactionsByKey(ensurePostReactions(db), "postId", postId);
}

function aggregatePostCommentReactions(db, commentId) {
  return _aggregateReactionsByKey(
    ensurePostCommentReactions(db),
    "commentId",
    commentId,
  );
}

function attachPostReactions(db, post) {
  if (!post) return post;
  const clone = structuredClone(post);
  clone.reactions = aggregatePostReactions(db, clone.id);
  return clone;
}

function attachCommentReactions(db, comment) {
  if (!comment) return comment;
  const clone = structuredClone(comment);
  clone.reactions = aggregatePostCommentReactions(db, clone.id);
  return clone;
}

// SPEED-9 D: общий хвост listPostComments/listPostCommentsForPosts —
// сортировка + hydrate authorPhotoUrl + реакции. Вынесено, чтобы
// батч-версия (один _read() на страницу постов) давала БУКВАЛЬНО ту же
// форму на каждый пост, что и одиночный вызов — не две копии одной и
// той же логики, расходящиеся со временем.
function buildUsersByIdMap(db) {
  return new Map(
    (Array.isArray(db.users) ? db.users : []).map((user) => [
      String(user?.id || "").trim(),
      user,
    ]),
  );
}

function hydrateAndSortPostComments(db, entries, usersById) {
  return entries
    .slice()
    .sort((left, right) =>
      String(left.createdAt || "").localeCompare(String(right.createdAt || "")),
    )
    .map((entry) => {
      const hydrated = structuredClone(entry);
      if (!String(hydrated.authorPhotoUrl || "").trim()) {
        const author = usersById.get(String(hydrated.authorId || "").trim());
        const photoUrl = author?.profile?.photoUrl;
        if (String(photoUrl || "").trim()) {
          hydrated.authorPhotoUrl = String(photoUrl).trim();
        }
      }
      return attachCommentReactions(db, hydrated);
    });
}

function ensureStoryReactions(db) {
  db.storyReactions = Array.isArray(db.storyReactions) ? db.storyReactions : [];
  return db.storyReactions;
}

function aggregateStoryReactions(db, storyId) {
  return _aggregateReactionsByKey(ensureStoryReactions(db), "storyId", storyId);
}

function attachStoryReactions(db, story) {
  if (!story) return story;
  const clone = structuredClone(story);
  clone.reactions = aggregateStoryReactions(db, clone.id);
  return clone;
}

/// Resolve the user's primary person-card in a given tree. Smart-set
/// computation needs an anchor on the graph — we look for the first
/// person on the tree whose `userId` matches. Returns null if the
/// user isn't on the tree at all (guest, viewer, or hasn't claimed
/// their card yet).
function _resolveAnchorPerson(db, treeId, userId) {
  const normalizedUserId = String(userId || "").trim();
  if (!normalizedUserId) return null;
  return (
    (Array.isArray(db.persons) ? db.persons : []).find(
      (person) => person.treeId === treeId && person.userId === normalizedUserId,
    ) || null
  );
}

function isMessageReadByUser(message, userId) {
  const readBy = normalizeParticipantIds(message?.readBy);
  if (readBy.length > 0) {
    return readBy.includes(userId);
  }
  return message?.isRead === true;
}

class FileStore {
  constructor(dataPath) {
    this.dataPath = dataPath;
    this.storageMode = "file-store";
    this.storageTarget = dataPath;
    this._writeQueue = Promise.resolve();
    // Serializes the WHOLE read-modify-write of every _mutate() call so no two
    // mutations interleave (store-wide lost-update fix). Distinct from
    // _writeQueue, which only serializes the persist half.
    this._mutateQueue = Promise.resolve();
    this._sessionTouchCache = new Map();
    this._sessionCache = new Map();
    this._userCache = new Map();
    this._onboardingIncompleteCache = new Map();
    this._initializePromise = null;
  }

  async initialize() {
    if (!this._initializePromise) {
      this._initializePromise = this._initializeFileStore();
    }
    return this._initializePromise;
  }

  async _initializeFileStore() {
    await fs.mkdir(path.dirname(this.dataPath), {recursive: true});

    try {
      await fs.access(this.dataPath);
    } catch {
      await fs.writeFile(
        this.dataPath,
        JSON.stringify(EMPTY_DB, null, 2),
        "utf8",
      );
      return;
    }

    const raw = await fs.readFile(this.dataPath, "utf8");
    const parsed = JSON.parse(raw);
    const normalized = normalizeDbState(parsed);
    const migration = backfillPersonIdentities(normalized);
    const migratedSnapshot = migration.snapshot;
    // Phase 3.1: one-shot trees → graph + branches migration.
    // Idempotent (skips on `migrationStatus.treesToGraph ===
    // "complete"`), so re-runs after the initial fill are free.
    // Fires AFTER backfillPersonIdentities so every person has an
    // identityId and the graph rows can dedupe by it. The legacy
    // collections stay in place — Phase 3.1c will wire reads/
    // writes to the graph behind the existing /v1/trees/:treeId
    // routes; until then this just stages the data side ready
    // for the next layer.
    const graphMigration = migrateTreesToGraphAndBranches(migratedSnapshot);
    const defaultCirclesChanged = ensureCirclesForAllTrees(migratedSnapshot);
    if (
      migration.changed ||
      defaultCirclesChanged ||
      graphMigration.changed
    ) {
      const directoryPath = path.dirname(this.dataPath);
      const tempPath = path.join(
        directoryPath,
        `${path.basename(this.dataPath)}.${crypto.randomUUID()}.tmp`,
      );
      await fs.writeFile(
        tempPath,
        JSON.stringify(migratedSnapshot, null, 2),
        "utf8",
      );
      await fs.rename(tempPath, this.dataPath);
    }
  }

  async healthCheck() {
    await this.initialize();
    await fs.access(path.dirname(this.dataPath));
  }

  async _read() {
    await this.initialize();
    await this._writeQueue;
    const raw = await fs.readFile(this.dataPath, "utf8");
    const parsed = JSON.parse(raw);
    const normalized = normalizeDbState(parsed);
    // Phase 3.1c: keep the graph mirror eventually consistent
    // with the legacy collections without wiring sync into every
    // write path. Idempotent — no-op once the graph already
    // matches the legacy side.
    this._syncGraphFromLegacy(normalized);
    return normalized;
  }

  async _write(data) {
    // Same sync pass as _read, but on the OUT-bound side: ensures
    // the data we're about to persist already has graph rows that
    // mirror the legacy mutation the caller just made. Without
    // this, the next process boot would read a snapshot whose
    // graph is one step behind the legacy state.
    this._syncGraphFromLegacy(data);
    this._writeQueue = this._writeQueue.then(async () => {
      // store-race guard: read the freshest persisted calls INSIDE this
      // serialized write link (all prior writes have landed) and keep any
      // terminal call terminal — see _preserveTerminalCalls.
      try {
        const currentRaw = await fs.readFile(this.dataPath, "utf8");
        this._preserveTerminalCalls(data, JSON.parse(currentRaw)?.calls);
      } catch (_) {
        // First write / missing file — nothing persisted to preserve.
      }
      const directoryPath = path.dirname(this.dataPath);
      const tempPath = path.join(
        directoryPath,
        `${path.basename(this.dataPath)}.${crypto.randomUUID()}.tmp`,
      );

      await fs.writeFile(tempPath, JSON.stringify(data, null, 2), "utf8");
      await fs.rename(tempPath, this.dataPath);
    });
    return this._writeQueue;
  }

  // Atomic read-modify-write. Serializes the ENTIRE read → mutate → write of
  // every mutation through a dedicated lock (_mutateQueue) so two concurrent
  // mutations can never interleave — closing the whole-document lost-update
  // where a stale snapshot's write clobbers a field it never saw (the
  // store-wide race the per-field _preserveTerminalCalls guard only patched for
  // terminal calls). It REUSES _read()/_write() (so PostgresStore inherits it
  // unchanged, with its own overrides handling snapshot/projection/cache), and
  // simply prevents interleaving:
  //   - the lock guarantees this mutation's _read() sees the previous
  //     mutation's already-persisted _write();
  //   - _read()/_write() await _writeQueue/_stateWriteQueue, NOT _mutateQueue,
  //     so there is no circular wait / deadlock.
  // `applyFn(data, skip)` mutates `data` in place and returns the method's
  // result. It MUST be pure in-memory — it must NOT call _read/_write/_mutate
  // itself. On a read-only / not-found / no-op path it should `return skip(x)`
  // instead of `return x`: that returns `x` WITHOUT persisting, so those
  // early-returns stay pure reads exactly as they were before the migration
  // (no redundant whole-document write, and — importantly on Postgres — no new
  // write-layer failure surface on a path the old code never wrote on, e.g. an
  // already-terminal call handled by applyCallWebhook). Forgetting `skip` only
  // costs a redundant idempotent write, never a lost update (fail-safe). If
  // applyFn throws, nothing is persisted and the error propagates; the fresh
  // read on the next mutation discards the aborted in-memory changes.
  async _mutate(applyFn) {
    if (!this._mutateQueue) {
      this._mutateQueue = Promise.resolve();
    }
    const run = this._mutateQueue.then(async () => {
      const data = await this._read();
      let shouldWrite = true;
      const skip = (value) => {
        shouldWrite = false;
        return value;
      };
      const result = await applyFn(data, skip);
      if (shouldWrite) {
        await this._write(data);
      }
      return result;
    });
    // Keep the lock chained even if applyFn/persist rejects, so later mutations
    // serialize after this link instead of inheriting a rejected promise.
    this._mutateQueue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  // Test/shutdown hook: drain every mutation/persist already enqueued before
  // the caller tears down the process/dataPath (e.g. a test deleting its
  // tempDir). `_mutate`/`_write` are fire-and-forget from route handlers'
  // point of view (send/push dispatch replies BEFORE the blob write lands),
  // so a snapshot-then-await of `_mutateQueue` can miss work appended WHILE
  // we're waiting — that's exactly what caused the Windows ENOTEMPTY flake
  // (rm() walks a directory that gains a fresh `*.tmp` from an in-flight
  // _write mid-delete). Loop until a full await cycle appends nothing new,
  // i.e. the queue reference is stable — only then is the store quiescent.
  // Purely additive: reads existing fields, calls nothing that isn't already
  // called by normal mutation traffic, so it changes no production timing.
  async close() {
    let previous = null;
    let current = this._mutateQueue;
    while (current !== previous) {
      previous = current;
      await current;
      current = this._mutateQueue;
    }
  }

  /**
   * store-race guard: enforce the invariant that a terminal call never
   * un-terminates. The whole-document store persists all of `data` on every
   * write, so a write built on a STALE (pre-teardown) snapshot would otherwise
   * resurrect a call that hangup / ring-timeout just ended — the lost-update
   * the GP3 add-mid-call review flagged, and the top teardown-regression risk.
   * `currentCalls` is the freshest persisted calls array (read inside the
   * serialized write); any call terminal there is kept terminal in `data`.
   * This is a CORRECT invariant (calls never un-end), not a merge heuristic.
   * It does NOT address the broader whole-document lost-update for concurrent
   * NON-terminal edits — that remains the store-wide atomicity task.
   */
  _preserveTerminalCalls(data, currentCalls) {
    if (!Array.isArray(data?.calls) || data.calls.length === 0) {
      return;
    }
    if (!Array.isArray(currentCalls) || currentCalls.length === 0) {
      return;
    }
    const terminalById = new Map();
    for (const call of currentCalls) {
      if (call && isCallTerminalState(String(call.state || ""))) {
        terminalById.set(String(call.id || ""), call);
      }
    }
    if (terminalById.size === 0) {
      return;
    }
    for (let index = 0; index < data.calls.length; index += 1) {
      const call = data.calls[index];
      const terminal = terminalById.get(String(call?.id || ""));
      if (terminal && !isCallTerminalState(String(call?.state || ""))) {
        data.calls[index] = terminal;
      }
    }
  }

  _rememberSession(session) {
    const normalizedToken = String(session?.token || "").trim();
    if (!normalizedToken) {
      return;
    }
    this._sessionCache.set(normalizedToken, structuredClone(session));
  }

  _forgetSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return;
    }
    this._sessionCache.delete(normalizedToken);
    this._sessionTouchCache.delete(normalizedToken);
  }

  _rememberUser(user) {
    const normalizedUserId = String(user?.id || "").trim();
    if (!normalizedUserId) {
      return;
    }
    this._userCache.set(normalizedUserId, cloneUserWithAuthState(user));
  }

  _forgetUser(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return;
    }
    this._userCache.delete(normalizedUserId);
    this._onboardingIncompleteCache.delete(normalizedUserId);
  }

  _appendTreeChangeRecord(db, {
    treeId,
    actorId = null,
    type,
    personId = null,
    personIds = [],
    relationId = null,
    mediaId = null,
    details = {},
  }) {
    const record = createTreeChangeRecord({
      treeId,
      actorId,
      type,
      personId,
      personIds,
      relationId,
      mediaId,
      details,
    });
    db.treeChangeRecords.push(record);
    return record;
  }

  // ── SPEED-8b: хуки над журналом изменений и аудитом hard-delete ──────
  // На FileStore коллекции живут в блобе — хуки правят массивы на месте.
  // PostgresStore держит их в таблицах и переопределяет хуки: массивы в
  // блобе после миграции пусты, а табличная часть операции уходит в очередь,
  // которую применяет _write (хуки зовутся из _mutate-applyFn — там нельзя
  // await'ить SQL).
  _rewriteTreeChangeRecordsForMerge(db, {
    treeId,
    duplicatePersonId,
    preferredPersonId,
  }) {
    for (const record of db.treeChangeRecords || []) {
      if (record.treeId !== treeId) {
        continue;
      }
      if (record.personId === duplicatePersonId) {
        record.personId = preferredPersonId;
      }
      record.personIds = normalizeParticipantIds(
        (record.personIds || []).map((personId) =>
          personId === duplicatePersonId ? preferredPersonId : personId,
        ),
      );
    }
  }

  _pseudonymizeTreeChangeActor(db, userId) {
    for (const record of db.treeChangeRecords || []) {
      if (record.actorId === userId) {
        record.actorId = "deleted-user";
        record.actorName = null;
      }
    }
  }

  /// Срезает before/after/mergedFrom у НЕ-article записей старше cutoffTs
  /// (сама запись остаётся — таймлайн цел). Возвращает число затронутых.
  _stripTreeChangeDetails(db, {cutoffTs, dryRun = false}) {
    let stripped = 0;
    for (const record of db.treeChangeRecords || []) {
      if (stripTreeChangeRecordDetails(record, {cutoffTs, dryRun})) {
        stripped += 1;
      }
    }
    return stripped;
  }

  /// Аудит hard-delete: записи старше cutoffTs выбывают. Возвращает
  /// {surviving, pruned}; при dryRun ничего не меняет, только считает.
  _pruneHardDeleteAudit(db, {cutoffTs, dryRun = false}) {
    const existing = Array.isArray(db.hardDeleteAudit) ? db.hardDeleteAudit : [];
    const surviving = [];
    let pruned = 0;
    for (const entry of existing) {
      if (isHardDeleteAuditEntryExpired(entry, cutoffTs)) {
        pruned += 1;
        if (dryRun) surviving.push(entry);
      } else {
        surviving.push(entry);
      }
    }
    return {surviving, pruned};
  }

  // Phase B Ship 6: public wrapper для route-layer additive audit
  // entries (e.g. person.pulled-from-semya). Existing pattern —
  // change records appended inside store mutation methods. Когда
  // change source = composite route (pull = bulkImport + audit +
  // notify), route нужен hook без re-walking entire mutation flow.
  async appendTreeChangeRecord({
    treeId,
    actorId = null,
    type,
    personId = null,
    personIds = [],
    relationId = null,
    mediaId = null,
    details = {},
  }) {
    if (!treeId || typeof treeId !== "string") {
      throw new Error("INVALID_TREE_ID");
    }
    if (!type || typeof type !== "string") {
      throw new Error("INVALID_TYPE");
    }
    const db = await this._read();
    const record = this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type,
      personId,
      personIds,
      relationId,
      mediaId,
      details,
    });
    await this._write(db);
    return structuredClone(record);
  }

  _ensurePersonIdentityCollection(db) {
    db.personIdentities = Array.isArray(db.personIdentities)
      ? db.personIdentities
      : [];
    return db.personIdentities;
  }

  _reconcilePersonIdentities(db) {
    backfillPersonIdentities(db);
    const identities = this._ensurePersonIdentityCollection(db);
    const validUserIds = new Set(
      db.users
        .map((entry) => normalizeNullableString(entry.id))
        .filter(Boolean),
    );
    const personIdsByIdentity = new Map();

    for (const person of db.persons) {
      const identityId = normalizeNullableString(person.identityId);
      if (!identityId) {
        person.identityId = null;
        continue;
      }

      person.identityId = identityId;
      if (!personIdsByIdentity.has(identityId)) {
        personIdsByIdentity.set(identityId, []);
      }
      personIdsByIdentity.get(identityId).push(person.id);
    }

    const seenIdentityIds = new Set();
    db.personIdentities = identities.reduce((result, entry) => {
      const identityId = normalizeNullableString(entry?.id);
      if (!identityId || seenIdentityIds.has(identityId)) {
        return result;
      }

      seenIdentityIds.add(identityId);
      const linkedUserId = normalizeNullableString(entry?.userId);
      const normalizedUserId = linkedUserId && validUserIds.has(linkedUserId)
        ? linkedUserId
        : null;
      const personIds = normalizeParticipantIds(
        personIdsByIdentity.get(identityId) || [],
      );
      const claimedByUserId = normalizeNullableString(
        entry?.claimedByUserId || normalizedUserId,
      );
      const linkedPersons = personIds
        .map((personId) => db.persons.find((person) => person.id === personId))
        .filter(Boolean);
      const hasLivingPerson = linkedPersons.some(
        (person) => person.isAlive !== false,
      );

      if (!normalizedUserId && !claimedByUserId && personIds.length === 0) {
        return result;
      }

      const nextIdentity = {
        ...entry,
        id: identityId,
        userId: normalizedUserId || claimedByUserId,
        claimedByUserId,
        primaryPersonId:
          normalizeNullableString(entry?.primaryPersonId) || personIds[0] || null,
        personIds,
        isLiving:
          entry?.isLiving === undefined ? hasLivingPerson : entry.isLiving === true,
        isPublicDiscoverable: entry?.isPublicDiscoverable === true,
        mergedInto: normalizeNullableString(entry?.mergedInto),
        stewardUserIds: [],
        createdAt: entry?.createdAt || nowIso(),
        updatedAt: entry?.updatedAt || nowIso(),
      };
      nextIdentity.stewardUserIds = identityStewardUserIds(db, nextIdentity);
      result.push({
        ...nextIdentity,
      });
      return result;
    }, []);

    const identitiesByUserId = new Map(
      db.personIdentities
        .filter((entry) => entry.userId)
        .map((entry) => [entry.userId, entry.id]),
    );
    for (const user of db.users) {
      const normalizedIdentityId = normalizeNullableString(user.identityId);
      const ownedIdentityId = identitiesByUserId.get(user.id) || null;
      const currentIdentityValue = user.identityId;
      if (
        normalizedIdentityId &&
        db.personIdentities.some(
          (entry) =>
            entry.id === normalizedIdentityId && entry.userId === user.id,
        )
      ) {
        if (currentIdentityValue !== normalizedIdentityId) {
          user.identityId = normalizedIdentityId;
        }
        continue;
      }

      if (ownedIdentityId) {
        if (currentIdentityValue !== ownedIdentityId) {
          user.identityId = ownedIdentityId;
        }
        continue;
      }

      if (normalizedIdentityId !== null) {
        user.identityId = null;
      }
    }

    // BUG3 follow-up: ретро-бэкфилл аватара профиля для УЖЕ-привязанных
    // аккаунтов из фото связанной граф-персоны (поставленного ДО
    // регистрации). Идём здесь, после реконсиляции связей, чтобы линки
    // были актуальны. Покрывает и существующие связи (Анастасия и пр.).
    this._backfillUserAvatarsFromPersons(db);
  }

  // Заполняет пустой profile.photoUrl фотом связанной граф-персоны.
  // fillIfEmpty — загруженный пользователем аватар НЕ перетираем.
  // Идемпотентно (трогает только пустые). Связь резолвится и напрямую
  // (person.userId), и через identity (claimedByUserId/userId). Один проход
  // O(persons + identities + users).
  _backfillUserAvatarsFromPersons(db) {
    const persons = Array.isArray(db.persons) ? db.persons : [];
    if (persons.length === 0 || !Array.isArray(db.users)) {
      return;
    }
    const personPhoto = (person) =>
      normalizeNullableString(person?.primaryPhotoUrl || person?.photoUrl);

    const photoByUserId = new Map();
    const photoByIdentityId = new Map();
    for (const person of persons) {
      const photo = personPhoto(person);
      if (!photo) {
        continue;
      }
      const directUserId = normalizeNullableString(person.userId);
      if (directUserId && !photoByUserId.has(directUserId)) {
        photoByUserId.set(directUserId, photo);
      }
      const identityId = normalizeNullableString(person.identityId);
      if (identityId && !photoByIdentityId.has(identityId)) {
        photoByIdentityId.set(identityId, photo);
      }
    }

    const photoByLinkedUserViaIdentity = new Map();
    for (const identity of Array.isArray(db.personIdentities)
      ? db.personIdentities
      : []) {
      const linkedUserId = normalizeNullableString(
        identity?.claimedByUserId || identity?.userId,
      );
      const photo = photoByIdentityId.get(normalizeNullableString(identity?.id));
      if (linkedUserId && photo && !photoByLinkedUserViaIdentity.has(linkedUserId)) {
        photoByLinkedUserViaIdentity.set(linkedUserId, photo);
      }
    }

    for (const user of db.users) {
      if (!user) {
        continue;
      }
      if (!user.profile) {
        user.profile = {};
      }
      if (normalizeNullableString(user.profile.photoUrl)) {
        continue; // существующий аватар не перетираем
      }
      const photo =
        photoByUserId.get(user.id) ||
        photoByLinkedUserViaIdentity.get(user.id) ||
        null;
      if (photo) {
        user.profile.photoUrl = photo;
      }
    }
  }

  _ensureUserIdentity(db, userId) {
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const identities = this._ensurePersonIdentityCollection(db);
    const normalizedIdentityId = normalizeNullableString(user.identityId);
    let identity = normalizedIdentityId
      ? identities.find((entry) => entry.id === normalizedIdentityId)
      : null;

    if (!identity) {
      identity = identities.find((entry) => entry.userId === userId);
    }

    if (!identity) {
      identity = createPersonIdentityRecord({
        id: normalizedIdentityId || crypto.randomUUID(),
        userId,
      });
      identities.push(identity);
    }

    identity.userId = userId;
    identity.claimedByUserId = normalizeNullableString(
      identity.claimedByUserId || userId,
    );
    identity.updatedAt = nowIso();
    user.identityId = identity.id;
    user.updatedAt = nowIso();
    return identity;
  }

  _attachPersonToIdentity(db, person, identity, userId = null) {
    if (!person || !identity) {
      return false;
    }

    const normalizedUserId = normalizeNullableString(userId || person.userId);
    if (normalizedUserId) {
      if (person.userId && person.userId !== normalizedUserId) {
        return false;
      }
      if (identity.userId && identity.userId !== normalizedUserId) {
        return false;
      }
      person.userId = normalizedUserId;
      identity.userId = normalizedUserId;
      const user = db.users.find((entry) => entry.id === normalizedUserId);
      if (user) {
        user.identityId = identity.id;
        user.updatedAt = nowIso();
        // BUG 3: при привязке аккаунта к граф-персоне бэкфиллим пустой
        // аватар профиля из фото персоны (поставленного ДО регистрации).
        // fillIfEmpty — существующий аватар НЕ перетираем. Это единая
        // точка всех путей линковки (claim-approve / join / auto-link).
        if (!user.profile) {
          user.profile = {};
        }
        const personPhoto = normalizeNullableString(
          person.primaryPhotoUrl || person.photoUrl,
        );
        if (personPhoto && !normalizeNullableString(user.profile.photoUrl)) {
          user.profile.photoUrl = personPhoto;
        }
      }
    }

    person.identityId = identity.id;
    person.updatedAt = nowIso();
    identity.updatedAt = nowIso();
    this._reconcilePersonIdentities(db);
    return true;
  }

  _mergePersonIntoClaimTarget(db, {
    treeId,
    preferredPerson,
    duplicatePerson,
    userId,
    actorId = userId,
  }) {
    if (
      !preferredPerson ||
      !duplicatePerson ||
      preferredPerson.id === duplicatePerson.id
    ) {
      return preferredPerson;
    }

    const beforePreferred = structuredClone(preferredPerson);
    const removedDuplicate = structuredClone(duplicatePerson);
    const mergedPhotoState = normalizePersonPhotoGallery(
      [
        ...(Array.isArray(preferredPerson.photoGallery)
          ? preferredPerson.photoGallery
          : []),
        ...(Array.isArray(duplicatePerson.photoGallery)
          ? duplicatePerson.photoGallery
          : []),
      ],
      {
        photoUrl: preferredPerson.photoUrl || duplicatePerson.photoUrl,
        primaryPhotoUrl:
          preferredPerson.primaryPhotoUrl ||
          duplicatePerson.primaryPhotoUrl ||
          preferredPerson.photoUrl ||
          duplicatePerson.photoUrl,
      },
    );

    preferredPerson.name = pickPersonValue(
      preferredPerson.name,
      duplicatePerson.name,
    );
    preferredPerson.maidenName = pickPersonValue(
      preferredPerson.maidenName,
      duplicatePerson.maidenName,
    );
    preferredPerson.birthDate = pickPersonValue(
      preferredPerson.birthDate,
      duplicatePerson.birthDate,
    );
    preferredPerson.birthPlace = pickPersonValue(
      preferredPerson.birthPlace,
      duplicatePerson.birthPlace,
    );
    preferredPerson.deathDate = pickPersonValue(
      preferredPerson.deathDate,
      duplicatePerson.deathDate,
    );
    preferredPerson.deathPlace = pickPersonValue(
      preferredPerson.deathPlace,
      duplicatePerson.deathPlace,
    );
    preferredPerson.bio = pickPersonValue(preferredPerson.bio, duplicatePerson.bio);
    preferredPerson.notes = pickPersonValue(
      preferredPerson.notes,
      duplicatePerson.notes,
    );
    preferredPerson.creatorId = pickPersonValue(
      preferredPerson.creatorId,
      duplicatePerson.creatorId,
    );
    preferredPerson.photoUrl = mergedPhotoState.photoUrl;
    preferredPerson.primaryPhotoUrl = mergedPhotoState.primaryPhotoUrl;
    preferredPerson.photoGallery = mergedPhotoState.photoGallery;
    preferredPerson.userId = userId;
    preferredPerson.identityId = normalizeNullableString(
      preferredPerson.identityId || duplicatePerson.identityId,
    );
    preferredPerson.isAlive = preferredPerson.deathDate == null;
    preferredPerson.updatedAt = nowIso();

    for (const relation of db.relations) {
      if (relation.treeId !== treeId) {
        continue;
      }
      if (relation.person1Id === duplicatePerson.id) {
        relation.person1Id = preferredPerson.id;
      }
      if (relation.person2Id === duplicatePerson.id) {
        relation.person2Id = preferredPerson.id;
      }
    }
    db.relations = db.relations.reduce((result, relation) => {
      if (
        relation.treeId === treeId &&
        relation.person1Id === relation.person2Id
      ) {
        return result;
      }

      const dedupKey = relationDedupKey(relation);
      if (result.some((entry) => relationDedupKey(entry) === dedupKey)) {
        return result;
      }

      result.push(relation);
      return result;
    }, []);

    for (const post of db.posts) {
      if (post.treeId !== treeId) {
        continue;
      }
      post.anchorPersonIds = normalizeParticipantIds(
        (post.anchorPersonIds || []).map((personId) =>
          personId === duplicatePerson.id ? preferredPerson.id : personId,
        ),
      );
    }

    for (const chat of db.chats) {
      if (chat.treeId !== treeId) {
        continue;
      }
      chat.branchRootPersonIds = normalizeParticipantIds(
        (chat.branchRootPersonIds || []).map((personId) =>
          personId === duplicatePerson.id ? preferredPerson.id : personId,
        ),
      );
    }

    for (const request of db.relationRequests) {
      if (request.treeId !== treeId) {
        continue;
      }
      if (request.targetPersonId === duplicatePerson.id) {
        request.targetPersonId = preferredPerson.id;
      }
      if (request.offlineRelativeId === duplicatePerson.id) {
        request.offlineRelativeId = preferredPerson.id;
      }
    }

    this._rewriteTreeChangeRecordsForMerge(db, {
      treeId,
      duplicatePersonId: duplicatePerson.id,
      preferredPersonId: preferredPerson.id,
    });

    db.persons = db.persons.filter((entry) => entry.id !== duplicatePerson.id);
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "person.merged",
      personId: preferredPerson.id,
      personIds: [preferredPerson.id, duplicatePerson.id],
      details: {
        before: beforePreferred,
        mergedFrom: removedDuplicate,
        after: structuredClone(preferredPerson),
      },
    });
    this._reconcilePersonIdentities(db);
    return preferredPerson;
  }

  async createUser({
    email,
    password = null,
    displayName,
    authIdentity = null,
    photoUrl = null,
    // Согласие при регистрации: версия документов, которую пользователь
    // принял чекбоксом (аддитивно — старые клиенты не шлют, поле null).
    consentDocVersion = null,
  }) {
    const db = await this._read();
    const normalizedEmail = String(email || "").trim().toLowerCase();

    if (db.users.some((user) => user.email === normalizedEmail)) {
      throw new Error("EMAIL_ALREADY_EXISTS");
    }

    const createdAt = nowIso();
    const hasPassword = typeof password === "string" && password.length > 0;
    const passwordCredentials = hasPassword ? hashPassword(password) : null;
    const userId = crypto.randomUUID();

    const nameParts = String(displayName || "")
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    const authIdentities = [];
    if (hasPassword) {
      const passwordAuthIdentity = createPasswordAuthIdentity(
        normalizedEmail,
        createdAt,
      );
      if (passwordAuthIdentity) {
        authIdentities.push(passwordAuthIdentity);
      }
    }

    const normalizedAuthIdentity = normalizeAuthIdentityRecord(authIdentity);
    if (normalizedAuthIdentity) {
      authIdentities.push(normalizedAuthIdentity);
    }

    const normalizedConsentVersion =
      normalizeNullableString(consentDocVersion);
    const user = {
      id: userId,
      identityId: null,
      email: normalizedEmail,
      passwordHash: passwordCredentials?.passwordHash || null,
      passwordSalt: passwordCredentials?.salt || null,
      providerIds: [],
      authIdentities,
      createdAt,
      updatedAt: createdAt,
      // Факт согласия с Соглашением/ПДн: когда и какая версия документов.
      consentAt: normalizedConsentVersion ? createdAt : null,
      consentDocVersion: normalizedConsentVersion,
      profile: {
        id: userId,
        email: normalizedEmail,
        displayName: String(displayName || "").trim(),
        firstName: nameParts[0] || "",
        lastName: nameParts.length > 1 ? nameParts[nameParts.length - 1] : "",
        middleName:
          nameParts.length > 2 ? nameParts.slice(1, -1).join(" ") : "",
        username: "",
        phoneNumber: "",
        normalizedPhoneNumber: null,
        countryCode: null,
        countryName: null,
        city: "",
        photoUrl: String(photoUrl || "").trim() || null,
        gender: "unknown",
        maidenName: "",
        birthDate: null,
        birthPlace: null,
        bio: "",
        familyStatus: "",
        aboutFamily: "",
        education: "",
        work: "",
        hometown: "",
        languages: "",
        values: "",
        religion: "",
        interests: "",
        profileContributionPolicy: "suggestions",
        primaryTrustedChannel: normalizePrimaryTrustedChannel(
          normalizedAuthIdentity?.provider,
        ),
        createdAt,
        updatedAt: createdAt,
      },
      profileNotes: [],
    };
    user.providerIds = deriveProviderIdsForUser(user);

    db.users.push(user);
    await this._write(db);
    this._rememberUser(user);
    return cloneUserWithAuthState(user);
  }

  // Per-account brute-force lockout policy. The IP-based rate
  // limiter in app.js caps an attacker who hits us from a single
  // address, but anyone with a proxy pool can rotate IPs and burn
  // through 30 attempts/min PER IP. Locking the ACCOUNT after a
  // small streak of failures denies the easy attack regardless of
  // how many IPs the attacker controls.
  //
  // Tuning:
  //   * 7 failures before lockout — generous enough that a user
  //     fat-fingering their password doesn't get locked out
  //     mid-typing, but tight enough that an attacker only gets a
  //     handful of guesses before the account becomes unreachable.
  //   * 15-minute lockout window — long enough that a brute-force
  //     attacker would need >67 hours to make the same number of
  //     guesses they could without lockout, short enough that a
  //     legitimate user doesn't get permanently locked out from
  //     a forgotten-password situation.
  //   * Successful login resets both fields. So a user who
  //     remembers their password on attempt 3 doesn't carry the
  //     two failures into the next session.
  static get _maxLoginFailuresBeforeLockout() {
    return 7;
  }

  static get _loginLockoutDurationMs() {
    return 15 * 60 * 1000; // 15 minutes
  }

  async authenticate(email, password) {
    const db = await this._read();
    const normalizedEmail = String(email || "").trim().toLowerCase();
    const user = db.users.find((entry) => entry.email === normalizedEmail);

    // Always run a real scrypt+timingSafeEqual hop. If the user
    // doesn't exist, run it against a dummy salt so the response
    // takes the same wall-clock time as a real verify — closes the
    // user-enumeration timing oracle. If the user exists, run the
    // real async verify on the libuv thread pool so the event loop
    // stays responsive under concurrent logins (the previous
    // synchronous scrypt blocked for ~150 ms per request).
    if (!user) {
      await dummyVerifyForTimingParity(String(password || ""));
      return null;
    }

    // ── Per-account lockout check ────────────────────────────────
    // Rejected before we even compute the hash, so a locked account
    // can't be used as a CPU sink either. We still run the dummy
    // verify so the wall-clock matches the unknown-email branch
    // and an attacker can't tell "locked" from "not registered" by
    // timing.
    const lockedUntil = user.lockedUntil
        ? Date.parse(user.lockedUntil)
        : null;
    if (lockedUntil && Number.isFinite(lockedUntil) && lockedUntil > Date.now()) {
      await dummyVerifyForTimingParity(String(password || ""));
      return null;
    }

    const isValid = await verifyPasswordAsync(password, user);
    if (!isValid) {
      // Bump failure counter and persist. If we've crossed the
      // threshold, set lockedUntil so the next attempt short-circuits.
      const nextCount = (Number(user.failedLoginCount) || 0) + 1;
      const updates = {failedLoginCount: nextCount};
      if (nextCount >= FileStore._maxLoginFailuresBeforeLockout) {
        const unlockAt = Date.now() + FileStore._loginLockoutDurationMs;
        updates.lockedUntil = new Date(unlockAt).toISOString();
      }
      try {
        await this._persistAuthFailureState(user.id, updates);
      } catch (error) {
        // Persistence is best-effort — never fail the auth response
        // because the failure counter couldn't be written. The
        // attacker still doesn't get in; we just lose one increment.
        console.error(
          "[backend] failed to persist login-failure state",
          JSON.stringify({userId: user.id, message: error?.message}),
        );
      }
      return null;
    }

    // Successful sign-in resets the failure state.
    if (user.failedLoginCount || user.lockedUntil) {
      try {
        await this._persistAuthFailureState(user.id, {
          failedLoginCount: 0,
          lockedUntil: null,
        });
      } catch (error) {
        // Reset is best-effort. Leaving a stale `lockedUntil` in the
        // past does no harm because the date check ignores expired
        // entries.
        console.error(
          "[backend] failed to clear login-failure state",
          JSON.stringify({userId: user.id, message: error?.message}),
        );
      }
    }

    this._rememberUser(user);
    return cloneUserWithAuthState(user);
  }

  // Targeted persister for the lockout fields. Lives separately from
  // the bulk user-update path so a failure here doesn't poison the
  // larger `_write` queue. Subclasses (PostgresStore) override to
  // skip the full state read and write only the touched columns.
  async _persistAuthFailureState(userId, updates) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) return;
    if ("failedLoginCount" in updates) {
      user.failedLoginCount = updates.failedLoginCount;
    }
    if ("lockedUntil" in updates) {
      user.lockedUntil = updates.lockedUntil;
    }
    await this._write(db);
  }

  /// Mark the user's last-seen timestamp. Called by the realtime hub when
  /// the user's last socket disconnects, so clients can render "был(а) N
  /// минут назад" in chat subtitles. Idempotent and resilient: errors
  /// don't propagate (the broadcast itself is more important than the
  /// timestamp persistence).
  async markUserSeenAt(userId, {when} = {}) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return;
    }
    const timestamp =
      when instanceof Date ? when.toISOString() : when || nowIso();
    try {
      const db = await this._read();
      const user = db.users.find((entry) => entry.id === normalizedUserId);
      if (!user) {
        return;
      }
      user.lastSeenAt = timestamp;
      this._rememberUser(user);
      await this._write(db);
    } catch (_) {
      // Last-seen is a best-effort UX hint, not auth state.
    }
  }

  async findUserById(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return null;
    }
    const cachedUser = this._userCache.get(normalizedUserId);
    if (cachedUser) {
      return cloneUserWithAuthState(cachedUser);
    }
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === normalizedUserId);
    if (user) {
      this._rememberUser(user);
    }
    return user ? cloneUserWithAuthState(user) : null;
  }

  async findUserByEmail(email) {
    const db = await this._read();
    const normalizedEmail = String(email || "").trim().toLowerCase();
    if (!normalizedEmail) {
      return null;
    }

    const user = db.users.find((entry) => entry.email === normalizedEmail);
    if (user) {
      this._rememberUser(user);
    }
    return user ? cloneUserWithAuthState(user) : null;
  }

  async findUserByAuthIdentity(provider, providerUserId) {
    const db = await this._read();
    const normalizedProvider = normalizeAuthProvider(provider);
    const normalizedProviderUserId = String(providerUserId || "").trim();
    if (!normalizedProvider || !normalizedProviderUserId) {
      return null;
    }

    const user = db.users.find((entry) =>
      listAuthIdentitiesForUser(entry).some(
        (identity) =>
          identity.provider === normalizedProvider &&
          identity.providerUserId === normalizedProviderUserId,
      ),
    );
    if (user) {
      this._rememberUser(user);
    }
    return user ? cloneUserWithAuthState(user) : null;
  }

  async createSession(userId, deviceContext = {}) {
    const db = await this._read();
    const createdAt = nowIso();
    const token = crypto.randomBytes(32).toString("hex");
    const refreshToken = crypto.randomBytes(32).toString("hex");

    const userSessions = db.sessions.filter((s) => s.userId === userId);
    const otherSessions = db.sessions.filter((s) => s.userId !== userId);

    const normalizedDeviceContext = normalizeSessionDeviceContext(deviceContext);
    const incomingInstanceId = normalizedDeviceContext.instanceId;

    // If the same client instance re-authenticates, evict its previous session.
    // Otherwise keep last 5 sessions for this user.
    const supersededInstanceMatches = incomingInstanceId
      ? userSessions.filter((s) => s.instanceId === incomingInstanceId)
      : [];
    const remainingAfterInstanceMatch = incomingInstanceId
      ? userSessions.filter((s) => s.instanceId !== incomingInstanceId)
      : userSessions;

    const sessionsToKeep = remainingAfterInstanceMatch.slice(-4);
    const overflowEvicted = remainingAfterInstanceMatch.slice(
      0,
      Math.max(0, remainingAfterInstanceMatch.length - sessionsToKeep.length),
    );
    const evictedSessions = [...supersededInstanceMatches, ...overflowEvicted];

    const createdSession = {
      token,
      refreshToken,
      userId,
      createdAt,
      lastSeenAt: createdAt,
      ...normalizedDeviceContext,
    };

    db.sessions = [
      ...otherSessions,
      ...sessionsToKeep,
      createdSession,
    ];

    await this._write(db);
    for (const session of evictedSessions) {
      this._forgetSession(session?.token);
    }
    this._rememberSession(createdSession);
    return {
      token,
      refreshToken,
      session: structuredClone(createdSession),
      evictedTokens: evictedSessions
        .map((entry) => String(entry?.token || "").trim())
        .filter(Boolean),
    };
  }

  async listSessionsForUser(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    const db = await this._read();
    return db.sessions
      .filter((entry) => entry.userId === normalizedUserId)
      .map((entry) => structuredClone(entry))
      .sort((left, right) => {
        const leftAt = String(left.lastSeenAt || left.createdAt || "");
        const rightAt = String(right.lastSeenAt || right.createdAt || "");
        return rightAt.localeCompare(leftAt);
      });
  }

  async findSessionByPublicId(userId, publicId) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedPublicId = String(publicId || "").trim();
    if (!normalizedUserId || !normalizedPublicId) {
      return null;
    }
    const sessions = await this.listSessionsForUser(normalizedUserId);
    for (const session of sessions) {
      const candidate = deriveSessionPublicId(
        session.token,
        session.instanceId || "",
      );
      if (candidate === normalizedPublicId) {
        return session;
      }
    }
    return null;
  }

  async updateSessionMetadata(token, patch = {}) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }
    const db = await this._read();
    const session = db.sessions.find((entry) => entry.token === normalizedToken);
    if (!session) {
      return null;
    }
    const allowedPatch = {};
    if (patch.deviceName !== undefined) {
      allowedPatch.deviceName = normalizeOptionalString(patch.deviceName, 80);
    }
    if (patch.platform !== undefined) {
      allowedPatch.platform = normalizeOptionalString(patch.platform, 40);
    }
    if (patch.osVersion !== undefined) {
      allowedPatch.osVersion = normalizeOptionalString(patch.osVersion, 40);
    }
    if (patch.appVersion !== undefined) {
      allowedPatch.appVersion = normalizeOptionalString(patch.appVersion, 40);
    }
    Object.assign(session, allowedPatch);
    await this._write(db);
    this._rememberSession(session);
    return structuredClone(session);
  }

  async findSessionByRefreshToken(refreshToken) {
    const db = await this._read();
    const session = db.sessions.find((entry) => entry.refreshToken === refreshToken);
    if (session) {
      this._rememberSession(session);
    }
    return session ? structuredClone(session) : null;
  }

  // Password reset token storage. Plaintext token NEVER hits the
  // DB — we store `crypto.randomBytes(32).toString('base64url')` in
  // the email URL and a `sha256(token)` hex digest in the row.
  // Standard Rails/Django pattern: a DB read leak doesn't reveal
  // active reset tokens, but lookup is still O(1) per identity
  // because we only key by hash equality.
  //
  // Rate-limit at the issue side: max 1 unconsumed token per user
  // per hour. Without this, a malicious actor can spam reset
  // emails to a victim's inbox indefinitely (annoying, but ALSO
  // helps phishing — flood, then spoof a fake reset email mid-
  // flood). The rate window is short enough that a real user who
  // mistyped won't be blocked for long.
  static get _passwordResetTokenTtlMs() {
    return 24 * 60 * 60 * 1000; // 24 hours
  }

  static get _passwordResetMinIssueIntervalMs() {
    return 60 * 60 * 1000; // 1 hour
  }

  _hashResetToken(plaintext) {
    return crypto
      .createHash("sha256")
      .update(String(plaintext || ""))
      .digest("hex");
  }

  _cleanupExpiredPasswordResetTokens(db) {
    if (!Array.isArray(db.passwordResetTokens)) {
      db.passwordResetTokens = [];
      return false;
    }
    const beforeLength = db.passwordResetTokens.length;
    const nowMs = Date.now();
    db.passwordResetTokens = db.passwordResetTokens.filter((entry) => {
      const expiresMs = Date.parse(entry?.expiresAt || "");
      if (Number.isFinite(expiresMs) && expiresMs <= nowMs) {
        return false;
      }
      // Drop already-consumed tokens older than 1 hour — keep them
      // briefly for audit, then GC. We don't want a "consumed" row
      // pinning memory forever.
      if (entry?.consumedAt) {
        const consumedMs = Date.parse(entry.consumedAt);
        if (
          Number.isFinite(consumedMs) &&
          consumedMs + 60 * 60 * 1000 <= nowMs
        ) {
          return false;
        }
      }
      return true;
    });
    return db.passwordResetTokens.length !== beforeLength;
  }

  // Returns the plaintext token to embed in the reset URL. The
  // CALLER is responsible for getting it into the email and never
  // storing it elsewhere — once we return, the plaintext is gone
  // from the server.
  //
  // Returns null if the user is rate-limited (too many resets in
  // the last hour). Caller should still treat it as success to the
  // outside world — anti-enumeration.
  async issuePasswordResetToken(userId) {
    const db = await this._read();
    this._cleanupExpiredPasswordResetTokens(db);

    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) {
      return null;
    }
    const user = db.users.find((entry) => entry.id === normalizedUserId);
    if (!user) {
      return null;
    }

    const nowMs = Date.now();
    const recentForUser = db.passwordResetTokens.find((entry) => {
      if (entry.userId !== normalizedUserId) return false;
      if (entry.consumedAt) return false;
      const createdMs = Date.parse(entry.createdAt || "");
      if (!Number.isFinite(createdMs)) return false;
      return (
        nowMs - createdMs <
        FileStore._passwordResetMinIssueIntervalMs
      );
    });
    if (recentForUser) {
      // Don't issue a new token — the one we already sent within
      // the last hour is still valid. Returning null here lets the
      // route choose its anti-enumeration response (it returns
      // 202 anyway).
      return null;
    }

    const plaintext = crypto.randomBytes(32).toString("base64url");
    const tokenHash = this._hashResetToken(plaintext);
    const createdAt = nowIso();
    const expiresAt = new Date(
      nowMs + FileStore._passwordResetTokenTtlMs,
    ).toISOString();

    db.passwordResetTokens.push({
      id: crypto.randomUUID(),
      userId: normalizedUserId,
      tokenHash,
      createdAt,
      expiresAt,
      consumedAt: null,
    });
    await this._write(db);

    return {
      plaintext,
      expiresAt,
      ttlSeconds: Math.floor(FileStore._passwordResetTokenTtlMs / 1000),
    };
  }

  // Look up a reset token by its plaintext (re-hashed here), and
  // mark it consumed atomically. Returns the user id if the token
  // was valid and not previously used, null otherwise.
  //
  // We DO NOT update the password here — the caller does that
  // explicitly via `updateUserPassword` so the route can validate
  // the new password's shape (length etc.) BEFORE consuming the
  // token. Otherwise a malformed-password attempt would burn a
  // valid token and force the user to re-request.
  async consumePasswordResetToken(plaintextToken) {
    const db = await this._read();
    this._cleanupExpiredPasswordResetTokens(db);

    const trimmed = String(plaintextToken || "").trim();
    if (!trimmed) return null;

    const tokenHash = this._hashResetToken(trimmed);
    const index = db.passwordResetTokens.findIndex(
      (entry) =>
        entry.tokenHash === tokenHash &&
        !entry.consumedAt &&
        !isExpiredAt(entry?.expiresAt),
    );
    if (index < 0) {
      // Cleanup may have changed the array — flush even on miss.
      await this._write(db);
      return null;
    }
    const record = db.passwordResetTokens[index];
    record.consumedAt = nowIso();
    await this._write(db);
    return record.userId;
  }

  async findUserByEmail(emailRaw) {
    const db = await this._read();
    const normalized = String(emailRaw || "").trim().toLowerCase();
    if (!normalized) return null;
    const user = db.users.find((entry) => entry.email === normalized);
    return user ? structuredClone(user) : null;
  }

  // Used by the password-reset confirm route. Async-hashes via
  // libuv thread pool — same scrypt cost as login verify, so the
  // event loop stays responsive under concurrent resets.
  async updateUserPassword(userId, newPlaintextPassword) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) return false;

    const credentials = await hashPasswordAsync(
      String(newPlaintextPassword || ""),
    );
    user.passwordHash = credentials.passwordHash;
    user.passwordSalt = credentials.salt;
    // Reset failed-login state so the user isn't still locked
    // out with their fresh password. Common UX: "I locked myself
    // out → reset my password → still locked".
    user.failedLoginCount = 0;
    user.lockedUntil = null;
    user.updatedAt = nowIso();

    // Security hygiene: invalidate all existing sessions on
    // password reset. If the user reset because they suspected
    // compromise, leaving open sessions defeats the point. They'll
    // re-login on each device. We MUST also evict the in-memory
    // session cache (`_sessionCache`) — `db.sessions` is the
    // persistent store, but requireAuth hits the cache first.
    const userSessionTokens = (Array.isArray(db.sessions) ? db.sessions : [])
      .filter((session) => session.userId === userId)
      .map((session) => session.token);
    db.sessions = (Array.isArray(db.sessions) ? db.sessions : []).filter(
      (session) => session.userId !== userId,
    );
    for (const token of userSessionTokens) {
      this._forgetSession(token);
    }

    // Drop any other unconsumed reset tokens for this user — once
    // they've used one, the rest are stale and shouldn't sit
    // around as latent attack surface.
    if (Array.isArray(db.passwordResetTokens)) {
      db.passwordResetTokens = db.passwordResetTokens.filter((entry) => {
        if (entry.userId !== userId) return true;
        if (entry.consumedAt) return true; // keep the one we just consumed for audit
        return false;
      });
    }

    await this._write(db);
    return true;
  }

  _cleanupExpiredAuthHandoffs(db) {
    const beforeLength = Array.isArray(db.authHandoffs) ? db.authHandoffs.length : 0;
    db.authHandoffs = (Array.isArray(db.authHandoffs) ? db.authHandoffs : []).filter(
      (entry) => !isExpiredAt(entry?.expiresAt),
    );
    return db.authHandoffs.length !== beforeLength;
  }

  async createAuthHandoff({type, payload = {}, userId = null, expiresAt = null}) {
    const db = await this._read();
    this._cleanupExpiredAuthHandoffs(db);
    const handoff = createAuthHandoffRecord({
      type,
      payload,
      userId,
      expiresAt,
    });
    db.authHandoffs.push(handoff);
    await this._write(db);
    return structuredClone(handoff);
  }

  async consumeAuthHandoff(code, {type = null} = {}) {
    const db = await this._read();
    this._cleanupExpiredAuthHandoffs(db);
    const normalizedCode = String(code || "").trim();
    const index = db.authHandoffs.findIndex((entry) => {
      if (entry.code !== normalizedCode) {
        return false;
      }
      if (type && entry.type !== type) {
        return false;
      }
      return true;
    });
    if (index < 0) {
      if (this._cleanupExpiredAuthHandoffs(db)) {
        await this._write(db);
      }
      return null;
    }

    const [handoff] = db.authHandoffs.splice(index, 1);
    await this._write(db);
    return structuredClone(handoff);
  }

  async findAuthHandoff(code, {type = null} = {}) {
    const db = await this._read();
    const cleaned = this._cleanupExpiredAuthHandoffs(db);
    if (cleaned) {
      await this._write(db);
    }
    const normalizedCode = String(code || "").trim();
    if (!normalizedCode) {
      return null;
    }
    const handoff = db.authHandoffs.find((entry) => {
      if (entry.code !== normalizedCode) {
        return false;
      }
      if (type && entry.type !== type) {
        return false;
      }
      return true;
    });
    return handoff ? structuredClone(handoff) : null;
  }

  async updateAuthHandoffPayload(code, patch = {}, {type = null} = {}) {
    const db = await this._read();
    this._cleanupExpiredAuthHandoffs(db);
    const normalizedCode = String(code || "").trim();
    if (!normalizedCode) {
      return null;
    }
    const handoff = db.authHandoffs.find((entry) => {
      if (entry.code !== normalizedCode) {
        return false;
      }
      if (type && entry.type !== type) {
        return false;
      }
      return true;
    });
    if (!handoff) {
      return null;
    }
    handoff.payload = {
      ...(handoff.payload && typeof handoff.payload === "object"
        ? handoff.payload
        : {}),
      ...(patch && typeof patch === "object" ? patch : {}),
    };
    await this._write(db);
    return structuredClone(handoff);
  }

  async findSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }
    const cachedSession = this._sessionCache.get(normalizedToken);
    if (cachedSession) {
      return structuredClone(cachedSession);
    }
    const db = await this._read();
    const session = db.sessions.find((entry) => entry.token === normalizedToken);
    if (session) {
      this._rememberSession(session);
    }
    return session ? structuredClone(session) : null;
  }

  async touchSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }

    const nowMs = Date.now();
    const cachedTouchedAt = this._sessionTouchCache.get(normalizedToken);
    if (
      Number.isFinite(cachedTouchedAt) &&
      nowMs - cachedTouchedAt < SESSION_TOUCH_MIN_INTERVAL_MS
    ) {
      return null;
    }

    this._sessionTouchCache.set(normalizedToken, nowMs);
    const db = await this._read();
    const session = db.sessions.find((entry) => entry.token === normalizedToken);
    if (!session) {
      this._forgetSession(normalizedToken);
      return null;
    }

    const lastSeenAtMs = new Date(session.lastSeenAt || 0).getTime();
    if (
      Number.isFinite(lastSeenAtMs) &&
      nowMs - lastSeenAtMs < SESSION_TOUCH_MIN_INTERVAL_MS
    ) {
      this._sessionTouchCache.set(normalizedToken, lastSeenAtMs);
      this._rememberSession(session);
      return structuredClone(session);
    }

    session.lastSeenAt = nowIso();
    try {
      await this._write(db);
    } catch (error) {
      this._forgetSession(normalizedToken);
      throw error;
    }
    this._rememberSession(session);
    return structuredClone(session);
  }

  async deleteSession(token) {
    const normalizedToken = String(token || "").trim();
    if (!normalizedToken) {
      return null;
    }
    const db = await this._read();
    const removedSession = db.sessions.find(
      (entry) => entry.token === normalizedToken,
    );
    db.sessions = db.sessions.filter((entry) => entry.token !== normalizedToken);
    this._forgetSession(normalizedToken);
    await this._write(db);
    return removedSession ? structuredClone(removedSession) : null;
  }

  async deleteSessionsForUser(userId) {
    const db = await this._read();
    const deletedTokens = db.sessions
      .filter((entry) => entry.userId === userId)
      .map((entry) => entry.token);
    db.sessions = db.sessions.filter((entry) => entry.userId !== userId);
    for (const token of deletedTokens) {
      this._forgetSession(token);
    }
    await this._write(db);
  }

  async listUserAuthIdentities(userId) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    return listAuthIdentitiesForUser(user).map((identity) => structuredClone(identity));
  }

  async linkAuthIdentity(userId, identityPayload) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const normalizedIdentity = normalizeAuthIdentityRecord(identityPayload);
    if (!normalizedIdentity) {
      throw new Error("INVALID_AUTH_IDENTITY");
    }

    const alreadyLinkedOwner = db.users.find((entry) => {
      if (entry.id === userId) {
        return false;
      }

      return listAuthIdentitiesForUser(entry).some(
        (identity) =>
          identity.provider === normalizedIdentity.provider &&
          identity.providerUserId === normalizedIdentity.providerUserId,
      );
    });
    if (alreadyLinkedOwner) {
      throw new Error("AUTH_IDENTITY_ALREADY_LINKED");
    }

    const now = nowIso();
    const nextAuthIdentities = listAuthIdentitiesForUser(user);
    const existingIdentityIndex = nextAuthIdentities.findIndex(
      (identity) =>
        identity.provider === normalizedIdentity.provider &&
        identity.providerUserId === normalizedIdentity.providerUserId,
    );
    const existingProviderIndex = nextAuthIdentities.findIndex(
      (identity) => identity.provider === normalizedIdentity.provider,
    );
    if (
      existingProviderIndex >= 0 &&
      existingIdentityIndex < 0 &&
      normalizedIdentity.provider !== "password"
    ) {
      throw new Error("AUTH_PROVIDER_ALREADY_LINKED_FOR_USER");
    }
    const nextIdentity = {
      ...normalizedIdentity,
      linkedAt:
        existingIdentityIndex >= 0
          ? nextAuthIdentities[existingIdentityIndex].linkedAt
          : normalizedIdentity.linkedAt || now,
      lastUsedAt: now,
    };

    if (existingIdentityIndex >= 0) {
      nextAuthIdentities[existingIdentityIndex] = nextIdentity;
    } else {
      nextAuthIdentities.push(nextIdentity);
    }

    user.authIdentities = nextAuthIdentities;
    user.providerIds = deriveProviderIdsForUser(user);
    user.profile = {
      ...user.profile,
      primaryTrustedChannel:
        normalizePrimaryTrustedChannel(user.profile?.primaryTrustedChannel) ||
        normalizePrimaryTrustedChannel(normalizedIdentity.provider),
    };
    user.updatedAt = now;

    await this._write(db);
    return cloneUserWithAuthState(user);
  }

  async resolveAuthIdentityTarget({
    provider,
    providerUserId,
    email = null,
    phoneNumber = null,
  }) {
    const linkedUser = await this.findUserByAuthIdentity(provider, providerUserId);
    if (linkedUser) {
      return {
        reason: "provider_identity",
        user: linkedUser,
      };
    }

    const emailMatchedUser = await this.findUserByEmail(email);
    if (emailMatchedUser) {
      // Ship Bug B (2026-05-26): block silent cross-provider merge.
      // Pre-fix: any email match triggered linkAuthIdentity → Bob's
      // Google would silently link к Alice's account because
      // emails matched. Account-takeover risk если email reused.
      //
      // Post-fix: refuse merge — return `email_provider_mismatch`
      // reason без user object. Route layer translates to 409 с
      // existing provider list так что user может log in via their
      // actual existing provider (then add new one через authenticated
      // /v1/auth/{provider}/link endpoint).
      //
      // Note: behavior strictly safer than Q2 spec literal — even
      // when the new attempt's provider TYPE matches an existing
      // identity (different providerUserId), мы refuse because the
      // exact provider+sub combo не matched в `findUserByAuthIdentity`
      // above. Scenario: Alice has google linked with alice-sub;
      // Bob attempts google login с different sub but same email —
      // we refuse merge (audit-aligned).
      const identities = listAuthIdentitiesForUser(emailMatchedUser);
      const existingProviders = Array.from(
        new Set(identities.map((entry) => entry.provider)),
      );
      return {
        reason: "email_provider_mismatch",
        user: null,
        existingProviders,
        email: emailMatchedUser.email || null,
      };
    }

    return {
      reason: "new_account",
      user: null,
    };
  }

  async updateProfile(userId, updater) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const previousProfile = user.profile || {};
    const nextProfile = updater(structuredClone(user.profile));
    const nextPhoneNumber = String(nextProfile?.phoneNumber || "").trim();
    const nextCountryCode = nextProfile?.countryCode ?? user.profile?.countryCode;
    const normalizedPhoneNumber = normalizePhoneNumber(
      nextPhoneNumber,
      nextCountryCode,
    );
    user.profile = {
      ...user.profile,
      ...nextProfile,
      phoneNumber: nextPhoneNumber,
      normalizedPhoneNumber,
      birthPlace:
        nextProfile && Object.prototype.hasOwnProperty.call(nextProfile, "birthPlace")
          ? normalizeNullableString(nextProfile.birthPlace)
          : normalizeNullableString(user.profile?.birthPlace),
      profileContributionPolicy:
        nextProfile &&
        Object.prototype.hasOwnProperty.call(
          nextProfile,
          "profileContributionPolicy",
        )
          ? normalizeProfileContributionPolicy(nextProfile.profileContributionPolicy)
          : normalizeProfileContributionPolicy(
              user.profile?.profileContributionPolicy,
            ),
      primaryTrustedChannel:
        nextProfile &&
        Object.prototype.hasOwnProperty.call(
          nextProfile,
          "primaryTrustedChannel",
        )
          ? normalizePrimaryTrustedChannel(nextProfile.primaryTrustedChannel)
          : normalizePrimaryTrustedChannel(user.profile?.primaryTrustedChannel),
      id: user.id,
      email: user.email,
      updatedAt: nowIso(),
    };
    user.updatedAt = nowIso();

    const touchedTreeIds = new Set();
    for (const person of db.persons) {
      if (person.userId !== userId) {
        continue;
      }
      applyCanonicalProfileToPerson(person, user.profile);
      if (person.treeId) {
        touchedTreeIds.add(person.treeId);
      }
    }
    for (const tree of db.trees) {
      if (touchedTreeIds.has(tree.id)) {
        tree.updatedAt = nowIso();
      }
    }

    await this._write(db);
    this._rememberUser(user);
    return structuredClone(user);
  }

  async deleteUser(userId) {
    // SPEED-2/STORE-RACE: аккаунт-удаление через _mutate. Иначе фоновый
    // фан-аут отправки сообщения (createNotification / markChatMessageDelivered
    // на _mutate) мог прочитать снапшот с ещё живой сессией и записать её
    // обратно, ВОСКРЕСИВ только что удалённую сессию (raw _read/_write не
    // сериализован против _mutate). Кеш-очистка — ПОСЛЕ персиста.
    let deletedSessionTokens = [];
    const result = await this._mutate((db, skip) => {
    const existingUser = db.users.find((entry) => entry.id === userId);
    if (!existingUser) {
      return skip(null);
    }
    deletedSessionTokens = db.sessions
      .filter((entry) => entry.userId === userId)
      .map((entry) => entry.token);

    const timestamp = nowIso();
    const removedTreeIds = new Set();
    db.trees = db.trees.reduce((trees, tree) => {
      const nextMemberIds = normalizeParticipantIds(
        (tree.memberIds || tree.members || []).filter(
          (memberId) => memberId !== userId,
        ),
      );

      if (tree.creatorId === userId && nextMemberIds.length === 0) {
        removedTreeIds.add(tree.id);
        return trees;
      }

      const creatorId =
        tree.creatorId === userId ? nextMemberIds[0] || null : tree.creatorId;
      const membersChanged =
        nextMemberIds.length !== (tree.memberIds || tree.members || []).length ||
        creatorId !== tree.creatorId;

      trees.push({
        ...tree,
        creatorId,
        memberIds: nextMemberIds,
        members: nextMemberIds,
        updatedAt: membersChanged ? timestamp : tree.updatedAt,
      });
      return trees;
    }, []);

    const removedPersonIds = new Set(
      db.persons
        .filter(
          (entry) => entry.userId === userId || removedTreeIds.has(entry.treeId),
        )
        .map((entry) => entry.id),
    );

    db.users = db.users.filter((entry) => entry.id !== userId);
    db.sessions = db.sessions.filter((entry) => entry.userId !== userId);
    db.authHandoffs = (db.authHandoffs || []).filter((entry) => entry.userId !== userId);
    // GDPR cleanup: drop any pending or consumed password-reset
    // tokens for this user. We keep no audit trail across the
    // delete since the user record itself is gone.
    db.passwordResetTokens = (db.passwordResetTokens || []).filter(
      (entry) => entry.userId !== userId,
    );
    // Drop this user's identity-suggestion dismissals.
    db.dismissedIdentitySuggestions = (
      db.dismissedIdentitySuggestions || []
    ).filter((entry) => entry.userId !== userId);
    db.persons = db.persons.filter((entry) => !removedPersonIds.has(entry.id));
    db.relations = db.relations.filter((entry) => {
      return (
        !removedTreeIds.has(entry.treeId) &&
        !removedPersonIds.has(entry.person1Id) &&
        !removedPersonIds.has(entry.person2Id)
      );
    });
    db.circles = db.circles.filter((entry) => !removedTreeIds.has(entry.treeId));
    db.circleMembers = db.circleMembers.filter(
      (entry) => !removedTreeIds.has(entry.treeId),
    );

    const nextPosts = [];
    const removedPostIds = new Set();
    for (const post of db.posts) {
      if (post.authorId === userId || removedTreeIds.has(post.treeId)) {
        removedPostIds.add(post.id);
        continue;
      }

      nextPosts.push({
        ...post,
        anchorPersonIds: normalizeParticipantIds(
          (post.anchorPersonIds || []).filter(
            (personId) => !removedPersonIds.has(personId),
          ),
        ),
      });
    }
    db.posts = nextPosts;
    db.stories = db.stories.filter((story) => {
      return !(
        story.authorId === userId ||
        removedTreeIds.has(story.treeId)
      );
    });

    const removedCommentIds = new Set();
    db.comments = db.comments.filter((entry) => {
      const shouldRemove =
        entry.authorId === userId || removedPostIds.has(entry.postId);
      if (shouldRemove) {
        removedCommentIds.add(entry.id);
      }
      return !shouldRemove;
    });

    const removedRelationRequestIds = new Set();
    db.relationRequests = db.relationRequests.filter((entry) => {
      const shouldRemove =
        entry.senderId === userId ||
        entry.recipientId === userId ||
        removedTreeIds.has(entry.treeId);
      if (shouldRemove) {
        removedRelationRequestIds.add(entry.id);
      }
      return !shouldRemove;
    });

    const removedInvitationIds = new Set();
    db.treeInvitations = db.treeInvitations.filter((entry) => {
      const shouldRemove =
        entry.userId === userId || removedTreeIds.has(entry.treeId);
      if (shouldRemove) {
        removedInvitationIds.add(entry.id);
      }
      return !shouldRemove;
    });

    const nextChats = [];
    const removedChatIds = new Set();
    for (const chat of db.chats) {
      if (chat.treeId && removedTreeIds.has(chat.treeId)) {
        removedChatIds.add(chat.id);
        continue;
      }

      const nextParticipantIds = normalizeParticipantIds(
        (chat.participantIds || []).filter((entry) => entry !== userId),
      );
      const nextBranchRootPersonIds = normalizeParticipantIds(
        (chat.branchRootPersonIds || []).filter(
          (entry) => !removedPersonIds.has(entry),
        ),
      );
      const shouldKeep = chat.type === "direct"
        ? nextParticipantIds.length === 2
        : nextParticipantIds.length >= 2;

      if (!shouldKeep) {
        removedChatIds.add(chat.id);
        continue;
      }

      nextChats.push({
        ...chat,
        participantIds: nextParticipantIds,
        branchRootPersonIds: nextBranchRootPersonIds,
      });
    }
    db.chats = nextChats;
    const activeChatIds = new Set(nextChats.map((chat) => chat.id));
    db.messages = db.messages.filter((entry) => {
      return (
        entry.senderId !== userId &&
        (!Array.isArray(entry.participants) ||
          !entry.participants.includes(userId)) &&
        activeChatIds.has(entry.chatId)
      );
    });
    db.chatDrafts = db.chatDrafts.filter((entry) => {
      return entry.userId !== userId && activeChatIds.has(entry.chatId);
    });
    const activeMessageIds = new Set(
      db.messages.map((entry) => String(entry?.id || "").trim()).filter(Boolean),
    );
    db.chatPins = ensureChatPins(db).filter((entry) => {
      return (
        activeChatIds.has(entry.chatId) &&
        activeMessageIds.has(String(entry?.messageId || "").trim()) &&
        entry.pinnedBy !== userId
      );
    });

    db.notifications = db.notifications.filter((entry) => {
      if (entry.userId === userId) {
        return false;
      }

      const data = entry.data && typeof entry.data === "object" ? entry.data : {};
      if (
        data.userId === userId ||
        data.senderId === userId ||
        data.recipientId === userId ||
        data.actorId === userId ||
        data.targetUserId === userId ||
        data.authorId === userId ||
        data.ownerId === userId
      ) {
        return false;
      }

      if (
        (data.chatId && removedChatIds.has(data.chatId)) ||
        (data.treeId && removedTreeIds.has(data.treeId)) ||
        (data.postId && removedPostIds.has(data.postId)) ||
        (data.commentId && removedCommentIds.has(data.commentId)) ||
        (data.requestId && removedRelationRequestIds.has(data.requestId)) ||
        (data.invitationId && removedInvitationIds.has(data.invitationId))
      ) {
        return false;
      }

      return true;
    });

    db.reports = db.reports.filter((entry) => {
      return (
        entry.reporterId !== userId &&
        entry.resolvedBy !== userId &&
        !(
          entry.targetType === "user" &&
          entry.targetId === userId
        ) &&
        !(
          entry.targetType === "post" &&
          removedPostIds.has(entry.targetId)
        ) &&
        !(
          entry.targetType === "comment" &&
          removedCommentIds.has(entry.targetId)
        ) &&
        !(
          entry.targetType === "tree" &&
          removedTreeIds.has(entry.targetId)
        ) &&
        !(
          entry.targetType === "chat" &&
          removedChatIds.has(entry.targetId)
        )
      );
    });
    db.blocks = db.blocks.filter((entry) => {
      return entry.blockerId !== userId && entry.blockedUserId !== userId;
    });
    db.pushDevices = db.pushDevices.filter((entry) => entry.userId !== userId);
    const activeNotificationIds = new Set(db.notifications.map((entry) => entry.id));
    db.pushDeliveries = db.pushDeliveries.filter((entry) => {
      return (
        entry.userId !== userId &&
        (!entry.notificationId || activeNotificationIds.has(entry.notificationId))
      );
    });

    // ── GDPR completeness sweep ──────────────────────────────────────
    // Every record that ties the deleted user's id to user-visible
    // surface must be either removed or anonymized. The original
    // deleteUser missed reactions on OTHER users' content
    // ("Иван reacted ❤️" stayed visible after Иван's account was
    // deleted) and a few audit-side records that name the user.
    if (Array.isArray(db.postReactions)) {
      db.postReactions = db.postReactions.filter((entry) => {
        return entry.userId !== userId && !removedPostIds.has(entry.postId);
      });
    }
    if (Array.isArray(db.postCommentReactions)) {
      db.postCommentReactions = db.postCommentReactions.filter((entry) => {
        return (
          entry.userId !== userId &&
          !removedCommentIds.has(entry.commentId)
        );
      });
    }
    if (Array.isArray(db.storyReactions)) {
      db.storyReactions = db.storyReactions.filter(
        (entry) => entry.userId !== userId,
      );
    }
    if (Array.isArray(db.messageReactions)) {
      db.messageReactions = db.messageReactions.filter((entry) => {
        return (
          entry.userId !== userId &&
          (!entry.messageId || activeMessageIds.has(String(entry.messageId).trim()))
        );
      });
    }
    if (Array.isArray(db.profileContributions)) {
      db.profileContributions = db.profileContributions.filter((entry) => {
        return entry.contributorId !== userId && entry.targetUserId !== userId;
      });
    }
    if (Array.isArray(db.mergeProposals)) {
      db.mergeProposals = db.mergeProposals.filter((entry) => {
        return (
          entry.proposerId !== userId &&
          !removedTreeIds.has(entry.treeId)
        );
      });
    }
    if (Array.isArray(db.identityClaims)) {
      db.identityClaims = db.identityClaims.filter(
        (entry) => entry.claimerId !== userId,
      );
    }
    if (Array.isArray(db.calls)) {
      // Drop calls where the deleted user was the only initiator,
      // and scrub the user from participant lists of group calls.
      const filteredCalls = [];
      for (const call of db.calls) {
        if (call.initiatorId === userId) continue;
        if (Array.isArray(call.participantIds)) {
          call.participantIds = call.participantIds.filter(
            (id) => id !== userId,
          );
          if (call.participantIds.length === 0) continue;
        }
        filteredCalls.push(call);
      }
      db.calls = filteredCalls;
    }
    // Anonymize rather than delete — change records are an audit
    // log; preserving them as "deleted user changed X" keeps the
    // tree's history intact while removing the personal identifier.
    // Right-to-erasure under GDPR allows pseudonymization for
    // legitimate-interest audit logs (recital 26).
    this._pseudonymizeTreeChangeActor(db, userId);
    if (Array.isArray(db.identityFieldConflicts)) {
      // Phase 1.3: drop conflict rows that touch trees or persons
      // we just removed (the surface they referred to is gone),
      // and pseudonymize `resolvedBy` on the rest — same GDPR
      // tradeoff as treeChangeRecords above.
      db.identityFieldConflicts = db.identityFieldConflicts.filter(
        (entry) =>
          !removedTreeIds.has(entry.targetTreeId) &&
          !removedTreeIds.has(entry.sourceTreeId) &&
          !removedPersonIds.has(entry.targetPersonId) &&
          !removedPersonIds.has(entry.sourcePersonId),
      );
      for (const entry of db.identityFieldConflicts) {
        if (entry.resolvedBy === userId) {
          entry.resolvedBy = "deleted-user";
        }
      }
    }

    this._reconcilePersonIdentities(db);
    return {
      userId,
      removedTreeIds: Array.from(removedTreeIds),
      removedPersonIds: Array.from(removedPersonIds),
      removedChatIds: Array.from(removedChatIds),
      removedPostIds: Array.from(removedPostIds),
      // SPEED-7: точные множества для табличного notification-каскада
      // PostgresStore — реконструкция дифом блоба до/после гонялась бы с
      // конкурентными удалениями других пользователей.
      removedCommentIds: Array.from(removedCommentIds),
      removedRelationRequestIds: Array.from(removedRelationRequestIds),
      removedInvitationIds: Array.from(removedInvitationIds),
    };
    });
    if (result === null) {
      return null;
    }
    this._forgetUser(userId);
    for (const token of deletedSessionTokens) {
      this._forgetSession(token);
    }
    return result;
  }

  async listOwnedMediaUrls(userId) {
    const db = await this._read();
    return collectOwnedMediaUrlsForUser(db, userId);
  }

  async createTree({creatorId, name, description, isPrivate, kind, includeRules = null}) {
    // Phase 3.4-prep fix-1: pre-flight validation на includeRules
    // ДО touch'а DB. `applyIncludeRulesToBranch` throws на explicit
    // invalid type — нужно catch'нуть здесь, чтобы caller (POST
    // /v1/trees route) превратил в 400 БЕЗ partial side-effects
    // (tree уже push'нутый в db, person'а ещё нет, и т.д.).
    if (includeRules && typeof includeRules === "object") {
      const probeBranch = {
        includeRules: {
          type: "manual",
          manualPersonIds: [],
          anchorPersonId: null,
          maxHops: 5,
        },
      };
      applyIncludeRulesToBranch(probeBranch, includeRules);
    }

    const db = await this._read();
    const createdAt = nowIso();
    const normalizedKind = String(kind || "family").trim().toLowerCase() === "friends"
      ? "friends"
      : "family";
    const tree = {
      id: crypto.randomUUID(),
      name: String(name || "").trim(),
      description: String(description || "").trim(),
      creatorId,
      memberIds: [creatorId],
      members: [creatorId],
      createdAt,
      updatedAt: createdAt,
      isPrivate: isPrivate !== false,
      kind: normalizedKind,
      publicSlug: null,
      isCertified: false,
      certificationNote: null,
      // Phase B Ship 5: reverse-FK к семья. Null = tree «свободный»
      // (не bound к семье). createSemya sets к семья.id atomically.
      semyaId: null,
    };

    const creator = db.users.find((entry) => entry.id === creatorId);
    const creatorProfile = creator?.profile || {};
    const creatorIdentity = this._ensureUserIdentity(db, creatorId);
    const creatorPerson = buildPersonRecord({
      treeId: tree.id,
      creatorId,
      userId: creatorId,
      identityId: creatorIdentity?.id || null,
      personData: {
        firstName: creatorProfile.firstName,
        lastName: creatorProfile.lastName,
        middleName: creatorProfile.middleName,
        name: creatorProfile.displayName,
        maidenName: creatorProfile.maidenName,
        photoUrl: creatorProfile.photoUrl,
        gender: creatorProfile.gender,
        birthDate: creatorProfile.birthDate,
      },
    });

    db.trees.push(tree);
    ensureDefaultCirclesForTree(db, tree);
    db.persons.push(creatorPerson);
    if (creatorIdentity) {
      this._attachPersonToIdentity(db, creatorPerson, creatorIdentity, creatorId);
    } else {
      this._reconcilePersonIdentities(db);
    }

    // Phase 3.4-prep (DECISIONS.md 2026-05-10 ответ Q4):
    // если caller передал `includeRules`, применяем поверх default
    // manual rule, который ставит `_syncTreeToBranch`. Делаем после
    // `_attachPersonToIdentity`, чтобы branch уже существовал.
    if (includeRules && typeof includeRules === "object") {
      this._syncTreeToBranch(db, tree);
      const branch = (db.branches || []).find((b) => b.id === tree.id);
      if (branch) {
        applyIncludeRulesToBranch(branch, includeRules);
      }
    }
    this._appendTreeChangeRecord(db, {
      treeId: tree.id,
      actorId: creatorId,
      type: "person.created",
      personId: creatorPerson.id,
      details: {
        after: structuredClone(creatorPerson),
      },
    });
    upsertPersonAttributesForPerson(db, creatorPerson, creatorId);
    await this._write(db);
    return structuredClone(tree);
  }

  async listUserTrees(userId) {
    const db = await this._read();
    return db.trees
      .filter((tree) => {
        return (
          tree.creatorId === userId ||
          (Array.isArray(tree.memberIds) && tree.memberIds.includes(userId))
        );
      })
      .sort((left, right) =>
        String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")),
      )
      .map((tree) => structuredClone(tree));
  }

  async findTree(treeId) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    return tree ? structuredClone(tree) : null;
  }

  // ---------------------------------------------------------------
  // Phase B federated семьи — entity CRUD (Week 2 Ship 1).
  //
  // Атомарный createSemya: семья record + owner membership row,
  // gated через single _write. Pattern mirrors `createTree` + member
  // setup chain, но без legacy fields (tree.memberIds compat shim
  // приходит в Week 3).
  //
  // Invariants enforced на этом layer (см. ENTITY-DESIGN.md §3):
  //   - One-tree-per-семья — treeId уникален среди не-deleted семей.
  //   - Membership uniqueness — (semyaId, userId) pair единственный.
  //   - At-least-one-owner — countActiveOwners(semyaId) >= 1
  //     (enforced на role transition + member kick paths в Ship 3+).
  // ---------------------------------------------------------------

  async createSemya({ownerId, name, treeId, description = null}) {
    if (!ownerId || typeof ownerId !== "string") {
      throw new Error("INVALID_OWNER_ID");
    }
    if (!name || typeof name !== "string" || !name.trim()) {
      throw new Error("INVALID_NAME");
    }
    if (!treeId || typeof treeId !== "string") {
      throw new Error("INVALID_TREE_ID");
    }

    const db = await this._read();
    const owner = db.users.find((entry) => entry.id === ownerId);
    if (!owner) {
      throw new Error("OWNER_NOT_FOUND");
    }
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      throw new Error("TREE_NOT_FOUND");
    }
    // One-tree-per-семья invariant (§3.1).
    const existingForTree = (db.semyi || []).find(
      (entry) => entry.treeId === treeId && !entry.deletedAt,
    );
    if (existingForTree) {
      throw new Error("TREE_ALREADY_BOUND");
    }

    const createdAt = nowIso();
    const semya = {
      id: crypto.randomUUID(),
      name: name.trim(),
      ownerId,
      treeId,
      description: description ? String(description).trim() : null,
      createdAt,
      updatedAt: createdAt,
      deletedAt: null,
    };
    const ownerMembership = {
      id: crypto.randomUUID(),
      semyaId: semya.id,
      userId: ownerId,
      role: "owner",
      joinedAt: createdAt,
      invitedByUserId: null,
      hasInviteGrant: true,
      hiddenAt: null,
    };

    db.semyi.push(semya);
    db.semyaMembers.push(ownerMembership);

    // Phase B Ship 5: reverse-FK + dual-write. Write tree.semyaId
    // atomically с семья record так чтобы requireTreeAccess (когда
    // feature flag ON) могла O(1) lookup семья без index walk.
    // Owner уже в tree.memberIds[] (createTree always seeds
    // memberIds: [creatorId]), поэтому не дублируем здесь.
    tree.semyaId = semya.id;

    await this._write(db);
    return structuredClone(semya);
  }

  // Phase B: легаси-пути вступления в дерево (accept tree-инвайта,
  // identity-attach, person-create-with-userId, restore из корзины)
  // писали только tree.memberIds. Для дерева, привязанного к семье,
  // этого мало: с RODNYA_FEDERATED_SEMYI_ENABLED=true доступ решает
  // ИСКЛЮЧИТЕЛЬНО членство в семье — без dual-write новый участник
  // ловил бы 403 сразу после флипа. Роль viewer — как в миграции
  // (решение Q1: безопасный дефолт, owner повышает вручную).
  _ensureSemyaMembershipForLegacyJoin(db, tree, userId) {
    const normalizedUserId = String(userId || "").trim();
    const semyaId = String(tree?.semyaId || "").trim();
    if (!normalizedUserId || !semyaId) {
      return;
    }
    const semya = (db.semyi || []).find((entry) => entry.id === semyaId);
    if (!semya || semya.deletedAt) {
      return;
    }
    db.semyaMembers = Array.isArray(db.semyaMembers) ? db.semyaMembers : [];
    const existing = db.semyaMembers.find(
      (entry) =>
        entry.semyaId === semyaId && entry.userId === normalizedUserId,
    );
    if (existing) {
      // Явное повторное вступление снимает скрытие (kick) — как re-invite.
      existing.hiddenAt = null;
      return;
    }
    db.semyaMembers.push({
      id: crypto.randomUUID(),
      semyaId,
      userId: normalizedUserId,
      role: "viewer",
      joinedAt: nowIso(),
      invitedByUserId: null,
      hasInviteGrant: false,
      hiddenAt: null,
    });
  }

  async findSemyaById(semyaId) {
    if (!semyaId || typeof semyaId !== "string") {
      return null;
    }
    const db = await this._read();
    const semya = (db.semyi || []).find((entry) => entry.id === semyaId);
    return semya ? structuredClone(semya) : null;
  }

  async listSemyiForUser(userId) {
    if (!userId || typeof userId !== "string") {
      return [];
    }
    const db = await this._read();
    const memberSemyaIds = new Set(
      (db.semyaMembers || [])
        .filter((m) => m.userId === userId && !m.hiddenAt)
        .map((m) => m.semyaId),
    );
    return (db.semyi || [])
      .filter((entry) => !entry.deletedAt && memberSemyaIds.has(entry.id))
      .sort((left, right) =>
        String(right.updatedAt || "").localeCompare(
          String(left.updatedAt || ""),
        ),
      )
      .map((entry) => structuredClone(entry));
  }

  async listMembershipsForSemya(semyaId) {
    if (!semyaId || typeof semyaId !== "string") {
      return [];
    }
    const db = await this._read();
    return (db.semyaMembers || [])
      .filter((m) => m.semyaId === semyaId && !m.hiddenAt)
      .sort((left, right) =>
        String(left.joinedAt || "").localeCompare(String(right.joinedAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  // SPEED-9 B: prefetchedDb — опциональный уже прочитанный блоб
  // (requireTreeAccess в app.js передаёт свой снимок, чтобы не читать
  // блоб дважды за один HTTP-запрос). Без него поведение прежнее.
  async findMembership(semyaId, userId, prefetchedDb = null) {
    if (!semyaId || !userId) {
      return null;
    }
    const db = prefetchedDb || (await this._read());
    const row = (db.semyaMembers || []).find(
      (m) => m.semyaId === semyaId && m.userId === userId && !m.hiddenAt,
    );
    return row ? structuredClone(row) : null;
  }

  async updateSemya({semyaId, actorUserId, name, description}) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!actorUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }
    // Owner-only mutation (Q2 — name editable by owner only).
    const actorMembership = (db.semyaMembers || []).find(
      (m) =>
        m.semyaId === semyaId &&
        m.userId === actorUserId &&
        m.role === "owner" &&
        !m.hiddenAt,
    );
    if (!actorMembership) {
      throw new Error("NOT_OWNER");
    }

    let mutated = false;
    if (name !== undefined && name !== null) {
      if (typeof name !== "string" || !name.trim()) {
        throw new Error("INVALID_NAME");
      }
      const trimmed = name.trim();
      if (trimmed !== semya.name) {
        semya.name = trimmed;
        mutated = true;
      }
    }
    if (description !== undefined) {
      // null clears, string sets, no-op для same value
      const next = description === null ? null : String(description).trim();
      const current = semya.description ?? null;
      if (next !== current) {
        semya.description = next;
        mutated = true;
      }
    }

    if (mutated) {
      semya.updatedAt = nowIso();
      await this._write(db);
    }
    return structuredClone(semya);
  }

  // ---------------------------------------------------------------
  // Membership mutations (Ship 3). Built на findMembership +
  // listMembershipsForSemya (Ship 1) + access patterns в Ship 2 routes.
  //
  // Invariants enforced (ENTITY-DESIGN §3):
  //   - addMembership: role ∈ {editor, viewer} (owner role only через
  //     PATCH promote либо initial createSemya), one membership per
  //     (semyaId, userId) pair (idempotent re-call).
  //   - updateMembership: role transitions allowed only by owner.
  //     Self role change blocked (always need another owner для
  //     self-demote). Last-owner demote rejected.
  //     hasInviteGrant toggle meaningful только для editor.
  //   - removeMembership: self-leave permitted (если не последний
  //     owner). Kick others requires owner role.
  // ---------------------------------------------------------------

  _countActiveOwners(db, semyaId) {
    return (db.semyaMembers || []).filter(
      (m) => m.semyaId === semyaId && m.role === "owner" && !m.hiddenAt,
    ).length;
  }

  async addMembership({
    semyaId,
    userId,
    role,
    invitedByUserId,
    hasInviteGrant = false,
  }) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!userId || typeof userId !== "string") {
      throw new Error("INVALID_USER_ID");
    }
    if (role !== "editor" && role !== "viewer") {
      throw new Error("INVALID_ROLE");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }
    const user = (db.users || []).find((entry) => entry.id === userId);
    if (!user) {
      throw new Error("USER_NOT_FOUND");
    }
    // Idempotent — если already member (любой role), return existing.
    const existing = (db.semyaMembers || []).find(
      (m) => m.semyaId === semyaId && m.userId === userId && !m.hiddenAt,
    );
    if (existing) {
      return {created: false, membership: structuredClone(existing)};
    }
    // hasInviteGrant only meaningful для editor (ENTITY-DESIGN §3.4).
    const grant = role === "editor" ? !!hasInviteGrant : false;
    const createdAt = nowIso();
    const membership = {
      id: crypto.randomUUID(),
      semyaId,
      userId,
      role,
      joinedAt: createdAt,
      invitedByUserId: invitedByUserId || null,
      hasInviteGrant: grant,
      hiddenAt: null,
    };
    db.semyaMembers.push(membership);
    // Phase B Ship 5: dual-write к tree.memberIds[] для backward
    // compat пока legacy tree-routes (requireTreeAccess pre-Phase-B
    // path) sunset не закроется (Week 8 staged rollout). Без этого
    // existing endpoints не видели бы новых членов семьи.
    const tree = (db.trees || []).find((t) => t.id === semya.treeId);
    if (tree) {
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      if (!tree.memberIds.includes(userId)) {
        tree.memberIds.push(userId);
      }
      // Legacy `tree.members` alias — same content, preserved.
      tree.members = Array.isArray(tree.members) ? tree.members : [];
      if (!tree.members.includes(userId)) {
        tree.members.push(userId);
      }
    }
    await this._write(db);
    return {created: true, membership: structuredClone(membership)};
  }

  async updateMembership({
    semyaId,
    targetUserId,
    actorUserId,
    role,
    hasInviteGrant,
  }) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!targetUserId || typeof targetUserId !== "string") {
      throw new Error("INVALID_USER_ID");
    }
    if (!actorUserId) {
      throw new Error("INVALID_ACTOR");
    }
    if (role !== undefined && !["owner", "editor", "viewer"].includes(role)) {
      throw new Error("INVALID_ROLE");
    }
    if (role === undefined && hasInviteGrant === undefined) {
      throw new Error("NO_CHANGES");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }
    const actor = (db.semyaMembers || []).find(
      (m) =>
        m.semyaId === semyaId &&
        m.userId === actorUserId &&
        m.role === "owner" &&
        !m.hiddenAt,
    );
    if (!actor) {
      throw new Error("NOT_OWNER");
    }
    const target = (db.semyaMembers || []).find(
      (m) =>
        m.semyaId === semyaId && m.userId === targetUserId && !m.hiddenAt,
    );
    if (!target) {
      throw new Error("MEMBERSHIP_NOT_FOUND");
    }

    let mutated = false;
    if (role !== undefined && role !== target.role) {
      // Self role change blocked (ENTITY-DESIGN §2.1 «Owner → editor
      // требует ≥1 другой active owner»; self-promotion uncommon
      // case but blocked для symmetry, requires другой owner).
      if (targetUserId === actorUserId) {
        throw new Error("SELF_ROLE_CHANGE_FORBIDDEN");
      }
      // Demote owner → editor/viewer requires ≥1 другой owner remaining.
      if (target.role === "owner" && role !== "owner") {
        if (this._countActiveOwners(db, semyaId) <= 1) {
          throw new Error("LAST_OWNER_DEMOTE_FORBIDDEN");
        }
      }
      target.role = role;
      // Clear invite grant when not editor (ENTITY-DESIGN §3.4).
      if (role !== "editor") {
        target.hasInviteGrant = false;
      }
      mutated = true;
    }
    if (hasInviteGrant !== undefined) {
      const targetRole = target.role; // after possible role change
      if (targetRole !== "editor") {
        // Owner implicitly имеет invite power; viewer cannot invite.
        // Toggle nonsensical для non-editor — reject explicitly.
        throw new Error("INVITE_GRANT_ONLY_EDITOR");
      }
      const next = !!hasInviteGrant;
      if (target.hasInviteGrant !== next) {
        target.hasInviteGrant = next;
        mutated = true;
      }
    }

    if (mutated) {
      semya.updatedAt = nowIso();
      await this._write(db);
    }
    return structuredClone(target);
  }

  async removeMembership({semyaId, targetUserId, actorUserId}) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!targetUserId || typeof targetUserId !== "string") {
      throw new Error("INVALID_USER_ID");
    }
    if (!actorUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }
    const target = (db.semyaMembers || []).find(
      (m) =>
        m.semyaId === semyaId && m.userId === targetUserId && !m.hiddenAt,
    );
    if (!target) {
      throw new Error("MEMBERSHIP_NOT_FOUND");
    }
    const actorIsSelf = targetUserId === actorUserId;
    if (!actorIsSelf) {
      // Kick others — owner only.
      const actor = (db.semyaMembers || []).find(
        (m) =>
          m.semyaId === semyaId &&
          m.userId === actorUserId &&
          m.role === "owner" &&
          !m.hiddenAt,
      );
      if (!actor) {
        throw new Error("NOT_OWNER");
      }
    }
    // At-least-one-owner invariant. Both kick + self-leave paths check.
    if (target.role === "owner" && this._countActiveOwners(db, semyaId) <= 1) {
      throw new Error("LAST_OWNER_REMOVE_FORBIDDEN");
    }

    const removedAt = nowIso();
    target.hiddenAt = removedAt;
    semya.updatedAt = removedAt;
    // Phase B Ship 5: dual-write cleanup tree.memberIds[] так чтобы
    // legacy tree-routes (pre-Phase-B path) тоже видели removal.
    // NB: tree.creatorId preserved — никогда не «kick'аем» creator
    // из legacy field, иначе tree-routes гасят весь access. После
    // semya.deletedAt (Q4 orphan policy) tree becomes inaccessible
    // через семья model только.
    const tree = (db.trees || []).find((t) => t.id === semya.treeId);
    if (tree && targetUserId !== tree.creatorId) {
      if (Array.isArray(tree.memberIds)) {
        tree.memberIds = tree.memberIds.filter((id) => id !== targetUserId);
      }
      if (Array.isArray(tree.members)) {
        tree.members = tree.members.filter((id) => id !== targetUserId);
      }
    }
    await this._write(db);
    return {membership: structuredClone(target), wasSelfLeave: actorIsSelf};
  }

  // ---------------------------------------------------------------
  // Invitation flow (Ship 4). State machine: pending → accepted |
  // revoked | expired. Simpler than kinship-checks (no reject ветка
  // — recipient just не accept'ит до expiry либо revoke).
  //
  // Mirror Phase 6.5 kinship-checks lazy-expiry pattern: each read
  // sweeps invitations for этого semyaId where expiresAt < now()
  // и status='pending' → status='expired'. Reduces background-job
  // surface (no separate sweep task needed Ship 4).
  // ---------------------------------------------------------------

  _lazyExpireInvitations(db, semyaId) {
    const now = Date.now();
    let mutated = false;
    for (const inv of db.semyaInvitations || []) {
      if (semyaId && inv.semyaId !== semyaId) continue;
      if (inv.status !== "pending") continue;
      const expiresAtMs = inv.expiresAt ? Date.parse(inv.expiresAt) : null;
      if (expiresAtMs && expiresAtMs <= now) {
        inv.status = "expired";
        inv.expiredAt = nowIso();
        mutated = true;
      }
    }
    return mutated;
  }

  async createInvitation({
    semyaId,
    inviterUserId,
    recipientUserId = null,
    recipientEmail = null,
    recipientPhone = null,
    role,
    expiresInDays = 30,
  }) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!inviterUserId) {
      throw new Error("INVALID_INVITER");
    }
    if (role !== "editor" && role !== "viewer") {
      throw new Error("INVALID_ROLE");
    }
    const hasRecipient =
      (recipientUserId && typeof recipientUserId === "string") ||
      (recipientEmail && typeof recipientEmail === "string") ||
      (recipientPhone && typeof recipientPhone === "string");
    if (!hasRecipient) {
      throw new Error("MISSING_RECIPIENT");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }
    // Validate recipientUserId if provided.
    if (recipientUserId) {
      const recipient = (db.users || []).find((u) => u.id === recipientUserId);
      if (!recipient) {
        throw new Error("RECIPIENT_NOT_FOUND");
      }
      // Если recipient already member → no point creating invitation.
      const existingMembership = (db.semyaMembers || []).find(
        (m) =>
          m.semyaId === semyaId &&
          m.userId === recipientUserId &&
          !m.hiddenAt,
      );
      if (existingMembership) {
        throw new Error("ALREADY_MEMBER");
      }
    }

    // Lazy-expire previous invitations for этого семья перед
    // duplicate-check (так stale pending не блокирует resend).
    this._lazyExpireInvitations(db, semyaId);

    // Idempotent re-create — if existing pending invitation для same
    // (semyaId, recipientUserId либо recipientEmail/Phone) → return it.
    let existing = null;
    if (recipientUserId) {
      existing = (db.semyaInvitations || []).find(
        (inv) =>
          inv.semyaId === semyaId &&
          inv.recipientUserId === recipientUserId &&
          inv.status === "pending",
      );
    } else if (recipientEmail) {
      const targetEmail = recipientEmail.toLowerCase().trim();
      existing = (db.semyaInvitations || []).find(
        (inv) =>
          inv.semyaId === semyaId &&
          (inv.recipientEmail || "").toLowerCase() === targetEmail &&
          inv.status === "pending",
      );
    } else if (recipientPhone) {
      const targetPhone = recipientPhone.replace(/\s+/g, "");
      existing = (db.semyaInvitations || []).find(
        (inv) =>
          inv.semyaId === semyaId &&
          (inv.recipientPhone || "").replace(/\s+/g, "") === targetPhone &&
          inv.status === "pending",
      );
    }
    if (existing) {
      return {created: false, invitation: structuredClone(existing)};
    }

    const createdAt = nowIso();
    const expiresAt = new Date(
      Date.now() + Math.max(1, expiresInDays) * 24 * 60 * 60 * 1000,
    ).toISOString();
    const invitation = {
      id: crypto.randomUUID(),
      // Token = uuid (32-char URL-safe). Sufficient entropy для
      // shareable link capability. Treat как Bearer secret.
      token: crypto.randomUUID() + crypto.randomUUID().replace(/-/g, ""),
      semyaId,
      inviterUserId,
      recipientUserId: recipientUserId || null,
      recipientEmail: recipientEmail
        ? String(recipientEmail).toLowerCase().trim()
        : null,
      recipientPhone: recipientPhone
        ? String(recipientPhone).trim()
        : null,
      role,
      createdAt,
      expiresAt,
      status: "pending",
      acceptedAt: null,
      revokedAt: null,
      revokedByUserId: null,
      expiredAt: null,
    };
    db.semyaInvitations.push(invitation);
    await this._write(db);
    return {created: true, invitation: structuredClone(invitation)};
  }

  async findInvitationByToken(token) {
    if (!token || typeof token !== "string") {
      return null;
    }
    const db = await this._read();
    this._lazyExpireInvitations(db, null);
    const found = (db.semyaInvitations || []).find((inv) => inv.token === token);
    return found ? structuredClone(found) : null;
  }

  async listInvitationsForSemya(semyaId) {
    if (!semyaId || typeof semyaId !== "string") {
      return [];
    }
    const db = await this._read();
    this._lazyExpireInvitations(db, semyaId);
    return (db.semyaInvitations || [])
      .filter((inv) => inv.semyaId === semyaId)
      .sort((a, b) =>
        String(b.createdAt || "").localeCompare(String(a.createdAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  // Ship FE9 (2026-05-27): list invitations addressed к caller — used
  // by onboarding wizard к surface «У вас есть приглашение от семьи X»
  // CTA. Returns only `pending` status invitations matched по userId
  // либо email (с lazy expiry sweep). Each row enriched с denormalized
  // semya name to spare frontend extra round-trip.
  //
  // Matching logic:
  //   • recipientUserId == userId — explicit user-targeted invitation
  //   • recipientEmail == email AND recipientUserId == null —
  //     email-only invitation matches after user registered с тем же
  //     email (typical post-registration flow для invitations sent
  //     before user existed)
  //
  // Phone matches not supported здесь (phone-based invitations rare).
  async listPendingInvitationsForUser({userId, email}) {
    if (!userId || typeof userId !== "string") {
      return [];
    }
    const normalizedEmail = (email || "").toLowerCase().trim();
    const db = await this._read();
    this._lazyExpireInvitations(db, null);
    const matching = (db.semyaInvitations || []).filter((inv) => {
      if (inv.status !== "pending") return false;
      if (inv.recipientUserId === userId) return true;
      if (!inv.recipientUserId && normalizedEmail) {
        const invEmail = (inv.recipientEmail || "").toLowerCase().trim();
        if (invEmail && invEmail === normalizedEmail) return true;
      }
      return false;
    });
    // Enrich с семя name. Soft-deleted semya excluded (their pending
    // invitations stale — recipient cannot accept anyway).
    const enriched = [];
    for (const inv of matching) {
      const semya = (db.semyi || []).find(
        (s) => s.id === inv.semyaId && !s.deletedAt,
      );
      if (!semya) continue;
      const clone = structuredClone(inv);
      clone.semyaName = semya.name;
      enriched.push(clone);
    }
    return enriched.sort((a, b) =>
      String(b.createdAt || "").localeCompare(String(a.createdAt || "")),
    );
  }

  async acceptInvitation({token, acceptingUserId}) {
    if (!token || typeof token !== "string") {
      throw new Error("INVALID_TOKEN");
    }
    if (!acceptingUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    this._lazyExpireInvitations(db, null);
    const invitation = (db.semyaInvitations || []).find(
      (inv) => inv.token === token,
    );
    if (!invitation) {
      throw new Error("INVITATION_NOT_FOUND");
    }
    if (invitation.status !== "pending") {
      throw new Error("INVITATION_NOT_PENDING");
    }
    // If invitation targets specific user, accepting user must match.
    // Иначе (email/phone либо bare token mode) — any authenticated
    // user with token can accept (token = capability).
    if (
      invitation.recipientUserId &&
      invitation.recipientUserId !== acceptingUserId
    ) {
      throw new Error("WRONG_RECIPIENT");
    }

    const semya = (db.semyi || []).find(
      (entry) => entry.id === invitation.semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }

    // Atomic accept + membership create.
    const now = nowIso();
    invitation.status = "accepted";
    invitation.acceptedAt = now;

    // Idempotent membership add — если already member (race либо
    // hidden re-join), skip new row.
    const existingMembership = (db.semyaMembers || []).find(
      (m) =>
        m.semyaId === invitation.semyaId &&
        m.userId === acceptingUserId &&
        !m.hiddenAt,
    );
    let membership;
    if (existingMembership) {
      membership = existingMembership;
    } else {
      membership = {
        id: crypto.randomUUID(),
        semyaId: invitation.semyaId,
        userId: acceptingUserId,
        role: invitation.role,
        joinedAt: now,
        invitedByUserId: invitation.inviterUserId,
        hasInviteGrant: false,
        hiddenAt: null,
      };
      db.semyaMembers.push(membership);
    }

    semya.updatedAt = now;
    await this._write(db);
    return {
      invitation: structuredClone(invitation),
      membership: structuredClone(membership),
    };
  }

  async revokeInvitation({invitationId, actingUserId}) {
    if (!invitationId || typeof invitationId !== "string") {
      throw new Error("INVALID_INVITATION_ID");
    }
    if (!actingUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    const invitation = (db.semyaInvitations || []).find(
      (inv) => inv.id === invitationId,
    );
    if (!invitation) {
      throw new Error("INVITATION_NOT_FOUND");
    }
    // Per Ship 4 spec: revoker = inviter либо semya owner.
    const isInviter = invitation.inviterUserId === actingUserId;
    let isOwner = false;
    if (!isInviter) {
      isOwner = !!(db.semyaMembers || []).find(
        (m) =>
          m.semyaId === invitation.semyaId &&
          m.userId === actingUserId &&
          m.role === "owner" &&
          !m.hiddenAt,
      );
    }
    if (!isInviter && !isOwner) {
      throw new Error("NOT_INVITER_OR_OWNER");
    }
    if (invitation.status !== "pending") {
      throw new Error("INVITATION_NOT_PENDING");
    }

    const now = nowIso();
    invitation.status = "revoked";
    invitation.revokedAt = now;
    invitation.revokedByUserId = actingUserId;

    await this._write(db);
    return structuredClone(invitation);
  }

  // ---------------------------------------------------------------
  // Browse tokens (Ship 7). Per ENTITY-DESIGN §1.5 + SHARED-TREE-
  // PROPOSAL §3.4 Mode 2. Token = capability — anyone с valid token
  // gets ephemeral read-only access. NOT persistent membership.
  //
  // Token chains explicitly blocked в Ship 7: browse holder cannot
  // generate new tokens (per Артёма recommendation). Direct invites
  // only — owner либо editor с invite-grant generate tokens.
  // ---------------------------------------------------------------

  async createBrowseToken({semyaId, createdByUserId, expiresInDays = 30}) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!createdByUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }

    const createdAt = nowIso();
    const expiresAt = new Date(
      Date.now() + Math.max(1, expiresInDays) * 24 * 60 * 60 * 1000,
    ).toISOString();
    const token = {
      id: crypto.randomUUID(),
      // Capability secret — same 2× uuid construction как invitation
      // tokens. Logging plaintext запрещено (see semya-browse-routes
      // comment).
      token: crypto.randomUUID() + crypto.randomUUID().replace(/-/g, ""),
      semyaId,
      createdByUserId,
      createdAt,
      expiresAt,
      revokedAt: null,
      lastUsedAt: null,
    };
    db.semyaBrowseTokens.push(token);
    await this._write(db);
    return structuredClone(token);
  }

  async findBrowseTokenByValue(tokenValue) {
    if (!tokenValue || typeof tokenValue !== "string") {
      return null;
    }
    const db = await this._read();
    const found = (db.semyaBrowseTokens || []).find(
      (t) => t.token === tokenValue,
    );
    return found ? structuredClone(found) : null;
  }

  async findBrowseTokenById(tokenId) {
    if (!tokenId || typeof tokenId !== "string") {
      return null;
    }
    const db = await this._read();
    const found = (db.semyaBrowseTokens || []).find((t) => t.id === tokenId);
    return found ? structuredClone(found) : null;
  }

  async listBrowseTokensForSemya(semyaId) {
    if (!semyaId || typeof semyaId !== "string") {
      return [];
    }
    const db = await this._read();
    return (db.semyaBrowseTokens || [])
      .filter((t) => t.semyaId === semyaId)
      .sort((a, b) =>
        String(b.createdAt || "").localeCompare(String(a.createdAt || "")),
      )
      .map((t) => structuredClone(t));
  }

  // Touches lastUsedAt (best-effort analytics — does NOT throw).
  // Called from GET /v1/browse/:token on resolve.
  async touchBrowseTokenLastUsed(tokenId) {
    if (!tokenId) return;
    try {
      const db = await this._read();
      const found = (db.semyaBrowseTokens || []).find((t) => t.id === tokenId);
      if (!found) return;
      found.lastUsedAt = nowIso();
      await this._write(db);
    } catch (_) {
      // best-effort
    }
  }

  async revokeBrowseToken({tokenId, actingUserId}) {
    if (!tokenId || typeof tokenId !== "string") {
      throw new Error("INVALID_TOKEN_ID");
    }
    if (!actingUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    const token = (db.semyaBrowseTokens || []).find((t) => t.id === tokenId);
    if (!token) {
      throw new Error("TOKEN_NOT_FOUND");
    }
    if (token.revokedAt) {
      throw new Error("TOKEN_ALREADY_REVOKED");
    }
    // Revoker = token creator либо семья owner (per Артёма spec).
    const isCreator = token.createdByUserId === actingUserId;
    let isOwner = false;
    if (!isCreator) {
      isOwner = !!(db.semyaMembers || []).find(
        (m) =>
          m.semyaId === token.semyaId &&
          m.userId === actingUserId &&
          m.role === "owner" &&
          !m.hiddenAt,
      );
    }
    if (!isCreator && !isOwner) {
      throw new Error("NOT_CREATOR_OR_OWNER");
    }

    token.revokedAt = nowIso();
    await this._write(db);
    return structuredClone(token);
  }

  // ---------------------------------------------------------------
  // Hide filter (Ship 8). Per-user opaque personId filter. Stored
  // в db.semyaMemberHiddenPersons composite-key collection
  // ({semyaId, userId, personId, hiddenAt}). Не visible другим
  // members (per ENTITY-DESIGN §1.3) — semantically «не показывать
  // мне». Cross-семя scoped: hiding в семе X не hide twin в семе Y.
  //
  // Storage chosen over membership.hideFilterPersonIds[] array (per
  // original spec) для query efficiency: per-tree filter requires
  // O(1) Set lookup, composite-key row gives natural index. Same
  // semantics, better access pattern.
  // ---------------------------------------------------------------

  async addHidePerson({semyaId, userId, personId}) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!userId || typeof userId !== "string") {
      throw new Error("INVALID_USER_ID");
    }
    if (!personId || typeof personId !== "string") {
      throw new Error("INVALID_PERSON_ID");
    }

    const db = await this._read();
    // Idempotent: existing row → no-op (composite-key unique).
    const existing = (db.semyaMemberHiddenPersons || []).find(
      (h) =>
        h.semyaId === semyaId &&
        h.userId === userId &&
        h.personId === personId,
    );
    if (existing) {
      return {created: false, hide: structuredClone(existing)};
    }
    const hide = {
      semyaId,
      userId,
      personId,
      hiddenAt: nowIso(),
    };
    db.semyaMemberHiddenPersons.push(hide);
    await this._write(db);
    return {created: true, hide: structuredClone(hide)};
  }

  async removeHidePerson({semyaId, userId, personId}) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!userId || typeof userId !== "string") {
      throw new Error("INVALID_USER_ID");
    }
    if (!personId || typeof personId !== "string") {
      throw new Error("INVALID_PERSON_ID");
    }

    const db = await this._read();
    const before = (db.semyaMemberHiddenPersons || []).length;
    db.semyaMemberHiddenPersons = (db.semyaMemberHiddenPersons || []).filter(
      (h) =>
        !(
          h.semyaId === semyaId &&
          h.userId === userId &&
          h.personId === personId
        ),
    );
    const removed = db.semyaMemberHiddenPersons.length < before;
    if (removed) {
      await this._write(db);
    }
    return {removed};
  }

  // SPEED-9 B: prefetchedDb — см. listPersons выше.
  async listHiddenPersonIdsForCaller(semyaId, userId, prefetchedDb = null) {
    if (!semyaId || !userId) {
      return [];
    }
    const db = prefetchedDb || (await this._read());
    return (db.semyaMemberHiddenPersons || [])
      .filter((h) => h.semyaId === semyaId && h.userId === userId)
      .map((h) => h.personId);
  }

  // Soft-delete семья per ENTITY-DESIGN §1.1 lifecycle + Q4 orphan
  // policy. Sets `deletedAt` and hides все memberships (their listings
  // exclude). Persons + relations preserved (orphan), identity links
  // preserve через personIdentities (twin persons в других семей
  // continue работать). Hard-delete background job extends Phase 3.6
  // pattern (90d window — Q5 answer).
  // Notification dispatch к members — async, deferred к Week 3 broadcast
  // scope work (Ship 2 строго CRUD).
  async softDeleteSemya({semyaId, actorUserId}) {
    if (!semyaId || typeof semyaId !== "string") {
      throw new Error("INVALID_SEMYA_ID");
    }
    if (!actorUserId) {
      throw new Error("INVALID_ACTOR");
    }

    const db = await this._read();
    const semya = (db.semyi || []).find(
      (entry) => entry.id === semyaId && !entry.deletedAt,
    );
    if (!semya) {
      throw new Error("SEMYA_NOT_FOUND");
    }
    const actorMembership = (db.semyaMembers || []).find(
      (m) =>
        m.semyaId === semyaId &&
        m.userId === actorUserId &&
        m.role === "owner" &&
        !m.hiddenAt,
    );
    if (!actorMembership) {
      throw new Error("NOT_OWNER");
    }

    const deletedAt = nowIso();
    semya.deletedAt = deletedAt;
    semya.updatedAt = deletedAt;

    // Memberships hidden — listSemyiForUser + findMembership exclude
    // hidden rows, поэтому members перестают видеть семья в их list.
    // Membership records preserved (audit trail).
    for (const m of db.semyaMembers || []) {
      if (m.semyaId === semyaId && !m.hiddenAt) {
        m.hiddenAt = deletedAt;
      }
    }

    await this._write(db);
    return structuredClone(semya);
  }

  _circleMemberCount(db, circle) {
    if (!circle) {
      return 0;
    }
    if (circle.kind === "all_tree") {
      return (Array.isArray(db.persons) ? db.persons : []).filter(
        (person) => person.treeId === circle.treeId,
      ).length;
    }
    return (Array.isArray(db.circleMembers) ? db.circleMembers : []).filter(
      (entry) => entry.treeId === circle.treeId && entry.circleId === circle.id,
    ).length;
  }

  _mapCircleWithCount(db, circle) {
    return {
      ...circle,
      memberCount: this._circleMemberCount(db, circle),
    };
  }

  async listCircles(treeId) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const {changed} = ensureCirclesForTree(db, tree);
    if (changed) {
      await this._write(db);
    }

    return db.circles
      .filter((entry) => entry.treeId === treeId)
      .sort((left, right) => {
        const kindOrder = {
          all_tree: 0,
          favorites: 1,
          descendants_of: 2,
          ancestors_of: 3,
          pair: 4,
          custom: 5,
        };
        const leftOrder = kindOrder[left.kind] ?? 99;
        const rightOrder = kindOrder[right.kind] ?? 99;
        if (leftOrder !== rightOrder) {
          return leftOrder - rightOrder;
        }
        return String(left.name || "").localeCompare(String(right.name || ""));
      })
      .map((circle) => structuredClone(this._mapCircleWithCount(db, circle)));
  }

  async findCircle(treeId, circleId) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }
    const {changed} = ensureCirclesForTree(db, tree);
    if (changed) {
      await this._write(db);
    }
    const circle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === circleId,
    );
    return circle
      ? structuredClone(this._mapCircleWithCount(db, circle))
      : null;
  }

  async createCircle({treeId, name, description = null, createdBy = null}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }
    ensureCirclesForTree(db, tree);
    const circle = createCircleRecord({
      treeId,
      name,
      description,
      createdBy,
      kind: "custom",
    });
    db.circles.push(circle);
    await this._write(db);
    return structuredClone(this._mapCircleWithCount(db, circle));
  }

  async updateCircle({treeId, circleId, name, description = undefined}) {
    const db = await this._read();
    const circle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === circleId,
    );
    if (!circle) {
      return null;
    }
    if (circle.kind !== "custom" && circle.kind !== "favorites") {
      return false;
    }

    const normalizedName = String(name || "").trim();
    if (normalizedName) {
      circle.name = normalizedName;
    }
    if (description !== undefined) {
      circle.description = normalizeNullableString(description);
    }
    circle.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(this._mapCircleWithCount(db, circle));
  }

  async deleteCircle({treeId, circleId}) {
    const db = await this._read();
    const circleIndex = db.circles.findIndex(
      (entry) => entry.treeId === treeId && entry.id === circleId,
    );
    if (circleIndex < 0) {
      return null;
    }
    const circle = db.circles[circleIndex];
    if (circle.kind !== "custom") {
      return false;
    }
    db.circles.splice(circleIndex, 1);
    db.circleMembers = db.circleMembers.filter(
      (entry) => !(entry.treeId === treeId && entry.circleId === circleId),
    );
    for (const post of db.posts) {
      if (post.treeId === treeId && post.circleId === circleId) {
        const {allTreeCircle} = ensureDefaultCirclesForTree(db, treeId);
        post.circleId = allTreeCircle?.id || null;
        post.updatedAt = nowIso();
      }
    }
    await this._write(db);
    return structuredClone(circle);
  }

  async replaceCircleMembers({
    treeId,
    circleId,
    identityIds = [],
    personIds = [],
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }
    ensureCirclesForTree(db, tree);
    const circle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === circleId,
    );
    if (!circle) {
      return null;
    }
    if (circle.kind !== "custom" && circle.kind !== "favorites") {
      return false;
    }

    const identityIdsFromPersons = (Array.isArray(personIds) ? personIds : [])
      .map((personId) => {
        const normalizedPersonId = normalizeNullableString(personId);
        return db.persons.find(
          (person) => person.treeId === treeId && person.id === normalizedPersonId,
        )?.identityId;
      })
      .filter(Boolean);
    const normalizedIdentityIds = normalizeCircleMemberIdentityIds(db, treeId, [
      ...identityIds,
      ...identityIdsFromPersons,
    ]);
    const timestamp = nowIso();
    db.circleMembers = db.circleMembers.filter(
      (entry) => !(entry.treeId === treeId && entry.circleId === circleId),
    );
    for (const identityId of normalizedIdentityIds) {
      db.circleMembers.push({
        id: crypto.randomUUID(),
        treeId,
        circleId,
        identityId,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    }
    circle.updatedAt = timestamp;
    await this._write(db);
    return structuredClone(this._mapCircleWithCount(db, circle));
  }

  async listCircleMembers(treeId, circleId) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }
    const {changed} = ensureCirclesForTree(db, tree);
    if (changed) {
      await this._write(db);
    }
    const circle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === circleId,
    );
    if (!circle) {
      return null;
    }
    if (circle.kind === "all_tree") {
      return db.persons
        .filter((person) => person.treeId === treeId)
        .map((person) => ({
          treeId,
          circleId,
          identityId: normalizeNullableString(person.identityId),
          personId: person.id,
        }))
        .filter((entry) => entry.identityId)
        .map((entry) => structuredClone(entry));
    }
    return db.circleMembers
      .filter((entry) => entry.treeId === treeId && entry.circleId === circleId)
      .map((entry) => structuredClone(entry));
  }

  async removeTreeForUser({treeId, userId}) {
    const db = await this._read();
    const treeIndex = db.trees.findIndex((entry) => entry.id === treeId);
    if (treeIndex < 0) {
      return null;
    }

    const tree = db.trees[treeIndex];
    tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    tree.members = Array.isArray(tree.members) ? tree.members : [];

    const isCreator = tree.creatorId === userId;
    const isMember = tree.memberIds.includes(userId) || tree.members.includes(userId);
    if (!isCreator && !isMember) {
      return false;
    }

    if (isCreator) {
      db.trees.splice(treeIndex, 1);
      db.persons = db.persons.filter((entry) => entry.treeId !== treeId);
      db.relations = db.relations.filter((entry) => entry.treeId !== treeId);
      db.circles = db.circles.filter((entry) => entry.treeId !== treeId);
      db.circleMembers = db.circleMembers.filter(
        (entry) => entry.treeId !== treeId,
      );
      const removedChatIds = db.chats
        .filter((entry) => entry.treeId === treeId)
        .map((entry) => entry.id);
      db.chats = db.chats.filter((entry) => entry.treeId !== treeId);
      db.messages = db.messages.filter(
        (entry) => !removedChatIds.includes(entry.chatId),
      );
      db.relationRequests = db.relationRequests.filter(
        (entry) => entry.treeId !== treeId,
      );
      db.treeInvitations = db.treeInvitations.filter(
        (entry) => entry.treeId !== treeId,
      );
      const removedPostIds = db.posts
        .filter((entry) => entry.treeId === treeId)
        .map((entry) => entry.id);
      db.posts = db.posts.filter((entry) => entry.treeId !== treeId);
      db.stories = db.stories.filter((entry) => entry.treeId !== treeId);
      db.comments = db.comments.filter(
        (entry) => !removedPostIds.includes(entry.postId),
      );
      db.notifications = db.notifications.filter(
        (entry) => entry.data?.treeId !== treeId,
      );

      const creator = db.users.find((entry) => entry.id === userId);
      if (creator && Array.isArray(creator.creatorOfTreeIds)) {
        creator.creatorOfTreeIds = creator.creatorOfTreeIds.filter(
          (entry) => entry !== treeId,
        );
        creator.updatedAt = nowIso();
      }

      await this._write(db);
      return {
        action: "deleted",
        tree: structuredClone(tree),
      };
    }

    tree.memberIds = tree.memberIds.filter((entry) => entry !== userId);
    tree.members = tree.members.filter((entry) => entry !== userId);
    tree.updatedAt = nowIso();

    for (const person of db.persons) {
      if (person.treeId === treeId && person.userId === userId) {
        person.userId = null;
        person.updatedAt = nowIso();
      }
    }

    db.relationRequests = db.relationRequests.filter((entry) => {
      return !(
        entry.treeId === treeId &&
        (entry.senderId === userId || entry.recipientId === userId)
      );
    });
    db.treeInvitations = db.treeInvitations.filter((entry) => {
      return !(entry.treeId === treeId && entry.userId === userId);
    });
    db.notifications = db.notifications.filter((entry) => {
      return !(
        entry.userId === userId &&
        entry.data?.treeId === treeId
      );
    });

    await this._write(db);
    return {
      action: "left",
      tree: structuredClone(tree),
    };
  }

  async findPublicTreeByRouteId(publicTreeId) {
    const db = await this._read();
    const normalizedRouteId = String(publicTreeId || "").trim();
    if (!normalizedRouteId) {
      return null;
    }

    const tree = db.trees.find((entry) => {
      if (entry.isPrivate !== false) {
        return false;
      }

      const publicRouteId = String(entry.publicSlug || entry.id || "").trim();
      return publicRouteId === normalizedRouteId;
    });

    return tree ? structuredClone(tree) : null;
  }

  async ensureTreeMembership(treeId, userId) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    tree.members = Array.isArray(tree.members) ? tree.members : [];

    let changed = false;
    if (!tree.memberIds.includes(userId)) {
      tree.memberIds.push(userId);
      changed = true;
    }
    if (!tree.members.includes(userId)) {
      tree.members.push(userId);
      changed = true;
    }
    this._ensureSemyaMembershipForLegacyJoin(db, tree, userId);

    if (changed) {
      tree.updatedAt = nowIso();
    await this._write(db);
    this._forgetUser(userId);
    for (const entry of db.sessions) {
      if (entry.userId === userId) {
        this._forgetSession(entry.token);
      }
    }
  }

    return structuredClone(tree);
  }

  async linkPersonToUser({treeId, personId, userId}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return undefined;
    }

    if (person.userId && person.userId !== userId) {
      return false;
    }

    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const canonicalIdentity = this._ensureUserIdentity(db, userId);
    if (!canonicalIdentity) {
      return null;
    }

    const existingLinkedPerson = db.persons.find(
      (entry) =>
        entry.treeId === treeId &&
        entry.userId === userId &&
        entry.id !== person.id,
    );
    if (existingLinkedPerson) {
      this._mergePersonIntoClaimTarget(db, {
        treeId,
        preferredPerson: person,
        duplicatePerson: existingLinkedPerson,
        userId,
        actorId: userId,
      });
    }

    person.userId = userId;
    // additive=true: НЕ перезатирать имя/гендер/birthDate/фото
    // существующего слота в дереве. Если владелец дерева заполнил
    // поля под этого человека, они остаются как есть. Если что-то
    // пусто — заполняем из профиля нового пользователя.
    applyCanonicalProfileToPerson(person, user.profile, {additive: true});
    if (!this._attachPersonToIdentity(db, person, canonicalIdentity, userId)) {
      return false;
    }

    tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    tree.members = Array.isArray(tree.members) ? tree.members : [];
    if (!tree.memberIds.includes(userId)) {
      tree.memberIds.push(userId);
    }
    if (!tree.members.includes(userId)) {
      tree.members.push(userId);
    }
    this._ensureSemyaMembershipForLegacyJoin(db, tree, userId);
    tree.updatedAt = nowIso();
    this._reconcilePersonIdentities(db);

    await this._write(db);
    return structuredClone(person);
  }

  /// Снимает привязку пользователя с person record. Имя/гендер/фото
  /// person'а НЕ трогаются — после нового additive-фикса в
  /// linkPersonToUser они и так не должны были быть переписаны;
  /// если до фикса перезаписались, владелец дерева может править их
  /// руками через обычный edit.
  ///
  /// Возвращает:
  ///   * `null` — нет дерева
  ///   * `undefined` — нет такого person'а в дереве
  ///   * `false` — caller (actorId) не имеет прав отвязывать в этом
  ///     дереве (он не владелец)
  ///   * person snapshot после отвязки — успех
  async unlinkUserFromPerson({treeId, personId, actorId}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }
    if (tree.creatorId !== actorId) {
      return false;
    }
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return undefined;
    }
    if (!person.userId) {
      return structuredClone(person);
    }

    const detachedUserId = person.userId;
    person.userId = null;
    person.identityId = null;
    person.updatedAt = nowIso();

    // Если у юзера больше нет ни одной person-карточки в этом
    // дереве — он перестаёт быть «членом» дерева. Иначе у него в
    // available-trees висит дерево, в которое он зайти зайдёт, а
    // увидит пустоту: нет своего person'а, нет «Это вы» индикатора.
    // Юзер-репорт: «раз я Степу отвязал, он не должен видеть дерево».
    const stillHasPersonInTree = db.persons.some(
      (entry) => entry.treeId === treeId && entry.userId === detachedUserId,
    );
    if (!stillHasPersonInTree) {
      if (Array.isArray(tree.memberIds)) {
        tree.memberIds = tree.memberIds.filter(
          (entry) => entry !== detachedUserId,
        );
      }
      if (Array.isArray(tree.members)) {
        tree.members = tree.members.filter(
          (entry) => entry !== detachedUserId,
        );
      }
      tree.updatedAt = nowIso();
    }

    this._reconcilePersonIdentities(db);

    await this._write(db);
    return structuredClone(person);
  }

  async ensureUserPersonInTree({treeId, userId, creatorId = userId}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const canonicalIdentity = this._ensureUserIdentity(db, userId);
    if (!canonicalIdentity) {
      return null;
    }

    const existingPerson = db.persons.find(
      (entry) => entry.treeId === treeId && entry.userId === userId,
    );
    if (existingPerson) {
      const user = db.users.find((entry) => entry.id === userId);
      // additive=true по той же причине что и в linkPersonToUser —
      // не затирать имя/гендер существующего person record.
      applyCanonicalProfileToPerson(existingPerson, user?.profile, {
        additive: true,
      });
      this._attachPersonToIdentity(db, existingPerson, canonicalIdentity, userId);
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      tree.members = Array.isArray(tree.members) ? tree.members : [];
      if (!tree.memberIds.includes(userId)) {
        tree.memberIds.push(userId);
      }
      if (!tree.members.includes(userId)) {
        tree.members.push(userId);
      }
      this._ensureSemyaMembershipForLegacyJoin(db, tree, userId);
      tree.updatedAt = nowIso();
      this._reconcilePersonIdentities(db);
      await this._write(db);
      return structuredClone(existingPerson);
    }

    const existingIdentityPerson = db.persons.find(
      (entry) =>
        entry.treeId === treeId &&
        entry.identityId === canonicalIdentity.id &&
        (!entry.userId || entry.userId === userId),
    );
    if (existingIdentityPerson) {
      const user = db.users.find((entry) => entry.id === userId);
      existingIdentityPerson.userId = userId;
      applyCanonicalProfileToPerson(existingIdentityPerson, user?.profile);
      this._attachPersonToIdentity(
        db,
        existingIdentityPerson,
        canonicalIdentity,
        userId,
      );
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      tree.members = Array.isArray(tree.members) ? tree.members : [];
      if (!tree.memberIds.includes(userId)) {
        tree.memberIds.push(userId);
      }
      if (!tree.members.includes(userId)) {
        tree.members.push(userId);
      }
      this._ensureSemyaMembershipForLegacyJoin(db, tree, userId);
      tree.updatedAt = nowIso();
      this._reconcilePersonIdentities(db);
      await this._write(db);
      return structuredClone(existingIdentityPerson);
    }

    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const profile = user.profile || {};
    const person = buildPersonRecord({
      treeId,
      creatorId,
      userId,
      identityId: canonicalIdentity.id,
      personData: {
        firstName: profile.firstName,
        lastName: profile.lastName,
        middleName: profile.middleName,
        name: profile.displayName,
        maidenName: profile.maidenName,
        photoUrl: profile.photoUrl,
        gender: profile.gender,
        birthDate: profile.birthDate,
        birthPlace: profile.birthPlace,
      },
    });
    applyCanonicalProfileToPerson(person, profile);

    db.persons.push(person);
    tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    tree.members = Array.isArray(tree.members) ? tree.members : [];
    if (!tree.memberIds.includes(userId)) {
      tree.memberIds.push(userId);
    }
    if (!tree.members.includes(userId)) {
      tree.members.push(userId);
    }
    this._ensureSemyaMembershipForLegacyJoin(db, tree, userId);
    tree.updatedAt = nowIso();
    this._attachPersonToIdentity(db, person, canonicalIdentity, userId);
    this._reconcilePersonIdentities(db);

    await this._write(db);
    return structuredClone(person);
  }

  // SPEED-9 B: prefetchedDb — опциональный уже прочитанный блоб
  // (например, снимок requireTreeAccess из app.js). Без него — как
  // раньше, честный собственный _read().
  //
  // SPEED-10: usersById строится ОДИН раз на весь вызов (было: db.users
  // .find(...) внутри buildCanonicalPersonView на КАЖДОГО person — O(P×U)).
  async listPersons(treeId, prefetchedDb = null) {
    const db = prefetchedDb || (await this._read());
    const usersById = buildUsersByIdMap(db);
    return db.persons
      .filter((person) => person.treeId === treeId)
      .sort((left, right) => String(left.name || "").localeCompare(String(right.name || "")))
      .map((person) => buildCanonicalPersonView(db, person, {usersById}));
  }

  async findPerson(treeId, personId, prefetchedDb = null) {
    const db = prefetchedDb || (await this._read());
    return this._buildPersonViewFromGraph(db, treeId, personId);
  }

  async findPersonByUserId(treeId, userId) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.treeId === treeId && entry.userId === userId,
    );
    if (!person) return null;
    return this._buildPersonViewFromGraph(db, treeId, person.id);
  }

  // Phase 0 of the unified-graph migration: when the user adds a
  // relative on tree T2, surface relatives they ALREADY entered on
  // any of their other trees so they don't have to re-type the same
  // person. The picker calls this with a name fragment; we walk the
  // user's accessible trees and rank persons by:
  //   1. Whether the person's tree is the currently-open one
  //      (excluded entirely — caller passes excludeTreeId so the
  //      picker doesn't suggest someone already on this tree).
  //   2. Substring match against displayName (case-insensitive).
  // Limit defaults to 20 — UI only shows ~6 at a time, but we
  // overfetch so the user can keep typing without round-tripping.
  //
  // Privacy: scoped to the caller's accessible trees only. We never
  // leak other users' graphs through this endpoint — that's a
  // future Phase 4 feature with explicit consent.
  async searchPersonsForUser({
    userId,
    query = "",
    excludeTreeId = null,
    limit = 20,
  } = {}) {
    const db = await this._read();
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) {
      return [];
    }

    const accessibleTrees = db.trees.filter((tree) =>
      this._userCanAccessTreeRecord(tree, normalizedUserId),
    );
    if (accessibleTrees.length === 0) {
      return [];
    }

    const treeById = new Map(accessibleTrees.map((tree) => [tree.id, tree]));
    const normalizedExcludeTreeId = normalizeNullableString(excludeTreeId);
    const trimmedQuery = String(query || "").trim().toLowerCase();
    const safeLimit = Math.min(
      Math.max(Number(limit) || 20, 1),
      50,
    );

    const matches = [];
    for (const person of db.persons) {
      if (!treeById.has(person.treeId)) {
        continue;
      }
      if (
        normalizedExcludeTreeId &&
        person.treeId === normalizedExcludeTreeId
      ) {
        continue;
      }

      const haystack = String(person.name || "").toLowerCase();
      if (trimmedQuery && !haystack.includes(trimmedQuery)) {
        continue;
      }

      matches.push({
        person,
        tree: treeById.get(person.treeId),
        // Names that START with the query rank before mid-string
        // matches — closer to how iOS/Android contacts pickers feel.
        rank: trimmedQuery && haystack.startsWith(trimmedQuery) ? 0 : 1,
      });

      if (matches.length >= safeLimit * 4) {
        // Cap the inner walk so pathological queries (huge graph,
        // empty query) don't hold the event loop. We still pick the
        // best `safeLimit` after sort; the rest get dropped.
        break;
      }
    }

    matches.sort((left, right) => {
      if (left.rank !== right.rank) {
        return left.rank - right.rank;
      }
      return String(left.person.name || "").localeCompare(
        String(right.person.name || ""),
      );
    });

    return matches.slice(0, safeLimit).map(({person, tree}) => ({
      ...buildCanonicalPersonView(db, person),
      treeName: tree.name || "",
    }));
  }

  async getPersonDossier(treeId, personId) {
    const db = await this._read();
    const personView = this._buildPersonViewFromGraph(db, treeId, personId);
    if (!personView) {
      return null;
    }

    const linkedUser = personView.userId
      ? db.users.find((entry) => entry.id === personView.userId) || null
      : null;

    return {
      person: personView,
      linkedProfile: linkedUser?.profile ? structuredClone(linkedUser.profile) : null,
    };
  }

  _userCanAccessTreeRecord(tree, userId) {
    const normalizedUserId = normalizeNullableString(userId);
    if (!tree || !normalizedUserId) {
      return false;
    }
    const memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    const members = Array.isArray(tree.members) ? tree.members : [];
    return (
      tree.creatorId === normalizedUserId ||
      memberIds.includes(normalizedUserId) ||
      members.includes(normalizedUserId)
    );
  }

  _isPersonSteward(db, person, userId) {
    return personStewardUserIds(db, person).includes(userId);
  }

  // ── Phase 1.2 voltage-indicator matcher ─────────────────────────────
  // For one specific person, find medium+high confidence matches in
  // OTHER trees the user has access to. Used by the 💡 indicator on
  // canvas: cards with at least one suggestion get a small dot, tap
  // it to see the suggestion list, confirm or dismiss.

  async findCrossTreeSuggestionsForPerson({
    userId,
    treeId,
    personId,
    limit = 10,
    // SPEED-8d: route-хендлер identity-suggestions ниже по коду сам
    // вызывает filterLegacyPersonsByGraphVisibility на результате —
    // без этого параметра обе функции читали бы блоб независимо
    // (2 полных _read() на один HTTP-запрос; на PostgresStore это
    // structuredClone всего состояния + версия/сессии round-trip
    // ДВАЖДЫ). Caller передаёт уже прочитанный db, чтобы _read()
    // на запрос был один.
    db: prefetchedDb = null,
  }) {
    const db = prefetchedDb || (await this._read());
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) return [];

    const sourcePerson = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!sourcePerson) return [];

    const accessibleTrees = db.trees.filter((tree) =>
      this._userCanAccessTreeRecord(tree, normalizedUserId),
    );
    if (accessibleTrees.length <= 1) {
      // Only one accessible tree → nothing cross-tree to suggest.
      return [];
    }

    // Build the per-user dismissal set for this source person.
    const dismissedTargetPersonIds = new Set(
      (db.dismissedIdentitySuggestions || [])
        .filter(
          (entry) =>
            entry.userId === normalizedUserId &&
            entry.sourcePersonId === personId,
        )
        .map((entry) => entry.dismissedTargetPersonId),
    );

    return findCrossTreeIdentitySuggestions({
      sourcePerson,
      accessibleTrees,
      persons: db.persons,
      dismissedTargetPersonIds,
      limit,
    });
  }

  async dismissIdentitySuggestion({
    userId,
    sourcePersonId,
    dismissedTargetPersonId,
  }) {
    const db = await this._read();
    const normalizedUserId = normalizeNullableString(userId);
    const normalizedSource = normalizeNullableString(sourcePersonId);
    const normalizedTarget = normalizeNullableString(dismissedTargetPersonId);
    if (!normalizedUserId || !normalizedSource || !normalizedTarget) {
      return false;
    }
    db.dismissedIdentitySuggestions = Array.isArray(
      db.dismissedIdentitySuggestions,
    )
      ? db.dismissedIdentitySuggestions
      : [];
    // Idempotent: don't pile up duplicate dismissal records.
    const exists = db.dismissedIdentitySuggestions.some(
      (entry) =>
        entry.userId === normalizedUserId &&
        entry.sourcePersonId === normalizedSource &&
        entry.dismissedTargetPersonId === normalizedTarget,
    );
    if (exists) return true;
    db.dismissedIdentitySuggestions.push({
      userId: normalizedUserId,
      sourcePersonId: normalizedSource,
      dismissedTargetPersonId: normalizedTarget,
      dismissedAt: nowIso(),
    });
    await this._write(db);
    return true;
  }

  // Manually link two persons under one PersonIdentity. Used when
  // the user confirms a 💡-surfaced suggestion. Idempotent: if both
  // already share an identity, no-op; if one has identity and the
  // other doesn't, the unidentified one inherits; if neither has,
  // a new identity is created and both join.
  //
  // Caller is responsible for verifying that BOTH persons live in
  // trees the userId can access — this method assumes authorization
  // has already happened at the route layer.
  async linkPersonsByIdentity({
    sourceTreeId,
    sourcePersonId,
    targetTreeId,
    targetPersonId,
    actorId = null,
  }) {
    const db = await this._read();
    const sourcePerson = db.persons.find(
      (entry) => entry.id === sourcePersonId && entry.treeId === sourceTreeId,
    );
    const targetPerson = db.persons.find(
      (entry) => entry.id === targetPersonId && entry.treeId === targetTreeId,
    );
    if (!sourcePerson || !targetPerson) return null;

    // Same identity already → no-op.
    const sourceIdentityId = normalizeNullableString(sourcePerson.identityId);
    const targetIdentityId = normalizeNullableString(targetPerson.identityId);
    if (
      sourceIdentityId &&
      targetIdentityId &&
      sourceIdentityId === targetIdentityId
    ) {
      return {sourcePerson, targetPerson, identityId: sourceIdentityId};
    }

    const identities = this._ensurePersonIdentityCollection(db);
    const sourceIdentity = sourceIdentityId
      ? identities.find((entry) => entry.id === sourceIdentityId) || null
      : null;
    const targetIdentity = targetIdentityId
      ? identities.find((entry) => entry.id === targetIdentityId) || null
      : null;

    // Conflict guard: if BOTH identities are claimed by different
    // user accounts, that's a destructive merge (would collapse
    // two real humans' canonical records). Refuse and let the
    // route surface 409 — the user must reconcile via explicit
    // merge proposals (`mergeProposals`) instead.
    const sourceUserClaim = normalizeNullableString(sourceIdentity?.userId);
    const targetUserClaim = normalizeNullableString(targetIdentity?.userId);
    if (
      sourceUserClaim &&
      targetUserClaim &&
      sourceUserClaim !== targetUserClaim
    ) {
      throw new Error("CONFLICTING_IDENTITIES");
    }

    // Pick the canonical identity. Prefer the one that's claimed
    // by a user (it's the "real human"); else either; else create.
    let identity = null;
    if (sourceUserClaim) {
      identity = sourceIdentity;
    } else if (targetUserClaim) {
      identity = targetIdentity;
    } else if (sourceIdentity) {
      identity = sourceIdentity;
    } else if (targetIdentity) {
      identity = targetIdentity;
    }
    if (!identity) {
      identity = createPersonIdentityRecord({
        personIds: [sourcePersonId, targetPersonId],
      });
      identities.push(identity);
    }

    // The OTHER identity (the one we didn't pick) gets retired —
    // its persons reattach to the canonical identity. Without
    // this, both identities would dangle in db.personIdentities
    // and `_reconcilePersonIdentities` would re-split them on
    // the next read. We mark `mergedInto` for audit, then drop
    // the row from the live collection.
    const retiredIdentity = identity === sourceIdentity ? targetIdentity : sourceIdentity;
    if (retiredIdentity && retiredIdentity.id !== identity.id) {
      retiredIdentity.mergedInto = identity.id;
      retiredIdentity.updatedAt = nowIso();
      // Reattach any persons that were on the retired identity.
      for (const otherPerson of db.persons) {
        if (otherPerson.identityId === retiredIdentity.id) {
          otherPerson.identityId = identity.id;
          otherPerson.updatedAt = nowIso();
        }
      }
      // Drop the retired record from the live collection.
      const retiredIdx = identities.findIndex(
        (entry) => entry.id === retiredIdentity.id,
      );
      if (retiredIdx >= 0) {
        identities.splice(retiredIdx, 1);
      }
    }

    // Attach both — _attachPersonToIdentity also re-runs the
    // PersonIdentity reconciliation pass so personIds stays
    // consistent.
    this._attachPersonToIdentity(db, sourcePerson, identity, sourcePerson.userId);
    this._attachPersonToIdentity(db, targetPerson, identity, targetPerson.userId);

    // Audit trail on both trees so each tree's history shows the
    // explicit linking.
    const linkDetails = {
      identityId: identity.id,
      linkedToPersonId: targetPersonId,
      linkedToTreeId: targetTreeId,
    };
    this._appendTreeChangeRecord(db, {
      treeId: sourceTreeId,
      actorId,
      type: "person.identity-linked",
      personId: sourcePersonId,
      details: linkDetails,
    });
    this._appendTreeChangeRecord(db, {
      treeId: targetTreeId,
      actorId,
      type: "person.identity-linked",
      personId: targetPersonId,
      details: {
        identityId: identity.id,
        linkedToPersonId: sourcePersonId,
        linkedToTreeId: sourceTreeId,
      },
    });

    await this._write(db);
    return {
      sourcePerson: structuredClone(sourcePerson),
      targetPerson: structuredClone(targetPerson),
      identityId: identity.id,
    };
  }

  // ── Phase 1.3: edit-time conflict surfacing ─────────────────────────
  // List unresolved identity-field conflicts visible to the user.
  // Auth model: target-side. The user sees a row when it lives on a
  // tree they can access — i.e. "someone's edit on another tree
  // wants to overwrite YOUR copy of mom's name". Source-side
  // visibility isn't useful (the user knows what they wrote) and
  // would also leak conflict existence into trees the user
  // doesn't necessarily have access to.
  async listIdentityConflicts({userId, treeId = null, personId = null}) {
    const db = await this._read();
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) return [];

    const accessibleTreeIds = new Set(
      db.trees
        .filter((tree) =>
          this._userCanAccessTreeRecord(tree, normalizedUserId),
        )
        .map((tree) => tree.id),
    );

    return (db.identityFieldConflicts || [])
      .filter((entry) => !entry.resolvedAt)
      .filter((entry) => accessibleTreeIds.has(entry.targetTreeId))
      .filter((entry) => !treeId || entry.targetTreeId === treeId)
      .filter((entry) => !personId || entry.targetPersonId === personId)
      .map((entry) => structuredClone(entry));
  }

  // Apply the user's resolution. `keep` leaves the target value
  // alone and just marks the row resolved (subsequent propagation
  // sees the resolved row, treats it as muted, and stops nagging
  // about this exact pair). `overwrite` writes sourceValue onto
  // the target person AND refreshes lastPropagatedFields[field]
  // — without that refresh the very next propagation would re-
  // diff `current vs lastWritten` and fire a fresh conflict.
  async resolveIdentityConflict({conflictId, choice, actorId}) {
    if (choice !== "keep" && choice !== "overwrite") {
      throw new Error("INVALID_CHOICE");
    }
    const normalizedActorId = normalizeNullableString(actorId);
    if (!normalizedActorId) {
      throw new Error("FORBIDDEN");
    }
    const db = await this._read();
    if (!Array.isArray(db.identityFieldConflicts)) {
      db.identityFieldConflicts = [];
    }
    const conflict = db.identityFieldConflicts.find(
      (entry) => entry.id === conflictId,
    );
    if (!conflict) return null;
    if (conflict.resolvedAt) {
      // Already resolved — return current state. Idempotent so
      // double-clicks on the resolve button don't 500.
      const targetPerson = db.persons.find(
        (entry) =>
          entry.id === conflict.targetPersonId &&
          entry.treeId === conflict.targetTreeId,
      );
      return {
        conflict: structuredClone(conflict),
        person: targetPerson ? structuredClone(targetPerson) : null,
      };
    }

    const targetTree = db.trees.find(
      (entry) => entry.id === conflict.targetTreeId,
    );
    if (
      !targetTree ||
      !this._userCanAccessTreeRecord(targetTree, normalizedActorId)
    ) {
      throw new Error("FORBIDDEN");
    }
    const targetPerson = db.persons.find(
      (entry) =>
        entry.id === conflict.targetPersonId &&
        entry.treeId === conflict.targetTreeId,
    );
    if (!targetPerson) {
      // Target gone (deleted between conflict creation and now).
      // Drop the row; UI will refetch and stop showing the badge.
      db.identityFieldConflicts = db.identityFieldConflicts.filter(
        (entry) => entry.id !== conflictId,
      );
      await this._write(db);
      return null;
    }

    const nowTs = nowIso();
    if (choice === "overwrite") {
      const previousPersonSnapshot = structuredClone(targetPerson);
      targetPerson[conflict.field] = structuredClone(conflict.sourceValue);
      if (
        !targetPerson.lastPropagatedFields ||
        typeof targetPerson.lastPropagatedFields !== "object"
      ) {
        targetPerson.lastPropagatedFields = {};
      }
      targetPerson.lastPropagatedFields[conflict.field] = structuredClone(
        conflict.sourceValue,
      );
      targetPerson.updatedAt = nowTs;
      targetTree.updatedAt = nowTs;

      this._appendTreeChangeRecord(db, {
        treeId: conflict.targetTreeId,
        actorId: normalizedActorId,
        type: "person.updated",
        personId: conflict.targetPersonId,
        details: {
          before: previousPersonSnapshot,
          after: structuredClone(targetPerson),
          identityConflictResolution: {
            conflictId,
            field: conflict.field,
            choice: "overwrite",
            sourceTreeId: conflict.sourceTreeId,
            sourcePersonId: conflict.sourcePersonId,
          },
        },
      });
      upsertPersonAttributesForPerson(db, targetPerson, normalizedActorId);
    }

    conflict.resolvedAt = nowTs;
    conflict.resolvedBy = normalizedActorId;
    conflict.resolution = choice;

    await this._write(db);
    return {
      conflict: structuredClone(conflict),
      person: structuredClone(targetPerson),
    };
  }

  // SPEED-10: normCache — опциональная Map personId→normalizePersonForScoring
  // (см. identity-matcher.js), построенная и переиспользуемая вызывающим
  // на протяжении ОДНОГО listPendingMergeProposalsForUser: тот же person
  // проверяется тут МНОГОКРАТНО (кандидат в _ensureCrossTreeMergeProposals,
  // потом снова в _markStaleMergeProposals, потом снова в финальном
  // .filter()) — без кэша каждый раз заново гонял normalizeName/
  // normalizeNameTokens/normalizeIsoDate по обеим сторонам (scorePersonPair).
  // Без normCache — прежнее поведение (reviewMergeProposal и т.п.
  // одиночные вызовы, кэш ради одной пары не нужен).
  _scorePersonPairCached(left, right, normCache = null) {
    if (!normCache) {
      return scorePersonPair(left, right);
    }
    const leftKey = left?.id;
    const rightKey = right?.id;
    let leftNorm = leftKey && normCache.get(leftKey);
    if (!leftNorm) {
      leftNorm = normalizePersonForScoring(left);
      if (leftKey) normCache.set(leftKey, leftNorm);
    }
    let rightNorm = rightKey && normCache.get(rightKey);
    if (!rightNorm) {
      rightNorm = normalizePersonForScoring(right);
      if (rightKey) normCache.set(rightKey, rightNorm);
    }
    return scoreNormalizedPersons(leftNorm, rightNorm);
  }

  _mergeProposalStillActionable(db, proposal, normCache = null) {
    if (!proposal || proposal.status !== "pending") {
      return false;
    }
    const fromPerson = db.persons.find(
      (person) => person.id === proposal.fromPersonId,
    );
    const candidatePerson = db.persons.find(
      (person) => person.id === proposal.candidatePersonId,
    );
    if (!fromPerson || !candidatePerson) {
      return false;
    }
    if (
      fromPerson.id === candidatePerson.id ||
      fromPerson.treeId === candidatePerson.treeId
    ) {
      return false;
    }
    const fromTree = db.trees.find((tree) => tree.id === fromPerson.treeId);
    const candidateTree = db.trees.find(
      (tree) => tree.id === candidatePerson.treeId,
    );
    if (!fromTree || !candidateTree) {
      return false;
    }
    const fromIdentityId = normalizeNullableString(fromPerson.identityId);
    const candidateIdentityId = normalizeNullableString(candidatePerson.identityId);
    if (
      !fromIdentityId ||
      !candidateIdentityId ||
      fromIdentityId === candidateIdentityId
    ) {
      return false;
    }
    return Boolean(this._scorePersonPairCached(fromPerson, candidatePerson, normCache));
  }

  _markStaleMergeProposals(db, normCache = null) {
    let changed = false;
    db.mergeProposals = Array.isArray(db.mergeProposals)
      ? db.mergeProposals
      : [];
    for (const proposal of db.mergeProposals) {
      if (
        proposal.status === "pending" &&
        !this._mergeProposalStillActionable(db, proposal, normCache)
      ) {
        proposal.status = "stale";
        proposal.resolvedAt = nowIso();
        changed = true;
      }
    }
    return changed;
  }

  _mergeProposalPersonContext(db, person, viewerUserId) {
    if (!person) {
      return "Карточка удалена";
    }
    const tree = db.trees.find((entry) => entry.id === person.treeId);
    if (!tree) {
      return "Дерево удалено";
    }
    if (this._userCanAccessTreeRecord(tree, viewerUserId)) {
      const treeName =
        String(tree.name || "Без названия").trim() || "Без названия";
      return `Дерево: ${treeName}`;
    }
    return "Другое приватное дерево";
  }

  /// A-copy: чья карточка для зрителя — «own» (ваша/в вашем дереве),
  /// «shared» (уже общая — identity связана с несколькими) либо «other».
  _mergePersonOwnership(db, person, viewerUserId) {
    if (!person) return "other";
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (
      normalizedViewer &&
      personStewardUserIds(db, person).includes(normalizedViewer)
    ) {
      return "own";
    }
    const identityId = normalizeNullableString(person.identityId);
    if (identityId) {
      const linkedCount = db.persons.filter(
        (entry) => entry.identityId === identityId,
      ).length;
      if (linkedCount > 1) return "shared";
    }
    return "other";
  }

  _mergeProposalView(db, proposal, viewerUserId = null) {
    const fromPerson = db.persons.find(
      (person) => person.id === proposal.fromPersonId,
    );
    const candidatePerson = db.persons.find(
      (person) => person.id === proposal.candidatePersonId,
    );
    // K1: зритель должен видеть СВОЙ статус (баннер на home обязан гаснуть
    // после голоса, хотя предложение остаётся pending до консенсуса) и
    // ПОИМЁННЫЙ статус остальных ответственных («Вы ✓ · Наталья — ждём»).
    // Имена резолвим как в Phase B (c49676f): userId → profile.displayName,
    // нет имени → displayName опускаем (клиент фолбэчит сам).
    const reviewerIds = normalizeParticipantIds(proposal.reviewerUserIds);
    const reviews = Array.isArray(proposal.reviews) ? proposal.reviews : [];
    const status = proposal.status || "pending";
    const myReview = viewerUserId
      ? reviews.find((entry) => entry.userId === viewerUserId)
      : null;
    const reviewers = reviewerIds.map((reviewerUserId) => {
      const user = db.users.find((entry) => entry.id === reviewerUserId);
      const profile = user?.profile || {};
      const displayName =
        normalizeNullableString(profile.displayName) ||
        composeDisplayNameFromProfile(profile) ||
        null;
      const review = reviews.find((entry) => entry.userId === reviewerUserId);
      return {
        userId: reviewerUserId,
        ...(displayName ? {displayName} : {}),
        decision: review ? review.decision : null,
        isViewer: Boolean(viewerUserId) && reviewerUserId === viewerUserId,
      };
    });
    return {
      id: proposal.id,
      status,
      matchScore: Number(proposal.matchScore || 0),
      confidence: proposal.matchScore >= 0.9 ? "high" : "medium",
      matchSignals:
        proposal.matchSignals && typeof proposal.matchSignals === "object"
          ? structuredClone(proposal.matchSignals)
          : {},
      reasons: Array.isArray(proposal.reasons) ? proposal.reasons : [],
      personA: safeMergePersonPreview(fromPerson, {
        contextLabel: this._mergeProposalPersonContext(
          db,
          fromPerson,
          viewerUserId,
        ),
        ownership: this._mergePersonOwnership(db, fromPerson, viewerUserId),
      }),
      personB: safeMergePersonPreview(candidatePerson, {
        contextLabel: this._mergeProposalPersonContext(
          db,
          candidatePerson,
          viewerUserId,
        ),
        ownership: this._mergePersonOwnership(db, candidatePerson, viewerUserId),
      }),
      requiredReviewCount: reviewerIds.length,
      reviewCount: reviews.filter((entry) => entry.decision === "accepted")
        .length,
      myDecision: myReview ? myReview.decision : null,
      awaitingMyDecision:
        status === "pending" &&
        Boolean(viewerUserId) &&
        reviewerIds.includes(viewerUserId) &&
        !myReview,
      reviewers,
      createdAt: proposal.createdAt,
      resolvedAt: proposal.resolvedAt || null,
    };
  }

  _notifyReviewers(db, {type, title, body, reviewerUserIds, data}) {
    db.notifications = Array.isArray(db.notifications) ? db.notifications : [];
    const normalizedReviewerIds = normalizeParticipantIds(reviewerUserIds);
    for (const userId of normalizedReviewerIds) {
      const alreadyQueued = db.notifications.some((notification) => {
        return (
          notification.userId === userId &&
          notification.type === type &&
          !notification.readAt &&
          notification.data?.proposalId === data?.proposalId &&
          notification.data?.claimId === data?.claimId
        );
      });
      if (alreadyQueued) {
        continue;
      }
      db.notifications.push(
        createNotificationRecord({
          userId,
          type,
          title,
          body,
          data,
        }),
      );
    }
  }

  // SPEED-10: normCache — см. _scorePersonPairCached. Этот метод — сам
  // главный потребитель: цикл stewardPersons × allPersons без кэша
  // renormализовал ОБОИХ persons на КАЖДУЮ пару, хотя allPersons — тот же
  // фиксированный набор на протяжении всего двойного цикла (и candidatePerson
  // повторно перебирается для каждого fromPerson) — см. docs/speed_measurement.md
  // SPEED-10 (profile: normalizeIsoDate/normalizeName/normalizeNameTokens
  // суммарно ~16% self-time одного бёрста).
  _ensureCrossTreeMergeProposals(db, userId, {limit = 50, normCache = null} = {}) {
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) {
      return false;
    }
    db.mergeProposals = Array.isArray(db.mergeProposals)
      ? db.mergeProposals
      : [];
    this._reconcilePersonIdentities(db);

    const accessibleTreeIds = new Set(
      db.trees
        .filter((tree) => this._userCanAccessTreeRecord(tree, normalizedUserId))
        .map((tree) => tree.id),
    );
    const stewardPersons = db.persons.filter((person) => {
      return (
        accessibleTreeIds.has(person.treeId) &&
        this._isPersonSteward(db, person, normalizedUserId)
      );
    });
    if (stewardPersons.length === 0) {
      return false;
    }

    let changed = false;
    let createdCount = 0;
    const allPersons = Array.isArray(db.persons) ? db.persons : [];
    for (const fromPerson of stewardPersons) {
      for (const candidatePerson of allPersons) {
        if (
          fromPerson.id === candidatePerson.id ||
          fromPerson.treeId === candidatePerson.treeId ||
          normalizeNullableString(fromPerson.identityId) ===
            normalizeNullableString(candidatePerson.identityId)
        ) {
          continue;
        }

        const match = this._scorePersonPairCached(fromPerson, candidatePerson, normCache);
        if (!match) {
          continue;
        }

        const proposalPersonIds = [fromPerson.id, candidatePerson.id].sort(
          (left, right) => left.localeCompare(right),
        );
        const proposalId = `merge:${proposalPersonIds[0]}:${proposalPersonIds[1]}`;
        const existing = db.mergeProposals.find(
          (proposal) => proposal.id === proposalId,
        );
        if (existing && existing.status !== "pending") {
          continue;
        }

        const fromIdentity = db.personIdentities.find(
          (identity) => identity.id === fromPerson.identityId,
        );
        const candidateIdentity = db.personIdentities.find(
          (identity) => identity.id === candidatePerson.identityId,
        );
        const reviewerUserIds = normalizeParticipantIds([
          ...personStewardUserIds(db, fromPerson),
          ...personStewardUserIds(db, candidatePerson),
          ...identityStewardUserIds(db, fromIdentity),
          ...identityStewardUserIds(db, candidateIdentity),
        ]);
        if (!reviewerUserIds.includes(normalizedUserId)) {
          continue;
        }

        const matchSignals = {
          name: true,
          birthYear:
            normalizedBirthYear(fromPerson.birthDate) &&
            normalizedBirthYear(fromPerson.birthDate) ===
              normalizedBirthYear(candidatePerson.birthDate),
        };
        if (!existing) {
          db.mergeProposals.push({
            id: proposalId,
            fromPersonId: fromPerson.id,
            toIdentityId: normalizeNullableString(fromPerson.identityId),
            candidatePersonId: candidatePerson.id,
            candidateIdentityId: normalizeNullableString(candidatePerson.identityId),
            matchScore: match.score,
            matchSignals,
            reasons: match.reasons,
            status: "pending",
            proposedByUserId: null,
            reviewerUserIds,
            reviews: [],
            createdAt: nowIso(),
            resolvedAt: null,
          });
          this._notifyReviewers(db, {
            type: "merge_proposal",
            title: "Возможное совпадение",
            body: "Проверьте, не описывают ли две карточки одного человека.",
            reviewerUserIds,
            data: {proposalId, kind: "cross_tree_merge"},
          });
          changed = true;
          createdCount += 1;
        } else {
          // SPEED-10: раньше этот путь безусловно ставил changed=true —
          // на дереве, где хотя бы одна pending-пара уже существует (что
          // после первого прохода почти всегда так), КАЖДЫЙ вызов
          // listPendingMergeProposalsForUser безусловно писал блоб целиком
          // (полный JSON.stringify + fs.rename на GET-путь), даже когда
          // recompute дал ТЕ ЖЕ значения. Итоговые поля existing — те же
          // самые независимо от этой проверки; меняется только то, нужен
          // ли _write. См. docs/speed_measurement.md SPEED-10.
          const matchSignalsChanged =
            Boolean(existing.matchSignals?.name) !== Boolean(matchSignals.name) ||
            Boolean(existing.matchSignals?.birthYear) !== Boolean(matchSignals.birthYear);
          const reasonsChanged =
            !Array.isArray(existing.reasons) ||
            existing.reasons.length !== match.reasons.length ||
            existing.reasons.some((reason, index) => reason !== match.reasons[index]);
          const somethingChanged =
            existing.matchScore !== match.score ||
            matchSignalsChanged ||
            reasonsChanged ||
            !sameNormalizedIds(existing.reviewerUserIds, reviewerUserIds);

          existing.matchScore = match.score;
          existing.matchSignals = matchSignals;
          existing.reasons = match.reasons;
          existing.reviewerUserIds = reviewerUserIds;
          if (somethingChanged) {
            changed = true;
          }
        }

        if (createdCount >= limit) {
          return changed;
        }
      }
    }
    return changed;
  }

  // D1: вместо boolean возвращает ЖУРНАЛ слияния — что именно переехало
  // и что поглотилось. По нему unmerge восстанавливает source-identity.
  // Чтение старого `mergeApplied: true` остаётся совместимым (unmerge на
  // легаси-boolean отвечает 409 — применённых слияний в проде ещё нет).
  _mergeIdentitiesForProposal(db, proposal) {
    const targetIdentityId = normalizeNullableString(proposal.toIdentityId);
    const sourceIdentityId = normalizeNullableString(proposal.candidateIdentityId);
    if (!targetIdentityId || !sourceIdentityId || targetIdentityId === sourceIdentityId) {
      // No-op слияние (одна identity) — журнал пустой, но валидный.
      return {
        movedPersonIds: [],
        movedAttributeIds: [],
        sourceIdentityId: sourceIdentityId || targetIdentityId || null,
        targetIdentityId: targetIdentityId || null,
        userIdAbsorbed: false,
        claimedByAbsorbed: false,
        appliedAt: nowIso(),
      };
    }

    const targetIdentity = db.personIdentities.find(
      (identity) => identity.id === targetIdentityId,
    );
    const sourceIdentity = db.personIdentities.find(
      (identity) => identity.id === sourceIdentityId,
    );
    if (!targetIdentity || !sourceIdentity) {
      return false;
    }
    if (
      targetIdentity.userId &&
      sourceIdentity.userId &&
      targetIdentity.userId !== sourceIdentity.userId
    ) {
      return false;
    }

    const movedPersonIds = [];
    for (const person of db.persons) {
      if (person.identityId === sourceIdentityId) {
        person.identityId = targetIdentityId;
        person.updatedAt = nowIso();
        movedPersonIds.push(person.id);
      }
    }
    const movedAttributeIds = [];
    for (const attribute of db.personAttributes || []) {
      if (attribute.identityId === sourceIdentityId) {
        attribute.identityId = targetIdentityId;
        attribute.updatedAt = nowIso();
        movedAttributeIds.push(attribute.id);
      }
    }

    const userIdAbsorbed =
      !targetIdentity.userId && Boolean(sourceIdentity.userId);
    const claimedByAbsorbed =
      !targetIdentity.claimedByUserId &&
      Boolean(sourceIdentity.claimedByUserId);

    targetIdentity.userId = targetIdentity.userId || sourceIdentity.userId || null;
    targetIdentity.claimedByUserId =
      targetIdentity.claimedByUserId || sourceIdentity.claimedByUserId || null;
    targetIdentity.personIds = normalizeParticipantIds([
      ...(targetIdentity.personIds || []),
      ...(sourceIdentity.personIds || []),
    ]);
    targetIdentity.stewardUserIds = normalizeParticipantIds([
      ...(targetIdentity.stewardUserIds || []),
      ...(sourceIdentity.stewardUserIds || []),
    ]);
    targetIdentity.isLiving =
      targetIdentity.isLiving === true || sourceIdentity.isLiving === true;
    targetIdentity.isPublicDiscoverable =
      targetIdentity.isPublicDiscoverable === true &&
      sourceIdentity.isPublicDiscoverable === true;
    targetIdentity.updatedAt = nowIso();
    sourceIdentity.personIds = [];
    sourceIdentity.mergedInto = targetIdentityId;
    sourceIdentity.isPublicDiscoverable = false;
    sourceIdentity.updatedAt = nowIso();

    this._reconcilePersonIdentities(db);
    return {
      movedPersonIds,
      movedAttributeIds,
      sourceIdentityId,
      targetIdentityId,
      userIdAbsorbed,
      claimedByAbsorbed,
      appliedAt: nowIso(),
    };
  }

  // SPEED-10: normCache — одна Map на весь вызов, разделяемая
  // _ensureCrossTreeMergeProposals/_markStaleMergeProposals/финальным
  // .filter() ниже — те же persons проверяются во ВСЕХ трёх местах
  // (кандидаты → staleness-рефреш → staleness-рецепт для reviewer-набора),
  // без кэша каждый раз заново нормализовался. См. _scorePersonPairCached.
  async listPendingMergeProposalsForUser(userId, {limit = 50} = {}) {
    const normalizedUserId = normalizeNullableString(userId);
    const db = await this._read();
    const normCache = new Map();
    let changed = this._ensureCrossTreeMergeProposals(db, normalizedUserId, {limit, normCache});
    changed = this._markStaleMergeProposals(db, normCache) || changed;
    if (changed) {
      await this._write(db);
    }

    return db.mergeProposals
      .filter(
        (proposal) =>
          proposal.status === "pending" &&
          normalizeParticipantIds(proposal.reviewerUserIds).includes(
            normalizedUserId,
          ) &&
          this._mergeProposalStillActionable(db, proposal, normCache),
      )
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .slice(0, Math.max(0, Math.min(Number(limit) || 50, 100)))
      .map((proposal) =>
        structuredClone(this._mergeProposalView(db, proposal, normalizedUserId)),
      );
  }

  async reviewMergeProposal({proposalId, reviewerUserId, decision, reason = null}) {
    const db = await this._read();
    db.mergeProposals = Array.isArray(db.mergeProposals)
      ? db.mergeProposals
      : [];
    const proposal = db.mergeProposals.find((entry) => entry.id === proposalId);
    if (!proposal) {
      return null;
    }
    if (!normalizeParticipantIds(proposal.reviewerUserIds).includes(reviewerUserId)) {
      return false;
    }
    if (proposal.status !== "pending") {
      return structuredClone(
        this._mergeProposalView(db, proposal, reviewerUserId),
      );
    }
    if (!this._mergeProposalStillActionable(db, proposal)) {
      proposal.status = "stale";
      proposal.resolvedAt = nowIso();
      await this._write(db);
      return structuredClone(
        this._mergeProposalView(db, proposal, reviewerUserId),
      );
    }

    const normalizedDecision =
      String(decision || "").trim().toLowerCase() === "accept"
        ? "accepted"
        : "rejected";
    proposal.reviews = (Array.isArray(proposal.reviews) ? proposal.reviews : [])
      .filter((review) => review.userId !== reviewerUserId);
    proposal.reviews.push({
      userId: reviewerUserId,
      decision: normalizedDecision,
      reason: normalizeNullableString(reason),
      at: nowIso(),
    });

    if (normalizedDecision === "rejected") {
      proposal.status = "rejected";
      proposal.resolvedAt = nowIso();
    } else {
      const acceptedReviewerIds = new Set(
        proposal.reviews
          .filter((review) => review.decision === "accepted")
          .map((review) => review.userId),
      );
      const allAccepted = normalizeParticipantIds(proposal.reviewerUserIds)
        .every((userId) => acceptedReviewerIds.has(userId));
      if (allAccepted) {
        proposal.status = "accepted";
        proposal.mergeApplied = this._mergeIdentitiesForProposal(db, proposal);
        proposal.resolvedAt = nowIso();
      }
    }
    await this._write(db);
    return structuredClone(
      this._mergeProposalView(db, proposal, reviewerUserId),
    );
  }

  // D1: применённые слияния, видимые зрителю — секция «Объединённые
  // ранее» на экране «Один человек?». Только те, где зритель был
  // ответственным.
  async listMergedProposalsForUser(userId, {limit = 50} = {}) {
    const normalizedUserId = normalizeNullableString(userId);
    const db = await this._read();
    return (db.mergeProposals || [])
      .filter(
        (proposal) =>
          proposal.status === "accepted" &&
          Boolean(proposal.mergeApplied) &&
          normalizeParticipantIds(proposal.reviewerUserIds).includes(
            normalizedUserId,
          ),
      )
      .sort((left, right) =>
        String(right.resolvedAt || right.createdAt || "").localeCompare(
          String(left.resolvedAt || left.createdAt || ""),
        ),
      )
      .slice(0, Math.max(0, Math.min(Number(limit) || 50, 100)))
      .map((proposal) =>
        structuredClone(this._mergeProposalView(db, proposal, normalizedUserId)),
      );
  }

  // D1: разъединение применённого слияния по журналу. Карточки в
  // деревьях не меняются — распадается только связка «это один человек».
  // Возвраты: null — нет предложения; false — актор не ответственный;
  // {error: 'legacy'} — слияние применено до журнала (легаси boolean);
  // {error: 'not_applied'} — нечего разъединять; иначе — view.
  async unmergeMergeProposal({proposalId, actorUserId}) {
    const db = await this._read();
    const proposal = (db.mergeProposals || []).find(
      (entry) => entry.id === proposalId,
    );
    if (!proposal) {
      return null;
    }
    if (
      !normalizeParticipantIds(proposal.reviewerUserIds).includes(
        normalizeNullableString(actorUserId),
      )
    ) {
      return false;
    }
    if (proposal.status !== "accepted" || !proposal.mergeApplied) {
      return {error: "not_applied"};
    }
    const journal = proposal.mergeApplied;
    if (journal === true || typeof journal !== "object") {
      // Слияние времён boolean-флага — журнала нет, честно отказываем.
      return {error: "legacy"};
    }

    const sourceIdentityId = normalizeNullableString(journal.sourceIdentityId);
    const targetIdentityId = normalizeNullableString(journal.targetIdentityId);
    const sourceIdentity = sourceIdentityId
      ? db.personIdentities.find((entry) => entry.id === sourceIdentityId)
      : null;
    const targetIdentity = targetIdentityId
      ? db.personIdentities.find((entry) => entry.id === targetIdentityId)
      : null;

    // Persons, удалённые с момента слияния, пропускаем молча.
    const survivingPersonIds = normalizeParticipantIds(
      journal.movedPersonIds,
    ).filter((personId) =>
      db.persons.some((person) => person.id === personId),
    );
    for (const person of db.persons) {
      if (survivingPersonIds.includes(person.id)) {
        person.identityId = sourceIdentityId;
        person.updatedAt = nowIso();
      }
    }
    const movedAttributeIds = new Set(
      Array.isArray(journal.movedAttributeIds) ? journal.movedAttributeIds : [],
    );
    for (const attribute of db.personAttributes || []) {
      if (movedAttributeIds.has(attribute.id)) {
        attribute.identityId = sourceIdentityId;
        attribute.updatedAt = nowIso();
      }
    }

    if (sourceIdentity) {
      sourceIdentity.mergedInto = null;
      sourceIdentity.personIds = survivingPersonIds;
      // Осознанный дефолт: в публичный поиск не возвращаем — пусть
      // включают сами.
      sourceIdentity.isPublicDiscoverable = false;
      sourceIdentity.updatedAt = nowIso();
    }
    if (targetIdentity) {
      targetIdentity.personIds = normalizeParticipantIds(
        (targetIdentity.personIds || []).filter(
          (personId) => !survivingPersonIds.includes(personId),
        ),
      );
      if (journal.userIdAbsorbed === true) {
        targetIdentity.userId = null;
      }
      if (journal.claimedByAbsorbed === true) {
        targetIdentity.claimedByUserId = null;
      }
      targetIdentity.updatedAt = nowIso();
    }

    // История сохраняется: повторный матч сможет предложить заново.
    proposal.status = "unmerged";
    proposal.unmergedAt = nowIso();
    proposal.unmergedByUserId = normalizeNullableString(actorUserId);

    this._reconcilePersonIdentities(db);
    await this._write(db);
    return structuredClone(
      this._mergeProposalView(db, proposal, actorUserId),
    );
  }

  async listPersonAttributes({treeId, personId}) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.treeId === treeId && entry.id === personId,
    );
    if (!person) {
      return null;
    }
    const changed = upsertPersonAttributesForPerson(db, person, person.creatorId);
    if (changed) {
      await this._write(db);
    }
    return (db.personAttributes || [])
      .filter(
        (entry) =>
          entry.identityId === person.identityId &&
          entry.sourcePersonId === person.id &&
          entry.status !== "archived",
      )
      .map((entry) => structuredClone(entry));
  }

  async updatePersonAttributeVisibility({
    treeId,
    personId,
    actorUserId,
    attributes = [],
    cardVisibility = undefined,
  }) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.treeId === treeId && entry.id === personId,
    );
    if (!person) {
      return null;
    }
    if (!this._isPersonSteward(db, person, actorUserId)) {
      return false;
    }

    if (cardVisibility !== undefined) {
      person.visibility = normalizePersonVisibility(
        cardVisibility,
        defaultPersonVisibility(person),
      );
      person.updatedAt = nowIso();
    }
    upsertPersonAttributesForPerson(db, person, actorUserId);
    for (const item of Array.isArray(attributes) ? attributes : []) {
      const field = String(item?.field || "").trim();
      if (!PERSON_ATTRIBUTE_FIELDS.includes(field)) {
        continue;
      }
      const attribute = db.personAttributes.find(
        (entry) =>
          entry.identityId === person.identityId &&
          entry.sourcePersonId === person.id &&
          entry.field === field &&
          entry.status !== "archived",
      );
      if (!attribute) {
        continue;
      }
      attribute.visibility = normalizePersonVisibility(item.visibility);
      attribute.updatedAt = nowIso();
    }
    await this._write(db);
    return this.listPersonAttributes({treeId, personId});
  }

  _identityClaimView(claim) {
    return {
      id: claim.id,
      identityId: claim.identityId,
      personId: claim.personId,
      claimantUserId: claim.claimantUserId,
      status: claim.status,
      reviewerUserIds: normalizeParticipantIds(claim.reviewerUserIds),
      reviews: Array.isArray(claim.reviews)
        ? claim.reviews.map((entry) => structuredClone(entry))
        : [],
      createdAt: claim.createdAt,
      resolvedAt: claim.resolvedAt || null,
    };
  }

  _approveIdentityClaim(db, claim) {
    const identity = db.personIdentities.find(
      (entry) => entry.id === claim.identityId,
    );
    const person = db.persons.find((entry) => entry.id === claim.personId);
    if (!identity || !person) {
      return false;
    }
    return this._attachPersonToIdentity(
      db,
      person,
      identity,
      claim.claimantUserId,
    );
  }

  async createIdentityClaim({treeId, personId, claimantUserId, evidence = null}) {
    const db = await this._read();
    db.identityClaims = Array.isArray(db.identityClaims)
      ? db.identityClaims
      : [];
    const person = db.persons.find(
      (entry) => entry.treeId === treeId && entry.id === personId,
    );
    if (!person) {
      return null;
    }
    this._reconcilePersonIdentities(db);
    const identity = db.personIdentities.find(
      (entry) => entry.id === person.identityId,
    );
    if (!identity) {
      return null;
    }
    const existing = db.identityClaims.find(
      (claim) =>
        claim.identityId === identity.id &&
        claim.claimantUserId === claimantUserId &&
        claim.status === "pending",
    );
    if (existing) {
      return structuredClone(this._identityClaimView(existing));
    }

    const reviewerUserIds = normalizeParticipantIds([
      ...identityStewardUserIds(db, identity),
      ...personStewardUserIds(db, person),
    ]).filter((userId) => userId !== claimantUserId);
    const timestamp = nowIso();
    const claim = {
      id: crypto.randomUUID(),
      identityId: identity.id,
      personId: person.id,
      claimantUserId,
      evidence: normalizeNullableString(evidence),
      status: reviewerUserIds.length === 0 ? "approved" : "pending",
      reviewerUserIds,
      reviews: [],
      createdAt: timestamp,
      resolvedAt: reviewerUserIds.length === 0 ? timestamp : null,
    };
    db.identityClaims.push(claim);
    if (claim.status === "approved") {
      this._approveIdentityClaim(db, claim);
    } else {
      this._notifyReviewers(db, {
        type: "identity_claim",
        title: "Запрос подтверждения личности",
        body: "Пользователь просит связать профиль с карточкой в дереве.",
        reviewerUserIds,
        data: {claimId: claim.id, personId: person.id},
      });
    }
    await this._write(db);
    return structuredClone(this._identityClaimView(claim));
  }

  async listPendingIdentityClaimsForUser(userId) {
    const db = await this._read();
    db.identityClaims = Array.isArray(db.identityClaims)
      ? db.identityClaims
      : [];
    return (db.identityClaims || [])
      .filter(
        (claim) =>
          claim.status === "pending" &&
          normalizeParticipantIds(claim.reviewerUserIds).includes(userId),
      )
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((claim) => structuredClone(this._identityClaimView(claim)));
  }

  async reviewIdentityClaim({claimId, reviewerUserId, decision, reason = null}) {
    const db = await this._read();
    db.identityClaims = Array.isArray(db.identityClaims)
      ? db.identityClaims
      : [];
    const claim = db.identityClaims.find((entry) => entry.id === claimId);
    if (!claim) {
      return null;
    }
    if (!normalizeParticipantIds(claim.reviewerUserIds).includes(reviewerUserId)) {
      return false;
    }
    if (claim.status !== "pending") {
      return structuredClone(this._identityClaimView(claim));
    }
    const normalizedDecision =
      String(decision || "").trim().toLowerCase() === "approve"
        ? "approved"
        : "denied";
    claim.reviews = (Array.isArray(claim.reviews) ? claim.reviews : [])
      .filter((review) => review.userId !== reviewerUserId);
    claim.reviews.push({
      userId: reviewerUserId,
      decision: normalizedDecision,
      reason: normalizeNullableString(reason),
      at: nowIso(),
    });
    if (normalizedDecision === "denied") {
      claim.status = "denied";
      claim.resolvedAt = nowIso();
    } else {
      const approvedReviewerIds = new Set(
        claim.reviews
          .filter((review) => review.decision === "approved")
          .map((review) => review.userId),
      );
      if (
        normalizeParticipantIds(claim.reviewerUserIds).every((userId) =>
          approvedReviewerIds.has(userId),
        )
      ) {
        claim.status = "approved";
        claim.resolvedAt = nowIso();
        this._approveIdentityClaim(db, claim);
      }
    }
    await this._write(db);
    return structuredClone(this._identityClaimView(claim));
  }

  async setIdentityDiscoverability({userId, isPublicDiscoverable}) {
    const db = await this._read();
    const identity = this._ensureUserIdentity(db, userId);
    if (!identity) {
      return null;
    }
    identity.isPublicDiscoverable = isPublicDiscoverable === true;
    identity.updatedAt = nowIso();
    await this._write(db);
    return structuredClone({
      identityId: identity.id,
      isPublicDiscoverable: identity.isPublicDiscoverable,
    });
  }

  async searchPublicIdentities({query, birthYear = null, limit = 20} = {}) {
    const db = await this._read();
    const normalizedQuery = String(query || "").trim().toLowerCase();
    const normalizedBirthYear = normalizeNullableString(birthYear);
    if (normalizedQuery.length < 2 && !normalizedBirthYear) {
      return [];
    }
    return (db.personIdentities || [])
      .filter((identity) => identity.isPublicDiscoverable === true)
      .map((identity) => {
        const primaryPerson =
          db.persons.find((person) => person.id === identity.primaryPersonId) ||
          db.persons.find((person) =>
            normalizeParticipantIds(identity.personIds).includes(person.id),
          );
        return {identity, primaryPerson};
      })
      .filter(({primaryPerson}) => {
        if (!primaryPerson) {
          return false;
        }
        const name = String(primaryPerson.name || "").toLowerCase();
        const year = extractBirthYear(primaryPerson.birthDate);
        if (normalizedBirthYear && year !== normalizedBirthYear) {
          return false;
        }
        return !normalizedQuery || name.includes(normalizedQuery);
      })
      .slice(0, Math.max(0, Math.min(Number(limit) || 20, 50)))
      .map(({identity, primaryPerson}) => ({
        identityId: identity.id,
        name: String(primaryPerson.name || "Без имени").trim() || "Без имени",
        birthYear: extractBirthYear(primaryPerson.birthDate),
      }));
  }

  async createPerson({
    treeId,
    creatorId,
    personData,
    userId = null,
    sourcePersonId = null,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    if (userId) {
      const existingLinkedPerson = db.persons.find(
        (entry) => entry.treeId === treeId && entry.userId === userId,
      );
      if (existingLinkedPerson) {
        const canonicalIdentity = this._ensureUserIdentity(db, userId);
        if (canonicalIdentity) {
          this._attachPersonToIdentity(
            db,
            existingLinkedPerson,
            canonicalIdentity,
            userId,
          );
          ensureCirclesForTree(db, tree);
          upsertPersonAttributesForPerson(db, existingLinkedPerson, creatorId);
          await this._write(db);
        }
        return structuredClone(existingLinkedPerson);
      }
    }

    // Phase 0 cross-tree picker: if the caller picked an existing
    // relative from one of their other trees, we (a) ensure the
    // source has a PersonIdentity (creating one if it didn't),
    // and (b) inherit that identityId onto the new person so they
    // are correlated as "the same human" across trees. Phase 1
    // turns this hint into full edit-propagation; for now it just
    // tags the relationship.
    //
    // sourcePersonId is RESOLVED here, not at the route layer, so
    // a malicious client can't forge an identityId — the source
    // must live in a tree the caller has access to. The route
    // layer is responsible for that access check before calling.
    let sourcePerson = null;
    if (sourcePersonId) {
      sourcePerson = db.persons.find(
        (entry) => entry.id === sourcePersonId,
      ) || null;
      if (sourcePerson) {
        const sourceTree = db.trees.find(
          (entry) => entry.id === sourcePerson.treeId,
        );
        if (
          !sourceTree ||
          !this._userCanAccessTreeRecord(sourceTree, creatorId)
        ) {
          // Don't surface the existence of inaccessible persons —
          // treat as "source unknown" and proceed without the link.
          sourcePerson = null;
        }
      }
    }

    let canonicalIdentity = userId ? this._ensureUserIdentity(db, userId) : null;
    if (!canonicalIdentity && sourcePerson) {
      // Source has an identity already → reuse it. Otherwise
      // create a fresh PersonIdentity record and attach BOTH the
      // source and the new person to it, so they share a canonical
      // node in the unified graph.
      const identities = this._ensurePersonIdentityCollection(db);
      const existingIdentity = sourcePerson.identityId
        ? identities.find((entry) => entry.id === sourcePerson.identityId)
        : null;
      if (existingIdentity) {
        canonicalIdentity = existingIdentity;
      } else {
        canonicalIdentity = createPersonIdentityRecord({
          personIds: [sourcePerson.id],
        });
        identities.push(canonicalIdentity);
        sourcePerson.identityId = canonicalIdentity.id;
        sourcePerson.updatedAt = nowIso();
      }
    }

    // Pre-fill any fields the caller didn't supply from the source
    // record, so the picker can drop a partial `personData` and
    // still get a fully-populated relative. Caller-supplied fields
    // always win — no overwrites of user intent.
    const mergedPersonData = sourcePerson
      ? mergePersonDataFromSource(personData, sourcePerson)
      : personData;

    const person = buildPersonRecord({
      treeId,
      creatorId,
      personData: mergedPersonData,
      userId,
      identityId: canonicalIdentity?.id || null,
    });
    db.persons.push(person);

    if (userId) {
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      tree.members = Array.isArray(tree.members) ? tree.members : [];
      if (!tree.memberIds.includes(userId)) {
        tree.memberIds.push(userId);
      }
      if (!tree.members.includes(userId)) {
        tree.members.push(userId);
      }
      this._ensureSemyaMembershipForLegacyJoin(db, tree, userId);
    }
    tree.updatedAt = nowIso();
    if (canonicalIdentity) {
      this._attachPersonToIdentity(db, person, canonicalIdentity, userId);
    } else {
      this._reconcilePersonIdentities(db);
    }
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId: creatorId,
      type: "person.created",
      personId: person.id,
      details: {
        after: structuredClone(person),
      },
    });
    this._reconcilePersonIdentities(db);
    ensureCirclesForTree(db, tree);
    upsertPersonAttributesForPerson(db, person, creatorId);

    await this._write(db);
    return structuredClone(person);
  }

  /// Bulk-copy persons from one tree to another, then bridge any
  /// source-tree relations that have at least one endpoint among
  /// the imported set. "Bridging" means translating the relation's
  /// endpoint personIds: if the source endpoint was just imported,
  /// use the new target id; if it wasn't imported but already
  /// exists in target via shared `identityId` (e.g. the user
  /// themselves on both trees), use that existing id; otherwise
  /// skip. The result is the natural answer to "I dragged my
  /// girlfriend's card from the Кузнецовых tree into Родня — why
  /// is she empty and disconnected from me?". Person data
  /// (name / photo / dates) is fully inherited via the existing
  /// `mergePersonDataFromSource` path.
  ///
  /// Idempotent on relations — if the same relation already exists
  /// between the bridged endpoints in target it isn't duplicated.
  /// Idempotent on persons too — picking someone who's already in
  /// target (via identityId) results in the existing target person
  /// being reused, not a duplicate row.
  async bulkImportPersonsToTree({
    sourceTreeId,
    sourcePersonIds,
    targetTreeId,
    actorId,
  }) {
    const db = await this._read();
    const sourceTree = db.trees.find((entry) => entry.id === sourceTreeId);
    const targetTree = db.trees.find((entry) => entry.id === targetTreeId);
    if (!sourceTree || !targetTree) return null;
    if (
      !this._userCanAccessTreeRecord(sourceTree, actorId) ||
      !this._userCanAccessTreeRecord(targetTree, actorId)
    ) {
      return null;
    }
    if (!Array.isArray(sourcePersonIds) || sourcePersonIds.length === 0) {
      return {persons: [], relations: []};
    }
    const requestedIds = Array.from(new Set(
      sourcePersonIds
        .map((value) => normalizeNullableString(value))
        .filter((value) => value),
    ));
    const sourcePersonRecords = requestedIds
      .map((id) => db.persons.find(
        (entry) => entry.id === id && entry.treeId === sourceTreeId,
      ))
      .filter(Boolean);

    // Map identityId → existing target personId. Built before we
    // start importing so the user-themselves card on target is
    // immediately discoverable as a relation endpoint.
    const targetPersonsByIdentity = new Map();
    for (const targetPerson of db.persons) {
      if (targetPerson.treeId !== targetTreeId) continue;
      const identity = normalizeNullableString(targetPerson.identityId);
      if (identity) {
        targetPersonsByIdentity.set(identity, targetPerson.id);
      }
    }

    const sourceToTargetMap = new Map();
    const importedPersons = [];

    for (const sourcePerson of sourcePersonRecords) {
      const identityId = normalizeNullableString(sourcePerson.identityId);
      if (identityId && targetPersonsByIdentity.has(identityId)) {
        // Already in target as the same human — skip the copy and
        // map the source id to the existing target id so any
        // source relation involving this person bridges to the
        // existing target card.
        sourceToTargetMap.set(
          sourcePerson.id,
          targetPersonsByIdentity.get(identityId),
        );
        continue;
      }

      // Ensure the source row has a canonical identity so the new
      // target row can share it. Reuse the existing one if any,
      // otherwise allocate.
      let canonicalIdentity = null;
      if (identityId) {
        const identities = this._ensurePersonIdentityCollection(db);
        canonicalIdentity = identities.find((entry) => entry.id === identityId);
      }
      if (!canonicalIdentity) {
        const identities = this._ensurePersonIdentityCollection(db);
        canonicalIdentity = createPersonIdentityRecord({
          personIds: [sourcePerson.id],
        });
        identities.push(canonicalIdentity);
        sourcePerson.identityId = canonicalIdentity.id;
        sourcePerson.updatedAt = nowIso();
      }

      const mergedData = mergePersonDataFromSource({}, sourcePerson);
      const newPerson = buildPersonRecord({
        treeId: targetTreeId,
        creatorId: actorId,
        identityId: canonicalIdentity.id,
        personData: mergedData,
      });
      db.persons.push(newPerson);
      this._attachPersonToIdentity(db, newPerson, canonicalIdentity, null);
      this._appendTreeChangeRecord(db, {
        treeId: targetTreeId,
        actorId,
        type: "person.created",
        personId: newPerson.id,
        details: {
          after: structuredClone(newPerson),
          importedFrom: {
            sourceTreeId,
            sourcePersonId: sourcePerson.id,
          },
        },
      });
      sourceToTargetMap.set(sourcePerson.id, newPerson.id);
      targetPersonsByIdentity.set(canonicalIdentity.id, newPerson.id);
      importedPersons.push(newPerson);
    }

    // Resolve a source personId to a target personId via either
    // (a) the just-imported map, or (b) identity bridge to a
    // pre-existing target person (the "user themselves" case).
    const bridgeToTarget = (sourcePersonId) => {
      if (!sourcePersonId) return null;
      if (sourceToTargetMap.has(sourcePersonId)) {
        return sourceToTargetMap.get(sourcePersonId);
      }
      const candidate = db.persons.find(
        (entry) =>
          entry.id === sourcePersonId && entry.treeId === sourceTreeId,
      );
      const identity = normalizeNullableString(candidate?.identityId);
      if (identity && targetPersonsByIdentity.has(identity)) {
        return targetPersonsByIdentity.get(identity);
      }
      return null;
    };

    const requestedIdSet = new Set(requestedIds);
    const importedRelations = [];
    const sourceRelations = db.relations.filter(
      (entry) => entry.treeId === sourceTreeId,
    );
    for (const sourceRelation of sourceRelations) {
      const involvesImported =
        requestedIdSet.has(sourceRelation.person1Id) ||
        requestedIdSet.has(sourceRelation.person2Id);
      if (!involvesImported) continue;
      const newP1 = bridgeToTarget(sourceRelation.person1Id);
      const newP2 = bridgeToTarget(sourceRelation.person2Id);
      if (!newP1 || !newP2 || newP1 === newP2) continue;

      const existingRelation = db.relations.find((entry) => {
        return (
          entry.treeId === targetTreeId &&
          ((entry.person1Id === newP1 && entry.person2Id === newP2) ||
            (entry.person1Id === newP2 && entry.person2Id === newP1))
        );
      });
      if (existingRelation) continue;

      const timestamp = nowIso();
      const newRelation = {
        id: crypto.randomUUID(),
        treeId: targetTreeId,
        person1Id: newP1,
        person2Id: newP2,
        relation1to2: sourceRelation.relation1to2,
        relation2to1: sourceRelation.relation2to1,
        isConfirmed: true,
        createdAt: timestamp,
        updatedAt: timestamp,
        createdBy: actorId,
        marriageDate: sourceRelation.marriageDate ?? null,
        divorceDate: sourceRelation.divorceDate ?? null,
        customRelationLabel1to2: sourceRelation.customRelationLabel1to2 || null,
        customRelationLabel2to1: sourceRelation.customRelationLabel2to1 || null,
        // Skip parent-set / union plumbing — those are derived
        // during normalization and re-derive correctly on next
        // read. Carrying them across trees would force us to also
        // import sibling parents to keep the set consistent, and
        // that's a bigger semantic call for a separate iteration.
        parentSetId: null,
        parentSetType: null,
        isPrimaryParentSet: null,
        unionId: null,
        unionType: null,
        unionStatus: null,
      };
      db.relations.push(newRelation);
      this._appendTreeChangeRecord(db, {
        treeId: targetTreeId,
        actorId,
        type: "relation.created",
        personIds: [newP1, newP2],
        relationId: newRelation.id,
        details: {
          after: structuredClone(newRelation),
          importedFrom: {
            sourceTreeId,
            sourceRelationId: sourceRelation.id,
          },
        },
      });
      importedRelations.push(newRelation);
    }

    targetTree.updatedAt = nowIso();
    ensureCirclesForTree(db, targetTree);
    this._reconcilePersonIdentities(db);
    await this._write(db);

    return {
      persons: importedPersons.map((entry) => structuredClone(entry)),
      relations: importedRelations.map((entry) => structuredClone(entry)),
    };
  }

  async updatePerson(treeId, personId, personData, actorId = null) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

    const previousPerson = structuredClone(person);
    const nextPerson = {
      ...person,
      ...personData,
    };
    nextPerson.userId = person.userId;
    nextPerson.identityId = person.identityId;
    nextPerson.treeId = person.treeId;
    nextPerson.creatorId = person.creatorId;
    nextPerson.name = fullNameFromPersonInput(nextPerson);
    nextPerson.maidenName = normalizeNullableString(nextPerson.maidenName);
    nextPerson.birthPlace = normalizeNullableString(nextPerson.birthPlace);
    nextPerson.deathPlace = normalizeNullableString(nextPerson.deathPlace);
    nextPerson.familySummary = resolvePersonFamilySummary(nextPerson);
    nextPerson.bio = normalizeNullableString(nextPerson.bio);
    nextPerson.notes = normalizeNullableString(nextPerson.notes);
    nextPerson.birthDate = normalizeIsoDate(nextPerson.birthDate);
    nextPerson.deathDate = normalizeIsoDate(nextPerson.deathDate);
    // F5: точность дат («знаю только год») нормализуется тем же путём,
    // что и сами даты; без даты точность не имеет смысла — exact.
    nextPerson.birthDatePrecision = nextPerson.birthDate
      ? normalizeDatePrecision(nextPerson.birthDatePrecision)
      : "exact";
    nextPerson.deathDatePrecision = nextPerson.deathDate
      ? normalizeDatePrecision(nextPerson.deathDatePrecision)
      : "exact";
    nextPerson.isAlive = nextPerson.deathDate === null;
    nextPerson.visibility = normalizePersonVisibility(
      nextPerson.visibility,
      defaultPersonVisibility({
        deathDate: nextPerson.deathDate,
        isAlive: nextPerson.isAlive,
      }),
    );
    const photoState = normalizePersonPhotoGallery(nextPerson.photoGallery, {
      photoUrl: nextPerson.photoUrl,
      primaryPhotoUrl: nextPerson.primaryPhotoUrl,
    });
    nextPerson.photoUrl = photoState.photoUrl;
    nextPerson.primaryPhotoUrl = photoState.primaryPhotoUrl;
    nextPerson.photoGallery = photoState.photoGallery;
    if (person.userId) {
      const linkedUser = db.users.find((entry) => entry.id === person.userId);
      if (linkedUser?.profile) {
        applyCanonicalProfileToPerson(nextPerson, linkedUser.profile, {
          touchUpdatedAt: false,
        });
      }
    }
    nextPerson.updatedAt = nowIso();

    Object.assign(person, nextPerson);
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = nowIso();
    }
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "person.updated",
      personId: person.id,
      details: {
        before: previousPerson,
        after: structuredClone(person),
      },
    });
    ensureCirclesForTree(db, treeId);
    upsertPersonAttributesForPerson(db, person, actorId);

    // Phase 1.1 of the unified-graph migration: identity propagation.
    // When a person record updates, fan the canonical-fields part of
    // the change out to every OTHER person record that shares the
    // same identityId (typically: the same human entered into a
    // different tree by the same user via the cross-tree picker, OR
    // the same user's auto-card in their own tree).
    //
    // Tree-local fields (notes / familySummary / bio / visibility)
    // are deliberately NOT propagated — those are the editor's
    // annotation about how this person fits into THIS tree's
    // story. A field "describing the human" (name, dates, places,
    // photos, gender) is shared because it's the same human;
    // editorial fields are per-tree.
    //
    // Returns the list of (treeId, personId) tuples that were
    // touched so the route layer can include it in the response —
    // the Flutter client uses it to invalidate per-tree caches.
    const propagatedTo = this._propagateIdentityFields(
      db,
      person,
      previousPerson,
      actorId,
    );

    await this._write(db);
    const result = structuredClone(person);
    if (propagatedTo.length > 0) {
      // Hidden side-channel for the route layer. Decorating the
      // returned record with a non-enumerable-style hint keeps
      // existing callers (which deepEqual-check the return) happy
      // while letting the route surface the affected trees in
      // the JSON response. Plain property — `mapPerson` will
      // ignore it because it pulls a fixed schema.
      result._propagatedTo = propagatedTo;
    }
    return result;
  }

  // Allowlist for identity propagation. Anything not in this list
  // stays per-tree. Order matches the field's role in the record:
  // identity-shape first (name parts → composed name), then
  // demographics, then media. NEVER add `notes` / `bio` /
  // `familySummary` / `visibility` here — those are editorial
  // and per-tree by design.
  static get _identityPropagationFields() {
    return Object.freeze([
      "name",
      "maidenName",
      "gender",
      "birthDate",
      // F5: точность дат описывает человека так же, как сама дата —
      // путешествует между карточками одной identity вместе с ней.
      "birthDatePrecision",
      "deathDate",
      "deathDatePrecision",
      "isAlive",
      "birthPlace",
      "deathPlace",
      "photoUrl",
      "primaryPhotoUrl",
      "photoGallery",
    ]);
  }

  _propagateIdentityFields(db, sourcePerson, previousSourcePerson, actorId) {
    const identityId = normalizeNullableString(sourcePerson?.identityId);
    if (!identityId) return [];

    // Find sibling person records that share this identityId.
    // Excludes the source itself (we just updated it) and any
    // record that's somehow tagged with the identityId but lives
    // in the same tree+id (defensive — shouldn't exist after
    // _reconcilePersonIdentities, but a malformed import could).
    const linked = db.persons.filter(
      (entry) =>
        entry.identityId === identityId &&
        !(entry.treeId === sourcePerson.treeId && entry.id === sourcePerson.id),
    );
    if (linked.length === 0) return [];

    if (!Array.isArray(db.identityFieldConflicts)) {
      db.identityFieldConflicts = [];
    }

    const propagated = [];
    const fields = FileStore._identityPropagationFields;
    const nowTs = nowIso();

    for (const linkedPerson of linked) {
      const previousLinked = structuredClone(linkedPerson);
      let anyChange = false;

      // Per-target snapshot of "what this propagator last wrote
      // here". First propagation populates it; subsequent passes
      // diff `current vs lastWritten` to tell apart "still our
      // value, just out-of-date" (overwrite freely) from "user
      // locally edited this between propagations" (conflict, do
      // NOT clobber). See Phase 1.3 RFC §1.3.
      if (
        !linkedPerson.lastPropagatedFields ||
        typeof linkedPerson.lastPropagatedFields !== "object"
      ) {
        linkedPerson.lastPropagatedFields = {};
      }

      for (const field of fields) {
        const sourceValue = sourcePerson[field];
        const linkedValue = linkedPerson[field];
        if (valuesEqualForPropagation(field, linkedValue, sourceValue)) {
          // Values already match — no overwrite needed. But we
          // still stamp the snapshot if absent, so a future
          // local edit on the target followed by a divergent
          // source update lands in the conflict path instead of
          // a silent overwrite (snapshotPresent would otherwise
          // stay false on this field forever).
          if (
            !Object.prototype.hasOwnProperty.call(
              linkedPerson.lastPropagatedFields,
              field,
            )
          ) {
            linkedPerson.lastPropagatedFields[field] = structuredClone(
              sourceValue,
            );
          }
          continue;
        }

        // Conflict detection only kicks in AFTER the snapshot is
        // present — before that we can't distinguish "different
        // initial values" from "local edit". `hasOwnProperty`
        // keeps a deliberately-stamped null/undefined from being
        // treated as unset.
        const snapshotPresent = Object.prototype.hasOwnProperty.call(
          linkedPerson.lastPropagatedFields,
          field,
        );
        const lastWritten = linkedPerson.lastPropagatedFields[field];
        const localEdit =
          snapshotPresent &&
          !valuesEqualForPropagation(field, linkedValue, lastWritten);
        if (localEdit) {
          // The user already resolved this exact (sourceValue,
          // targetValue) pair earlier with `keep` — honor it and
          // leave the divergence in place silently. Without this
          // mute-check, every later propagation pass would
          // resurface the same conflict the user dismissed.
          const muted = db.identityFieldConflicts.find(
            (entry) =>
              entry.resolvedAt &&
              entry.targetPersonId === linkedPerson.id &&
              entry.targetTreeId === linkedPerson.treeId &&
              entry.field === field &&
              valuesEqualForPropagation(
                field,
                entry.sourceValue,
                sourceValue,
              ) &&
              valuesEqualForPropagation(
                field,
                entry.targetValue,
                linkedValue,
              ),
          );
          if (muted) {
            continue;
          }

          // Refresh an existing open row for the same
          // (target, field) rather than appending a duplicate —
          // /conflicts stays clean if propagation runs many
          // times before the user resolves.
          const existing = db.identityFieldConflicts.find(
            (entry) =>
              !entry.resolvedAt &&
              entry.targetPersonId === linkedPerson.id &&
              entry.targetTreeId === linkedPerson.treeId &&
              entry.field === field,
          );
          if (existing) {
            existing.identityId = identityId;
            existing.sourcePersonId = sourcePerson.id;
            existing.sourceTreeId = sourcePerson.treeId;
            existing.sourceValue = structuredClone(sourceValue);
            existing.targetValue = structuredClone(linkedValue);
            existing.updatedAt = nowTs;
          } else {
            db.identityFieldConflicts.push({
              id: crypto.randomUUID(),
              identityId,
              sourcePersonId: sourcePerson.id,
              sourceTreeId: sourcePerson.treeId,
              targetPersonId: linkedPerson.id,
              targetTreeId: linkedPerson.treeId,
              field,
              sourceValue: structuredClone(sourceValue),
              targetValue: structuredClone(linkedValue),
              createdAt: nowTs,
              updatedAt: nowTs,
              resolvedAt: null,
              resolvedBy: null,
            });
          }
          continue;
        }

        linkedPerson[field] = structuredClone(sourceValue);
        linkedPerson.lastPropagatedFields[field] = structuredClone(sourceValue);
        anyChange = true;
      }
      if (!anyChange) continue;
      linkedPerson.updatedAt = nowTs;
      // Make sure the linked tree's last-modified timestamp also
      // moves so the Flutter client knows to refetch its data.
      const linkedTree = db.trees.find(
        (entry) => entry.id === linkedPerson.treeId,
      );
      if (linkedTree) {
        linkedTree.updatedAt = nowTs;
      }
      this._appendTreeChangeRecord(db, {
        treeId: linkedPerson.treeId,
        actorId,
        type: "person.updated",
        personId: linkedPerson.id,
        details: {
          before: previousLinked,
          after: structuredClone(linkedPerson),
          // Audit hint: each propagated tree's change-log shows
          // where the update came from. Crucial for debugging
          // ("why did mom's birth date change in this tree?
          // I didn't touch it — oh, came from the other tree").
          identityPropagation: {
            sourceTreeId: sourcePerson.treeId,
            sourcePersonId: sourcePerson.id,
            sourceVersionAt: sourcePerson.updatedAt,
            previousSourceUpdatedAt: previousSourcePerson?.updatedAt,
          },
        },
      });
      upsertPersonAttributesForPerson(db, linkedPerson, actorId);
      propagated.push({
        treeId: linkedPerson.treeId,
        personId: linkedPerson.id,
      });
      // graphPerson sync is handled centrally by _write →
      // _syncGraphFromLegacy; no need to mirror here.
    }
    return propagated;
  }

  // ── Phase 3.1c: incremental graph-sync helpers ──────────────────────
  // After each legacy-side write the relevant helper mirrors the
  // change into graphPersons / graphRelations / branches /
  // branchPersonViews. Idempotent — calling them with no change is
  // a no-op. Ids are stable: graphPerson.id keys on identityId,
  // branch.id on legacyTreeId, graphRelation.id reuses the first
  // legacy relation id in the dedup group. Stable ids matter because
  // future collections (posts.branchIds, conflict-log graphPersonId)
  // hold references that must survive incremental rewrites.
  //
  // Why not full re-migration on every write? It's fine for the 19-
  // person prod state today but rebuilds non-identity graph rows
  // with fresh uuids each pass — any reference held by another
  // collection would break. The helpers preserve identity.

  // `index` — обязательные Map-индексы из _buildGraphSyncIndex
  // (SPEED-9 A). Единственный caller — _syncGraphFromLegacy; индексы
  // мутируются здесь же (push нового graphPerson/view, новый
  // legacyPersonId в existing graphPerson), чтобы следующий person в
  // ТОМ ЖЕ проходе увидел изменение — как видел бы живой `.find()`.
  _syncPersonToGraph(db, legacyPerson, index) {
    if (!legacyPerson) return;
    if (!Array.isArray(db.graphPersons)) db.graphPersons = [];
    if (!Array.isArray(db.branchPersonViews)) db.branchPersonViews = [];
    if (!Array.isArray(db.branches)) db.branches = [];

    const identityId = normalizeNullableString(legacyPerson.identityId);
    if (!identityId) {
      // After Phase 0 backfill every legacy person has an identityId.
      // Hitting this branch means we're mid-creation BEFORE
      // _reconcilePersonIdentities ran; the caller will re-sync after
      // that step.
      return;
    }

    let graphPerson = index.graphPersonsById.get(identityId);
    if (!graphPerson) {
      graphPerson = {
        id: identityId,
        createdBy: legacyPerson.creatorId || null,
        createdAt: legacyPerson.createdAt,
        updatedAt: legacyPerson.updatedAt,
        version: 0,
        deletedAt: null,
        // Phase 3.1 (DECISIONS.md ответ C): 30-day soft-delete
        // window, set on soft-delete, cleared on undo. Hard-delete
        // background job (Phase 3.6) will pick up rows whose
        // hardDeleteScheduledAt < now.
        hardDeleteScheduledAt: null,
        deletedByUserId: null,
        mergedInto: null,
        userId: legacyPerson.userId || null,
        legacyPersonIds: [legacyPerson.id],
        contactPrivacy: "owner-only",
        isPublic: false,
        source: "manual",
        // Phase 3.1 (DECISIONS.md ответ A): default privacy
        // "connected-via-blood-graph" (≤4 hops видят узел). Owner
        // override через UI поднимает до "owner-only" с
        // visibilityOverride=true.
        visibility: "connected-via-blood-graph",
        visibilityOverride: false,
      };
      for (const field of GRAPH_PERSON_CANONICAL_FIELDS) {
        graphPerson[field] = legacyPerson[field] ?? null;
      }
      db.graphPersons.push(graphPerson);
      index.graphPersonsById.set(graphPerson.id, graphPerson);
      if (!index.graphPersonsByLegacyId.has(legacyPerson.id)) {
        index.graphPersonsByLegacyId.set(legacyPerson.id, graphPerson);
      }
    } else {
      let canonicalChanged = false;
      for (const field of GRAPH_PERSON_CANONICAL_FIELDS) {
        const next = legacyPerson[field] ?? null;
        const cur = graphPerson[field] ?? null;
        // JSON-equality covers both scalar fields and the array-
        // shaped photoGallery — we don't need a deep-equal helper.
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
      if (!index.graphPersonsByLegacyId.has(legacyPerson.id)) {
        index.graphPersonsByLegacyId.set(legacyPerson.id, graphPerson);
      }
      if (!graphPerson.userId && legacyPerson.userId) {
        graphPerson.userId = legacyPerson.userId;
      }
      if (graphPerson.deletedAt) {
        // Resurrect — the legacy person came back, so does its
        // canonical node. Most likely path: a soft-delete the user
        // reverted, or a sibling person re-created on another branch.
        graphPerson.deletedAt = null;
        graphPerson.hardDeleteScheduledAt = null;
        graphPerson.deletedByUserId = null;
      }
      // Phase 3.1 lazy-fill: snapshots created before this fix won't
      // carry visibility / hardDeleteScheduledAt. Fill defaults via
      // null-coalescing — if a future admin path sets `visibility:
      // "owner-only"` directly, we MUST NOT clobber that to default.
      // `??=` triggers only on undefined/null; explicit values
      // (including `false` for visibilityOverride) survive.
      graphPerson.visibility ??= "connected-via-blood-graph";
      graphPerson.visibilityOverride ??= false;
      graphPerson.hardDeleteScheduledAt ??= null;
      graphPerson.deletedByUserId ??= null;
    }

    // Per-(branch, person) editorial slot.
    const viewKey = `${legacyPerson.treeId} ${graphPerson.id}`;
    let view = index.branchPersonViewByKey.get(viewKey);
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
      index.branchPersonViewByKey.set(viewKey, view);
    } else {
      view.notes = legacyPerson.notes ?? null;
      view.familySummary = legacyPerson.familySummary ?? null;
      view.bio = legacyPerson.bio ?? null;
      view.visibility = legacyPerson.visibility ?? null;
      view.updatedAt = legacyPerson.updatedAt;
      if (!view.legacyPersonId) view.legacyPersonId = legacyPerson.id;
    }

    // Auto-extend the branch's manual-include rule. Phase 3.2's
    // wizard will let the user pick richer rule types per branch
    // (blood-from-me, ancestors-of, etc.); for now every legacy
    // tree just becomes a manual-list branch and the rule grows
    // as people get added to the tree.
    const branch = index.branchById.get(legacyPerson.treeId);
    if (branch) {
      if (
        !branch.includeRules ||
        typeof branch.includeRules !== "object"
      ) {
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

  _syncTreeToBranch(db, tree) {
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
        // Phase 3.1 (DECISIONS.md ответ D): includeRules с
        // полным shape (anchorPersonId / maxHops). Совпадает с
        // migration-utils.buildBranchFromTree — incremental mirror
        // и one-shot migration пишут идентичную форму.
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
    // Phase 3.1 lazy-fill для existing branches без новых rule
    // полей. ??= triggers только на undefined/null — не overwrite'ит
    // user-set значения.
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

  _markPersonDeletedInGraph(db, legacyPerson, actorUserId = null) {
    if (!legacyPerson) return;
    if (!Array.isArray(db.graphPersons)) db.graphPersons = [];
    if (!Array.isArray(db.branchPersonViews)) db.branchPersonViews = [];
    if (!Array.isArray(db.branches)) db.branches = [];

    db.branchPersonViews = db.branchPersonViews.filter(
      (v) => v.legacyPersonId !== legacyPerson.id,
    );

    const identityId = normalizeNullableString(legacyPerson.identityId);
    if (!identityId) return;

    // Drop from branch.includeRules ONLY if no other legacy person
    // on the same branch is still tied to the same identity. Several
    // legacy persons sharing an identity on one branch is unusual but
    // possible (e.g. a botched import); we hold the inclusion until
    // the LAST such legacy row is gone.
    const stillOnBranch = (db.persons || []).some(
      (p) =>
        p.id !== legacyPerson.id &&
        p.treeId === legacyPerson.treeId &&
        normalizeNullableString(p.identityId) === identityId,
    );
    if (!stillOnBranch) {
      const branch = db.branches.find((b) => b.id === legacyPerson.treeId);
      if (branch?.includeRules?.manualPersonIds) {
        branch.includeRules.manualPersonIds =
          branch.includeRules.manualPersonIds.filter(
            (gid) => gid !== identityId,
          );
        branch.updatedAt = nowIso();
      }
    }

    // Soft-delete the graphPerson when no legacy row anywhere ties
    // to its identity. Phase 3.1 (DECISIONS.md ответ C): hard-delete
    // is deferred to a 30-day window — `hardDeleteScheduledAt` is
    // set now+30d so the future Phase 3.6 background job can pick
    // up rows past their window. Undo flips both deletedAt and
    // hardDeleteScheduledAt back to null (handled in _syncPersonToGraph
    // resurrect path).
    const stillReferenced = (db.persons || []).some(
      (p) =>
        p.id !== legacyPerson.id &&
        normalizeNullableString(p.identityId) === identityId,
    );
    if (!stillReferenced) {
      const graphPerson = db.graphPersons.find((g) => g.id === identityId);
      if (graphPerson && !graphPerson.deletedAt) {
        const deletedTs = nowIso();
        graphPerson.deletedAt = deletedTs;
        const expirationDate = new Date(Date.parse(deletedTs));
        expirationDate.setUTCDate(expirationDate.getUTCDate() + 30);
        graphPerson.hardDeleteScheduledAt = expirationDate.toISOString();
        graphPerson.deletedByUserId =
          normalizeNullableString(actorUserId) || null;
      }
    }
  }

  // `index` — обязательные Map-индексы из _buildGraphSyncIndex
  // (SPEED-9 A). personsById/graphPersonsByLegacyId заменяют два
  // прежних .find() по db.persons/db.graphPersons.
  _resolveGraphPersonIdForLegacy(db, legacyPersonId, index) {
    if (!legacyPersonId) return null;
    const legacyPerson = index.personsById.get(legacyPersonId);
    if (legacyPerson) {
      const identityId = normalizeNullableString(legacyPerson.identityId);
      if (identityId) return identityId;
    }
    // Person already deleted — fall back to a stale lookup through
    // existing graph rows so callers still operating on a relation
    // mid-cleanup don't get null.
    const fromGraph = index.graphPersonsByLegacyId.get(legacyPersonId);
    return fromGraph ? fromGraph.id : null;
  }

  _syncRelationToGraph(db, legacyRelation, index) {
    if (!legacyRelation) return;
    if (!Array.isArray(db.graphRelations)) db.graphRelations = [];
    const p1g = this._resolveGraphPersonIdForLegacy(
      db,
      legacyRelation.person1Id,
      index,
    );
    const p2g = this._resolveGraphPersonIdForLegacy(
      db,
      legacyRelation.person2Id,
      index,
    );
    if (!p1g || !p2g) return;

    const dedupKey = buildGraphRelationDedupKey(p1g, p2g, legacyRelation);
    // Тот же приоритет, что и у прежнего .find(): точное совпадение
    // по legacyRelationId — раньше, дедуп по ключу — fallback (для
    // валидных данных, которые эти же функции и поддерживают,
    // legacyRelationId принадлежит не более чем одному graphRelation
    // и dedup-ключ не более чем одному graphRelation — коллизия
    // порядка между двумя РАЗНЫМИ записями не возникает).
    let graphRelation = index.graphRelationsByLegacyId.get(legacyRelation.id);
    if (!graphRelation) {
      graphRelation = index.graphRelationsByDedupKey.get(dedupKey);
    }

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
        customRelationLabel1to2:
          legacyRelation.customRelationLabel1to2 || null,
        customRelationLabel2to1:
          legacyRelation.customRelationLabel2to1 || null,
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
      index.graphRelationsByLegacyId.set(legacyRelation.id, graphRelation);
      index.graphRelationsByDedupKey.set(dedupKey, graphRelation);
      return;
    }

    // relation1to2/relation2to1 входят в dedup-ключ и МОГУТ меняться
    // ниже — если тип связи поменялся, следующая relation в этом же
    // проходе, которая должна была бы задедуплицироваться в эту же
    // graphRelation, обязана найти её по НОВОМУ ключу (раньше .find()
    // просто пересчитывал ключ заново на каждый вызов).
    const previousDedupKey = buildGraphRelationDedupKey(
      graphRelation.person1Id,
      graphRelation.person2Id,
      graphRelation,
    );

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

    // Индекс — на случай, если legacyRelation.id раньше указывал на
    // dedup-путь (не был в graphRelationsByLegacyId), и на случай,
    // если relation1to2/relation2to1 поменялись и dedup-ключ сдвинулся.
    index.graphRelationsByLegacyId.set(legacyRelation.id, graphRelation);
    const updatedDedupKey = buildGraphRelationDedupKey(
      graphRelation.person1Id,
      graphRelation.person2Id,
      graphRelation,
    );
    if (
      updatedDedupKey !== previousDedupKey &&
      index.graphRelationsByDedupKey.get(previousDedupKey) === graphRelation
    ) {
      index.graphRelationsByDedupKey.delete(previousDedupKey);
    }
    index.graphRelationsByDedupKey.set(updatedDedupKey, graphRelation);
  }

  // ── Phase 4: Find Blood Relation (BFS over the unified graph) ──────
  // Walks `graphRelations` looking only at blood-relation edges
  // (parent/child/sibling). Returns the shortest chain of graph
  // persons from `fromId` to `toId`, the edge sequence describing
  // the path, the consanguinity degree, and a Russian label
  // ("троюродная сестра", "прадедушка"). Returns null when no
  // blood path exists within `maxDepth` hops.
  //
  // Why blood-only: spouse/partner/step/adopted edges connect
  // people who share the household but not necessarily DNA. The
  // RFC restricts the "найти родство" feature to the consanguinity
  // graph by design — adding non-blood edges turns the engine
  // into "social distance" rather than "родство".
  // `adjacency` — опциональная предпостроенная карта смежности
  // (SPEED-8d). Без неё поведение не меняется (строим с нуля из db,
  // как раньше); передаётся, когда caller гоняет BFS много раз ПОДРЯД
  // для одного и того же db в рамках одного запроса
  // (filterLegacyPersonsByGraphVisibility на N кандидатов) — без
  // этого каждый вызов пересобирал бы весь граф родства заново.
  _findBloodRelationBetween(
    db,
    fromGraphPersonId,
    toGraphPersonId,
    {maxDepth = 10, adjacency: precomputedAdjacency = null} = {},
  ) {
    if (!fromGraphPersonId || !toGraphPersonId) return null;
    if (fromGraphPersonId === toGraphPersonId) {
      return {
        chain: [fromGraphPersonId],
        edges: [],
        label: "Это вы",
        degree: 0,
      };
    }
    const adjacency = precomputedAdjacency || this._buildBloodAdjacency(db);
    const fromList = adjacency.get(fromGraphPersonId);
    if (!fromList) return null;

    // BFS gives shortest path in an unweighted graph — exactly
    // what we want for "ближайшая степень родства".
    const visited = new Map([[fromGraphPersonId, null]]);
    const queue = [{node: fromGraphPersonId, depth: 0, edges: []}];
    while (queue.length) {
      const current = queue.shift();
      if (current.depth >= maxDepth) continue;
      const neighbors = adjacency.get(current.node) || [];
      for (const {neighbor, edgeType} of neighbors) {
        if (visited.has(neighbor)) continue;
        visited.set(neighbor, {parent: current.node, edgeType});
        if (neighbor === toGraphPersonId) {
          const path = [neighbor];
          const edges = [edgeType];
          let cursor = current.node;
          while (cursor !== fromGraphPersonId) {
            path.push(cursor);
            const back = visited.get(cursor);
            edges.push(back.edgeType);
            cursor = back.parent;
          }
          path.push(fromGraphPersonId);
          path.reverse();
          edges.reverse();
          const targetPerson = (db.graphPersons || []).find(
            (g) => g.id === toGraphPersonId,
          );
          const description = describeBloodRelation(
            edges,
            targetPerson?.gender,
          );
          return {
            chain: path,
            edges,
            label: description.label,
            degree: description.degree,
          };
        }
        queue.push({
          node: neighbor,
          depth: current.depth + 1,
          edges: [...current.edges, edgeType],
        });
      }
    }
    return null;
  }

  _buildBloodAdjacency(db) {
    const adjacency = new Map();
    const relations = Array.isArray(db.graphRelations)
      ? db.graphRelations
      : [];
    const ensure = (id) => {
      if (!adjacency.has(id)) adjacency.set(id, []);
      return adjacency.get(id);
    };
    // Adjacency uses the role-of-TARGET convention. For a relation
    // (p1, p2, relation1to2='parent') — p1 is parent of p2 — we
    // record:
    //   adjacency[p2] += {neighbor: p1, edgeType: 'parent'}
    //   adjacency[p1] += {neighbor: p2, edgeType: 'child'}
    // Walking p2 → p1 means I traversed an edge whose target is a
    // 'parent' (going UP / towards ancestor). Walking p1 → p2 means
    // I traversed an edge whose target is a 'child' (going DOWN /
    // towards descendant). This matches the convention in
    // _buildBranchVisiblePersonIds (line ~12420) so two engines
    // describe the same family the same way.
    //
    // If `relation2to1` is missing we derive it via `mirrorBloodType`
    // — the existing branch-visibility code does the same fallback
    // through `relationMirror`. Without this, half of legacy rows
    // (one-sided imports) silently drop out of the blood graph and
    // BFS returns "no path" for relatives that obviously share DNA.
    for (const relation of relations) {
      if (relation.deletedAt) continue;
      const r1 = canonicalBloodType(relation.relation1to2);
      const r2 =
        canonicalBloodType(relation.relation2to1) ||
        mirrorBloodType(relation.relation1to2);
      if (!r1 || !r2) continue;
      ensure(relation.person2Id).push({
        neighbor: relation.person1Id,
        edgeType: r1,
      });
      ensure(relation.person1Id).push({
        neighbor: relation.person2Id,
        edgeType: r2,
      });
    }
    return adjacency;
  }

  async findBloodRelation({fromGraphPersonId, toGraphPersonId, maxDepth = 10}) {
    const db = await this._read();
    return this._findBloodRelationBetween(
      db,
      fromGraphPersonId,
      toGraphPersonId,
      {maxDepth},
    );
  }

  // Preview shape for the chain returned by `/v1/graph/relation`.
  // Only the bare minimum — name + photo + dates — so the client
  // can render a relationship-path strip without leaking editorial
  // fields from non-accessible branches.
  async previewGraphPersonsByIds(graphPersonIds, {viewerUserId = null} = {}) {
    const db = await this._read();
    const ids = Array.isArray(graphPersonIds) ? graphPersonIds : [];
    const normalizedViewer = normalizeNullableString(viewerUserId);
    return ids.map((id) => {
      const graphPerson = (db.graphPersons || []).find((g) => g.id === id);
      if (!graphPerson || graphPerson.deletedAt) {
        return {
          id,
          name: null,
          gender: null,
          birthDate: null,
          deathDate: null,
          photoUrl: null,
        };
      }
      // Phase 3.2: chain hydration (BFS, /v1/graph/relation,
      // future /v1/me/extended-family) — каждый node идёт через
      // visibility gate. Hidden node возвращается с пустыми
      // canonical полями + `hidden: true`, чтобы UI знал «здесь
      // звено есть, но имя не показано». Chain shape сохраняется,
      // BFS-степень всё ещё считается — это всё, что нужно для
      // «троюродная сестра через скрытого предка».
      if (
        normalizedViewer &&
        !this._userCanSeeGraphPerson(db, graphPerson, normalizedViewer)
      ) {
        return {
          id: graphPerson.id,
          name: null,
          gender: null,
          birthDate: null,
          deathDate: null,
          photoUrl: null,
          hidden: true,
        };
      }
      return {
        id: graphPerson.id,
        name: graphPerson.name,
        gender: graphPerson.gender,
        birthDate: graphPerson.birthDate,
        deathDate: graphPerson.deathDate,
        photoUrl:
          graphPerson.primaryPhotoUrl || graphPerson.photoUrl || null,
      };
    });
  }

  // ── Phase 3.2: graph-person resolution + grants + visibility ──────
  // Owner-model enforcement (DECISIONS.md 2026-05-10 ответ C):
  // default owner-only edit, без auto-extension по hops; explicit
  // grants per-scope ("edit" / "merge-consent" / "soft-delete");
  // merge — двусторонний consent через mergeProposals; visibility —
  // owner-only-всегда (никаких grants даже на toggle).

  // Resolve a legacy person id to its canonical graphPerson row.
  // Returns null when the legacy person doesn't exist or its
  // graphPerson has been soft-deleted. Used by route gates that
  // need to call _userCanEditGraphPerson on a (treeId, personId)
  // pair from the URL.
  async findGraphPersonByLegacy(legacyPersonId) {
    const normalizedId = normalizeNullableString(legacyPersonId);
    if (!normalizedId) return null;
    const db = await this._read();
    const legacyPerson = (db.persons || []).find(
      (entry) => entry.id === normalizedId,
    );
    const identityId = legacyPerson
      ? normalizeNullableString(legacyPerson.identityId)
      : null;

    let graphPerson = identityId
      ? (db.graphPersons || []).find((g) => g.id === identityId)
      : null;

    if (!graphPerson) {
      // Edge case: legacy row exists but graphPerson hasn't been
      // synced yet (e.g. first read after a fresh migration). Falling
      // back to a `legacyPersonIds` reverse lookup keeps gates
      // working until the next _syncPersonToGraph pass.
      graphPerson = (db.graphPersons || []).find(
        (g) =>
          Array.isArray(g.legacyPersonIds) &&
          g.legacyPersonIds.includes(normalizedId),
      );
    }
    return graphPerson ? structuredClone(graphPerson) : null;
  }

  async findGraphPersonById(graphPersonId) {
    const normalizedId = normalizeNullableString(graphPersonId);
    if (!normalizedId) return null;
    const db = await this._read();
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === normalizedId,
    );
    return graphPerson ? structuredClone(graphPerson) : null;
  }

  // ─── Grant CRUD (POST/DELETE/GET /v1/graph-persons/:id/grants) ──

  async addGraphPersonGrant({
    graphPersonId,
    grantorUserId,
    granteeUserId,
    scope,
  }) {
    const normalizedScope = String(scope || "").trim();
    if (!["edit", "merge-consent", "soft-delete"].includes(normalizedScope)) {
      throw new Error("INVALID_SCOPE");
    }
    const normalizedGraphPersonId = normalizeNullableString(graphPersonId);
    const normalizedGrantor = normalizeNullableString(grantorUserId);
    const normalizedGrantee = normalizeNullableString(granteeUserId);
    if (!normalizedGraphPersonId || !normalizedGrantor || !normalizedGrantee) {
      throw new Error("INVALID_INPUT");
    }
    if (normalizedGrantor === normalizedGrantee) {
      throw new Error("SELF_GRANT");
    }
    const db = await this._read();
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === normalizedGraphPersonId,
    );
    if (!graphPerson || graphPerson.deletedAt) return null;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner !== normalizedGrantor) {
      throw new Error("NOT_OWNER");
    }

    if (!Array.isArray(db.graphPersonEditGrants)) {
      db.graphPersonEditGrants = [];
    }

    // Idempotency: re-issuing an active grant on the same triple
    // returns the existing row. A revoked row with the same triple
    // is left alone (audit trail) and a fresh row gets pushed.
    const activeExisting = db.graphPersonEditGrants.find(
      (entry) =>
        entry.graphPersonId === normalizedGraphPersonId &&
        entry.granteeUserId === normalizedGrantee &&
        entry.scope === normalizedScope &&
        !entry.revokedAt,
    );
    if (activeExisting) {
      return {grant: structuredClone(activeExisting), created: false};
    }

    const grant = {
      id: crypto.randomUUID(),
      graphPersonId: normalizedGraphPersonId,
      grantorUserId: normalizedGrantor,
      granteeUserId: normalizedGrantee,
      scope: normalizedScope,
      grantedAt: nowIso(),
      revokedAt: null,
      origin: "owner-grant",
    };
    db.graphPersonEditGrants.push(grant);
    await this._write(db);
    return {grant: structuredClone(grant), created: true};
  }

  async revokeGraphPersonGrant({graphPersonId, grantId, actorUserId}) {
    const normalizedGraphPersonId = normalizeNullableString(graphPersonId);
    const normalizedGrantId = normalizeNullableString(grantId);
    const normalizedActor = normalizeNullableString(actorUserId);
    if (!normalizedGraphPersonId || !normalizedGrantId || !normalizedActor) {
      return null;
    }
    const db = await this._read();
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === normalizedGraphPersonId,
    );
    if (!graphPerson) return null;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner !== normalizedActor) {
      throw new Error("NOT_OWNER");
    }

    if (!Array.isArray(db.graphPersonEditGrants)) {
      db.graphPersonEditGrants = [];
    }
    const grant = db.graphPersonEditGrants.find(
      (entry) =>
        entry.id === normalizedGrantId &&
        entry.graphPersonId === normalizedGraphPersonId,
    );
    if (!grant) return null;

    if (grant.revokedAt) {
      // Idempotent — already revoked, no rewrite of the timestamp.
      return structuredClone(grant);
    }
    grant.revokedAt = nowIso();
    await this._write(db);
    return structuredClone(grant);
  }

  async listGraphPersonGrants({graphPersonId, viewerUserId}) {
    const normalizedGraphPersonId = normalizeNullableString(graphPersonId);
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (!normalizedGraphPersonId || !normalizedViewer) return null;
    const db = await this._read();
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === normalizedGraphPersonId,
    );
    if (!graphPerson) return null;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner !== normalizedViewer) {
      throw new Error("NOT_OWNER");
    }
    return (db.graphPersonEditGrants || [])
      .filter((entry) => entry.graphPersonId === normalizedGraphPersonId)
      .map((entry) => structuredClone(entry));
  }

  // Phase 3.4-prep (DECISIONS.md 2026-05-10 Q3): grantor-side список
  // grants выписанных текущим юзером. Симметричен `listMyGrantsForUser`
  // (grantee-side). Пагинируется не только активными — включаем
  // revoked за 30d window для audit visibility «недавно отозвал».
  async listMyIssuedGrants({userId, includeRevokedSinceDays = 30}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return [];
    const db = await this._read();
    const cutoff = new Date(Date.now() - includeRevokedSinceDays * 86_400_000);
    return (db.graphPersonEditGrants || [])
      .filter((entry) => entry.grantorUserId === normalizedUser)
      .filter((entry) => {
        if (!entry.revokedAt) return true;
        const revoked = new Date(entry.revokedAt);
        return Number.isFinite(revoked.getTime()) && revoked >= cutoff;
      })
      .map((entry) => structuredClone(entry));
  }

  // Phase 3.4-prep (Q4): edit branch.includeRules с owner-only check.
  // Used by PATCH /v1/trees/:treeId/include-rules. Отдельный store
  // entry-point чтобы UI не лазил через generic updateTree (которого
  // нет — tree updates идут через _syncTreeToBranch + create flow).
  async updateBranchIncludeRules({treeId, rules, actorUserId}) {
    const normalizedTreeId = normalizeNullableString(treeId);
    const normalizedActor = normalizeNullableString(actorUserId);
    if (!normalizedTreeId || !normalizedActor) return null;
    const db = await this._read();
    const tree = (db.trees || []).find((entry) => entry.id === normalizedTreeId);
    if (!tree) return null;
    if (tree.creatorId !== normalizedActor) {
      throw new Error("NOT_OWNER");
    }
    if (!rules || typeof rules !== "object") {
      throw new Error("INVALID_RULES");
    }
    const requestedType = String(rules.type || "").trim();
    if (!VALID_INCLUDE_RULE_TYPES.has(requestedType)) {
      throw new Error("INVALID_RULE_TYPE");
    }

    // Sync first — гарантируем что branch row существует.
    this._syncTreeToBranch(db, tree);
    const branch = (db.branches || []).find(
      (entry) => entry.id === normalizedTreeId,
    );
    if (!branch) return null;

    const changed = applyIncludeRulesToBranch(branch, rules);
    if (changed) {
      branch.updatedAt = nowIso();
      tree.updatedAt = branch.updatedAt;
      await this._write(db);
    }
    return structuredClone(branch);
  }

  // Phase 3.4-prep (Q4 warning preview): возвращает counts ДО и
  // ПОСЛЕ применения новых rules БЕЗ commit'а. Helps UX warn'нуть
  // юзера «X родственников появятся, Y исчезнут» перед apply.
  async previewBranchIncludeRules({treeId, rules, viewerUserId}) {
    const normalizedTreeId = normalizeNullableString(treeId);
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (!normalizedTreeId || !normalizedViewer) return null;
    if (!rules || typeof rules !== "object") {
      throw new Error("INVALID_RULES");
    }
    const requestedType = String(rules.type || "").trim();
    if (!VALID_INCLUDE_RULE_TYPES.has(requestedType)) {
      throw new Error("INVALID_RULE_TYPE");
    }
    const db = await this._read();
    const branch = (db.branches || []).find(
      (entry) => entry.id === normalizedTreeId,
    );
    if (!branch) return null;
    if (
      branch.ownerId !== normalizedViewer &&
      !(Array.isArray(branch.memberIds) && branch.memberIds.includes(normalizedViewer))
    ) {
      throw new Error("FORBIDDEN");
    }

    const beforeSet = this._buildBranchVisiblePersonIds(
      db,
      branch,
      normalizedViewer,
    );

    // Симулируем новый branch через deep-clone и apply (без write'а).
    const previewBranch = structuredClone(branch);
    applyIncludeRulesToBranch(previewBranch, rules);
    const afterSet = this._buildBranchVisiblePersonIds(
      db,
      previewBranch,
      normalizedViewer,
    );

    const added = [...afterSet].filter((id) => !beforeSet.has(id));
    const removed = [...beforeSet].filter((id) => !afterSet.has(id));

    return {
      addedCount: added.length,
      removedCount: removed.length,
      totalBeforeCount: beforeSet.size,
      totalAfterCount: afterSet.size,
    };
  }

  // /v1/me/edit-grants: каждый grantee видит свои active + revoked
  // за последние N дней (default 30 — DECISIONS.md 2026-05-10 Q3
  // намеренно совпадает с hardDeleteScheduledAt window). Старее —
  // в audit-only state, не отдаём в UI.
  async listMyGrantsForUser({userId, includeRevokedSinceDays = 30}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return [];
    const db = await this._read();
    const cutoff = new Date(Date.now() - includeRevokedSinceDays * 86_400_000);
    return (db.graphPersonEditGrants || [])
      .filter((entry) => entry.granteeUserId === normalizedUser)
      .filter((entry) => {
        if (!entry.revokedAt) return true;
        const revoked = new Date(entry.revokedAt);
        return Number.isFinite(revoked.getTime()) && revoked >= cutoff;
      })
      .map((entry) => structuredClone(entry));
  }

  // ─── Phase 4: extended network slice ────────────────────────────
  //
  // BFS slice от self-node viewer'а через blood adjacency. Каждый
  // потенциальный target gate'ится через `_userCanSeeGraphPerson`
  // (privacy fence — Phase 3.1 invariant, не relax'ается). graphRelations
  // включаются только когда **оба** endpoints в slice — никаких
  // «public node как портал» leak'ов (DECISIONS.md 2026-05-12 Q1.A).
  //
  // ownerMap **sparse**: содержит только узлы где owner !== viewer
  // (foreign nodes). 90%+ узлов typical viewer'а — own; sparse pattern
  // экономит payload + memory на клиенте (DECISIONS.md 2026-05-12,
  // nice-to-have #1).
  //
  // Slice cap = 1000 persons (Phase 4 DECISIONS Q5.A). Если BFS hit
  // cap — truncate + `stats.capReached: true` для UX hint'а.
  //
  // maxHops clamp 2..4 на route layer'е (см. tree-routes.js); store
  // doubles down defensively (`max(2, min(4, value))`) на случай
  // прямого invocation'а с тестов.
  async getExtendedNetworkSlice({
    viewerUserId,
    treeId,
    maxHops = 4,
    includeAnonymous = true,
    branchIds = null,
    sliceCap = 1000,
  } = {}) {
    const normalizedViewer = normalizeNullableString(viewerUserId);
    const normalizedTree = normalizeNullableString(treeId);
    if (!normalizedViewer || !normalizedTree) {
      return null;
    }
    // Server-side clamp под privacy fence (Q6.A: slider 2..4).
    const fence = FileStore._connectedVisibilityMaxHops;
    let clampedMaxHops = Number.isFinite(Number(maxHops))
      ? Math.floor(Number(maxHops))
      : fence;
    clampedMaxHops = Math.max(2, Math.min(fence, clampedMaxHops));

    const db = await this._read();
    const tree = (db.trees || []).find((t) => t.id === normalizedTree);
    if (!tree) return null;

    // Tree membership check: viewer должен быть либо creator'ом
    // либо иметь хотя бы один person'а в этом дереве (Phase 3.2
    // owner-model). Если нет — endpoint вернёт 403.
    const treePersons = (db.persons || []).filter(
      (p) => p.treeId === normalizedTree && !p.deletedAt,
    );
    const isCreator = tree.creatorId === normalizedViewer;
    const isMember = treePersons.some((p) => p.userId === normalizedViewer);
    if (!isCreator && !isMember) {
      return {error: "NOT_TREE_MEMBER"};
    }

    // BFS roots: все persons моей tree → их identityId. Так slice
    // включает «моё дерево полностью» + соседей через identity граф.
    const myIdentityIds = new Set();
    for (const person of treePersons) {
      const identityId = normalizeNullableString(person.identityId);
      if (identityId) myIdentityIds.add(identityId);
    }
    if (myIdentityIds.size === 0) {
      // Свежее дерево, viewer ещё не добавил себя — пустой slice.
      return {
        graphPersons: [],
        graphRelations: [],
        branchMembership: {},
        ownerMap: {},
        viewerSelfGraphPersonId: null,
        stats: {
          totalCount: 0,
          myCount: 0,
          extendedCount: 0,
          anonymousCount: 0,
          maxHopsReached: false,
          capReached: false,
        },
      };
    }

    // Optional branch filter: если caller передал branchIds, только
    // identity'ы из этих веток считаем «моими» (для tree roots).
    const filteredBranchIds = Array.isArray(branchIds)
      ? new Set(
          branchIds
            .map((b) => normalizeNullableString(b))
            .filter((b) => b !== null),
        )
      : null;
    // На текущей schema'е branches mirror trees 1:1; branchIds filter
    // — placeholder для post-Phase-4.1 cross-branch filtering. v1
    // ignored unless explicitly matches treeId.
    if (
      filteredBranchIds !== null &&
      filteredBranchIds.size > 0 &&
      !filteredBranchIds.has(normalizedTree)
    ) {
      return {
        graphPersons: [],
        graphRelations: [],
        branchMembership: {},
        ownerMap: {},
        viewerSelfGraphPersonId: null,
        stats: {
          totalCount: 0,
          myCount: 0,
          extendedCount: 0,
          anonymousCount: 0,
          maxHopsReached: false,
          capReached: false,
        },
      };
    }

    const effectiveSliceCap = Number.isFinite(Number(sliceCap))
      ? Math.max(1, Math.floor(Number(sliceCap)))
      : 1000;
    const adjacency = this._buildBloodAdjacency(db);
    const visited = new Map(); // graphPersonId → hop distance
    const queue = [];
    let capReached = false;
    // Cap check на initial roots — если у viewer'а tree персон больше
    // чем cap, мы должны это поймать ДО BFS expansion'а. Иначе initial
    // visited.size может превысить cap молча.
    for (const rootId of myIdentityIds) {
      if (visited.size >= effectiveSliceCap) {
        capReached = true;
        break;
      }
      visited.set(rootId, 0);
      queue.push({id: rootId, depth: 0});
    }

    let maxHopsReached = false;

    while (queue.length > 0) {
      const current = queue.shift();
      if (current.depth >= clampedMaxHops) {
        maxHopsReached = true;
        continue;
      }
      const neighbors = adjacency.get(current.id) || [];
      for (const {neighbor} of neighbors) {
        if (visited.has(neighbor)) continue;
        if (visited.size >= effectiveSliceCap) {
          capReached = true;
          break;
        }
        visited.set(neighbor, current.depth + 1);
        queue.push({id: neighbor, depth: current.depth + 1});
      }
      if (capReached) break;
    }

    // Privacy gate per-target. Apply ПОСЛЕ BFS чтобы adjacency
    // traversal остался дешёвым; gate отсеивает hidden targets как
    // финальный filter. (Альтернатива — гейтить inside BFS — даёт
    // меньше work, но edge case: viewer self-node остаётся в slice
    // даже если по какой-то причине not seen by him — defensive.)
    const allowedIds = new Set();
    const graphPersonsOut = [];
    const ownerMapOut = {};
    let anonymousCount = 0;
    let myCount = 0;

    for (const [graphPersonId, hopDistance] of visited.entries()) {
      const graphPerson = (db.graphPersons || []).find(
        (g) => g.id === graphPersonId && !g.deletedAt,
      );
      if (!graphPerson) continue;
      // Privacy fence applied per-target-node (Q1.B). Self-node viewer'а
      // всегда allowed (owner === viewer); reused gate consistent с
      // другими read paths.
      if (!this._userCanSeeGraphPerson(db, graphPerson, normalizedViewer)) {
        continue;
      }
      // Skip anonymous nodes если includeAnonymous=false.
      const owner = this._graphPersonOwnerUserId(graphPerson);
      const isAnonymous = !graphPerson.userId;
      if (isAnonymous && !includeAnonymous) continue;

      allowedIds.add(graphPersonId);
      graphPersonsOut.push({
        id: graphPerson.id,
        name: graphPerson.name || null,
        gender: graphPerson.gender || null,
        birthDate: graphPerson.birthDate || null,
        deathDate: graphPerson.deathDate || null,
        photoUrl: graphPerson.photoUrl || null,
        isAlive: graphPerson.isAlive !== false,
        hopDistance,
      });
      if (isAnonymous) anonymousCount += 1;
      if (owner === normalizedViewer) {
        myCount += 1;
      } else {
        // Sparse ownerMap: только foreign nodes.
        ownerMapOut[graphPerson.id] = {
          userId: owner,
          displayName: null, // hydrate'ится ниже
          photoUrl: null,
        };
      }
    }

    // Hydrate owner displayNames + photo (только для foreign nodes).
    const foreignOwnerIds = new Set();
    for (const entry of Object.values(ownerMapOut)) {
      if (entry.userId) foreignOwnerIds.add(entry.userId);
    }
    for (const ownerUserId of foreignOwnerIds) {
      const user = (db.users || []).find((u) => u.id === ownerUserId);
      if (!user) continue;
      const profile = user.profile || {};
      for (const entry of Object.values(ownerMapOut)) {
        if (entry.userId === ownerUserId) {
          entry.displayName = profile.displayName || user.email || null;
          entry.photoUrl = profile.photoUrl || null;
        }
      }
    }

    // graphRelations: только когда оба endpoints in allowed set.
    const graphRelationsOut = [];
    for (const relation of db.graphRelations || []) {
      if (!relation || relation.deletedAt) continue;
      if (
        allowedIds.has(relation.person1Id) &&
        allowedIds.has(relation.person2Id)
      ) {
        graphRelationsOut.push({
          id: relation.id,
          person1Id: relation.person1Id,
          person2Id: relation.person2Id,
          relation1to2: relation.relation1to2,
          relation2to1: relation.relation2to1,
        });
      }
    }

    // branchMembership: для каждого graphPersonId — список trees, где
    // он представлен через persons.identityId. Это даёт UI'ю signal
    // «этот узел также есть в ветке X».
    const branchMembershipOut = {};
    for (const graphPersonId of allowedIds) {
      const branches = new Set();
      for (const person of db.persons || []) {
        if (
          person.identityId === graphPersonId &&
          !person.deletedAt &&
          person.treeId
        ) {
          branches.add(person.treeId);
        }
      }
      if (branches.size > 0) {
        branchMembershipOut[graphPersonId] = Array.from(branches);
      }
    }

    // Phase 4 chunk 4a: viewer self-node id для UI lazy-fetch
    // relation-to-me (через /v1/graph/relation). Single deterministic
    // value — слой DTO не делает client-side filter through
    // graphPersons. May be null если viewer не имеет claimed
    // identity (edge case — anonymous tester либо account без
    // self-node ещё не создан).
    const viewerSelfGraphPersonId =
        this._selfGraphPersonIdForUser(db, normalizedViewer);

    return {
      graphPersons: graphPersonsOut,
      graphRelations: graphRelationsOut,
      branchMembership: branchMembershipOut,
      ownerMap: ownerMapOut,
      viewerSelfGraphPersonId,
      stats: {
        totalCount: graphPersonsOut.length,
        myCount,
        extendedCount: graphPersonsOut.length - myCount,
        anonymousCount,
        maxHopsReached,
        capReached,
      },
    };
  }

  // ─── Visibility update (owner-only, не grants) ──────────────────

  async setGraphPersonVisibility({
    graphPersonId,
    visibility,
    actorUserId,
  }) {
    if (
      !["owner-only", "connected-via-blood-graph", "public"].includes(
        String(visibility || "").trim(),
      )
    ) {
      throw new Error("INVALID_VISIBILITY");
    }
    const normalizedGraphPersonId = normalizeNullableString(graphPersonId);
    const normalizedActor = normalizeNullableString(actorUserId);
    if (!normalizedGraphPersonId || !normalizedActor) return null;
    const db = await this._read();
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === normalizedGraphPersonId,
    );
    if (!graphPerson || graphPerson.deletedAt) return null;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner !== normalizedActor) {
      throw new Error("NOT_OWNER");
    }
    graphPerson.visibility = visibility;
    graphPerson.visibilityOverride = true;
    graphPerson.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(graphPerson);
  }

  async clearGraphPersonVisibilityOverride({
    graphPersonId,
    actorUserId,
  }) {
    const normalizedGraphPersonId = normalizeNullableString(graphPersonId);
    const normalizedActor = normalizeNullableString(actorUserId);
    if (!normalizedGraphPersonId || !normalizedActor) return null;
    const db = await this._read();
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === normalizedGraphPersonId,
    );
    if (!graphPerson || graphPerson.deletedAt) return null;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner !== normalizedActor) {
      throw new Error("NOT_OWNER");
    }
    graphPerson.visibilityOverride = false;
    graphPerson.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(graphPerson);
  }

  // ─── Sensitive-attributes-aware reads ───────────────────────────

  // Filter sensitive attribute fields (`field === "contacts"`)
  // when viewer isn't the graphPerson owner. Used by attributes
  // endpoint. Non-sensitive fields проходят без дополнительной
  // gate'и — посетитель уже прошёл `requireTreeAccess`, значит
  // имеет право видеть базовые поля person'а в этом дереве.
  filterSensitiveAttributesForViewer({
    db,
    graphPerson,
    viewerUserId,
    attributes,
  }) {
    if (!Array.isArray(attributes)) return [];
    return attributes.filter((attr) =>
      this._userCanSeeSensitiveAttributeField(
        db,
        graphPerson,
        viewerUserId,
        attr?.field,
      ),
    );
  }

  // ─── Cross-tree visibility filter for legacy-shape lists ────────

  // Bulk visibility check: для list-cross-tree-results (search,
  // identity-suggestions). Фильтрует persons по
  // `_userCanSeeGraphPerson`. Persons без graphPerson (mid-sync
  // edge case) — оставляем (fail-open до следующего sync'а).
  // Возвращает только legacy persons, которые viewer может видеть.
  // Один _read() на whole list — без N+1 на каждый person (caller
  // может передать уже прочитанный db третьим аргументом, чтобы не
  // читать блоб ещё раз, если он и так только что читал его сам —
  // см. identity-suggestions хендлер в tree-routes.js).
  //
  // SPEED-8d: сам _userCanSeeGraphPerson для visibility="connected-
  // via-blood-graph" (дефолт) резолвит viewer'а через
  // _selfGraphPersonIdForUser (линейный проход по users+graphPersons)
  // и гоняет BFS с ПЕРЕСБОРКОЙ adjacency из db.graphRelations с нуля
  // на каждый вызов. viewer и db внутри ОДНОГО вызова этого фильтра
  // не меняются, а количество вызовов — до `limit` (identity-
  // suggestions) целей, так что раньше на каждый ответ endpoint'а
  // могла приходиться до `limit` полных пересборок графа родства.
  // Здесь оба считаются один раз (adjacency — лениво, только если
  // хотя бы один person реально дошёл до blood-graph ветки) и
  // передаются через `context` дальше без изменения результата
  // _userCanSeeGraphPerson — она документированно детерминирована
  // по (db, graphPerson, viewerUserId) и не зависит от identity
  // объекта adjacency-мапы, лишь бы содержимое было тем же.
  async filterLegacyPersonsByGraphVisibility(
    persons,
    viewerUserId,
    prefetchedDb = null,
  ) {
    if (!Array.isArray(persons) || persons.length === 0) return [];
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (!normalizedViewer) return [];
    const db = prefetchedDb || (await this._read());
    const graphPersonsByIdentity = new Map(
      (db.graphPersons || []).map((entry) => [entry.id, entry]),
    );
    const graphPersonsByLegacy = new Map();
    for (const entry of db.graphPersons || []) {
      for (const legacyId of entry.legacyPersonIds || []) {
        graphPersonsByLegacy.set(legacyId, entry);
      }
    }
    const store = this;
    const viewerSelfGraphPersonId = store._selfGraphPersonIdForUser(
      db,
      normalizedViewer,
    );
    // Ленивая сборка: если ни один person не доходит до blood-graph
    // ветки (все — owner/granted/public/pre-sync), adjacency вообще
    // не строится, как и раньше.
    let cachedAdjacency = null;
    const visibilityContext = {
      viewerSelfGraphPersonId,
      get adjacency() {
        if (!cachedAdjacency) {
          cachedAdjacency = store._buildBloodAdjacency(db);
        }
        return cachedAdjacency;
      },
    };
    return persons.filter((person) => {
      const identityId = normalizeNullableString(person?.identityId);
      const graphPerson =
        (identityId && graphPersonsByIdentity.get(identityId)) ||
        graphPersonsByLegacy.get(person?.id) ||
        null;
      if (!graphPerson) return true; // Pre-sync — fail-open.
      return this._userCanSeeGraphPerson(
        db,
        graphPerson,
        normalizedViewer,
        visibilityContext,
      );
    });
  }

  _markRelationDeletedInGraph(db, legacyRelation) {
    if (!legacyRelation) return;
    if (!Array.isArray(db.graphRelations)) db.graphRelations = [];
    const target = db.graphRelations.find(
      (entry) =>
        Array.isArray(entry.legacyRelationIds) &&
        entry.legacyRelationIds.includes(legacyRelation.id),
    );
    if (!target) return;
    target.legacyRelationIds = target.legacyRelationIds.filter(
      (rid) => rid !== legacyRelation.id,
    );
    if (legacyRelation.treeId) {
      const stillUsed = (db.relations || []).some(
        (r) =>
          target.legacyRelationIds.includes(r.id) &&
          r.treeId === legacyRelation.treeId,
      );
      if (!stillUsed) {
        target.legacyTreeIds = target.legacyTreeIds.filter(
          (tid) => tid !== legacyRelation.treeId,
        );
      }
    }
    if (target.legacyRelationIds.length === 0 && !target.deletedAt) {
      target.deletedAt = nowIso();
    }
  }

  // ── Phase 3.1: privacy / owner-model / branch-rules helpers ─────────
  // DECISIONS.md 2026-05-10 ответы A / C / D: visibility default
  // "connected-via-blood-graph" (≤ MAX hops видят узел), owner-only
  // edit без auto-extension по hops, branch.includeRules с
  // blood/descendants/ancestors типами и maxHops slider.

  // ответ A.4: "≤4 hops по кровным рёбрам видят узел". Per-call
  // override через optional argument когда тестам или будущим UX
  // экспериментам нужен другой radius.
  static get _connectedVisibilityMaxHops() {
    return 4;
  }

  // ответ A.1: контактные поля (телефон, e-mail, текущий адрес)
  // в `personAttributes` живут под полем `field === "contacts"`
  // — это category-level, а не отдельные ключи. Phase 3.2 enforce'ит
  // owner-only-всегда на эту category регardless `visibility` поля
  // attribute'а: даже если кто-то ставит attribute'у visibility
  // "public", не-owner всё равно её не видит. Это «privacy escape
  // hatch на чувствительные поля» из ответа A.3.
  static get _sensitiveAttributeFields() {
    return new Set(["contacts"]);
  }

  // Public probe для route handlers — не leak'ает Set instance.
  static isSensitiveAttributeField(field) {
    return FileStore._sensitiveAttributeFields.has(String(field || ""));
  }

  // Helper: кто owner данного graphPerson? Если узел представляет
  // user-аккаунт — это он. Иначе — кто его создал в графе
  // (e.g. deceased ancestor добавил юзер X).
  _graphPersonOwnerUserId(graphPerson) {
    if (!graphPerson) return null;
    return graphPerson.userId || graphPerson.createdBy || null;
  }

  // Какой graphPerson «представляет» данного user-аккаунта? Это
  // его self-node, идентичен `users[userId].identityId`.
  // Используется как стартовая точка blood-BFS для visibility check.
  _selfGraphPersonIdForUser(db, userId) {
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) return null;
    const user = (db.users || []).find((entry) => entry.id === normalizedUserId);
    if (!user) return null;
    const identityId = normalizeNullableString(user.identityId);
    if (!identityId) return null;
    const graphPerson = (db.graphPersons || []).find(
      (entry) => entry.id === identityId && !entry.deletedAt,
    );
    return graphPerson ? graphPerson.id : null;
  }

  // ответ A.1: visibility derive — поле в БД не пересчитывается
  // background job'ом. Auto-public для исторических узлов
  // (isAlive=false + birthYear < now-100) применяется в read path
  // если owner НЕ выставил `visibilityOverride: true`. Stored
  // `visibility` остаётся «connected-via-blood-graph» — старение
  // само переключает effective без backfill.
  _effectiveGraphPersonVisibility(graphPerson) {
    if (!graphPerson) return "owner-only";
    const stored = graphPerson.visibility || "connected-via-blood-graph";
    if (graphPerson.visibilityOverride === true) {
      return stored;
    }
    if (graphPerson.isAlive === false) {
      const birthYear = parseInt(
        String(graphPerson.birthDate || "").slice(0, 4),
        10,
      );
      if (Number.isFinite(birthYear)) {
        const yearsAgo = new Date().getFullYear() - birthYear;
        if (yearsAgo > 100) return "public";
      }
    }
    return stored;
  }

  // ответ A: «может ли viewer видеть этот graphPerson»? Owner и
  // grants — всегда yes. Иначе — visibility level + (для
  // connected-via-blood-graph) BFS до MAX hops.
  // Вызывается из cross-tree picker / identity-suggestions /
  // /v1/graph/relation chain hydration / future /me/extended-family.
  //
  // `context` — опциональный кэш для batch-вызовов (SPEED-8d): когда
  // caller проверяет ОДНОГО и того же viewer'а по многим graphPerson
  // за один запрос (filterLegacyPersonsByGraphVisibility), он может
  // один раз посчитать viewerSelfGraphPersonId и adjacency и передать
  // их сюда — тогда single-call путь (без context) остаётся байт-в-
  // байт таким же, каким был: при context===null поведение НИЧЕМ не
  // отличается от прежнего (свежий _selfGraphPersonIdForUser + свежая
  // _buildBloodAdjacency внутри _findBloodRelationBetween).
  _userCanSeeGraphPerson(db, graphPerson, viewerUserId, context = null) {
    if (!graphPerson || graphPerson.deletedAt) return false;
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (!normalizedViewer) return false;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner === normalizedViewer) return true;

    // Любой active edit/view grant даёт visibility — без этого
    // owner-only узел нельзя показать даже granted-юзеру, который
    // должен его редактировать.
    const hasGrant = (db.graphPersonEditGrants || []).some(
      (entry) =>
        entry.graphPersonId === graphPerson.id &&
        entry.granteeUserId === normalizedViewer &&
        !entry.revokedAt,
    );
    if (hasGrant) return true;

    const visibility = this._effectiveGraphPersonVisibility(graphPerson);
    if (visibility === "public") return true;
    if (visibility === "owner-only") return false;

    // connected-via-blood-graph (default).
    const viewerSelfId =
      context && Object.prototype.hasOwnProperty.call(context, "viewerSelfGraphPersonId")
        ? context.viewerSelfGraphPersonId
        : this._selfGraphPersonIdForUser(db, normalizedViewer);
    if (!viewerSelfId) return false;
    if (viewerSelfId === graphPerson.id) return true;

    const path = this._findBloodRelationBetween(
      db,
      viewerSelfId,
      graphPerson.id,
      {
        maxDepth: FileStore._connectedVisibilityMaxHops,
        adjacency: context ? context.adjacency : null,
      },
    );
    return path !== null;
  }

  // ответ C: «может ли viewer редактировать этот graphPerson»?
  // Default — только owner. `scope` отделяет «edit canonical
  // fields» / «approve merge-proposal» / «soft-delete», грант
  // выписывается под конкретный scope.
  _userCanEditGraphPerson(db, graphPerson, viewerUserId, scope = "edit") {
    if (!graphPerson || graphPerson.deletedAt) return false;
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (!normalizedViewer) return false;

    const owner = this._graphPersonOwnerUserId(graphPerson);
    if (owner === normalizedViewer) return true;

    return (db.graphPersonEditGrants || []).some(
      (entry) =>
        entry.graphPersonId === graphPerson.id &&
        entry.granteeUserId === normalizedViewer &&
        entry.scope === scope &&
        !entry.revokedAt,
    );
  }

  // ответ A.3: sensitive attribute fields (category=contacts —
  // содержит телефон, e-mail, адрес) — owner-only ВСЕГДА,
  // независимо от node visibility. Public-узел всё равно не
  // показывает домашний телефон.
  //
  // Контракт: для не-sensitive field возвращает true БЕЗ
  // дополнительного visibility check. Visibility-уровень gate
  // на cross-tree READ paths делается отдельно (в
  // filterLegacyPersonsByGraphVisibility); этот метод —
  // category-only filter поверх уже-passed access path. Иначе
  // tree-creator после claim чужим юзером терял бы read-access
  // на собственные дерево-attributes (он не owner graphPerson'а
  // больше, но он tree-creator, и через requireTreeAccess уже
  // прошёл).
  _userCanSeeSensitiveAttributeField(db, graphPerson, viewerUserId, attributeField) {
    if (!FileStore._sensitiveAttributeFields.has(String(attributeField || ""))) {
      return true;
    }
    if (!graphPerson) return false;
    const normalizedViewer = normalizeNullableString(viewerUserId);
    if (!normalizedViewer) return false;
    const owner = this._graphPersonOwnerUserId(graphPerson);
    return owner === normalizedViewer;
  }

  // ответ D: вычисление актуального set'а graphPerson IDs внутри
  // branch'а с учётом includeRules.type. Phase 3.1 поддерживает
  // все четыре типа; UI wizard для не-manual типов прилетит в
  // Phase 6.4. До тех пор миграция оставляет все existing
  // branches с type=manual (см. buildBranchFromTree).
  _buildBranchVisiblePersonIds(db, branch, viewerUserId) {
    if (!branch) return new Set();
    const rules = branch.includeRules || {
      type: "manual",
      manualPersonIds: [],
    };
    const maxHops = Number.isFinite(rules.maxHops) ? rules.maxHops : 5;

    switch (rules.type) {
      case "manual":
        return new Set(
          (rules.manualPersonIds || []).filter(Boolean),
        );

      case "blood-from-me": {
        const selfId = this._selfGraphPersonIdForUser(db, viewerUserId);
        if (!selfId) return new Set();
        return this._collectBloodPersonsWithinHops(db, selfId, maxHops);
      }

      case "descendants-of": {
        const anchor = normalizeNullableString(rules.anchorPersonId);
        if (!anchor) return new Set();
        return this._collectDescendantsWithinHops(db, anchor, maxHops);
      }

      case "ancestors-of": {
        const anchor = normalizeNullableString(rules.anchorPersonId);
        if (!anchor) return new Set();
        return this._collectAncestorsWithinHops(db, anchor, maxHops);
      }

      default:
        // Unknown type — empty set, не падать. Логируем для
        // observability на случай если UI отправил мусорный rules
        // (i18n strings, опечатки, etc.).
        return new Set();
    }
  }

  // BFS наружу по обеим сторонам кровных рёбер (parent/child/sibling)
  // — нужно для blood-from-me: попадают и предки, и потомки, и
  // siblings и их потомки в пределах N hops. То есть всё, что в
  // твоём кровном круге не дальше maxHops.
  _collectBloodPersonsWithinHops(db, anchorGraphPersonId, maxHops) {
    const result = new Set();
    if (!anchorGraphPersonId) return result;
    const adjacency = this._buildBloodAdjacency(db);
    if (!adjacency.has(anchorGraphPersonId)) {
      // Узел изолированный (нет blood-edges) — branch включает только сам якорь.
      result.add(anchorGraphPersonId);
      return result;
    }
    const queue = [{node: anchorGraphPersonId, depth: 0}];
    const visited = new Set([anchorGraphPersonId]);
    result.add(anchorGraphPersonId);
    while (queue.length) {
      const current = queue.shift();
      if (current.depth >= maxHops) continue;
      const neighbors = adjacency.get(current.node) || [];
      for (const {neighbor} of neighbors) {
        if (visited.has(neighbor)) continue;
        visited.add(neighbor);
        result.add(neighbor);
        queue.push({node: neighbor, depth: current.depth + 1});
      }
    }
    return result;
  }

  _collectDescendantsWithinHops(db, anchorGraphPersonId, maxHops) {
    return this._collectDirectionalWithinHops(
      db,
      anchorGraphPersonId,
      maxHops,
      "child",
    );
  }

  _collectAncestorsWithinHops(db, anchorGraphPersonId, maxHops) {
    return this._collectDirectionalWithinHops(
      db,
      anchorGraphPersonId,
      maxHops,
      "parent",
    );
  }

  // Direction-aware BFS: walks edges where the TARGET role matches
  // direction. _buildBloodAdjacency пишет
  //   adjacency[child] += {neighbor: parent, edgeType: "parent"}
  //   adjacency[parent] += {neighbor: child, edgeType: "child"}
  // direction="child" значит идём вниз по потомкам; "parent" —
  // вверх по предкам. siblings игнорируются (включаем только
  // прямую вертикаль для descendants-of/ancestors-of).
  _collectDirectionalWithinHops(db, anchorGraphPersonId, maxHops, direction) {
    const result = new Set();
    if (!anchorGraphPersonId) return result;
    const adjacency = this._buildBloodAdjacency(db);
    if (!adjacency.has(anchorGraphPersonId)) {
      result.add(anchorGraphPersonId);
      return result;
    }
    const queue = [{node: anchorGraphPersonId, depth: 0}];
    const visited = new Set([anchorGraphPersonId]);
    result.add(anchorGraphPersonId);
    while (queue.length) {
      const current = queue.shift();
      if (current.depth >= maxHops) continue;
      const neighbors = adjacency.get(current.node) || [];
      for (const {neighbor, edgeType} of neighbors) {
        if (edgeType !== direction) continue;
        if (visited.has(neighbor)) continue;
        visited.add(neighbor);
        result.add(neighbor);
        queue.push({node: neighbor, depth: current.depth + 1});
      }
    }
    return result;
  }

  // ── Phase 3.1d: graph-first read helper ─────────────────────────────
  // Resolves a legacy-shape person record by reading from
  // graphPersons + branchPersonViews + tree first, falling back
  // to the legacy persons collection when graph data is missing
  // (e.g. row hasn't been synced yet, or migration hasn't run).
  // Returns null if no data exists for this (branch, personId).
  //
  // The shape returned is the same as the legacy `db.persons[i]`
  // record so callers and downstream `mapPerson` see no change in
  // payload structure. The values, however, come from the graph
  // side — once we drop the legacy collection in 3.4 this helper
  // simply stops touching `db.persons`.
  // SPEED-10: `index` — опциональные карты, построенные ОДИН раз вызывающим
  // циклом (см. _buildPersonGraphIndex), вместо четырёх .find() по
  // db.persons/db.graphPersons/db.branchPersonViews/db.users на КАЖДОГО
  // person. getTreeGraphSnapshot зовёт это для всех person'ов дерева —
  // было O(persons_в_дереве × (persons+graphPersons+views+users)_всего),
  // см. docs/speed_measurement.md SPEED-10. `legacyPerson` — сам person,
  // если он у вызывающего уже под рукой (снимает и первый .find()).
  // Без `index`/`legacyPerson` — прежнее поведение (findPerson/
  // findPersonByUserId/getPersonDossier — одиночные вызовы, строить
  // индекс ради одного person незачем).
  _buildPersonViewFromGraph(db, branchId, legacyPersonId, {
    index = null,
    legacyPerson: prefetchedLegacyPerson = null,
  } = {}) {
    const legacyPerson = prefetchedLegacyPerson || (db.persons || []).find(
      (p) => p.id === legacyPersonId && p.treeId === branchId,
    );
    if (!legacyPerson) return null;

    const identityId = normalizeNullableString(legacyPerson.identityId);
    const graphPerson = identityId
      ? (index
          ? index.graphPersonsById.get(identityId) || null
          : (db.graphPersons || []).find(
              (g) => g.id === identityId && !g.deletedAt,
            ))
      : null;

    if (!graphPerson) {
      // No graph row yet — happens during the boot window before
      // _syncGraphFromLegacy fires, or for a person whose
      // identityId backfill hasn't completed. Falling back to the
      // legacy record keeps the API working in those edge cases.
      return buildCanonicalPersonView(db, legacyPerson, {
        usersById: index?.usersById,
      });
    }

    const view = index
      ? index.branchPersonViewByKey.get(`${branchId} ${graphPerson.id}`) || null
      : (db.branchPersonViews || []).find(
          (v) => v.branchId === branchId && v.personId === graphPerson.id,
        );

    // Compose: legacy record as the base (carries firstName /
    // lastName / middleName / details / lastPropagatedFields and
    // any other field the graph layer doesn't own yet), then
    // override the canonical fields from graphPerson and the
    // editorial fields from branchPersonView. Output is shape-
    // compatible with the legacy `mapPerson` consumer.
    const personView = structuredClone(legacyPerson);
    for (const field of GRAPH_PERSON_CANONICAL_FIELDS) {
      if (graphPerson[field] !== undefined) {
        personView[field] =
          graphPerson[field] === null
            ? null
            : structuredClone(graphPerson[field]);
      }
    }
    if (view) {
      personView.notes = view.notes ?? personView.notes ?? null;
      personView.familySummary =
        view.familySummary ?? personView.familySummary ?? null;
      personView.bio = view.bio ?? personView.bio ?? null;
      if (view.visibility !== undefined && view.visibility !== null) {
        personView.visibility = view.visibility;
      }
    }

    if (!personView.userId) return personView;
    const user = index
      ? index.usersById.get(String(personView.userId || "").trim()) || null
      : db.users.find((entry) => entry.id === personView.userId);
    if (!user?.profile) return personView;
    return applyCanonicalProfileToPerson(personView, user.profile);
  }

  // SPEED-10: строит один раз карты для _buildPersonViewFromGraph,
  // переиспользуемые на ВСЕХ person'ов одного вызова (сейчас — только
  // getTreeGraphSnapshot). Те же соглашения, что и в _buildGraphSyncIndex
  // (SPEED-9 A): id предполагаются уникальными, forEach-порядок = порядок
  // массива, "последний выигрывает" при дублях — как и обычный .find()
  // на непротиворечивых данных.
  _buildPersonGraphIndex(db) {
    const graphPersonsById = new Map();
    for (const graphPerson of db.graphPersons || []) {
      if (graphPerson.deletedAt) continue;
      graphPersonsById.set(graphPerson.id, graphPerson);
    }
    const branchPersonViewByKey = new Map();
    for (const view of db.branchPersonViews || []) {
      branchPersonViewByKey.set(`${view.branchId} ${view.personId}`, view);
    }
    return {
      graphPersonsById,
      branchPersonViewByKey,
      usersById: buildUsersByIdMap(db),
    };
  }

  // SPEED-9 A: строит все индексы ОДИН раз на весь проход
  // `_syncGraphFromLegacy`, вместо того чтобы `_syncPersonToGraph`/
  // `_syncRelationToGraph`/`_resolveGraphPersonIdForLegacy` делали
  // линейный `.find()` по db.graphPersons/db.branchPersonViews/
  // db.branches/db.persons/db.graphRelations на КАЖДОГО person и
  // КАЖДУЮ relation (было O(persons×graphPersons +
  // relations×(graphRelations+persons)) ≈ O(N²) над ГЛОБАЛЬНЫМИ
  // коллекциями — измерено docs/speed_measurement.md SPEED-9: 136 мс
  // при 1240 persons, 560 мс при 2480).
  //
  // Карты МУТИРУЮТСЯ теми же helper'ами по ходу прохода (push нового
  // graphPerson/view/graphRelation, обновление dedup-ключа при смене
  // типа отношения) — это обязательно, чтобы воспроизвести поведение
  // живого `.find()` по массиву: он видел бы изменения, сделанные
  // РАНЕЕ в этом же проходе (пример — тест "collapses identity-
  // linked legacy persons across two trees onto one graphPerson":
  // второй person с тем же identityId должен найти graphPerson,
  // созданный первым в ЭТОМ ЖЕ вызове _syncGraphFromLegacy).
  //
  // Вызывается ПОСЛЕ цикла _syncTreeToBranch (тот может создавать
  // новые db.branches) и ДО циклов по persons/relations — иначе
  // branchById не увидел бы свежесозданные branch-строки.
  _buildGraphSyncIndex(db) {
    const graphPersonsById = new Map();
    const graphPersonsByLegacyId = new Map();
    for (const graphPerson of db.graphPersons) {
      graphPersonsById.set(graphPerson.id, graphPerson);
      if (Array.isArray(graphPerson.legacyPersonIds)) {
        for (const legacyId of graphPerson.legacyPersonIds) {
          // Первое совпадение по порядку массива — как и вернул бы
          // .find(); при корректных (не повреждённых) данных
          // legacyPersonId принадлежит не более чем одному graphPerson.
          if (!graphPersonsByLegacyId.has(legacyId)) {
            graphPersonsByLegacyId.set(legacyId, graphPerson);
          }
        }
      }
    }

    const branchPersonViewByKey = new Map();
    for (const view of db.branchPersonViews) {
      branchPersonViewByKey.set(`${view.branchId} ${view.personId}`, view);
    }

    const branchById = new Map();
    for (const branch of db.branches) {
      branchById.set(branch.id, branch);
    }

    const personsById = new Map();
    for (const person of db.persons || []) {
      personsById.set(person.id, person);
    }

    const graphRelationsByLegacyId = new Map();
    const graphRelationsByDedupKey = new Map();
    for (const graphRelation of db.graphRelations) {
      if (Array.isArray(graphRelation.legacyRelationIds)) {
        for (const legacyId of graphRelation.legacyRelationIds) {
          if (!graphRelationsByLegacyId.has(legacyId)) {
            graphRelationsByLegacyId.set(legacyId, graphRelation);
          }
        }
      }
      const key = buildGraphRelationDedupKey(
        graphRelation.person1Id,
        graphRelation.person2Id,
        graphRelation,
      );
      if (!graphRelationsByDedupKey.has(key)) {
        graphRelationsByDedupKey.set(key, graphRelation);
      }
    }

    return {
      graphPersonsById,
      graphPersonsByLegacyId,
      branchPersonViewByKey,
      branchById,
      personsById,
      graphRelationsByLegacyId,
      graphRelationsByDedupKey,
    };
  }

  // Aggregate full-scan helper. Walks the legacy collections and
  // brings the graph side into sync with whatever's currently
  // there. Idempotent — every step is a no-op when its row is
  // already up-to-date — so calling it on every _read and every
  // _write keeps the graph eventually consistent without wiring
  // a sync into each of the 30+ write paths individually.
  //
  // SPEED-9 A (05.09.2026): раньше комментарий здесь утверждал
  // O(persons + relations + trees) — это было НЕВЕРНО: три вложенных
  // .find()-скана без индексов внутри _syncPersonToGraph/
  // _syncRelationToGraph/_resolveGraphPersonIdForLegacy давали
  // фактически O(N²) (см. docs/speed_measurement.md SPEED-9, замер
  // bench_sync_scaling.js: 1240→2480 persons даёт ×4.1 времени —
  // учебный квадрат). _buildGraphSyncIndex выше строит Map-индексы
  // один раз на проход, так что теперь это ДЕЙСТВИТЕЛЬНО
  // O(persons + relations + trees). Комментарий про Phase 3.4
  // остаётся: CURRENT-PHASE.md явно держит graph-слой (не
  // депрекейтить), так что эта функция никуда не денется.
  _syncGraphFromLegacy(db) {
    if (!db || typeof db !== "object") return;
    if (!Array.isArray(db.graphPersons)) db.graphPersons = [];
    if (!Array.isArray(db.branchPersonViews)) db.branchPersonViews = [];
    if (!Array.isArray(db.branches)) db.branches = [];
    if (!Array.isArray(db.graphRelations)) db.graphRelations = [];

    const trees = Array.isArray(db.trees) ? db.trees : [];
    const persons = Array.isArray(db.persons) ? db.persons : [];
    const relations = Array.isArray(db.relations) ? db.relations : [];

    for (const tree of trees) {
      this._syncTreeToBranch(db, tree);
    }

    // Индексы строятся ПОСЛЕ _syncTreeToBranch (мог создать новые
    // db.branches) и ДО persons/relations — см. _buildGraphSyncIndex.
    const graphSyncIndex = this._buildGraphSyncIndex(db);

    const liveLegacyPersonIds = new Set();
    const liveIdentityIds = new Set();
    for (const person of persons) {
      liveLegacyPersonIds.add(person.id);
      const identityId = normalizeNullableString(person.identityId);
      if (identityId) liveIdentityIds.add(identityId);
      this._syncPersonToGraph(db, person, graphSyncIndex);
    }

    const liveRelationIds = new Set();
    for (const relation of relations) {
      liveRelationIds.add(relation.id);
      this._syncRelationToGraph(db, relation, graphSyncIndex);
    }

    // Drop branchPersonViews whose legacyPersonId is gone — the
    // person was hard-deleted before the graph caught up, so the
    // view is meaningless. (Soft-deletes leave the legacy person
    // in place; we don't reach this branch in that path.)
    db.branchPersonViews = db.branchPersonViews.filter(
      (view) =>
        !view.legacyPersonId || liveLegacyPersonIds.has(view.legacyPersonId),
    );

    // Soft-delete graphPersons whose identityId is no longer
    // referenced by any legacy person. (And clear deletedAt for
    // ones that came back — handled in _syncPersonToGraph already,
    // but a fresh data file might land in a state where the legacy
    // row exists but the graphPerson is stamped deleted.)
    for (const graphPerson of db.graphPersons) {
      if (liveIdentityIds.has(graphPerson.id)) {
        if (graphPerson.deletedAt) graphPerson.deletedAt = null;
        continue;
      }
      if (!graphPerson.deletedAt) {
        graphPerson.deletedAt = nowIso();
      }
    }

    // Trim branch.includeRules.manualPersonIds: if a legacy person
    // got deleted, its identity is no longer on this branch and the
    // inclusion list shouldn't claim it. Mirrors the per-branch
    // membership rebuild in _markPersonDeletedInGraph but for the
    // full-scan path.
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
        // Branch with no live persons — drop all manual entries.
        if (ids.length > 0) {
          branch.includeRules.manualPersonIds = [];
        }
        continue;
      }
      branch.includeRules.manualPersonIds = ids.filter((gid) =>
        allowed.has(gid),
      );
    }

    // Trim graphRelation.legacyRelationIds: drop ones that no
    // longer exist in db.relations. If the list goes empty, mark
    // the canonical edge deleted.
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
        // Re-attached after delete — clear the tombstone.
        graphRelation.deletedAt = null;
      }
    }

    // Drop branches whose legacy tree was deleted entirely.
    const liveTreeIds = new Set(trees.map((t) => t.id));
    for (const branch of db.branches) {
      if (!liveTreeIds.has(branch.id) && !branch.deletedAt) {
        branch.deletedAt = nowIso();
      }
    }
  }

  async deletePerson(treeId, personId, actorId = null) {
    // Ship Q4a (2026-05-28): soft-delete semantics. Previously hard-
    // delete via db.persons.filter (line 13052). Now moves person к
    // db.deletedPersons snapshot collection + filter-removes из
    // db.persons + db.relations (preserves 95 read sites unchanged
    // — Path 2 from design doc ec12804).
    //
    // External behavior identical:
    //   • DELETE returns true (was true)
    //   • Subsequent GET /v1/trees/.../persons returns без person
    //   • person.deleted tree-change event emitted с before snapshot
    //   • tree.memberIds + tree.members updated when applicable
    //   • relations cleaned up (snapshot retained в deletedPersons)
    //
    // New internal state:
    //   • db.deletedPersons row carries snapshot + relations + audit
    //   • hardDeleteScheduledAt = deletedAt + 30d (configurable)
    //   • earliestHardDelete = deletedAt + 3h (floor — protects vs
    //     immediate purge if user misclicks restore либо config bad)
    //
    // Restore (restorePerson) reverses: moves snapshot back к
    // db.persons + relations back к db.relations, clears tree-change
    // audit annotation. Idempotent — re-restore of already-restored
    // row = 404 «уже восстановлен».
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

    const deletedPerson = structuredClone(person);
    const removedRelations = db.relations
      .filter(
        (entry) =>
          entry.treeId === treeId &&
          (entry.person1Id === personId || entry.person2Id === personId),
      )
      .map((entry) => structuredClone(entry));
    db.persons = db.persons.filter((entry) => entry.id !== personId);
    db.relations = db.relations.filter(
      (entry) =>
        entry.treeId !== treeId ||
        (entry.person1Id !== personId && entry.person2Id !== personId),
    );

    if (person.userId) {
      const remainingLinkedPerson = db.persons.find(
        (entry) => entry.treeId === treeId && entry.userId === person.userId,
      );
      if (!remainingLinkedPerson) {
        const tree = db.trees.find((entry) => entry.id === treeId);
        if (tree) {
          tree.memberIds = (tree.memberIds || []).filter(
            (memberId) => memberId !== person.userId,
          );
          tree.members = (tree.members || []).filter(
            (memberId) => memberId !== person.userId,
          );
          tree.updatedAt = nowIso();
        }
      }
    }

    for (const relation of removedRelations) {
      this._appendTreeChangeRecord(db, {
        treeId,
        actorId,
        type: "relation.deleted",
        personIds: [relation.person1Id, relation.person2Id],
        relationId: relation.id,
        details: {
          before: relation,
        },
      });
    }

    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "person.deleted",
      personId,
      details: {
        before: deletedPerson,
      },
    });

    // Ship Q4a: write snapshot row to deletedPersons для 30d restore.
    // Find семья binding (if any) — affects permission gate in
    // restore endpoint (members of bound семя can restore).
    const tree = db.trees.find((entry) => entry.id === treeId);
    const boundSemyaId = tree?.semyaId
      ? (db.semyi || []).find(
          (s) => s.id === tree.semyaId && !s.deletedAt,
        )?.id || null
      : null;
    const nowIsoStr = nowIso();
    const retentionDays = Number(process.env.RODNYA_DELETED_PERSONS_RETENTION_DAYS) || 30;
    const floorHours = Number(process.env.RODNYA_DELETED_PERSONS_FLOOR_HOURS) || 3;
    const hardDeleteAt = new Date(
      Date.parse(nowIsoStr) + retentionDays * 24 * 3600 * 1000,
    ).toISOString();
    const earliestHardDelete = new Date(
      Date.parse(nowIsoStr) + floorHours * 3600 * 1000,
    ).toISOString();
    db.deletedPersons = Array.isArray(db.deletedPersons) ? db.deletedPersons : [];
    db.deletedPersons.push({
      id: crypto.randomUUID(),
      originalPersonId: personId,
      treeId,
      semyaId: boundSemyaId,
      snapshot: deletedPerson,
      relationsSnapshot: removedRelations,
      deletedAt: nowIsoStr,
      deletedByUserId: actorId,
      hardDeleteScheduledAt: hardDeleteAt,
      earliestHardDelete,
      restoredAt: null,
      restoredByUserId: null,
    });

    this._reconcilePersonIdentities(db);
    ensureCirclesForTree(db, treeId);

    await this._write(db);
    return true;
  }

  /// Ship Q4a (2026-05-28): list deleted persons for caller.
  /// Scoped by семя membership — caller sees deleted persons из
  /// семья where they're an active member, plus deletions they
  /// themselves performed (even если no longer member). Empty
  /// list if no matches либо storage incapable.
  async listDeletedPersonsForUser({userId}) {
    if (!userId || typeof userId !== "string") return [];
    const db = await this._read();
    const memberSemyaIds = new Set(
      (db.semyaMembers || [])
        .filter((m) => m.userId === userId && !m.hiddenAt)
        .map((m) => m.semyaId),
    );
    const rows = (db.deletedPersons || []).filter((entry) => {
      if (entry.restoredAt) return false;
      if (entry.deletedByUserId === userId) return true;
      if (entry.semyaId && memberSemyaIds.has(entry.semyaId)) return true;
      return false;
    });
    return rows
      .sort((a, b) =>
        String(b.deletedAt || "").localeCompare(String(a.deletedAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  /// Ship Q4a: list deleted persons in specific семя. Permission —
  /// caller must be active member.
  async listDeletedPersonsForSemya({semyaId, userId}) {
    if (!semyaId || typeof semyaId !== "string") return [];
    if (!userId) return [];
    const db = await this._read();
    const isMember = (db.semyaMembers || []).some(
      (m) => m.userId === userId && m.semyaId === semyaId && !m.hiddenAt,
    );
    if (!isMember) {
      throw new Error("NOT_MEMBER");
    }
    return (db.deletedPersons || [])
      .filter((entry) => entry.semyaId === semyaId && !entry.restoredAt)
      .sort((a, b) =>
        String(b.deletedAt || "").localeCompare(String(a.deletedAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  /// Ship Q4a: restore person из deletedPersons → live db.persons.
  /// Restores person snapshot + relations snapshot. Updates
  /// tree.memberIds/members if person had userId. Emits
  /// person.restored tree-change event. Throws:
  ///   • DELETED_PERSON_NOT_FOUND (404)
  ///   • ALREADY_RESTORED (409)
  ///   • HARD_DELETE_ELAPSED (410 — past retention window)
  ///   • FORBIDDEN (403 — not семя member либо not original actor)
  ///   • SEMYA_DELETED (410 — parent семя soft-deleted, restore
  ///     would orphan person)
  async restorePerson({deletedPersonId, actorUserId}) {
    if (!deletedPersonId || typeof deletedPersonId !== "string") {
      throw new Error("INVALID_INPUT");
    }
    if (!actorUserId) throw new Error("INVALID_ACTOR");

    const db = await this._read();
    const row = (db.deletedPersons || []).find(
      (entry) => entry.id === deletedPersonId,
    );
    if (!row) throw new Error("DELETED_PERSON_NOT_FOUND");
    if (row.restoredAt) throw new Error("ALREADY_RESTORED");
    const now = Date.now();
    if (
      row.hardDeleteScheduledAt &&
      Date.parse(row.hardDeleteScheduledAt) < now
    ) {
      throw new Error("HARD_DELETE_ELAPSED");
    }

    // Permission: actor must be member of bound семя либо original
    // deleter. Семя-less deletions allow original actor only.
    const isOriginalActor = row.deletedByUserId === actorUserId;
    let isSemyaMember = false;
    if (row.semyaId) {
      isSemyaMember = (db.semyaMembers || []).some(
        (m) =>
          m.userId === actorUserId &&
          m.semyaId === row.semyaId &&
          !m.hiddenAt,
      );
      // Защитный gate — если семя soft-deleted, restore would orphan
      // (no membership context, no tree owner). Reject.
      const semya = (db.semyi || []).find((s) => s.id === row.semyaId);
      if (semya?.deletedAt) {
        throw new Error("SEMYA_DELETED");
      }
    }
    if (!isOriginalActor && !isSemyaMember) {
      throw new Error("FORBIDDEN");
    }

    // Restore snapshot к live state.
    db.persons = Array.isArray(db.persons) ? db.persons : [];
    db.persons.push(structuredClone(row.snapshot));
    if (Array.isArray(row.relationsSnapshot)) {
      db.relations = Array.isArray(db.relations) ? db.relations : [];
      for (const rel of row.relationsSnapshot) {
        db.relations.push(structuredClone(rel));
      }
    }

    // Restore tree.memberIds linkage если person had userId.
    if (row.snapshot?.userId) {
      const tree = db.trees.find((entry) => entry.id === row.treeId);
      if (tree) {
        tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
        if (!tree.memberIds.includes(row.snapshot.userId)) {
          tree.memberIds.push(row.snapshot.userId);
        }
        tree.members = Array.isArray(tree.members) ? tree.members : [];
        if (!tree.members.includes(row.snapshot.userId)) {
          tree.members.push(row.snapshot.userId);
        }
        this._ensureSemyaMembershipForLegacyJoin(db, tree, row.snapshot.userId);
        tree.updatedAt = nowIso();
      }
    }

    row.restoredAt = nowIso();
    row.restoredByUserId = actorUserId;

    this._appendTreeChangeRecord(db, {
      treeId: row.treeId,
      actorId: actorUserId,
      type: "person.restored",
      personId: row.originalPersonId,
      details: {
        deletedPersonId: row.id,
        deletedAt: row.deletedAt,
      },
    });
    this._reconcilePersonIdentities(db);
    ensureCirclesForTree(db, row.treeId);

    await this._write(db);
    return structuredClone(row);
  }

  /// Ship Q4a: explicit hard-purge of deleted person (skip 30d wait).
  /// User-initiated GDPR-style erasure. 3h floor protection — even
  /// если user immediately tries to purge, must wait floor period.
  /// Throws:
  ///   • DELETED_PERSON_NOT_FOUND (404)
  ///   • FLOOR_NOT_MET (409 — earliestHardDelete > now)
  ///   • FORBIDDEN (403 — permission similar к restore)
  ///   • ALREADY_RESTORED (409 — restored row не purge-able)
  async hardDeletePerson({deletedPersonId, actorUserId}) {
    if (!deletedPersonId || typeof deletedPersonId !== "string") {
      throw new Error("INVALID_INPUT");
    }
    if (!actorUserId) throw new Error("INVALID_ACTOR");

    const db = await this._read();
    const idx = (db.deletedPersons || []).findIndex(
      (entry) => entry.id === deletedPersonId,
    );
    if (idx < 0) throw new Error("DELETED_PERSON_NOT_FOUND");
    const row = db.deletedPersons[idx];
    if (row.restoredAt) throw new Error("ALREADY_RESTORED");
    if (
      row.earliestHardDelete &&
      Date.parse(row.earliestHardDelete) > Date.now()
    ) {
      throw new Error("FLOOR_NOT_MET");
    }

    const isOriginalActor = row.deletedByUserId === actorUserId;
    let isSemyaMember = false;
    if (row.semyaId) {
      isSemyaMember = (db.semyaMembers || []).some(
        (m) =>
          m.userId === actorUserId &&
          m.semyaId === row.semyaId &&
          !m.hiddenAt,
      );
    }
    if (!isOriginalActor && !isSemyaMember) {
      throw new Error("FORBIDDEN");
    }

    db.deletedPersons.splice(idx, 1);
    await this._write(db);
    return {purged: true, deletedPersonId};
  }

  // ===== Profile Phase 1 (2026-05-28): article CRUD =====
  //
  // Permission is enforced at the route layer (requireTreeAccess for
  // reads, requireGraphPersonEdit for writes) — these methods are
  // attribution-aware mutators: record actorUserId per block + append
  // `article.*` records to treeChangeRecords (history reuses that log
  // per proposal §9.3). Media url-addressed; block content validated
  // by normalizeArticleBlockContent (throws INVALID_BLOCK_TYPE/CONTENT).

  _findPersonRecordById(db, personId) {
    const id = String(personId || "").trim();
    if (!id) return null;
    return (
      (Array.isArray(db.persons) ? db.persons : []).find(
        (entry) => entry.id === id,
      ) || null
    );
  }

  // Resolve {person, treeId, semyaId}. semyaId = person's tree's bound
  // active семья (null when standalone tree). Throws PERSON_NOT_FOUND.
  _resolveArticleContext(db, personId) {
    const person = this._findPersonRecordById(db, personId);
    if (!person) throw new Error("PERSON_NOT_FOUND");
    const treeId = person.treeId;
    const tree = (db.trees || []).find((entry) => entry.id === treeId);
    const semyaId =
      tree?.semyaId &&
      (db.semyi || []).some((s) => s.id === tree.semyaId && !s.deletedAt)
        ? tree.semyaId
        : null;
    return {person, treeId, semyaId};
  }

  // Find existing article or create+persist an empty one. Returns the
  // live object (caller is inside a read/write cycle).
  _ensureProfileArticle(db, personId, ctx) {
    db.profileArticles = Array.isArray(db.profileArticles)
      ? db.profileArticles
      : [];
    let article = db.profileArticles.find(
      (entry) => entry.personId === personId,
    );
    if (!article) {
      const timestamp = nowIso();
      article = {
        id: crypto.randomUUID(),
        personId,
        treeId: ctx.treeId,
        semyaId: ctx.semyaId,
        blocks: [],
        createdAt: timestamp,
        updatedAt: timestamp,
      };
      db.profileArticles.push(article);
    }
    return article;
  }

  // GET — returns the article. Synthesizes an empty shape if none yet
  // (NOT persisted on read). Throws PERSON_NOT_FOUND.
  async getProfileArticle({personId}) {
    const id = String(personId || "").trim();
    if (!id) throw new Error("INVALID_INPUT");
    const db = await this._read();
    const ctx = this._resolveArticleContext(db, id);
    const article = (db.profileArticles || []).find(
      (entry) => entry.personId === id,
    );
    if (article) return structuredClone(article);
    return {
      id: null,
      personId: id,
      treeId: ctx.treeId,
      semyaId: ctx.semyaId,
      blocks: [],
      createdAt: null,
      updatedAt: null,
    };
  }

  async appendArticleBlock({personId, type, content, actorUserId}) {
    const id = String(personId || "").trim();
    if (!id) throw new Error("INVALID_INPUT");
    if (!actorUserId) throw new Error("INVALID_ACTOR");
    const db = await this._read();
    const ctx = this._resolveArticleContext(db, id);
    // Validates shape (throws) BEFORE we touch db — no empty-article
    // side effect on a rejected block.
    const block = createArticleBlockRecord({type, content, actorUserId});
    const article = this._ensureProfileArticle(db, id, ctx);
    article.blocks.push(block);
    article.updatedAt = block.createdAt;
    this._appendTreeChangeRecord(db, {
      treeId: ctx.treeId,
      actorId: actorUserId,
      type: "article.block-added",
      personId: id,
      details: {blockId: block.id, blockType: block.type},
    });
    await this._write(db);
    return structuredClone(block);
  }

  // PATCH one block. Optional baseUpdatedAt = the updatedAt the editor
  // loaded; if the block changed since (another author wrote), it's a
  // conflict. Per Q3 (locked 2026-05-28): last-write-wins — apply the
  // write, keep prior content in the audit `before` snapshot, notify
  // the previous author. Returns {block, conflict}.
  async updateArticleBlock({
    personId,
    blockId,
    content,
    actorUserId,
    baseUpdatedAt = null,
  }) {
    const id = String(personId || "").trim();
    const bId = String(blockId || "").trim();
    if (!id || !bId) throw new Error("INVALID_INPUT");
    if (!actorUserId) throw new Error("INVALID_ACTOR");
    const db = await this._read();
    const ctx = this._resolveArticleContext(db, id);
    const article = (db.profileArticles || []).find(
      (entry) => entry.personId === id,
    );
    const block = article?.blocks?.find((b) => b.id === bId);
    if (!block) throw new Error("ARTICLE_BLOCK_NOT_FOUND");

    const nextContent = normalizeArticleBlockContent(block.type, content);
    const beforeContent = structuredClone(block.content);
    const priorAuthor = block.authorUserId;
    const conflict =
      baseUpdatedAt != null &&
      String(baseUpdatedAt) !== String(block.updatedAt);

    const timestamp = nowIso();
    block.content = nextContent;
    block.authorUserId = normalizeNullableString(actorUserId);
    block.updatedAt = timestamp;
    article.updatedAt = timestamp;

    this._appendTreeChangeRecord(db, {
      treeId: ctx.treeId,
      actorId: actorUserId,
      type: "article.block-updated",
      personId: id,
      details: {
        blockId: bId,
        blockType: block.type,
        before: beforeContent,
        conflict,
      },
    });

    // Q3: notify previous author when their text was overwritten.
    if (conflict && priorAuthor && priorAuthor !== actorUserId) {
      db.notifications = Array.isArray(db.notifications)
        ? db.notifications
        : [];
      db.notifications.push(
        createNotificationRecord({
          userId: priorAuthor,
          type: "article_block_conflict",
          title: "Ваш текст в карточке изменили",
          body:
            "Другой родственник отредактировал абзац, который вы писали. " +
            "Прежняя версия сохранена в истории изменений.",
          data: {personId: id, blockId: bId, treeId: ctx.treeId},
          silent: false,
        }),
      );
    }

    await this._write(db);
    return {block: structuredClone(block), conflict};
  }

  async removeArticleBlock({personId, blockId, actorUserId}) {
    const id = String(personId || "").trim();
    const bId = String(blockId || "").trim();
    if (!id || !bId) throw new Error("INVALID_INPUT");
    if (!actorUserId) throw new Error("INVALID_ACTOR");
    const db = await this._read();
    const ctx = this._resolveArticleContext(db, id);
    const article = (db.profileArticles || []).find(
      (entry) => entry.personId === id,
    );
    const blockIdx = article
      ? article.blocks.findIndex((b) => b.id === bId)
      : -1;
    if (!article || blockIdx < 0) {
      throw new Error("ARTICLE_BLOCK_NOT_FOUND");
    }
    const [removed] = article.blocks.splice(blockIdx, 1);
    article.updatedAt = nowIso();
    this._appendTreeChangeRecord(db, {
      treeId: ctx.treeId,
      actorId: actorUserId,
      type: "article.block-removed",
      personId: id,
      details: {
        blockId: bId,
        blockType: removed?.type || null,
        before: removed?.content ?? null,
      },
    });
    await this._write(db);
    return {removed: true, blockId: bId};
  }

  // Reorder blocks to match orderedBlockIds. Unknown ids ignored;
  // blocks omitted from the list keep their relative order at the end
  // (defensive — never drops a block on a stale client list).
  async reorderArticleBlocks({personId, orderedBlockIds, actorUserId}) {
    const id = String(personId || "").trim();
    if (!id) throw new Error("INVALID_INPUT");
    if (!actorUserId) throw new Error("INVALID_ACTOR");
    if (!Array.isArray(orderedBlockIds)) throw new Error("INVALID_INPUT");
    const db = await this._read();
    const ctx = this._resolveArticleContext(db, id);
    const article = (db.profileArticles || []).find(
      (entry) => entry.personId === id,
    );
    if (!article) throw new Error("ARTICLE_NOT_FOUND");
    const byId = new Map(article.blocks.map((b) => [b.id, b]));
    const seen = new Set();
    const reordered = [];
    for (const wantId of orderedBlockIds) {
      const b = byId.get(String(wantId));
      if (b && !seen.has(b.id)) {
        reordered.push(b);
        seen.add(b.id);
      }
    }
    for (const b of article.blocks) {
      if (!seen.has(b.id)) reordered.push(b);
    }
    article.blocks = reordered;
    article.updatedAt = nowIso();
    this._appendTreeChangeRecord(db, {
      treeId: ctx.treeId,
      actorId: actorUserId,
      type: "article.reordered",
      personId: id,
      details: {order: reordered.map((b) => b.id)},
    });
    await this._write(db);
    return structuredClone(article);
  }

  // History — filtered treeChangeRecords (proposal §9.3 reuse).
  // Newest first. Throws PERSON_NOT_FOUND.
  async getArticleHistory({personId}) {
    const id = String(personId || "").trim();
    if (!id) throw new Error("INVALID_INPUT");
    const db = await this._read();
    this._resolveArticleContext(db, id); // PERSON_NOT_FOUND guard
    return (db.treeChangeRecords || [])
      .filter(
        (r) =>
          r.personId === id &&
          typeof r.type === "string" &&
          r.type.startsWith("article."),
      )
      .sort((a, b) =>
        String(b.createdAt || "").localeCompare(String(a.createdAt || "")),
      )
      .map((r) => structuredClone(r));
  }

  // Lightweight by-id tree resolver — articles are addressed by
  // personId alone (person ids are globally unique). Returns null if
  // the person doesn't exist. Read-only; route permission gates use it
  // to obtain treeId before requireTreeAccess / requireGraphPersonEdit.
  async findPersonTreeId(personId) {
    const id = String(personId || "").trim();
    if (!id) return null;
    const db = await this._read();
    const person = this._findPersonRecordById(db, id);
    return person ? person.treeId : null;
  }

  async addPersonMedia({
    treeId,
    personId,
    actorId = null,
    media = {},
  }) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

    // Snapshot for Phase 1.1 photo propagation — captured BEFORE
    // we mutate person.* below. The propagator diffs against this
    // to detect what fields changed and replicates them onto any
    // linked records sharing identityId.
    const previousPersonSnapshot = structuredClone(person);
    const timestamp = nowIso();
    const requestedUrl = media.url || media.mediaUrl || media.photoUrl;
    const photoState = normalizePersonPhotoGallery([
      ...(Array.isArray(person.photoGallery) ? person.photoGallery : []),
      {
        id: media.id,
        url: requestedUrl,
        thumbnailUrl: media.thumbnailUrl,
        type: media.type,
        contentType: media.contentType,
        caption: media.caption,
        createdAt: timestamp,
        updatedAt: timestamp,
        isPrimary: media.isPrimary === true,
      },
    ], {
      photoUrl: media.isPrimary === true
        ? requestedUrl
        : person.photoUrl,
      primaryPhotoUrl: media.isPrimary === true
        ? requestedUrl
        : person.primaryPhotoUrl,
    });

    person.photoUrl = photoState.photoUrl;
    person.primaryPhotoUrl = photoState.primaryPhotoUrl;
    person.photoGallery = photoState.photoGallery;
    person.updatedAt = timestamp;

    const storedMedia = person.photoGallery.find((entry) => entry.url === requestedUrl)
      || person.photoGallery[0];
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = timestamp;
    }
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "person_media.created",
      personId,
      mediaId: storedMedia?.id || null,
      details: {
        after: storedMedia ? structuredClone(storedMedia) : null,
      },
    });
    // Phase 1.1 propagation: photo fields fan out to linked
    // records on other trees so the user's "I added a photo on
    // mom in tree A" actually shows up on mom in tree B too.
    // Without this, only the explicit `updatePerson` path
    // propagates — uploads silently stay tree-local.
    const propagatedTo = this._propagateIdentityFields(
      db,
      person,
      previousPersonSnapshot,
      actorId,
    );
    await this._write(db);
    return {
      person: structuredClone(person),
      media: storedMedia ? structuredClone(storedMedia) : null,
      propagatedTo,
    };
  }

  async updatePersonMedia({
    treeId,
    personId,
    mediaId,
    actorId = null,
    updates = {},
  }) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

    const previousPersonSnapshot = structuredClone(person);
    const currentGallery = Array.isArray(person.photoGallery)
      ? person.photoGallery.map((entry) => structuredClone(entry))
      : [];
    const targetIndex = currentGallery.findIndex((entry) => entry.id === mediaId);
    if (targetIndex < 0) {
      return false;
    }

    const previousMedia = structuredClone(currentGallery[targetIndex]);
    const timestamp = nowIso();
    currentGallery[targetIndex] = {
      ...currentGallery[targetIndex],
      ...updates,
      id: currentGallery[targetIndex].id,
      updatedAt: timestamp,
    };
    const updatedUrl = currentGallery[targetIndex].url;

    const requestedPrimaryUrl = updates.isPrimary === true
      ? updatedUrl
      : updates.isPrimary === false && person.primaryPhotoUrl === previousMedia.url
          ? currentGallery.find((entry) => entry.id !== mediaId)?.url || null
          : person.primaryPhotoUrl === previousMedia.url
              ? updatedUrl
              : person.primaryPhotoUrl;
    const photoState = normalizePersonPhotoGallery(currentGallery, {
      photoUrl: requestedPrimaryUrl,
      primaryPhotoUrl: requestedPrimaryUrl,
    });

    person.photoUrl = photoState.photoUrl;
    person.primaryPhotoUrl = photoState.primaryPhotoUrl;
    person.photoGallery = photoState.photoGallery;
    person.updatedAt = timestamp;

    const updatedMedia =
      person.photoGallery.find((entry) => entry.id === mediaId) || null;
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = timestamp;
    }
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "person_media.updated",
      personId,
      mediaId,
      details: {
        before: previousMedia,
        after: updatedMedia ? structuredClone(updatedMedia) : null,
      },
    });
    const propagatedTo = this._propagateIdentityFields(
      db,
      person,
      previousPersonSnapshot,
      actorId,
    );
    await this._write(db);
    return {
      person: structuredClone(person),
      media: updatedMedia ? structuredClone(updatedMedia) : null,
      propagatedTo,
    };
  }

  async deletePersonMedia({
    treeId,
    personId,
    mediaId,
    fallbackUrl = null,
    actorId = null,
  }) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

    const previousPersonSnapshot = structuredClone(person);
    const currentGallery = Array.isArray(person.photoGallery)
      ? person.photoGallery.map((entry) => structuredClone(entry))
      : [];

    // Primary lookup by ID; fall back to URL for clients with stale synthetic IDs.
    let removedMedia = currentGallery.find((entry) => entry.id === mediaId);
    if (!removedMedia && fallbackUrl) {
      const normalizedFallback = String(fallbackUrl).trim().toLowerCase();
      removedMedia = currentGallery.find(
        (entry) => String(entry.url || "").trim().toLowerCase() === normalizedFallback,
      );
    }
    if (!removedMedia) {
      return false;
    }

    const nextGallery = currentGallery.filter((entry) => entry.id !== mediaId);
    const nextPrimaryUrl =
      person.primaryPhotoUrl === removedMedia.url
        ? nextGallery[0]?.url || null
        : person.primaryPhotoUrl;
    const photoState = normalizePersonPhotoGallery(nextGallery, {
      photoUrl: nextPrimaryUrl,
      primaryPhotoUrl: nextPrimaryUrl,
    });
    const timestamp = nowIso();
    person.photoUrl = photoState.photoUrl;
    person.primaryPhotoUrl = photoState.primaryPhotoUrl;
    person.photoGallery = photoState.photoGallery;
    person.updatedAt = timestamp;

    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = timestamp;
    }
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "person_media.deleted",
      personId,
      mediaId,
      details: {
        before: removedMedia,
      },
    });
    const propagatedTo = this._propagateIdentityFields(
      db,
      person,
      previousPersonSnapshot,
      actorId,
    );
    await this._write(db);
    return {
      person: structuredClone(person),
      deletedMedia: structuredClone(removedMedia),
      propagatedTo,
    };
  }

  async listRelations(treeId) {
    const db = await this._read();
    const treePersons = db.persons.filter((person) => person.treeId === treeId);
    return normalizeTreeGraph(treeId, treePersons, db.relations).relations;
  }

  // SPEED-9 B: db — опциональный уже прочитанный блоб (снимок
  // requireTreeAccess). Без него — собственный _read(), как раньше.
  async getTreeGraphSnapshot(treeId, {viewerUserId = null, db: prefetchedDb = null} = {}) {
    const db = prefetchedDb || (await this._read());
    // Phase 3.1d: every person in the snapshot now flows through
    // the graph-first helper. Helper falls back to the legacy
    // record if graph data is absent, so nothing breaks during
    // the boot window or on a snapshot that hasn't been migrated.
    //
    // SPEED-10: index построен один раз для ВСЕХ person'ов дерева, а
    // person передан напрямую (уже под рукой из фильтра ниже) — было
    // O(persons_в_дереве²) global-scan через четыре .find() внутри
    // _buildPersonViewFromGraph на каждого. См. docs/speed_measurement.md.
    const graphIndex = this._buildPersonGraphIndex(db);
    const treePersons = db.persons
      .filter((person) => person.treeId === treeId)
      .map((person) =>
        this._buildPersonViewFromGraph(db, treeId, person.id, {
          index: graphIndex,
          legacyPerson: person,
        }),
      )
      .filter(Boolean);
    if (treePersons.length === 0 && !db.trees.some((tree) => tree.id === treeId)) {
      return null;
    }

    const viewerPerson = viewerUserId
      ? db.persons.find(
          (person) => person.treeId === treeId && person.userId === viewerUserId,
        )
      : null;

    return buildTreeGraphSnapshot({
      treeId,
      persons: treePersons,
      relations: db.relations,
      viewerPersonId: viewerPerson?.id || null,
    });
  }

  async listTreeChangeRecords(treeId, {
    personId = null,
    type = null,
    actorId = null,
  } = {}) {
    const db = await this._read();
    return db.treeChangeRecords
      .filter((record) => {
        if (record.treeId !== treeId) {
          return false;
        }
        if (personId) {
          const personIds = Array.isArray(record.personIds)
            ? record.personIds
            : [];
          if (record.personId !== personId && !personIds.includes(personId)) {
            return false;
          }
        }
        if (type && record.type !== type) {
          return false;
        }
        if (actorId && record.actorId !== actorId) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((record) => structuredClone(record));
  }

  async upsertRelation({
    treeId,
    person1Id,
    person2Id,
    relation1to2,
    relation2to1,
    customRelationLabel1to2 = undefined,
    customRelationLabel2to1 = undefined,
    isConfirmed = true,
    marriageDate = undefined,
    divorceDate = undefined,
    createdBy = null,
    parentSetId = undefined,
    parentSetType = "biological",
    isPrimaryParentSet = undefined,
    unionId = undefined,
    unionType = undefined,
    unionStatus = undefined,
  }) {
    const db = await this._read();
    const person1Exists = db.persons.some(
      (entry) => entry.id === person1Id && entry.treeId === treeId,
    );
    const person2Exists = db.persons.some(
      (entry) => entry.id === person2Id && entry.treeId === treeId,
    );
    if (!person1Exists || !person2Exists) {
      return null;
    }

    const resolvedRelation2to1 =
      relation2to1 || relationMirror(relation1to2);
    const normalizedRelation1to2 = String(relation1to2 || "other");
    const normalizedRelation2to1 = String(resolvedRelation2to1 || "other");
    const normalizedCustomRelationLabel1to2 =
      customRelationLabel1to2 === undefined
        ? undefined
        : normalizeNullableString(customRelationLabel1to2);
    const normalizedCustomRelationLabel2to1 =
      customRelationLabel2to1 === undefined
        ? undefined
        : normalizeNullableString(customRelationLabel2to1);
    const resolvedMarriageDate =
      marriageDate === undefined
        ? undefined
        : normalizeOptionalIsoTimestamp(marriageDate);
    const resolvedDivorceDate =
      divorceDate === undefined
        ? undefined
        : normalizeOptionalIsoTimestamp(divorceDate);
    const treeRelations = db.relations.filter((entry) => entry.treeId === treeId);
    const findRelationRecord = (leftId, rightId) => {
      return db.relations.find((entry) => {
        return (
          entry.treeId === treeId &&
          ((entry.person1Id === leftId && entry.person2Id === rightId) ||
            (entry.person1Id === rightId && entry.person2Id === leftId))
        );
      });
    };
    const getPrimaryParentRelations = (childId) => {
      return treeRelations.filter((entry) => {
        return (
          childIdFromRelation(entry) === childId &&
          entry.isPrimaryParentSet !== false
        );
      });
    };
    const getCurrentUnionPartners = (personId) => {
      const partnerIds = new Set();
      for (const relation of treeRelations) {
        if (!isCurrentUnionRelation(relation)) {
          continue;
        }
        if (relation.person1Id === personId) {
          partnerIds.add(relation.person2Id);
        } else if (relation.person2Id === personId) {
          partnerIds.add(relation.person1Id);
        }
      }
      return Array.from(partnerIds);
    };

    // Текущие СУПРУГИ/ПАРТНЁРЫ (романтический союз) — для со-родительства.
    // В отличие от getCurrentUnionPartners, исключает friend/other/single:
    // друг/прочий не должен становиться родителем ребёнка (ревью B3 FR2).
    // past/divorced уже отсечены isCurrentUnionRelation (только current).
    const getCurrentSpousePartnerIds = (personId) => {
      const partnerIds = new Set();
      for (const relation of treeRelations) {
        if (!isCurrentUnionRelation(relation)) {
          continue;
        }
        const unionType = normalizeUnionType(relation.unionType, {
          relationType: relation.relation1to2 || relation.relation2to1,
        });
        if (unionType !== "spouse" && unionType !== "partner") {
          continue;
        }
        if (relation.person1Id === personId) {
          partnerIds.add(relation.person2Id);
        } else if (relation.person2Id === personId) {
          partnerIds.add(relation.person1Id);
        }
      }
      return Array.from(partnerIds);
    };

    const normalizedParentId =
      normalizedRelation1to2 === "parent" || normalizedRelation2to1 === "child"
        ? person1Id
        : normalizedRelation1to2 === "child" || normalizedRelation2to1 === "parent"
          ? person2Id
          : null;
    const normalizedChildId =
      normalizedRelation1to2 === "parent" || normalizedRelation2to1 === "child"
        ? person2Id
        : normalizedRelation1to2 === "child" || normalizedRelation2to1 === "parent"
          ? person1Id
          : null;
    const resolvedParentSetType = normalizedParentId
      ? normalizeParentSetType(parentSetType)
      : null;
    let resolvedParentSetId =
      normalizeNullableString(parentSetId) || null;
    let resolvedIsPrimaryParentSet =
      normalizedParentId && isPrimaryParentSet !== false;

    if (normalizedParentId && normalizedChildId && !resolvedParentSetId) {
      const existingParentRelations = treeRelations.filter((entry) => {
        return (
          childIdFromRelation(entry) === normalizedChildId &&
          normalizeParentSetType(entry.parentSetType) === resolvedParentSetType
        );
      });
      const primaryGroupId =
        existingParentRelations.find((entry) => entry.isPrimaryParentSet !== false)
          ?.parentSetId || null;
      const primaryParentIds = new Set(
        existingParentRelations
          .filter((entry) => entry.parentSetId === primaryGroupId)
          .map((entry) => parentIdFromRelation(entry))
          .filter(Boolean),
      );
      if (primaryGroupId && (primaryParentIds.has(normalizedParentId) || primaryParentIds.size < 2)) {
        resolvedParentSetId = primaryGroupId;
        resolvedIsPrimaryParentSet = true;
      } else if (!primaryGroupId) {
        resolvedParentSetId =
          `ps:${treeId}:${normalizedChildId}:${resolvedParentSetType}:primary`;
        resolvedIsPrimaryParentSet = true;
      } else {
        resolvedParentSetId =
          `ps:${treeId}:${normalizedChildId}:${resolvedParentSetType}:${crypto.randomUUID()}`;
        resolvedIsPrimaryParentSet = false;
      }
    }

    const resolvedUnionType = isUnionRelationType(normalizedRelation1to2) ||
        isUnionRelationType(normalizedRelation2to1)
      ? normalizeUnionType(unionType, {
          relationType: normalizedRelation1to2,
        })
      : null;
    const resolvedUnionStatus = resolvedUnionType
      ? normalizeUnionStatus(unionStatus, {
          relationType: normalizedRelation1to2,
          divorceDate: resolvedDivorceDate,
        })
      : null;
    const resolvedUnionId = resolvedUnionType
      ? normalizeNullableString(unionId) ||
        `union:${treeId}:${buildSortedIdKey([person1Id, person2Id])}:${resolvedUnionType}:${resolvedUnionStatus}`
      : null;

    const upsertRawRelation = ({
      leftId,
      rightId,
      leftToRight,
      rightToLeft,
      trackChange = true,
      relationCreatedBy = createdBy,
      rawParentSetId = resolvedParentSetId,
      rawParentSetType = resolvedParentSetType,
      rawIsPrimaryParentSet = resolvedIsPrimaryParentSet,
      rawUnionId = resolvedUnionId,
      rawUnionType = resolvedUnionType,
      rawUnionStatus = resolvedUnionStatus,
      rawMarriageDate = resolvedMarriageDate,
      rawDivorceDate = resolvedDivorceDate,
      rawCustomRelationLabel1to2 = normalizedCustomRelationLabel1to2,
      rawCustomRelationLabel2to1 = normalizedCustomRelationLabel2to1,
    }) => {
      const existingRelation = findRelationRecord(leftId, rightId);
      const timestamp = nowIso();
      if (existingRelation) {
        const previousRelation = structuredClone(existingRelation);
        if (
          existingRelation.person1Id === leftId &&
          existingRelation.person2Id === rightId
        ) {
          existingRelation.relation1to2 = leftToRight;
          existingRelation.relation2to1 = rightToLeft;
          if (rawCustomRelationLabel1to2 !== undefined) {
            existingRelation.customRelationLabel1to2 =
              rawCustomRelationLabel1to2 || null;
          }
          if (rawCustomRelationLabel2to1 !== undefined) {
            existingRelation.customRelationLabel2to1 =
              rawCustomRelationLabel2to1 || null;
          }
        } else {
          existingRelation.relation1to2 = rightToLeft;
          existingRelation.relation2to1 = leftToRight;
          if (rawCustomRelationLabel1to2 !== undefined) {
            existingRelation.customRelationLabel2to1 =
              rawCustomRelationLabel1to2 || null;
          }
          if (rawCustomRelationLabel2to1 !== undefined) {
            existingRelation.customRelationLabel1to2 =
              rawCustomRelationLabel2to1 || null;
          }
        }
        existingRelation.isConfirmed = isConfirmed === true;
        if (rawMarriageDate !== undefined) {
          existingRelation.marriageDate = rawMarriageDate;
        }
        if (rawDivorceDate !== undefined) {
          existingRelation.divorceDate = rawDivorceDate;
        }
        existingRelation.parentSetId = rawParentSetId || null;
        existingRelation.parentSetType = rawParentSetType || null;
        existingRelation.isPrimaryParentSet =
          rawParentSetType ? rawIsPrimaryParentSet !== false : null;
        existingRelation.unionId = rawUnionId || null;
        existingRelation.unionType = rawUnionType || null;
        existingRelation.unionStatus = rawUnionStatus || null;
        existingRelation.updatedAt = timestamp;
        if (trackChange) {
          this._appendTreeChangeRecord(db, {
            treeId,
            actorId: relationCreatedBy,
            type: "relation.updated",
            personIds: [existingRelation.person1Id, existingRelation.person2Id],
            relationId: existingRelation.id,
            details: {
              before: previousRelation,
              after: structuredClone(existingRelation),
            },
          });
        }
        return existingRelation;
      }

      const relation = {
        id: crypto.randomUUID(),
        treeId,
        person1Id: leftId,
        person2Id: rightId,
        relation1to2: leftToRight,
        relation2to1: rightToLeft,
        isConfirmed: isConfirmed === true,
        createdAt: timestamp,
        updatedAt: timestamp,
        createdBy: relationCreatedBy,
        marriageDate: rawMarriageDate ?? null,
        divorceDate: rawDivorceDate ?? null,
        customRelationLabel1to2: rawCustomRelationLabel1to2 || null,
        customRelationLabel2to1: rawCustomRelationLabel2to1 || null,
        parentSetId: rawParentSetId || null,
        parentSetType: rawParentSetType || null,
        isPrimaryParentSet:
          rawParentSetType ? rawIsPrimaryParentSet !== false : null,
        unionId: rawUnionId || null,
        unionType: rawUnionType || null,
        unionStatus: rawUnionStatus || null,
      };
      db.relations.push(relation);
      treeRelations.push(relation);
      if (trackChange) {
        this._appendTreeChangeRecord(db, {
          treeId,
          actorId: relationCreatedBy,
          type: "relation.created",
          personIds: [leftId, rightId],
          relationId: relation.id,
          details: {
            after: structuredClone(relation),
          },
        });
      }
      return relation;
    };

    // B3 (ревью F3): со-родительство достраиваем ТОЛЬКО при создании НОВОГО
    // ребра parent→child. upsertRawRelation матчит по ПАРЕ и обновляет запись
    // на месте — без этой проверки повторное сохранение существующего ребра
    // (idempotent re-POST, правка дат/типа, подтверждение) ретро-линковало бы
    // супруга, появившегося ПОСЛЕ привязки к ребёнку (та же P0-коррапт).
    const mainEdgeExistedBefore = treeRelations.some(
      (entry) =>
        (entry.person1Id === person1Id && entry.person2Id === person2Id) ||
        (entry.person1Id === person2Id && entry.person2Id === person1Id),
    );

    const relation = upsertRawRelation({
      leftId: person1Id,
      rightId: person2Id,
      leftToRight: normalizedRelation1to2,
      rightToLeft: normalizedRelation2to1,
    });

    // B3 (со-родительство, УЗКО — ревью B3): достраиваем второго родителя
    // ТОЛЬКО при явном создании ребра parent→child (мы сейчас внутри его
    // создания) и ТОЛЬКО для набора ЭТОГО ребёнка. НЕ на браке, НЕ задним
    // числом, НЕ по всему дереву.
    //
    // Почему так: данные НЕ отличают «нуклеарная семья сложилась после
    // ребёнка» от «родитель женился повторно на постороннем ребёнку».
    // Прежняя широкая автоматика (срабатывание на браке + tree-wide
    // backfill существующих деревьев) из-за этого корраптила сводные
    // семьи — молча записывала отчима (и даже 'friend'-союз) биологическим
    // родителем ребёнка из ПРОШЛОГО союза. Остальные кейсы (брак после
    // привязки к ребёнку, починка старого дерева) закрываются ручным UI
    // «Добавить второго родителя» — это безопасно (явный выбор человека).
    //
    // Гарды: набор с РОВНО ОДНИМ родителем (только что добавленным); набор
    // биологический (приёмный/опекунский статус персональный, через брак не
    // распространяется); у родителя РОВНО ОДИН текущий СУПРУГ/ПАРТНЁР
    // (романтический союз; friend/other/single и past/divorced исключены —
    // FR2); партнёр ещё не родитель этого ребёнка ни в одном наборе; и ребро
    // parent→child создано ВПЕРВЫЕ (ревью F3 — не на повторном upsert'е).
    if (
      !mainEdgeExistedBefore &&
      normalizedParentId &&
      normalizedChildId &&
      resolvedParentSetId
    ) {
      const groupParentIds = new Set(
        treeRelations
          .filter((entry) => entry.parentSetId === resolvedParentSetId)
          .map((entry) => parentIdFromRelation(entry))
          .filter(Boolean),
      );
      const isBiologicalSet =
        normalizeParentSetType(resolvedParentSetType) === "biological";
      if (groupParentIds.size === 1 && isBiologicalSet) {
        const soleParentId = groupParentIds.values().next().value;
        const currentPartners = getCurrentSpousePartnerIds(soleParentId);
        if (currentPartners.length === 1) {
          const partnerId = currentPartners[0];
          // Партнёр уже родитель этого ребёнка в ЛЮБОМ наборе (в т.ч.
          // намеренно как отчим/step) — не дублируем и не перезаписываем.
          const partnerAlreadyParent = treeRelations.some(
            (entry) =>
              childIdFromRelation(entry) === normalizedChildId &&
              parentIdFromRelation(entry) === partnerId,
          );
          if (!partnerAlreadyParent) {
            upsertRawRelation({
              leftId: partnerId,
              rightId: normalizedChildId,
              leftToRight: "parent",
              rightToLeft: "child",
              trackChange: false,
              rawParentSetId: resolvedParentSetId,
              rawParentSetType: resolvedParentSetType,
              rawIsPrimaryParentSet: resolvedIsPrimaryParentSet,
              rawUnionId: null,
              rawUnionType: null,
              rawUnionStatus: null,
              rawMarriageDate: undefined,
              rawDivorceDate: undefined,
            });
          }
        }
      }
    }

    if (
      normalizedRelation1to2 === "sibling" &&
      normalizedRelation2to1 === "sibling"
    ) {
      const person1Parents = getPrimaryParentRelations(person1Id);
      const person2Parents = getPrimaryParentRelations(person2Id);
      if (person1Parents.length === 0 && person2Parents.length > 0) {
        for (const parentRelation of person2Parents) {
          const sourceParentId = parentIdFromRelation(parentRelation);
          if (!sourceParentId) {
            continue;
          }
          upsertRawRelation({
            leftId: sourceParentId,
            rightId: person1Id,
            leftToRight: "parent",
            rightToLeft: "child",
            trackChange: false,
            rawParentSetId: parentRelation.parentSetId,
            rawParentSetType: normalizeParentSetType(parentRelation.parentSetType),
            rawIsPrimaryParentSet: parentRelation.isPrimaryParentSet !== false,
            rawUnionId: null,
            rawUnionType: null,
            rawUnionStatus: null,
            rawMarriageDate: undefined,
            rawDivorceDate: undefined,
          });
        }
      } else if (person2Parents.length === 0 && person1Parents.length > 0) {
        for (const parentRelation of person1Parents) {
          const sourceParentId = parentIdFromRelation(parentRelation);
          if (!sourceParentId) {
            continue;
          }
          upsertRawRelation({
            leftId: sourceParentId,
            rightId: person2Id,
            leftToRight: "parent",
            rightToLeft: "child",
            trackChange: false,
            rawParentSetId: parentRelation.parentSetId,
            rawParentSetType: normalizeParentSetType(parentRelation.parentSetType),
            rawIsPrimaryParentSet: parentRelation.isPrimaryParentSet !== false,
            rawUnionId: null,
            rawUnionType: null,
            rawUnionStatus: null,
            rawMarriageDate: undefined,
            rawDivorceDate: undefined,
          });
        }
      }
    }

    // B3 (ревью): НЕ материализуем (не персистим) выведенные sibling-родители.
    // Прежде _materializeInferredParentLinks писал их РЕАЛЬНЫМИ biological-
    // записями на КАЖДОЙ мутации, по ВСЕМ деревьям, используя anyUnionParters
    // (любой союз — friend/ex/past), мимо всех B3-гардов: это молча записывало
    // постороннего человека биологическим родителем ребёнка из прошлого союза
    // (та же P0-коррапт сводных семей, второй путь). buildDisplayTreeRelations
    // по-прежнему ВЫВОДИТ их display-only для отрисовки — но мы их не
    // фиксируем как факт (FR4: существующие деревья не правим автоматически).
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = nowIso();
    }
    ensureCirclesForTree(db, treeId);
    await this._write(db);
    return structuredClone(relation);
  }

  /**
   * When a user updates their profile photo, propagate the new URL to every
   * tree-person card that is linked to their userId.  This keeps the tree node
   * avatar, chat avatar fallback, and profile photo in sync.
   */
  async syncUserPhotoToTreePersons(userId, photoUrl) {
    if (!userId || !photoUrl) return;
    const db = await this._read();
    let changed = false;
    const timestamp = nowIso();
    for (const person of db.persons) {
      if (String(person.userId || "").trim() !== userId) continue;
      // Only update if the person's primary photo differs.
      if (String(person.primaryPhotoUrl || "").trim() === String(photoUrl).trim()) continue;
      person.photoUrl = photoUrl;
      person.primaryPhotoUrl = photoUrl;
      // If the gallery doesn't include this URL yet, add it.
      const gallery = Array.isArray(person.photoGallery) ? person.photoGallery : [];
      const alreadyInGallery = gallery.some(
        (entry) => String(entry.url || "").trim() === String(photoUrl).trim(),
      );
      if (!alreadyInGallery) {
        const existing = gallery.map((e) => ({...e, isPrimary: false}));
        person.photoGallery = [
          {
            id: `profile-sync:${userId}:${timestamp}`,
            url: photoUrl,
            thumbnailUrl: null,
            type: "image",
            contentType: null,
            caption: null,
            createdAt: timestamp,
            updatedAt: timestamp,
            isPrimary: true,
          },
          ...existing,
        ];
      } else {
        // Mark this entry as primary.
        person.photoGallery = gallery.map((e) => ({
          ...e,
          isPrimary: String(e.url || "").trim() === String(photoUrl).trim(),
          updatedAt: timestamp,
        }));
      }
      person.updatedAt = timestamp;
      changed = true;
    }
    if (changed) await this._write(db);
  }

  async deleteRelation(treeId, relationId, actorId = null) {
    const db = await this._read();
    const relation = db.relations.find(
      (entry) => entry.id === relationId && entry.treeId === treeId,
    );
    if (!relation) {
      return null;
    }

    const deletedRelation = structuredClone(relation);
    db.relations = db.relations.filter((entry) => entry.id !== relationId);
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = nowIso();
    }
    this._appendTreeChangeRecord(db, {
      treeId,
      actorId,
      type: "relation.deleted",
      personIds: [relation.person1Id, relation.person2Id],
      relationId,
      details: {
        before: deletedRelation,
      },
    });
    ensureCirclesForTree(db, treeId);
    await this._write(db);
    return deletedRelation;
  }

  async getDirectRelationBetween(treeId, person1Id, person2Id) {
    const db = await this._read();
    const relation = db.relations.find((entry) => {
      return (
        entry.treeId === treeId &&
        ((entry.person1Id === person1Id && entry.person2Id === person2Id) ||
          (entry.person1Id === person2Id && entry.person2Id === person1Id))
      );
    });

    if (!relation) {
      return null;
    }

    if (relation.person1Id === person1Id && relation.person2Id === person2Id) {
      return relation.relation1to2;
    }

    return relation.relation2to1;
  }

  async listOfflineProfilesByCreator(treeId, creatorId) {
    const db = await this._read();
    return db.persons
      .filter(
        (person) =>
          person.treeId === treeId &&
          person.creatorId === creatorId &&
          !person.userId,
      )
      .sort((left, right) =>
        String(left.name || "").localeCompare(String(right.name || "")),
      )
      .map((person) => structuredClone(person));
  }

  async findSpouseId(treeId, personId) {
    const db = await this._read();
    const relation = db.relations.find((entry) => {
      if (entry.treeId !== treeId) {
        return false;
      }

      const involvesPerson =
        entry.person1Id === personId || entry.person2Id === personId;
      const isSpouseRelation =
        entry.relation1to2 === "spouse" ||
        entry.relation2to1 === "spouse" ||
        entry.relation1to2 === "partner" ||
        entry.relation2to1 === "partner";

      return involvesPerson && isSpouseRelation;
    });

    if (!relation) {
      return null;
    }

    return relation.person1Id === personId ? relation.person2Id : relation.person1Id;
  }

  async createRelationRequest({
    treeId,
    senderId,
    recipientId,
    senderToRecipient,
    targetPersonId = null,
    message = null,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const sender = db.users.find((entry) => entry.id === senderId);
    const recipient = db.users.find((entry) => entry.id === recipientId);
    if (!sender || !recipient) {
      return undefined;
    }

    if (senderId === recipientId) {
      return false;
    }

    if (targetPersonId) {
      const targetPerson = db.persons.find(
        (entry) => entry.id === targetPersonId && entry.treeId === treeId,
      );
      if (!targetPerson) {
        return "TARGET_PERSON_NOT_FOUND";
      }
    }

    const duplicate = db.relationRequests.find((entry) => {
      return (
        entry.treeId === treeId &&
        entry.senderId === senderId &&
        entry.recipientId === recipientId &&
        entry.status === "pending" &&
        String(entry.targetPersonId || "") === String(targetPersonId || "")
      );
    });
    if (duplicate) {
      return "DUPLICATE";
    }

    const timestamp = nowIso();
    const request = {
      id: crypto.randomUUID(),
      treeId,
      senderId,
      recipientId,
      senderToRecipient: String(senderToRecipient || "other"),
      targetPersonId: targetPersonId || null,
      offlineRelativeId: targetPersonId || null,
      createdAt: timestamp,
      updatedAt: timestamp,
      respondedAt: null,
      status: "pending",
      message: normalizeNullableString(message),
    };

    db.relationRequests.push(request);
    tree.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(request);
  }

  async listRelationRequests({
    treeId = null,
    senderId = null,
    recipientId = null,
    status = null,
  } = {}) {
    const db = await this._read();
    return db.relationRequests
      .filter((entry) => {
        if (treeId && entry.treeId !== treeId) {
          return false;
        }
        if (senderId && entry.senderId !== senderId) {
          return false;
        }
        if (recipientId && entry.recipientId !== recipientId) {
          return false;
        }
        if (status && entry.status !== status) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  async findRelationRequest(requestId) {
    const db = await this._read();
    const request = db.relationRequests.find((entry) => entry.id === requestId);
    return request ? structuredClone(request) : null;
  }

  async respondToRelationRequest(requestId, status) {
    const db = await this._read();
    const request = db.relationRequests.find((entry) => entry.id === requestId);
    if (!request) {
      return null;
    }

    request.status = String(status || request.status || "pending");
    request.respondedAt = nowIso();
    request.updatedAt = request.respondedAt;
    await this._write(db);
    return structuredClone(request);
  }

  async createTreeInvitation({
    treeId,
    userId,
    addedBy = null,
    relationToTree = null,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return undefined;
    }

    const isMember =
      tree.creatorId === userId ||
      (Array.isArray(tree.memberIds) && tree.memberIds.includes(userId));
    if (isMember) {
      return false;
    }

    const duplicate = db.treeInvitations.find((entry) => {
      return (
        entry.treeId === treeId &&
        entry.userId === userId &&
        entry.role === "pending"
      );
    });
    if (duplicate) {
      return "DUPLICATE";
    }

    const invitation = createTreeInvitationRecord({
      treeId,
      userId,
      addedBy,
      relationToTree,
    });
    db.treeInvitations.push(invitation);
    tree.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(invitation);
  }

  async listPendingTreeInvitations(userId) {
    const db = await this._read();
    return db.treeInvitations
      .filter((entry) => entry.userId === userId && entry.role === "pending")
      .sort((left, right) =>
        String(right.addedAt || "").localeCompare(String(left.addedAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  async findTreeInvitation(invitationId) {
    const db = await this._read();
    const invitation = db.treeInvitations.find((entry) => entry.id === invitationId);
    return invitation ? structuredClone(invitation) : null;
  }

  async respondToTreeInvitation(invitationId, accept) {
    const db = await this._read();
    const invitationIndex = db.treeInvitations.findIndex(
      (entry) => entry.id === invitationId,
    );
    if (invitationIndex < 0) {
      return null;
    }

    const invitation = db.treeInvitations[invitationIndex];
    const tree = db.trees.find((entry) => entry.id === invitation.treeId);
    if (!tree) {
      return undefined;
    }

    if (accept) {
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      tree.members = Array.isArray(tree.members) ? tree.members : [];
      if (!tree.memberIds.includes(invitation.userId)) {
        tree.memberIds.push(invitation.userId);
      }
      if (!tree.members.includes(invitation.userId)) {
        tree.members.push(invitation.userId);
      }
      this._ensureSemyaMembershipForLegacyJoin(db, tree, invitation.userId);
      tree.updatedAt = nowIso();
    }

    db.treeInvitations.splice(invitationIndex, 1);
    await this._write(db);
    return {
      invitation: structuredClone(invitation),
      tree: structuredClone(tree),
      accepted: accept === true,
    };
  }

  async createNotification({userId, type, title, body, data, silent = false}) {
    return this._mutate((db, skip) => {
      const user = db.users.find((entry) => entry.id === userId);
      if (!user) {
        return skip(null);
      }

      const notification = createNotificationRecord({
        userId,
        type,
        title,
        body,
        data,
        silent,
      });
      db.notifications.push(notification);
      return structuredClone(notification);
    });
  }

  async registerPushDevice({
    userId,
    provider,
    token,
    platform,
    sessionPublicId = null,
    instanceId = null,
  }) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const normalizedProvider = String(provider || "").trim();
    const normalizedToken = String(token || "").trim();
    if (!normalizedProvider || !normalizedToken) {
      return false;
    }

    const normalizedSessionPublicId = normalizeOptionalString(sessionPublicId, 32);
    const normalizedInstanceId = normalizeOptionalString(instanceId, 80);

    const existingDevice = db.pushDevices.find((entry) => {
      return (
        entry.userId === userId &&
        entry.provider === normalizedProvider &&
        entry.token === normalizedToken
      );
    });

    if (existingDevice) {
      existingDevice.platform = String(platform || existingDevice.platform || "unknown");
      existingDevice.updatedAt = nowIso();
      existingDevice.lastSeenAt = existingDevice.updatedAt;
      if (normalizedSessionPublicId) {
        existingDevice.sessionPublicId = normalizedSessionPublicId;
      }
      if (normalizedInstanceId) {
        existingDevice.instanceId = normalizedInstanceId;
      }
      await this._write(db);
      return structuredClone(existingDevice);
    }

    const device = createPushDeviceRecord({
      userId,
      provider: normalizedProvider,
      token: normalizedToken,
      platform,
      sessionPublicId: normalizedSessionPublicId,
      instanceId: normalizedInstanceId,
    });
    db.pushDevices.push(device);
    await this._write(db);
    return structuredClone(device);
  }

  async unbindPushDevicesForSession({userId, sessionPublicId}) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedSessionPublicId = String(sessionPublicId || "").trim();
    if (!normalizedUserId || !normalizedSessionPublicId) {
      return [];
    }
    const db = await this._read();
    const removed = [];
    db.pushDevices = db.pushDevices.filter((entry) => {
      if (
        entry.userId === normalizedUserId &&
        entry.sessionPublicId === normalizedSessionPublicId
      ) {
        removed.push(structuredClone(entry));
        return false;
      }
      return true;
    });
    if (removed.length === 0) {
      return [];
    }
    const removedIds = new Set(removed.map((entry) => entry.id));
    db.pushDeliveries = db.pushDeliveries.filter(
      (entry) => !removedIds.has(entry.deviceId),
    );
    await this._write(db);
    return removed;
  }

  async listPushDevices(userId) {
    const db = await this._read();
    return db.pushDevices
      .filter((entry) => entry.userId === userId)
      .sort((left, right) =>
        String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  async deletePushDevice(deviceId, userId) {
    const db = await this._read();
    const initialLength = db.pushDevices.length;
    db.pushDevices = db.pushDevices.filter((entry) => {
      return !(entry.id === deviceId && entry.userId === userId);
    });

    if (db.pushDevices.length === initialLength) {
      return false;
    }

    db.pushDeliveries = db.pushDeliveries.filter((entry) => entry.deviceId !== deviceId);
    await this._write(db);
    return true;
  }

  async createPushDelivery({
    notificationId,
    userId,
    deviceId,
    provider,
    status = "queued",
  }) {
    const db = await this._read();
    const delivery = createPushDeliveryRecord({
      notificationId,
      userId,
      deviceId,
      provider,
      status,
    });
    db.pushDeliveries.push(delivery);
    await this._write(db);
    return structuredClone(delivery);
  }

  async listPushDeliveries(userId, {limit = 50} = {}) {
    const db = await this._read();
    return db.pushDeliveries
      .filter((entry) => entry.userId === userId)
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .slice(0, limit)
      .map((entry) => structuredClone(entry));
  }

  async updatePushDelivery(
    deliveryId,
    {
      status,
      deliveredAt,
      lastError,
      responseCode,
    } = {},
  ) {
    const db = await this._read();
    const delivery = db.pushDeliveries.find((entry) => entry.id === deliveryId);
    if (!delivery) {
      return null;
    }

    if (status !== undefined) {
      delivery.status = String(status || delivery.status).trim();
    }
    if (deliveredAt !== undefined) {
      delivery.deliveredAt = deliveredAt || null;
    }
    if (lastError !== undefined) {
      delivery.lastError = lastError ? String(lastError) : null;
    }
    if (responseCode !== undefined) {
      const normalizedCode = Number(responseCode);
      delivery.responseCode = Number.isFinite(normalizedCode)
        ? normalizedCode
        : null;
    }
    delivery.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(delivery);
  }

  async listNotifications(userId, {status = null, limit = 50} = {}) {
    const db = await this._read();
    const normalizedLimit = Number.isFinite(Number(limit))
      ? Math.max(0, Number(limit))
      : 50;
    if (normalizedLimit === 0) {
      return [];
    }

    const notifications = [];
    for (let index = db.notifications.length - 1; index >= 0; index -= 1) {
      const entry = db.notifications[index];
      if (entry.userId !== userId) {
        continue;
      }
      if (status === "unread" && entry.readAt) {
        continue;
      }
      if (status === "read" && !entry.readAt) {
        continue;
      }

      notifications.push(entry);
      if (notifications.length >= normalizedLimit) {
        break;
      }
    }

    return notifications.map((entry) => structuredClone(entry));
  }

  async countUnreadNotifications(userId) {
    const db = await this._read();
    return db.notifications.filter((entry) => entry.userId === userId && !entry.readAt)
      .length;
  }

  async markNotificationRead(notificationId, userId) {
    return this._mutate((db, skip) => {
      const notification = db.notifications.find(
        (entry) => entry.id === notificationId && entry.userId === userId,
      );
      if (!notification) {
        return skip(null);
      }

      if (!notification.readAt) {
        notification.readAt = nowIso();
        return structuredClone(notification);
      }
      return skip(structuredClone(notification));
    });
  }

  /// «Прочитать всё»: один вызов вместо N поштучных POST'ов с клиента
  /// (экран активности лупил цикл markNotificationRead по каждому id).
  async markAllNotificationsRead(userId) {
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) return 0;
    return this._mutate((db, skip) => {
      const now = nowIso();
      let markedCount = 0;
      for (const notification of db.notifications) {
        if (notification.userId !== normalizedUserId) continue;
        if (notification.readAt) continue;
        notification.readAt = now;
        markedCount += 1;
      }
      if (markedCount === 0) {
        return skip(0);
      }
      return markedCount;
    });
  }

  /// Курсорная страница ленты активности (все статусы по умолчанию).
  /// Keyset-курсор `createdAt|id` (base64url), сортировка createdAt DESC,
  /// id DESC — стабильна при вставке новых сверху. nextCursor null =
  /// лента закончилась.
  async listNotificationsPage(userId, {status = null, limit = 50, cursor = null} = {}) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedLimit = Math.min(
      200,
      Math.max(1, Math.floor(Number(limit) || 50)),
    );
    if (!normalizedUserId) {
      return {notifications: [], nextCursor: null};
    }
    const decodedCursor = decodeNotificationCursor(cursor);
    const db = await this._read();
    const filtered = db.notifications.filter((entry) => {
      if (entry.userId !== normalizedUserId) return false;
      if (status === "unread" && entry.readAt) return false;
      if (status === "read" && !entry.readAt) return false;
      return true;
    });
    filtered.sort((left, right) => {
      const byCreated = String(right.createdAt || "").localeCompare(
        String(left.createdAt || ""),
      );
      if (byCreated !== 0) return byCreated;
      return String(right.id || "").localeCompare(String(left.id || ""));
    });
    const afterCursor = decodedCursor
      ? filtered.filter((entry) => {
          const created = String(entry.createdAt || "");
          if (created !== decodedCursor.createdAt) {
            return created < decodedCursor.createdAt;
          }
          return String(entry.id || "") < decodedCursor.id;
        })
      : filtered;
    const pageItems = afterCursor.slice(0, normalizedLimit);
    const hasMore = afterCursor.length > normalizedLimit;
    const last = pageItems[pageItems.length - 1];
    return {
      notifications: pageItems.map((entry) => structuredClone(entry)),
      nextCursor:
        hasMore && last
          ? encodeNotificationCursor(String(last.createdAt || ""), String(last.id || ""))
          : null,
    };
  }

  /// Bulk mark — отмечает прочитанными все уведомления юзера, у
  /// которых `data.<dataKey>` === `dataValue` И тип входит в
  /// `types` (если задан). Возвращает количество отмеченных
  /// записей. Используется для авто-погашения уведомлений когда
  /// юзер видит источник в приложении (например, открыл чат →
  /// гасим все «новое сообщение» по этому chatId).
  ///
  /// User-reported: «много в активностях остаётся оповещений
  /// которые были уже просмотрены в приложении» — раньше клиент
  /// должен был тапать каждое сообщение по отдельности или
  /// нажимать «Прочитать всё», что было неудобно и часто
  /// забывалось.
  async markNotificationsReadByDataKey({
    userId,
    dataKey,
    dataValue,
    types = null,
  }) {
    if (!userId || !dataKey) return 0;
    const normalizedValue = dataValue == null ? null : String(dataValue);
    const typeFilter = Array.isArray(types) && types.length > 0
      ? new Set(types.map((entry) => String(entry)))
      : null;

    return this._mutate((db, skip) => {
      const now = nowIso();
      let markedCount = 0;
      for (const notification of db.notifications) {
        if (notification.userId !== userId) continue;
        if (notification.readAt) continue;
        if (typeFilter && !typeFilter.has(String(notification.type || ""))) {
          continue;
        }
        const data = notification.data || {};
        const candidate = data[dataKey];
        if (candidate == null) continue;
        if (String(candidate) !== normalizedValue) continue;
        notification.readAt = now;
        markedCount += 1;
      }
      if (markedCount === 0) {
        return skip(markedCount);
      }
      return markedCount;
    });
  }

  async listUserBlocks(userId) {
    const db = await this._read();
    return db.blocks
      .filter((entry) => entry.blockerId === userId)
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  async createUserBlock({
    blockerId,
    blockedUserId,
    reason = null,
    metadata = {},
  }) {
    const db = await this._read();
    const normalizedBlockerId = String(blockerId || "").trim();
    const normalizedBlockedUserId = String(blockedUserId || "").trim();
    if (!normalizedBlockerId || !normalizedBlockedUserId) {
      return false;
    }
    if (normalizedBlockerId === normalizedBlockedUserId) {
      return false;
    }

    const blocker = db.users.find((entry) => entry.id === normalizedBlockerId);
    const blockedUser = db.users.find((entry) => entry.id === normalizedBlockedUserId);
    if (!blocker || !blockedUser) {
      return null;
    }

    const existingBlock = db.blocks.find((entry) => {
      return (
        entry.blockerId === normalizedBlockerId &&
        entry.blockedUserId === normalizedBlockedUserId
      );
    });
    if (existingBlock) {
      if (reason != null || (metadata && Object.keys(metadata).length > 0)) {
        existingBlock.reason = normalizeNullableString(reason) || existingBlock.reason;
        existingBlock.metadata = metadata && typeof metadata === "object"
          ? structuredClone(metadata)
          : existingBlock.metadata || {};
        existingBlock.updatedAt = nowIso();
        await this._write(db);
      }
      return structuredClone(existingBlock);
    }

    const block = createBlockRecord({
      blockerId: normalizedBlockerId,
      blockedUserId: normalizedBlockedUserId,
      reason,
      metadata,
    });
    db.blocks.push(block);
    await this._write(db);
    return structuredClone(block);
  }

  async deleteUserBlock({blockId, blockerId}) {
    const db = await this._read();
    const index = db.blocks.findIndex((entry) => {
      return entry.id === blockId && entry.blockerId === blockerId;
    });
    if (index < 0) {
      return null;
    }

    const [removed] = db.blocks.splice(index, 1);
    await this._write(db);
    return structuredClone(removed);
  }

  async isUserBlockedBetween(userIdA, userIdB) {
    const db = await this._read();
    return db.blocks.some((entry) => {
      return (
        (entry.blockerId === userIdA && entry.blockedUserId === userIdB) ||
        (entry.blockerId === userIdB && entry.blockedUserId === userIdA)
      );
    });
  }

  async createReport({
    reporterId,
    targetType,
    targetId,
    reason,
    details = null,
    metadata = {},
  }) {
    const db = await this._read();
    const normalizedReporterId = String(reporterId || "").trim();
    const normalizedTargetType = String(targetType || "").trim();
    const normalizedTargetId = String(targetId || "").trim();
    if (!normalizedReporterId || !normalizedTargetType || !normalizedTargetId) {
      return false;
    }

    if (!db.users.some((entry) => entry.id === normalizedReporterId)) {
      return null;
    }

    const report = createReportRecord({
      reporterId: normalizedReporterId,
      targetType: normalizedTargetType,
      targetId: normalizedTargetId,
      reason,
      details,
      metadata,
    });
    db.reports.push(report);
    await this._write(db);
    return structuredClone(report);
  }

  async listReports({status = null} = {}) {
    const db = await this._read();
    const normalizedStatus = normalizeNullableString(status);
    return db.reports
      .filter((entry) => {
        if (!normalizedStatus) {
          return true;
        }
        return entry.status === normalizedStatus;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  async resolveReport({
    reportId,
    resolvedBy,
    status,
    resolutionNote = null,
  }) {
    const db = await this._read();
    const report = db.reports.find((entry) => entry.id === reportId);
    if (!report) {
      return null;
    }

    report.status = String(status || "resolved").trim() || "resolved";
    report.resolvedBy = String(resolvedBy || "").trim() || null;
    report.resolutionNote = normalizeNullableString(resolutionNote);
    report.resolvedAt = nowIso();
    report.updatedAt = report.resolvedAt;
    await this._write(db);
    return structuredClone(report);
  }

  async createClientDiagnostic({
    userId,
    sessionId = null,
    type,
    message = "",
    platform = null,
    appVersion = null,
    context = {},
    error = null,
    stackTrace = null,
  }) {
    const db = await this._read();
    const event = {
      id: `diag_${crypto.randomUUID()}`,
      userId: normalizeNullableString(userId),
      sessionId: normalizeNullableString(sessionId),
      type: normalizeNullableString(type) || "client_event",
      message: normalizeNullableString(message) || "",
      platform,
      appVersion,
      context: context && typeof context === "object" ? context : {},
      error,
      stackTrace,
      createdAt: nowIso(),
    };
    db.clientDiagnostics.push(event);
    if (db.clientDiagnostics.length > 500) {
      db.clientDiagnostics = db.clientDiagnostics.slice(-500);
    }
    await this._write(db);
    return structuredClone(event);
  }

  async listClientDiagnostics({type = null, userId = null, limit = 100} = {}) {
    const db = await this._read();
    const normalizedType = normalizeNullableString(type);
    const normalizedUserId = normalizeNullableString(userId);
    const cappedLimit = Math.min(Math.max(Number(limit) || 100, 1), 500);
    return db.clientDiagnostics
      .filter((entry) => {
        if (normalizedType && entry.type !== normalizedType) {
          return false;
        }
        if (normalizedUserId && entry.userId !== normalizedUserId) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .slice(0, cappedLimit)
      .map((entry) => structuredClone(entry));
  }

  _userIdentityIdsInTree(db, treeId, userId) {
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) {
      return new Set();
    }
    return new Set(
      (Array.isArray(db.persons) ? db.persons : [])
        .filter(
          (person) => person.treeId === treeId && person.userId === normalizedUserId,
        )
        .map((person) => normalizeNullableString(person.identityId))
        .filter(Boolean),
    );
  }

  // SPEED-10: `cache` — опциональный объект {circles, identities} (см.
  // _createCircleVisibilityCache), построенный ОДИН раз вызывающим циклом
  // (listPosts/listStories/listGatherings/listPolls/getBranchDigest/
  // searchPosts). Без него ensureCirclesForTree(db, treeId) заново
  // пересобирает ВСЕ авто-круги дерева — BFS-обход persons×relations
  // (buildAutoCircleSpecsForTree) — на КАЖДЫЙ элемент ленты, хотя treeId
  // (и db) внутри одного вызова не меняются; аналогично
  // _userIdentityIdsInTree сканирует db.persons заново на каждый элемент.
  // db.circles уже содержит нужные записи после первого вызова
  // (ensureCirclesForTree идемпотентна на неизменном db), так что
  // повторные вызовы с тем же treeId в рамках одного db-снимка дают ТОТ
  // ЖЕ результат — см. docs/speed_measurement.md SPEED-10. Без `cache` —
  // прежнее поведение (одиночные вызовы вроде createPost/createStory, где
  // строить кэш ради одного circleId незачем).
  _canUserViewCircleContent(
    db,
    {treeId, circleId: rawCircleId = null, authorId = null, viewerUserId = null},
    cache = null,
  ) {
    const normalizedViewerUserId = normalizeNullableString(viewerUserId);
    if (!normalizedViewerUserId || !treeId) {
      return true;
    }
    if (authorId === normalizedViewerUserId) {
      return true;
    }

    const explicitCircleId = normalizeNullableString(rawCircleId);
    let allTreeCircle;
    if (cache) {
      if (!cache.circles.has(treeId)) {
        cache.circles.set(treeId, ensureCirclesForTree(db, treeId));
      }
      ({allTreeCircle} = cache.circles.get(treeId));
    } else {
      ({allTreeCircle} = ensureCirclesForTree(db, treeId));
    }
    const circleId = explicitCircleId || allTreeCircle?.id;
    const circle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === circleId,
    );
    if (!circle) {
      return !explicitCircleId;
    }
    if (circle.kind === "all_tree") {
      return true;
    }

    let viewerIdentityIds;
    if (cache) {
      const identityCacheKey = `${treeId} ${normalizedViewerUserId}`;
      if (!cache.identities.has(identityCacheKey)) {
        cache.identities.set(
          identityCacheKey,
          this._userIdentityIdsInTree(db, treeId, normalizedViewerUserId),
        );
      }
      viewerIdentityIds = cache.identities.get(identityCacheKey);
    } else {
      viewerIdentityIds = this._userIdentityIdsInTree(
        db,
        treeId,
        normalizedViewerUserId,
      );
    }
    if (viewerIdentityIds.size === 0) {
      return false;
    }

    return db.circleMembers.some((entry) => {
      return (
        entry.treeId === treeId &&
        entry.circleId === circle.id &&
        viewerIdentityIds.has(normalizeNullableString(entry.identityId))
      );
    });
  }

  // SPEED-10: см. _canUserViewCircleContent — `cache` опционален и
  // прокидывается в оба внутренних вызова один-в-один.
  _createCircleVisibilityCache() {
    return {circles: new Map(), identities: new Map()};
  }

  _canUserViewCirclePost(db, post, viewerUserId, cache = null) {
    if (!post) {
      return true;
    }
    // Audience model: a post is visible if the viewer is in the
    // audience of ANY branch the post was published to. The primary
    // branch (post.treeId) honors the post's targeted circle
    // (post.circleId), so circle-targeted posts stay scoped on the
    // tree the author chose. Additional branches in post.branchIds
    // (Phase 3.4 multi-branch fan-out) are checked at the all_tree
    // level — circles are per-tree by construction, so when an
    // author fans a post out across branches they implicitly accept
    // the broader (all-members) audience for the extra branches.
    //
    // Earlier this only checked post.treeId, which silently dropped
    // posts for viewers who belonged to a secondary branch but not
    // the primary one. User-visible bug: post in branchIds=[A, B],
    // viewer in B only, post.treeId=A → viewer never sees it even
    // though the author fan-out targeted B explicitly.
    if (
      this._canUserViewCircleContent(db, {
        treeId: post.treeId,
        circleId: post.circleId,
        authorId: post.authorId,
        viewerUserId,
      }, cache)
    ) {
      return true;
    }
    const branchIds = Array.isArray(post.branchIds) ? post.branchIds : [];
    for (const branchId of branchIds) {
      if (!branchId || branchId === post.treeId) continue;
      if (
        this._canUserViewCircleContent(db, {
          treeId: branchId,
          circleId: null,
          authorId: post.authorId,
          viewerUserId,
        }, cache)
      ) {
        return true;
      }
    }
    return false;
  }

  // ── Phase 6.3: «Эта неделя в семье» digest ─────────────────────────
  // Aggregates the next-N-days events for a single branch: upcoming
  // birthdays of living members, memorial anniversaries of those
  // who passed, recent posts, and persons added in the last N days.
  // Computed on read — no separate index. Cheap on small branches
  // (≤200 persons each) and the alternative (a per-branch event
  // table the tree code already maintains client-side via
  // event_service.dart) was a duplicate computation; better to
  // serve a uniform shape from the server so both home + sidebar
  // can render the same payload.
  async getBranchDigest({treeId, days = 7, viewerUserId = null}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) return null;
    const now = new Date();
    const horizonDays = Math.max(1, Math.min(Number(days) || 7, 31));
    const horizonMs = horizonDays * 86400_000;
    const horizonEnd = new Date(now.getTime() + horizonMs);

    const treePersons = db.persons.filter(
      (entry) => entry.treeId === treeId,
    );

    const birthdays = [];
    const memorials = [];
    for (const person of treePersons) {
      const event = computeUpcomingAnniversary(
        person.birthDate,
        now,
        horizonDays,
      );
      if (event && (person.isAlive !== false) && !person.deathDate) {
        birthdays.push({
          personId: person.id,
          name: person.name,
          photoUrl: person.primaryPhotoUrl || person.photoUrl || null,
          birthDate: person.birthDate,
          daysUntil: event.daysUntil,
          age: event.yearsSince,
          eventDate: event.date.toISOString(),
        });
      }
      if (person.deathDate) {
        const memorial = computeUpcomingAnniversary(
          person.deathDate,
          now,
          horizonDays,
        );
        if (memorial) {
          memorials.push({
            personId: person.id,
            name: person.name,
            photoUrl: person.primaryPhotoUrl || person.photoUrl || null,
            deathDate: person.deathDate,
            daysUntil: memorial.daysUntil,
            yearsSince: memorial.yearsSince,
            eventDate: memorial.date.toISOString(),
          });
        }
      }
    }
    birthdays.sort((a, b) => a.daysUntil - b.daysUntil);
    memorials.sort((a, b) => a.daysUntil - b.daysUntil);

    // Recent posts on this branch (back-compat: branchIds OR
    // legacy treeId — same gate as listPosts).
    const recentPostsCutoffMs = now.getTime() - horizonMs;
    const circleCache = this._createCircleVisibilityCache();
    const recentPosts = db.posts
      .filter((post) => {
        const branchIds = Array.isArray(post.branchIds)
          ? post.branchIds
          : [];
        const inBranch = branchIds.includes(treeId) || post.treeId === treeId;
        if (!inBranch) return false;
        if (!this._canUserViewCirclePost(db, post, viewerUserId, circleCache)) return false;
        const created = post.createdAt
          ? new Date(post.createdAt).getTime()
          : 0;
        return Number.isFinite(created) && created >= recentPostsCutoffMs;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(
          String(left.createdAt || ""),
        ),
      )
      .slice(0, 8)
      .map((post) => ({
        postId: post.id,
        authorId: post.authorId,
        authorName: post.authorName,
        authorPhotoUrl: post.authorPhotoUrl || null,
        content: post.content,
        imageUrls: Array.isArray(post.imageUrls) ? post.imageUrls : [],
        createdAt: post.createdAt,
      }));

    // Newly-added persons on this branch — surfacing them on the
    // home digest is what makes the user feel "the family is
    // growing" rather than just "I added someone".
    const newPersons = treePersons
      .filter((person) => {
        const created = person.createdAt
          ? new Date(person.createdAt).getTime()
          : 0;
        return Number.isFinite(created) && created >= recentPostsCutoffMs;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(
          String(left.createdAt || ""),
        ),
      )
      .slice(0, 8)
      .map((person) => ({
        personId: person.id,
        name: person.name,
        photoUrl: person.primaryPhotoUrl || person.photoUrl || null,
        createdAt: person.createdAt,
      }));

    return {
      treeId,
      treeName: tree.name,
      horizonDays,
      generatedAt: now.toISOString(),
      birthdays,
      memorials,
      recentPosts,
      newPersons,
    };
  }

  // Ленты (posts/stories/gatherings/polls) НЕ зовут ensureCirclesForAllTrees:
  // круги нужного дерева лениво сверяет _canUserViewCircleContent, а сверка
  // всех деревьев на каждое чтение — лишний CPU и запись блоба из читающего
  // пути в обход _mutate (lost-update). Хранимое состояние кругов чинят
  // мутации графа и listCircles/findCircle.
  async listPosts({
    treeId = null,
    authorId = null,
    scope = null,
    viewerUserId = null,
  } = {}) {
    const db = await this._read();
    const circleCache = this._createCircleVisibilityCache();
    return db.posts
      .filter((entry) => {
        // Phase 3.4 multi-branch visibility. If `treeId` filter is
        // set, the post matches when the requested tree is in
        // post.branchIds (preferred) OR matches post.treeId (back-
        // compat for posts created before 3.4). Without a treeId
        // filter the tree gate is skipped entirely (cross-branch
        // feed query) and visibility falls to the circle/scope
        // checks below.
        if (treeId) {
          const branchIds = Array.isArray(entry.branchIds)
            ? entry.branchIds
            : [];
          const inBranches = branchIds.includes(treeId);
          const matchesLegacyTreeId = entry.treeId === treeId;
          if (!inBranches && !matchesLegacyTreeId) {
            return false;
          }
        }
        if (authorId && entry.authorId !== authorId) {
          return false;
        }
        if (scope === "branches" && entry.scopeType !== "branches") {
          return false;
        }
        if (!this._canUserViewCirclePost(db, entry, viewerUserId, circleCache)) {
          return false;
        }
        return true;
      })
      .sort((left, right) => {
        // S2: tie-break по id — стабильный порядок при равных createdAt
        // обязателен для курсорной пагинации (иначе пост на границе
        // страницы может выпасть или задвоиться).
        const byCreatedAt = String(right.createdAt || "").localeCompare(
          String(left.createdAt || ""),
        );
        if (byCreatedAt !== 0) {
          return byCreatedAt;
        }
        return String(right.id || "").localeCompare(String(left.id || ""));
      })
      .map((entry) => attachPostReactions(db, entry));
  }

  // SPEED-9 B: db — опциональный уже прочитанный блоб (снимок
  // requireTreeAccess из того же HTTP-запроса, всегда моложе любой
  // мутации в этом обработчике — GET-хендлер /v1/stories не мутирует).
  // Просроченные истории по-прежнему чистятся ниже через this._write —
  // не трогаем этот побочный эффект, только источник db.
  async listStories({
    treeId = null,
    authorId = null,
    viewerUserId = null,
    db: prefetchedDb = null,
  } = {}) {
    const db = prefetchedDb || (await this._read());
    const now = Date.now();
    const activeStories = [];
    let removedExpiredStories = false;

    for (const story of db.stories) {
      if (isExpiredAt(story.expiresAt, now)) {
        removedExpiredStories = true;
        continue;
      }
      activeStories.push(story);
    }

    if (removedExpiredStories) {
      db.stories = activeStories;
      await this._write(db);
    }

    const circleCache = this._createCircleVisibilityCache();
    return activeStories
      .filter((entry) => {
        if (treeId && entry.treeId !== treeId) {
          return false;
        }
        if (authorId && entry.authorId !== authorId) {
          return false;
        }
        if (
          !this._canUserViewCircleContent(db, {
            treeId: entry.treeId,
            circleId: entry.circleId,
            authorId: entry.authorId,
            viewerUserId,
          }, circleCache)
        ) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((entry) => attachStoryReactions(db, entry));
  }

  async findStory(storyId) {
    const db = await this._read();
    const story = db.stories.find((entry) => entry.id === storyId);
    if (!story) {
      return null;
    }
    if (isExpiredAt(story.expiresAt)) {
      db.stories = db.stories.filter((entry) => entry.id !== storyId);
      await this._write(db);
      return null;
    }
    return attachStoryReactions(db, story);
  }

  async createStory({
    treeId,
    authorId,
    authorName,
    authorPhotoUrl = null,
    type = "text",
    text = null,
    mediaUrl = null,
    thumbnailUrl = null,
    expiresAt = null,
    circleId = null,
    scopeType = "wholeTree",
    anchorPersonIds = [],
  }) {
    const db = await this._read();
    db.stories = db.stories.filter((entry) => !isExpiredAt(entry.expiresAt));

    const tree = db.trees.find((entry) => entry.id === treeId);
    const user = db.users.find((entry) => entry.id === authorId);
    if (!tree || !user) {
      return null;
    }
    const {allTreeCircle} = ensureCirclesForTree(db, tree);
    const normalizedCircleId = normalizeNullableString(circleId) || allTreeCircle?.id;
    const targetCircle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === normalizedCircleId,
    );
    if (!targetCircle) {
      return null;
    }

    // Validate that submitted anchorPersonIds actually live on this
    // tree — drop stragglers silently rather than 400ing, so the
    // client can be a bit sloppy.
    const treePersonIds = new Set(
      db.persons
        .filter((p) => p.treeId === treeId)
        .map((p) => String(p.id || "")),
    );
    const sanitizedAnchorIds = Array.isArray(anchorPersonIds)
      ? anchorPersonIds
          .map((id) => String(id || "").trim())
          .filter((id) => treePersonIds.has(id))
      : [];

    const story = createStoryRecord({
      treeId,
      authorId,
      authorName,
      authorPhotoUrl,
      type,
      text,
      mediaUrl,
      thumbnailUrl,
      expiresAt,
      circleId: targetCircle.id,
      scopeType,
      anchorPersonIds: sanitizedAnchorIds,
    });
    if (story.type === "text" && !story.text) {
      return false;
    }
    if ((story.type === "image" || story.type === "video") && !story.mediaUrl) {
      return false;
    }

    db.stories.push(story);
    await this._write(db);
    return structuredClone(story);
  }

  async markStoryViewed(storyId, userId) {
    const db = await this._read();
    db.stories = db.stories.filter((entry) => !isExpiredAt(entry.expiresAt));
    const story = db.stories.find((entry) => entry.id === storyId);
    if (!story) {
      await this._write(db);
      return null;
    }

    if (story.authorId === userId) {
      return structuredClone(story);
    }

    story.viewedBy = Array.isArray(story.viewedBy) ? story.viewedBy : [];
    if (!story.viewedBy.includes(userId)) {
      story.viewedBy.push(userId);
      story.updatedAt = nowIso();
      await this._write(db);
    }
    return structuredClone(story);
  }

  async deleteStory(storyId, actorUserId) {
    const db = await this._read();
    const storyIndex = db.stories.findIndex((entry) => entry.id === storyId);
    if (storyIndex < 0) {
      return null;
    }

    const story = db.stories[storyIndex];
    if (story.authorId !== actorUserId) {
      return false;
    }

    db.stories.splice(storyIndex, 1);
    db.storyReactions = ensureStoryReactions(db).filter(
      (entry) => String(entry?.storyId || "").trim() !== storyId,
    );
    await this._write(db);
    return structuredClone(story);
  }

  async toggleStoryReaction({storyId, userId, emoji}) {
    const db = await this._read();
    db.stories = db.stories.filter((entry) => !isExpiredAt(entry.expiresAt));
    const story = db.stories.find((entry) => entry.id === storyId);
    if (!story) {
      return null;
    }
    const normalizedEmoji = normalizeReactionEmoji(emoji);
    if (!normalizedEmoji) {
      return "INVALID_EMOJI";
    }
    const reactions = ensureStoryReactions(db);
    const existingIndex = reactions.findIndex(
      (entry) =>
        String(entry?.storyId || "").trim() === story.id &&
        String(entry?.userId || "").trim() === userId &&
        normalizeReactionEmoji(entry?.emoji) === normalizedEmoji,
    );
    let added = false;
    if (existingIndex >= 0) {
      reactions.splice(existingIndex, 1);
    } else {
      reactions.push({
        storyId: story.id,
        userId,
        emoji: normalizedEmoji,
        createdAt: nowIso(),
      });
      added = true;
    }
    story.updatedAt = nowIso();
    await this._write(db);
    return {
      storyId: story.id,
      authorId: story.authorId,
      reactions: aggregateStoryReactions(db, story.id),
      added,
    };
  }

  /// SPEED-7: общий движок коалесцирующих уведомлений — hit по
  /// coalesce-ключу среди НЕпрочитанных бампает запись (createdAt=now,
  /// readAt сброс + патч плана), miss создаёт новую. PostgresStore
  /// переопределяет табличной реализацией; тексты живут в plan-builder'ах.
  async _applyNotificationCoalescePlan(plan) {
    if (!plan) {
      return null;
    }
    const coalesceKey = computeNotificationCoalesceKey({
      type: plan.type,
      data: plan.keyData,
    });
    const db = await this._read();
    db.notifications = Array.isArray(db.notifications)
      ? db.notifications
      : [];
    const existing = db.notifications.find(
      (entry) =>
        entry.userId === plan.userId &&
        !entry.readAt &&
        computeNotificationCoalesceKey(entry) === coalesceKey,
    );
    if (existing) {
      plan.patchExisting(existing);
      existing.createdAt = nowIso();
      existing.readAt = null;
      await this._write(db);
      return structuredClone(existing);
    }
    const notification = plan.buildRecord();
    db.notifications.push(notification);
    await this._write(db);
    return structuredClone(notification);
  }

  async addStoryReactionNotification(args) {
    return this._applyNotificationCoalescePlan(
      buildStoryReactionNotificationPlan(args || {}),
    );
  }

  /// Substring search across post content + author name. Query is
  /// tokenised using the same Russian-locale shape as chat search,
  /// AND-matched against the lowercased haystack so multi-word
  /// queries like "детский сад" only match posts containing both
  /// terms. Filters to trees the requesting user can access. Returns
  /// the posts ordered newest-first up to `limit`.
  async searchPosts({userId, query, treeId = null, limit = 50} = {}) {
    const db = await this._read();
    const normalizedUserId = String(userId || "").trim();
    const terms = normalizeChatSearchQuery(query);
    if (!normalizedUserId || terms.length === 0) {
      return [];
    }
    const normalizedLimit = Math.min(
      Math.max(1, Number.parseInt(String(limit || "50"), 10) || 50),
      100,
    );
    const normalizedTreeId = normalizeNullableString(treeId);

    // Resolve which trees the user can read content from. Mirrors
    // listPosts visibility — filter happens up front so we don't
    // even score posts the viewer can't open.
    const accessibleTreeIds = new Set(
      (Array.isArray(db.trees) ? db.trees : [])
        .filter((tree) => this._userCanAccessTreeRecord(tree, normalizedUserId))
        .map((tree) => tree.id),
    );
    if (normalizedTreeId && !accessibleTreeIds.has(normalizedTreeId)) {
      return [];
    }

    const circleCache = this._createCircleVisibilityCache();
    const candidates = (Array.isArray(db.posts) ? db.posts : [])
      .filter((post) => {
        // Phase 3.4: a post is visible if ANY of its branchIds is
        // accessible to the viewer (multi-branch publishing), or
        // its legacy treeId is — back-compat for posts created
        // before the branchIds field existed.
        const branchIds = Array.isArray(post.branchIds) ? post.branchIds : [];
        const hasAccessibleBranch = branchIds.some((bid) =>
          accessibleTreeIds.has(bid),
        );
        const hasAccessibleLegacyTree = accessibleTreeIds.has(post.treeId);
        if (!hasAccessibleBranch && !hasAccessibleLegacyTree) return false;
        if (normalizedTreeId) {
          const matchesBranch = branchIds.includes(normalizedTreeId);
          const matchesLegacyTreeId = post.treeId === normalizedTreeId;
          if (!matchesBranch && !matchesLegacyTreeId) return false;
        }
        return this._canUserViewCirclePost(db, post, normalizedUserId, circleCache);
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(
          String(left.createdAt || ""),
        ),
      );

    const results = [];
    for (const post of candidates) {
      if (results.length >= normalizedLimit) break;
      const haystack = normalizeSearchText(
        [post.content, post.authorName].filter(Boolean).join(" "),
      );
      if (terms.every((term) => haystack.includes(term))) {
        results.push(attachPostReactions(db, post));
      }
    }
    return results;
  }

  async findPost(postId) {
    const db = await this._read();
    const post = db.posts.find((entry) => entry.id === postId);
    return post ? attachPostReactions(db, post) : null;
  }

  async createPost({
    treeId,
    branchIds = null,
    authorId,
    authorName,
    authorPhotoUrl = null,
    content,
    imageUrls = [],
    isPublic = false,
    scopeType = "wholeTree",
    anchorPersonIds = [],
    circleId = null,
    clientRequestId = null,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    const user = db.users.find((entry) => entry.id === authorId);
    if (!tree || !user) {
      return null;
    }

    // Идемпотентность как у sendMessage (clientMessageId): клиентский
    // таймаут НЕ отменяет уже летящий запрос, и ретрай без ключа
    // публиковал бы второй экземпляр поста. Повтор от того же автора
    // возвращает уже созданный пост; _deduplicated подсказывает роуту
    // не рассылать уведомления второй раз.
    const normalizedClientRequestId = normalizeNullableString(clientRequestId);
    if (normalizedClientRequestId) {
      const existing = db.posts.find(
        (entry) =>
          entry.authorId === authorId &&
          entry.clientRequestId === normalizedClientRequestId,
      );
      if (existing) {
        return {...attachPostReactions(db, existing), _deduplicated: true};
      }
    }
    const {allTreeCircle} = ensureCirclesForTree(db, tree);
    const normalizedCircleId = normalizeNullableString(circleId) || allTreeCircle?.id;
    const targetCircle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === normalizedCircleId,
    );
    if (!targetCircle) {
      return null;
    }

    // Phase 3.4 multi-branch: validate every requested branchId
    // resolves to a tree the author can access. Without this, an
    // author could publish into someone else's branch by passing
    // a branchId they don't own. The treeId in the URL stays the
    // primary tree (visibility / circle membership inherits from
    // it); branchIds extend the audience to additional branches
    // the author also belongs to.
    let resolvedBranchIds = null;
    if (Array.isArray(branchIds) && branchIds.length > 0) {
      const accessibleTreeIds = new Set(
        db.trees
          .filter((entry) => this._userCanAccessTreeRecord(entry, authorId))
          .map((entry) => entry.id),
      );
      resolvedBranchIds = Array.from(
        new Set(
          branchIds
            .map((value) => normalizeNullableString(value))
            .filter((value) => value && accessibleTreeIds.has(value)),
        ),
      );
      // Always include the primary treeId; the route already
      // verified caller has access to it.
      if (!resolvedBranchIds.includes(treeId)) {
        resolvedBranchIds.unshift(treeId);
      }
    }

    const post = createPostRecord({
      treeId,
      branchIds: resolvedBranchIds,
      authorId,
      authorName,
      authorPhotoUrl,
      content,
      imageUrls,
      isPublic,
      scopeType,
      anchorPersonIds,
      circleId: targetCircle.id,
      clientRequestId: normalizedClientRequestId,
    });
    if (!post.content && post.imageUrls.length === 0) {
      return false;
    }

    db.posts.push(post);
    await this._write(db);
    return attachPostReactions(db, post);
  }

  /// Phase 6.5+ auto-refresh: tree-mutation audience. Used by route
  /// layer для dispatch `tree_mutated` silent notification после
  /// person/relation mutations. Returns userIds (minus actor) что
  /// must refetch tree state.
  ///
  /// Composition (union, deduplicated, actor excluded):
  ///   1. Tree owner (`tree.creatorId`).
  ///   2. Tree members (`tree.memberIds`) — co-editors / branch
  ///      collaborators.
  ///   3. Edit-grant holders на graphPersons в этой tree
  ///      (`graphPersonEditGrants` rows where `revokedAt=null`).
  ///   4. Identity-linked users — `graphPerson.userId !== null`
  ///      means пользователь claimed identity; они owners своих
  ///      cards across trees.
  ///
  /// Privacy fence rationale: `tree_mutated` payload carries только
  /// `{treeId, kind, actorUserId}` — НЕ personId либо diff. Recipient
  /// does GET tree, backend filters visible content per Phase 3.1/
  /// 3.4 visibility rules. Audience being broader does NOT leak
  /// content; broader audience = more refresh pings но zero
  /// information disclosure beyond «something changed».
  async resolveTreeAudienceUserIds(treeId, {excludeUserId = null} = {}) {
    const normalizedTreeId = String(treeId || "").trim();
    if (!normalizedTreeId) return [];
    const normalizedExcluded = excludeUserId
      ? String(excludeUserId).trim()
      : "";
    const db = await this._read();
    const tree = (db.trees || []).find((t) => t.id === normalizedTreeId);
    if (!tree) return [];

    const audience = new Set();
    if (tree.creatorId && tree.creatorId !== normalizedExcluded) {
      audience.add(tree.creatorId);
    }
    const memberIds = Array.isArray(tree.memberIds)
      ? tree.memberIds
      : Array.isArray(tree.members)
          ? tree.members
          : [];
    for (const memberId of memberIds) {
      if (!memberId || memberId === normalizedExcluded) continue;
      audience.add(memberId);
    }

    // GraphPersons на этой tree — derive presence через legacyPersonIds
    // lookup: graphPerson belongs to tree iff any of its legacy person
    // ids lives в db.persons с этим treeId. (graphPerson не carries
    // `legacyTreeIds` directly — это поле живёт только на graphRelation
    // и personIdentity.) Filter is identity-linked owners + edit-grant
    // anchors.
    const personsByTree = new Map();
    for (const p of db.persons || []) {
      if (p.treeId !== normalizedTreeId) continue;
      personsByTree.set(p.id, p);
    }
    const treeGraphPersonIds = new Set();
    for (const gp of db.graphPersons || []) {
      if (gp.deletedAt) continue;
      const legacyPersonIds = Array.isArray(gp.legacyPersonIds)
        ? gp.legacyPersonIds
        : [];
      const inTree = legacyPersonIds.some((id) => personsByTree.has(id));
      if (!inTree) continue;
      treeGraphPersonIds.add(gp.id);
      if (gp.userId && gp.userId !== normalizedExcluded) {
        audience.add(gp.userId);
      }
    }

    for (const grant of db.graphPersonEditGrants || []) {
      if (grant.revokedAt) continue;
      if (!treeGraphPersonIds.has(grant.graphPersonId)) continue;
      if (!grant.granteeUserId) continue;
      if (grant.granteeUserId === normalizedExcluded) continue;
      audience.add(grant.granteeUserId);
    }

    // Phase B Ship 9: extension к семя members когда tree bound
    // (tree.semyaId set). Strictly ADDITIVE — Set union semantics
    // never reduces existing audience. См. SHIP-9-AUDIENCE-DIFF.md
    // для full safety analysis. Edge: pre-Ship-5 семьи without
    // dual-write, либо seyma membership drift из tree.memberIds —
    // catches missing recipients. Soft-deleted семья memberships
    // (hiddenAt set by softDeleteSemya) excluded автоматически.
    if (tree.semyaId) {
      for (const m of db.semyaMembers || []) {
        if (m.semyaId !== tree.semyaId) continue;
        if (m.hiddenAt) continue;
        if (!m.userId) continue;
        if (m.userId === normalizedExcluded) continue;
        audience.add(m.userId);
      }
    }

    return Array.from(audience);
  }

  /// Audience = union of `tree.memberIds` across every branch the
  /// post was fanned out to. Returns the recipient userIds (minus
  /// the author) so the route layer can iterate and call
  /// `createAndDispatchNotification` — that's where push +
  /// realtime + in-app row all converge. Doing the dispatch
  /// inline in `createPost` would bypass push fan-out (the store
  /// has no access to the gateway), which was the original bug
  /// users reported as "уведомления на телефоне не работают".
  async resolvePostAudienceUserIds(postId) {
    const db = await this._read();
    const post = db.posts.find((entry) => entry.id === postId);
    if (!post) return [];
    const branchIds = new Set(
      Array.isArray(post.branchIds) && post.branchIds.length > 0
        ? post.branchIds
        : [post.treeId].filter(Boolean),
    );
    const audienceUserIds = new Set();
    for (const branchId of branchIds) {
      const tree = db.trees.find((entry) => entry.id === branchId);
      if (!tree) continue;
      const memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      for (const memberId of memberIds) {
        if (!memberId) continue;
        if (memberId === post.authorId) continue;
        audienceUserIds.add(memberId);
      }
    }
    return Array.from(audienceUserIds);
  }

  // ── Phase E1: Gatherings (Встречи) ───────────────────────────────
  // CRUD mirrors posts: circle-on-tree visibility, multi-branch fan-out
  // audience. No soft-delete (E1 scope = create + hard delete by author).

  async findGathering(gatheringId) {
    const db = await this._read();
    return db.gatherings.find((entry) => entry.id === gatheringId) || null;
  }

  // SPEED-9 B: db — опциональный уже прочитанный блоб (снимок
  // requireTreeAccess). Без него — собственный _read(), как раньше.
  async listGatherings({treeId = null, viewerUserId = null, db: prefetchedDb = null} = {}) {
    const db = prefetchedDb || (await this._read());
    const circleCache = this._createCircleVisibilityCache();
    return db.gatherings
      .filter((entry) => {
        // Same tree/branch match posts use: if a treeId filter is set,
        // the gathering matches when the requested tree is in its
        // branchIds OR equals its legacy treeId.
        if (treeId) {
          const branchIds = Array.isArray(entry.branchIds)
            ? entry.branchIds
            : [];
          const inBranches = branchIds.includes(treeId);
          const matchesLegacyTreeId = entry.treeId === treeId;
          if (!inBranches && !matchesLegacyTreeId) {
            return false;
          }
        }
        // Circle-on-tree visibility — identical gate to posts.
        if (!this._canUserViewCirclePost(db, entry, viewerUserId, circleCache)) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        // Soonest gathering first (posts sort newest-first; an event
        // list is more useful in chronological-upcoming order).
        String(left.startAt || "").localeCompare(String(right.startAt || "")),
      );
  }

  async createGathering({
    treeId,
    branchIds = null,
    authorId,
    authorName,
    authorPhotoUrl = null,
    title,
    description = null,
    startAt = null,
    endAt = null,
    isAllDay = false,
    place = null,
    imageUrls = [],
    scopeType = "wholeTree",
    anchorPersonIds = [],
    circleId = null,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    const user = db.users.find((entry) => entry.id === authorId);
    if (!tree || !user) {
      return null;
    }
    const {allTreeCircle} = ensureCirclesForTree(db, tree);
    const normalizedCircleId =
      normalizeNullableString(circleId) || allTreeCircle?.id;
    const targetCircle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === normalizedCircleId,
    );
    if (!targetCircle) {
      return null;
    }

    // Phase 3.4-style multi-branch: validate every branchId resolves to
    // a tree the author can access (mirror createPost).
    let resolvedBranchIds = null;
    if (Array.isArray(branchIds) && branchIds.length > 0) {
      const accessibleTreeIds = new Set(
        db.trees
          .filter((entry) => this._userCanAccessTreeRecord(entry, authorId))
          .map((entry) => entry.id),
      );
      resolvedBranchIds = Array.from(
        new Set(
          branchIds
            .map((value) => normalizeNullableString(value))
            .filter((value) => value && accessibleTreeIds.has(value)),
        ),
      );
      if (!resolvedBranchIds.includes(treeId)) {
        resolvedBranchIds.unshift(treeId);
      }
    }

    const gathering = createGatheringRecord({
      treeId,
      branchIds: resolvedBranchIds,
      authorId,
      authorName,
      authorPhotoUrl,
      title,
      description,
      startAt,
      endAt,
      isAllDay,
      place,
      imageUrls,
      scopeType,
      anchorPersonIds,
      circleId: targetCircle.id,
    });
    // A gathering needs at least a name and a start time.
    if (!gathering.title || !gathering.startAt) {
      return false;
    }

    db.gatherings.push(gathering);
    await this._write(db);
    return gathering;
  }

  // Audience = union of tree.memberIds across every branch the gathering
  // was fanned out to, minus the author. Clone of
  // resolvePostAudienceUserIds so the route layer can dispatch
  // gathering_created push/realtime/inbox the same way.
  async resolveGatheringAudienceUserIds(gatheringId) {
    const db = await this._read();
    const gathering = db.gatherings.find((entry) => entry.id === gatheringId);
    if (!gathering) return [];
    const branchIds = new Set(
      Array.isArray(gathering.branchIds) && gathering.branchIds.length > 0
        ? gathering.branchIds
        : [gathering.treeId].filter(Boolean),
    );
    const audienceUserIds = new Set();
    for (const branchId of branchIds) {
      const tree = db.trees.find((entry) => entry.id === branchId);
      if (!tree) continue;
      const memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      for (const memberId of memberIds) {
        if (!memberId) continue;
        if (memberId === gathering.authorId) continue;
        audienceUserIds.add(memberId);
      }
    }
    return Array.from(audienceUserIds);
  }

  async deleteGathering(gatheringId, actorUserId) {
    const db = await this._read();
    const index = db.gatherings.findIndex((entry) => entry.id === gatheringId);
    if (index < 0) {
      return null;
    }
    if (db.gatherings[index].authorId !== actorUserId) {
      return false; // Only the author may delete (route maps → 403).
    }
    const [removed] = db.gatherings.splice(index, 1);
    await this._write(db);
    return removed;
  }

  // Phase E3: UPSERT a viewer's RSVP on a gathering (last-write-wins per
  // userId), mirroring togglePostLike's read → mutate → write → return
  // pattern. Public tallies — the row carries userId (not anonymous).
  // headcount = extra people the responder brings (besides themselves).
  async setGatheringRsvp({
    gatheringId,
    userId,
    status,
    headcount = 0,
    note = null,
  }) {
    const db = await this._read();
    const gathering = db.gatherings.find((entry) => entry.id === gatheringId);
    if (!gathering) {
      return null;
    }
    gathering.rsvps = Array.isArray(gathering.rsvps) ? gathering.rsvps : [];
    const numericHeadcount = Number(headcount);
    const normalizedHeadcount =
        Number.isFinite(numericHeadcount) && numericHeadcount > 0
            ? Math.floor(numericHeadcount)
            : 0;
    const timestamp = nowIso();
    const existing = gathering.rsvps.find((entry) => entry.userId === userId);
    if (existing) {
      existing.status = status;
      existing.headcount = normalizedHeadcount;
      existing.note = normalizeNullableString(note);
      existing.respondedAt = timestamp;
    } else {
      gathering.rsvps.push({
        userId,
        status,
        headcount: normalizedHeadcount,
        note: normalizeNullableString(note),
        respondedAt: timestamp,
      });
    }
    gathering.updatedAt = timestamp;
    await this._write(db);
    return gathering;
  }

  // ── Phase E4: Polls (Опросы) ──────────────────────────────────────
  // Mirrors the gathering methods: circle-on-tree visibility, multi-branch
  // fan-out audience, author-only delete. Voting (submitPollResponse) is a
  // per-user UPSERT cloned from setGatheringRsvp.

  async findPoll(pollId) {
    const db = await this._read();
    return db.polls.find((entry) => entry.id === pollId) || null;
  }

  // SPEED-9 B: db — опциональный уже прочитанный блоб (снимок
  // requireTreeAccess). Без него — собственный _read(), как раньше.
  async listPolls({treeId = null, viewerUserId = null, db: prefetchedDb = null} = {}) {
    const db = prefetchedDb || (await this._read());
    const circleCache = this._createCircleVisibilityCache();
    return db.polls
      .filter((entry) => {
        if (treeId) {
          const branchIds = Array.isArray(entry.branchIds)
            ? entry.branchIds
            : [];
          const inBranches = branchIds.includes(treeId);
          const matchesLegacyTreeId = entry.treeId === treeId;
          if (!inBranches && !matchesLegacyTreeId) {
            return false;
          }
        }
        if (!this._canUserViewCirclePost(db, entry, viewerUserId, circleCache)) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        // Newest poll first (no startAt to order by, unlike gatherings).
        String(right.createdAt || "").localeCompare(
          String(left.createdAt || ""),
        ),
      );
  }

  async createPoll({
    treeId,
    branchIds = null,
    authorId,
    authorName,
    authorPhotoUrl = null,
    question,
    options = [],
    allowMultiple = false,
    closesAt = null,
    imageUrls = [],
    scopeType = "wholeTree",
    anchorPersonIds = [],
    circleId = null,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    const user = db.users.find((entry) => entry.id === authorId);
    if (!tree || !user) {
      return null;
    }
    const {allTreeCircle} = ensureCirclesForTree(db, tree);
    const normalizedCircleId =
      normalizeNullableString(circleId) || allTreeCircle?.id;
    const targetCircle = db.circles.find(
      (entry) => entry.treeId === treeId && entry.id === normalizedCircleId,
    );
    if (!targetCircle) {
      return null;
    }

    let resolvedBranchIds = null;
    if (Array.isArray(branchIds) && branchIds.length > 0) {
      const accessibleTreeIds = new Set(
        db.trees
          .filter((entry) => this._userCanAccessTreeRecord(entry, authorId))
          .map((entry) => entry.id),
      );
      resolvedBranchIds = Array.from(
        new Set(
          branchIds
            .map((value) => normalizeNullableString(value))
            .filter((value) => value && accessibleTreeIds.has(value)),
        ),
      );
      if (!resolvedBranchIds.includes(treeId)) {
        resolvedBranchIds.unshift(treeId);
      }
    }

    const poll = createPollRecord({
      treeId,
      branchIds: resolvedBranchIds,
      authorId,
      authorName,
      authorPhotoUrl,
      question,
      options,
      allowMultiple,
      closesAt,
      imageUrls,
      scopeType,
      anchorPersonIds,
      circleId: targetCircle.id,
    });
    // A poll needs a question and at least two options.
    if (!poll.question || poll.options.length < 2) {
      return false;
    }

    db.polls.push(poll);
    await this._write(db);
    return poll;
  }

  async resolvePollAudienceUserIds(pollId) {
    const db = await this._read();
    const poll = db.polls.find((entry) => entry.id === pollId);
    if (!poll) return [];
    const branchIds = new Set(
      Array.isArray(poll.branchIds) && poll.branchIds.length > 0
        ? poll.branchIds
        : [poll.treeId].filter(Boolean),
    );
    const audienceUserIds = new Set();
    for (const branchId of branchIds) {
      const tree = db.trees.find((entry) => entry.id === branchId);
      if (!tree) continue;
      const memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      for (const memberId of memberIds) {
        if (!memberId) continue;
        if (memberId === poll.authorId) continue;
        audienceUserIds.add(memberId);
      }
    }
    return Array.from(audienceUserIds);
  }

  async deletePoll(pollId, actorUserId) {
    const db = await this._read();
    const index = db.polls.findIndex((entry) => entry.id === pollId);
    if (index < 0) {
      return null;
    }
    if (db.polls[index].authorId !== actorUserId) {
      return false; // Only the author may delete (route maps → 403).
    }
    const [removed] = db.polls.splice(index, 1);
    await this._write(db);
    return removed;
  }

  // UPSERT a viewer's vote (last-write-wins per userId), cloned from
  // setGatheringRsvp. Filters optionIds to existing option ids and, for a
  // single-choice poll, truncates to one.
  async submitPollResponse({pollId, userId, optionIds = []}) {
    const db = await this._read();
    const poll = db.polls.find((entry) => entry.id === pollId);
    if (!poll) {
      return null;
    }
    poll.responses = Array.isArray(poll.responses) ? poll.responses : [];
    const validOptionIds = new Set(
      (Array.isArray(poll.options) ? poll.options : []).map((o) => o.id),
    );
    let cleaned = Array.from(
      new Set(
        (Array.isArray(optionIds) ? optionIds : [])
          .map((id) => String(id || "").trim())
          .filter((id) => validOptionIds.has(id)),
      ),
    );
    if (cleaned.length === 0) {
      return false; // nothing valid chosen (route maps → 400)
    }
    // Single-choice → the server keeps only the first pick.
    if (poll.allowMultiple !== true) {
      cleaned = cleaned.slice(0, 1);
    }
    const timestamp = nowIso();
    const existing = poll.responses.find((entry) => entry.userId === userId);
    if (existing) {
      existing.optionIds = cleaned;
      existing.respondedAt = timestamp;
    } else {
      poll.responses.push({
        userId,
        optionIds: cleaned,
        respondedAt: timestamp,
      });
    }
    poll.updatedAt = timestamp;
    await this._write(db);
    return poll;
  }

  async deletePost(postId, actorUserId) {
    // Ship Q4a (2026-05-28, Ship 30b): soft-delete semantics для
    // posts. Mirror persons pattern (Ship 30) — move snapshot к
    // db.deletedPosts вместо splice. External behavior identical:
    //   • 204 status returned by route
    //   • Post not visible in subsequent listings
    //   • Comments + reactions cleared from active state
    //
    // Snapshot captures full state для restore:
    //   • Post body, media, audience, branchIds
    //   • All comments (postId-scoped)
    //   • postReactions + postCommentReactions (для restored comments)
    //
    // Snapshot row carries: hardDeleteScheduledAt (deletedAt + 30d),
    // earliestHardDelete (deletedAt + 3h floor), deletedByUserId.
    // Restore (restorePost) reverses: push back к db.posts, db.comments,
    // и reaction collections. Phase 3.6 sweep prunes after retention.
    const db = await this._read();
    const postIndex = db.posts.findIndex((entry) => entry.id === postId);
    if (postIndex < 0) {
      return null;
    }

    const post = db.posts[postIndex];
    if (post.authorId !== actorUserId) {
      return false;
    }

    const snapshotPost = structuredClone(post);
    const snapshotComments = db.comments
      .filter((entry) => entry.postId === postId)
      .map((entry) => structuredClone(entry));
    const snapshotPostReactions = ensurePostReactions(db)
      .filter((entry) => String(entry?.postId || "").trim() === postId)
      .map((entry) => structuredClone(entry));
    const removedCommentIds = snapshotComments.map((c) => c.id);
    const removedCommentIdSet = new Set(removedCommentIds);
    const snapshotCommentReactions = removedCommentIds.length > 0
      ? ensurePostCommentReactions(db)
          .filter((entry) =>
            removedCommentIdSet.has(String(entry?.commentId || "").trim()),
          )
          .map((entry) => structuredClone(entry))
      : [];

    db.posts.splice(postIndex, 1);
    db.comments = db.comments.filter((entry) => entry.postId !== postId);
    // Cleanup reaction rows so they don't outlive their post / comment.
    db.postReactions = ensurePostReactions(db).filter(
      (entry) => String(entry?.postId || "").trim() !== postId,
    );
    if (removedCommentIds.length > 0) {
      db.postCommentReactions = ensurePostCommentReactions(db).filter(
        (entry) =>
          !removedCommentIdSet.has(String(entry?.commentId || "").trim()),
      );
    }

    // Ship Q4a: write snapshot row to deletedPosts для 30d restore.
    const nowIsoStr = nowIso();
    const retentionDays = Number(process.env.RODNYA_DELETED_POSTS_RETENTION_DAYS) || 30;
    const floorHours = Number(process.env.RODNYA_DELETED_POSTS_FLOOR_HOURS) || 3;
    const hardDeleteAt = new Date(
      Date.parse(nowIsoStr) + retentionDays * 24 * 3600 * 1000,
    ).toISOString();
    const earliestHardDelete = new Date(
      Date.parse(nowIsoStr) + floorHours * 3600 * 1000,
    ).toISOString();
    db.deletedPosts = Array.isArray(db.deletedPosts) ? db.deletedPosts : [];
    db.deletedPosts.push({
      id: crypto.randomUUID(),
      originalPostId: postId,
      treeId: post.treeId,
      snapshot: snapshotPost,
      commentsSnapshot: snapshotComments,
      postReactionsSnapshot: snapshotPostReactions,
      commentReactionsSnapshot: snapshotCommentReactions,
      deletedAt: nowIsoStr,
      deletedByUserId: actorUserId,
      hardDeleteScheduledAt: hardDeleteAt,
      earliestHardDelete,
      restoredAt: null,
      restoredByUserId: null,
    });

    await this._write(db);
    return structuredClone(post);
  }

  /// Ship Q4a (2026-05-28, Ship 30b): list caller's deleted posts.
  /// Returns rows где caller был author (deletedByUserId match —
  /// они одинаковые because только author может delete own post per
  /// route gate at line 287).
  async listDeletedPostsForUser({userId}) {
    if (!userId || typeof userId !== "string") return [];
    const db = await this._read();
    return (db.deletedPosts || [])
      .filter((entry) => !entry.restoredAt && entry.deletedByUserId === userId)
      .sort((a, b) =>
        String(b.deletedAt || "").localeCompare(String(a.deletedAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  /// Ship Q4a (2026-05-28, Ship 30b): restore post snapshot →
  /// db.posts + comments + reactions. Permission: original author
  /// либо семья owner of post's tree (если tree bound к семья).
  /// Throws:
  ///   • DELETED_POST_NOT_FOUND (404)
  ///   • ALREADY_RESTORED (409)
  ///   • HARD_DELETE_ELAPSED (410)
  ///   • FORBIDDEN (403)
  async restorePost({deletedPostId, actorUserId}) {
    if (!deletedPostId || typeof deletedPostId !== "string") {
      throw new Error("INVALID_INPUT");
    }
    if (!actorUserId) throw new Error("INVALID_ACTOR");

    const db = await this._read();
    const row = (db.deletedPosts || []).find(
      (entry) => entry.id === deletedPostId,
    );
    if (!row) throw new Error("DELETED_POST_NOT_FOUND");
    if (row.restoredAt) throw new Error("ALREADY_RESTORED");
    if (
      row.hardDeleteScheduledAt &&
      Date.parse(row.hardDeleteScheduledAt) < Date.now()
    ) {
      throw new Error("HARD_DELETE_ELAPSED");
    }

    // Permission: actor was original deleter (= author per route gate)
    // либо owner of семья bound к post's tree.
    const isOriginalActor = row.deletedByUserId === actorUserId;
    let isSemyaOwner = false;
    const tree = (db.trees || []).find((t) => t.id === row.treeId);
    if (tree?.semyaId) {
      const semya = (db.semyi || []).find(
        (s) => s.id === tree.semyaId && !s.deletedAt,
      );
      if (semya?.ownerId === actorUserId) {
        isSemyaOwner = true;
      }
    }
    if (!isOriginalActor && !isSemyaOwner) {
      throw new Error("FORBIDDEN");
    }

    // Restore snapshot к live state.
    db.posts = Array.isArray(db.posts) ? db.posts : [];
    db.posts.push(structuredClone(row.snapshot));
    if (Array.isArray(row.commentsSnapshot)) {
      db.comments = Array.isArray(db.comments) ? db.comments : [];
      for (const c of row.commentsSnapshot) {
        db.comments.push(structuredClone(c));
      }
    }
    if (Array.isArray(row.postReactionsSnapshot)) {
      db.postReactions = ensurePostReactions(db);
      for (const r of row.postReactionsSnapshot) {
        db.postReactions.push(structuredClone(r));
      }
    }
    if (Array.isArray(row.commentReactionsSnapshot)) {
      db.postCommentReactions = ensurePostCommentReactions(db);
      for (const r of row.commentReactionsSnapshot) {
        db.postCommentReactions.push(structuredClone(r));
      }
    }

    row.restoredAt = nowIso();
    row.restoredByUserId = actorUserId;

    await this._write(db);
    return structuredClone(row);
  }

  /// Ship Q4a (2026-05-28, Ship 30b): manual hard-purge с 3h floor.
  /// Throws:
  ///   • DELETED_POST_NOT_FOUND (404)
  ///   • ALREADY_RESTORED (409)
  ///   • FLOOR_NOT_MET (409)
  ///   • FORBIDDEN (403)
  async hardDeletePost({deletedPostId, actorUserId}) {
    if (!deletedPostId || typeof deletedPostId !== "string") {
      throw new Error("INVALID_INPUT");
    }
    if (!actorUserId) throw new Error("INVALID_ACTOR");

    const db = await this._read();
    const idx = (db.deletedPosts || []).findIndex(
      (entry) => entry.id === deletedPostId,
    );
    if (idx < 0) throw new Error("DELETED_POST_NOT_FOUND");
    const row = db.deletedPosts[idx];
    if (row.restoredAt) throw new Error("ALREADY_RESTORED");
    if (
      row.earliestHardDelete &&
      Date.parse(row.earliestHardDelete) > Date.now()
    ) {
      throw new Error("FLOOR_NOT_MET");
    }

    // Manual hard-purge: only author (per dispatch — «Manual
    // hard-delete post: only author»).
    if (row.deletedByUserId !== actorUserId) {
      throw new Error("FORBIDDEN");
    }

    db.deletedPosts.splice(idx, 1);
    await this._write(db);
    return {purged: true, deletedPostId};
  }

  async togglePostLike(postId, userId) {
    const db = await this._read();
    const post = db.posts.find((entry) => entry.id === postId);
    if (!post) {
      return null;
    }

    post.likedBy = Array.isArray(post.likedBy) ? post.likedBy : [];
    if (post.likedBy.includes(userId)) {
      post.likedBy = post.likedBy.filter((entry) => entry !== userId);
    } else {
      post.likedBy.push(userId);
    }
    post.updatedAt = nowIso();
    await this._write(db);
    return attachPostReactions(db, post);
  }

  /// Audience presets — pre-computed smart-set personId lists for the
  /// current user in a given tree. Lets the picker offer "Моя семья",
  /// "Близкие" as one-tap shortcuts instead of forcing the user to
  /// build a custom branch list. Resolved at request time so the
  /// numbers stay in sync with the current tree state.
  ///
  /// Returns null when the user has no person-card in the tree (anchor
  /// can't be resolved). The route handler turns that into a graceful
  /// empty-presets response so the UI degrades to "Всё дерево" only.
  async computeAudiencePresets({treeId, userId}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }
    const treePersons = db.persons.filter(
      (person) => person.treeId === treeId,
    );
    const anchor = _resolveAnchorPerson(db, treeId, userId);
    if (!anchor) {
      return {
        anchorPersonId: null,
        presets: [],
      };
    }

    // Build adjacency: personId → list of {otherId, relType}
    const treePersonIds = new Set(treePersons.map((p) => p.id));
    const treeRelations = db.relations.filter(
      (rel) =>
        treePersonIds.has(String(rel.person1Id || "")) &&
        treePersonIds.has(String(rel.person2Id || "")),
    );
    // adjacency[p] entries describe roles OTHERS play toward p, e.g.
    // {otherId: dadId, relType: "parent"} means "dad is my parent".
    // For a relation (person1, person2, relation1to2='parent') —
    // person1 is parent of person2 — we record:
    //   adjacency[person2] += {otherId: person1, relType: 'parent'}
    //   adjacency[person1] += {otherId: person2, relType: 'child'}
    // So we always use the mirror relation when populating.
    const adjacency = new Map();
    for (const id of treePersonIds) {
      adjacency.set(id, []);
    }
    for (const rel of treeRelations) {
      const a = String(rel.person1Id || "");
      const b = String(rel.person2Id || "");
      const aToB = String(rel.relation1to2 || "").trim().toLowerCase();
      const bToA =
        String(rel.relation2to1 || "").trim().toLowerCase() ||
        relationMirror(aToB);
      if (a && b && aToB) {
        // person2 sees person1 in role `aToB`.
        adjacency.get(b).push({otherId: a, relType: aToB});
      }
      if (a && b && bToA) {
        // person1 sees person2 in role `bToA`.
        adjacency.get(a).push({otherId: b, relType: bToA});
      }
    }

    const neighborsByType = (personId, types) => {
      const set = new Set(
        types.map((t) => String(t).toLowerCase()),
      );
      return (adjacency.get(personId) || [])
        .filter((edge) => set.has(edge.relType))
        .map((edge) => edge.otherId);
    };

    // core_family: anchor + parents + spouse/partner + siblings +
    // siblings' partners + nieces/nephews (siblings' children) +
    // children + children's partners.
    const coreSet = new Set([anchor.id]);
    const parents = neighborsByType(anchor.id, ["parent"]);
    parents.forEach((id) => coreSet.add(id));
    const partners = neighborsByType(anchor.id, ["spouse", "partner"]);
    partners.forEach((id) => coreSet.add(id));
    const siblings = neighborsByType(anchor.id, ["sibling"]);
    siblings.forEach((sib) => {
      coreSet.add(sib);
      neighborsByType(sib, ["spouse", "partner"]).forEach((id) =>
        coreSet.add(id),
      );
      neighborsByType(sib, ["child"]).forEach((id) => coreSet.add(id));
    });
    const children = neighborsByType(anchor.id, ["child"]);
    children.forEach((kid) => {
      coreSet.add(kid);
      neighborsByType(kid, ["spouse", "partner"]).forEach((id) =>
        coreSet.add(id),
      );
    });

    // close: core_family + grandparents + grandparents' partners +
    // aunts/uncles + first cousins + grandchildren.
    const closeSet = new Set(coreSet);
    parents.forEach((p) => {
      neighborsByType(p, ["parent"]).forEach((gp) => {
        closeSet.add(gp);
        neighborsByType(gp, ["spouse", "partner"]).forEach((id) =>
          closeSet.add(id),
        );
      });
      neighborsByType(p, ["sibling"]).forEach((auntUncle) => {
        closeSet.add(auntUncle);
        neighborsByType(auntUncle, ["spouse", "partner"]).forEach((id) =>
          closeSet.add(id),
        );
        neighborsByType(auntUncle, ["child"]).forEach((cousin) =>
          closeSet.add(cousin),
        );
      });
    });
    children.forEach((kid) => {
      neighborsByType(kid, ["child"]).forEach((id) => closeSet.add(id));
    });

    return {
      anchorPersonId: anchor.id,
      presets: [
        {
          key: "core_family",
          label: "Моя семья",
          description: "Родители, партнёр, сёстры/братья и племянники",
          personIds: Array.from(coreSet),
        },
        {
          key: "close",
          label: "Близкие",
          description: "Семья и круг тех, с кем общаетесь чаще остальных",
          personIds: Array.from(closeSet),
        },
      ],
    };
  }

  /// Push a "X reacted to your post" notification, coalescing unread
  /// entries for the same (recipient, post, actor) tuple — multiple
  /// reactions don't spam the inbox. Returns the notification record
  /// or null if skipped (self-react or already-unread).
  async addPostReactionNotification(args) {
    return this._applyNotificationCoalescePlan(
      buildPostReactionNotificationPlan(args || {}),
    );
  }

  /// Same shape as [addPostReactionNotification] but scoped to a
  /// comment. Notifies the comment author. Post author is left alone
  /// — they already get a notification stream when their own comments
  /// get reacted to (separate flow).
  async addCommentReactionNotification(args) {
    return this._applyNotificationCoalescePlan(
      buildCommentReactionNotificationPlan(args || {}),
    );
  }

  /// Notify the parent comment author that someone replied to their
  /// comment. Distinct from comment_reaction so the inbox can render a
  /// dedicated "ответил на ваш комментарий" string and route directly
  /// to the comment thread instead of the reaction overlay.
  ///
  /// We dedupe on (parentCommentId, actorUserId) for unread entries —
  /// a single user posting two replies in quick succession refreshes
  /// the existing entry rather than fanning out two pings.
  async addCommentReplyNotification(args) {
    return this._applyNotificationCoalescePlan(
      buildCommentReplyNotificationPlan(args || {}),
    );
  }

  async togglePostReaction({postId, userId, emoji}) {
    const db = await this._read();
    const post = db.posts.find((entry) => entry.id === postId);
    if (!post) {
      return null;
    }
    const normalizedEmoji = normalizeReactionEmoji(emoji);
    if (!normalizedEmoji) {
      return "INVALID_EMOJI";
    }
    const reactions = ensurePostReactions(db);
    const existingIndex = reactions.findIndex(
      (entry) =>
        String(entry?.postId || "").trim() === post.id &&
        String(entry?.userId || "").trim() === userId &&
        normalizeReactionEmoji(entry?.emoji) === normalizedEmoji,
    );
    let added = false;
    if (existingIndex >= 0) {
      reactions.splice(existingIndex, 1);
    } else {
      reactions.push({
        postId: post.id,
        userId,
        emoji: normalizedEmoji,
        createdAt: nowIso(),
      });
      added = true;
    }
    post.updatedAt = nowIso();
    await this._write(db);
    return {
      postId: post.id,
      reactions: aggregatePostReactions(db, post.id),
      added,
    };
  }

  async togglePostCommentReaction({postId, commentId, userId, emoji}) {
    const db = await this._read();
    const comment = db.comments.find(
      (entry) => entry.id === commentId && entry.postId === postId,
    );
    if (!comment) {
      return null;
    }
    const normalizedEmoji = normalizeReactionEmoji(emoji);
    if (!normalizedEmoji) {
      return "INVALID_EMOJI";
    }
    const reactions = ensurePostCommentReactions(db);
    const existingIndex = reactions.findIndex(
      (entry) =>
        String(entry?.commentId || "").trim() === comment.id &&
        String(entry?.userId || "").trim() === userId &&
        normalizeReactionEmoji(entry?.emoji) === normalizedEmoji,
    );
    let added = false;
    if (existingIndex >= 0) {
      reactions.splice(existingIndex, 1);
    } else {
      reactions.push({
        commentId: comment.id,
        userId,
        emoji: normalizedEmoji,
        createdAt: nowIso(),
      });
      added = true;
    }
    await this._write(db);
    return {
      commentId: comment.id,
      postId: comment.postId,
      reactions: aggregatePostCommentReactions(db, comment.id),
      added,
    };
  }

  async listPostComments(postId, {db: prefetchedDb = null} = {}) {
    const db = prefetchedDb || (await this._read());
    const usersById = buildUsersByIdMap(db);
    const entries = db.comments.filter((entry) => entry.postId === postId);
    return hydrateAndSortPostComments(db, entries, usersById);
  }

  /// SPEED-9 D: батч-сиблинг listPostComments — один _read() на СПИСОК
  /// постов вместо одного на каждый. До этого GET /v1/posts делал
  /// Promise.all(page.map(post => listPostComments(post.id))) — K
  /// независимых _read() на странице из K постов (на PostgresStore
  /// каждый — structuredClone всего состояния + 2 SQL round-trip'а,
  /// см. docs/speed_measurement.md SPEED-9). Возвращает Map<postId,
  /// comments[]>, где comments[] для каждого postId побайтово совпадает
  /// с тем, что вернул бы listPostComments(postId) на том же db —
  /// общий hydrateAndSortPostComments гарантирует это, а не просто
  /// "похожую" реализацию.
  async listPostCommentsForPosts(postIds, {db: prefetchedDb = null} = {}) {
    const db = prefetchedDb || (await this._read());
    const usersById = buildUsersByIdMap(db);
    const idSet = new Set(postIds);
    const entriesByPost = new Map();
    for (const id of idSet) {
      entriesByPost.set(id, []);
    }
    for (const entry of db.comments) {
      if (idSet.has(entry.postId)) {
        entriesByPost.get(entry.postId).push(entry);
      }
    }
    const result = new Map();
    for (const [postId, entries] of entriesByPost) {
      result.set(postId, hydrateAndSortPostComments(db, entries, usersById));
    }
    return result;
  }

  /// Lookup a single comment scoped to a post. Used by the route layer
  /// to fan out reply notifications without re-fetching the whole list.
  async findPostComment({postId, commentId}) {
    const db = await this._read();
    const trimmedId = String(commentId || "").trim();
    if (!trimmedId) return null;
    const comment = db.comments.find(
      (entry) => entry.id === trimmedId && entry.postId === postId,
    );
    return comment ? structuredClone(comment) : null;
  }

  async addPostComment({
    postId,
    authorId,
    authorName,
    authorPhotoUrl = null,
    content,
    parentCommentId = null,
  }) {
    const db = await this._read();
    const post = db.posts.find((entry) => entry.id === postId);
    const user = db.users.find((entry) => entry.id === authorId);
    if (!post || !user) {
      return null;
    }

    // Resolve parent for two-level threading. If the caller pointed at a
    // reply, climb to the top-level comment so the chain stays flat. If
    // the parent doesn't exist (or belongs to another post), treat the
    // comment as top-level rather than rejecting — kinder UX in the
    // race-condition where the parent was deleted between fetch and post.
    let resolvedParentId = null;
    if (parentCommentId) {
      const parent = db.comments.find(
        (entry) =>
          entry.id === String(parentCommentId).trim() &&
          entry.postId === postId,
      );
      if (parent) {
        resolvedParentId = parent.parentCommentId
          ? String(parent.parentCommentId).trim() || parent.id
          : parent.id;
      }
    }

    const comment = createCommentRecord({
      postId,
      authorId,
      authorName,
      authorPhotoUrl,
      content,
      parentCommentId: resolvedParentId,
    });
    if (!comment.content) {
      return false;
    }

    db.comments.push(comment);
    await this._write(db);
    return attachCommentReactions(db, comment);
  }

  async deletePostComment({postId, commentId, actorUserId}) {
    const db = await this._read();
    const commentIndex = db.comments.findIndex((entry) => {
      return entry.id === commentId && entry.postId === postId;
    });
    if (commentIndex < 0) {
      return null;
    }

    const comment = db.comments[commentIndex];
    const post = db.posts.find((entry) => entry.id === postId);
    if (!post) {
      return null;
    }

    const canDelete =
      comment.authorId === actorUserId || post.authorId === actorUserId;
    if (!canDelete) {
      return false;
    }

    db.comments.splice(commentIndex, 1);
    db.postCommentReactions = ensurePostCommentReactions(db).filter(
      (entry) => String(entry?.commentId || "").trim() !== commentId,
    );
    await this._write(db);
    return structuredClone(comment);
  }

  _findStoredChat(db, chatId) {
    return db.chats.find((entry) => entry.id === chatId) || null;
  }

  _resolveChat(db, chatId) {
    const normalizedChatId = String(chatId || "").trim();
    const storedChat = this._findStoredChat(db, normalizedChatId);
    if (storedChat) {
      return storedChat;
    }

    const directParticipants = parseDirectParticipantsFromChatId(
      normalizedChatId,
    );
    if (directParticipants.length === 2) {
      const canonicalChatId = directParticipants.join("_");
      const storedCanonicalChat = this._findStoredChat(db, canonicalChatId);
      if (storedCanonicalChat) {
        return storedCanonicalChat;
      }
      const relatedMessages = db.messages
        .filter((entry) => {
          return (
            entry.chatId === normalizedChatId ||
            entry.chatId === canonicalChatId
          );
        })
        .sort((left, right) =>
          String(left.timestamp || "").localeCompare(String(right.timestamp || "")),
        );
      const firstTimestamp = relatedMessages[0]?.timestamp || nowIso();
      const lastTimestamp =
        relatedMessages[relatedMessages.length - 1]?.timestamp || firstTimestamp;
      return {
        id: canonicalChatId,
        type: "direct",
        participantIds: directParticipants,
        title: null,
        createdBy: directParticipants[0],
        treeId: null,
        branchRootPersonIds: [],
        createdAt: firstTimestamp,
        updatedAt: lastTimestamp,
      };
    }

    return null;
  }

  _resolveEquivalentChatIds(chatId, resolvedChat = null) {
    const relatedChatIds = new Set();
    const normalizedChatId = String(chatId || "").trim();
    if (normalizedChatId) {
      relatedChatIds.add(normalizedChatId);
    }

    const directParticipants = parseDirectParticipantsFromChatId(normalizedChatId);
    if (directParticipants.length === 2) {
      relatedChatIds.add(directParticipants.join("_"));
    }

    if (resolvedChat?.id) {
      relatedChatIds.add(String(resolvedChat.id).trim());
    }

    return relatedChatIds;
  }

  async findChat(chatId) {
    const db = await this._read();
    const chat = this._resolveChat(db, chatId);
    return chat ? structuredClone(chat) : null;
  }

  _findChatDraft(db, {userId, chatId}) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedChatId = String(chatId || "").trim();
    if (!normalizedUserId || !normalizedChatId) {
      return null;
    }
    return (
      (Array.isArray(db.chatDrafts) ? db.chatDrafts : []).find((entry) => {
        return entry.userId === normalizedUserId && entry.chatId === normalizedChatId;
      }) || null
    );
  }

  _canAccessChatDraft(chat, userId) {
    return Boolean(
      chat &&
        String(userId || "").trim() &&
        normalizeParticipantIds(chat.participantIds).includes(String(userId).trim()),
    );
  }

  async getChatDraft({userId, chatId}) {
    const db = await this._read();
    const chat = this._resolveChat(db, chatId);
    if (!this._canAccessChatDraft(chat, userId)) {
      return null;
    }
    const draft = this._findChatDraft(db, {userId, chatId: chat.id});
    return draft ? structuredClone(draft) : null;
  }

  async listChatDrafts(userId) {
    const db = await this._read();
    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return [];
    }
    return (Array.isArray(db.chatDrafts) ? db.chatDrafts : [])
      .filter((draft) => {
        if (draft.userId !== normalizedUserId || !String(draft.text || "").trim()) {
          return false;
        }
        const chat = this._resolveChat(db, draft.chatId);
        return this._canAccessChatDraft(chat, normalizedUserId);
      })
      .sort((left, right) =>
        String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")),
      )
      .map((draft) => structuredClone(draft));
  }

  async saveChatDraft({userId, chatId, text}) {
    return this._mutate((db, skip) => {
      const chat = this._resolveChat(db, chatId);
      if (!this._canAccessChatDraft(chat, userId)) {
        return skip(null);
      }

      db.chatDrafts = Array.isArray(db.chatDrafts) ? db.chatDrafts : [];
      const normalizedUserId = String(userId || "").trim();
      const normalizedText = String(text || "");
      const existingIndex = db.chatDrafts.findIndex((entry) => {
        return entry.userId === normalizedUserId && entry.chatId === chat.id;
      });

      if (!normalizedText.trim()) {
        if (existingIndex >= 0) {
          db.chatDrafts.splice(existingIndex, 1);
          return null;
        }
        return skip(null);
      }

      const draft = createChatDraftRecord({
        userId: normalizedUserId,
        chatId: chat.id,
        text: normalizedText,
      });
      if (existingIndex >= 0) {
        db.chatDrafts[existingIndex] = draft;
      } else {
        db.chatDrafts.push(draft);
      }
      return structuredClone(draft);
    });
  }

  async clearChatDraft({userId, chatId}) {
    return this.saveChatDraft({userId, chatId, text: ""});
  }

  _canAccessChatPin(chat, userId) {
    return Boolean(
      chat &&
        String(userId || "").trim() &&
        normalizeParticipantIds(chat.participantIds).includes(String(userId).trim()),
    );
  }

  _findChatPin(db, chat) {
    if (!chat) {
      return null;
    }
    const relatedChatIds = this._resolveEquivalentChatIds(chat.id, chat);
    return (
      ensureChatPins(db).find((entry) => {
        return relatedChatIds.has(String(entry?.chatId || "").trim());
      }) || null
    );
  }

  _findMessageForChatPin(db, {chat, messageId}) {
    if (!chat) {
      return null;
    }
    const normalizedMessageId = String(messageId || "").trim();
    if (!normalizedMessageId) {
      return null;
    }
    const relatedChatIds = this._resolveEquivalentChatIds(chat.id, chat);
    return (
      db.messages.find((entry) => {
        return (
          String(entry?.id || "").trim() === normalizedMessageId &&
          relatedChatIds.has(String(entry?.chatId || "").trim())
        );
      }) || null
    );
  }

  async getChatPinnedMessage({userId, chatId}) {
    // Чтение с opportunistic-записями (TTL-purge + чистка осиротевшего
    // пина) — через _mutate, иначе его stale whole-doc запись может затереть
    // конкурентную мутацию (SPEED-2 сделал фан-аут конкурентным). skip()
    // держит обычный путь (ничего не протухло) чистым чтением без записи.
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!this._canAccessChatPin(chat, userId)) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return null;
        }
        return skip(null);
      }

      const pin = this._findChatPin(db, chat);
      if (!pin) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return null;
        }
        return skip(null);
      }

      const message = this._findMessageForChatPin(db, {
        chat,
        messageId: pin.messageId,
      });
      if (!message) {
        db.chatPins = ensureChatPins(db).filter(
          (entry) => String(entry?.messageId || "").trim() !== pin.messageId,
        );
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
        }
        return null;
      }

      const freshPin = {
        ...createChatPinRecord({
          chatId: chat.id,
          message,
          pinnedBy: pin.pinnedBy || userId,
        }),
        pinnedAt: pin.pinnedAt || nowIso(),
      };
      if (purgedChatIds.size > 0) {
        this._syncChatUpdatedAt(db, purgedChatIds);
        return structuredClone(freshPin);
      }
      return skip(structuredClone(freshPin));
    });
  }

  async pinChatMessage({userId, chatId, messageId}) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!this._canAccessChatPin(chat, userId)) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return false;
        }
        return skip(false);
      }

      const message = this._findMessageForChatPin(db, {chat, messageId});
      if (!message) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return null;
        }
        return skip(null);
      }

      const relatedChatIds = this._resolveEquivalentChatIds(chat.id, chat);
      db.chatPins = ensureChatPins(db).filter((entry) => {
        return !relatedChatIds.has(String(entry?.chatId || "").trim());
      });
      const pin = createChatPinRecord({
        chatId: chat.id,
        message,
        pinnedBy: userId,
      });
      db.chatPins.push(pin);
      if (purgedChatIds.size > 0) {
        this._syncChatUpdatedAt(db, purgedChatIds);
      }
      return structuredClone(pin);
    });
  }

  async clearChatPinnedMessage({userId, chatId}) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!this._canAccessChatPin(chat, userId)) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return false;
        }
        return skip(false);
      }

      const relatedChatIds = this._resolveEquivalentChatIds(chat.id, chat);
      const pins = ensureChatPins(db);
      const nextPins = pins.filter((entry) => {
        return !relatedChatIds.has(String(entry?.chatId || "").trim());
      });
      const changed = nextPins.length !== pins.length;
      db.chatPins = nextPins;
      if (purgedChatIds.size > 0) {
        this._syncChatUpdatedAt(db, purgedChatIds);
      }
      if (changed || purgedChatIds.size > 0) {
        return true;
      }
      return skip(true);
    });
  }

  // BUG 3: фото граф-персоны (person.photoUrl), поставленное человеку ДО
  // регистрации, и аватар user-аккаунта (profile.photoUrl) — разные поля.
  // Чат/звонок резолвят аватар из user-профиля (пустой у только что
  // вошедшего) → плейсхолдер «А», хотя на дереве фото есть. Фолбэк: если
  // у user аватара нет, берём фото СВЯЗАННОЙ граф-персоны — по прямой
  // связи person.userId и через identity.claimedByUserId/userId (обе
  // надёжно покрывают линк user→person).
  _resolveAvatarUrlForUser(db, userId, profilePhotoUrl) {
    const direct = normalizeNullableString(profilePhotoUrl);
    if (direct) {
      return direct;
    }
    const normalizedUserId = normalizeNullableString(userId);
    if (!normalizedUserId) {
      return null;
    }
    const persons = Array.isArray(db.persons) ? db.persons : [];
    const personPhoto = (person) =>
      normalizeNullableString(person?.primaryPhotoUrl || person?.photoUrl);

    for (const person of persons) {
      if (person && person.userId === normalizedUserId) {
        const photo = personPhoto(person);
        if (photo) {
          return photo;
        }
      }
    }

    const identities = Array.isArray(db.personIdentities)
      ? db.personIdentities
      : [];
    const linkedIdentityIds = new Set(
      identities
        .filter(
          (identity) =>
            normalizeNullableString(identity?.claimedByUserId) ===
              normalizedUserId ||
            normalizeNullableString(identity?.userId) === normalizedUserId,
        )
        .map((identity) => identity.id),
    );
    if (linkedIdentityIds.size > 0) {
      for (const person of persons) {
        if (person && linkedIdentityIds.has(person.identityId)) {
          const photo = personPhoto(person);
          if (photo) {
            return photo;
          }
        }
      }
    }
    return null;
  }

  _buildChatDetails(db, chat) {
    const normalizedChat = structuredClone(chat);
    const participantIds = normalizeParticipantIds(chat.participantIds || []);
    const participants = participantIds
      .map((participantId) => {
        const user = db.users.find((entry) => entry.id === participantId);
        if (!user) {
          return null;
        }
        return {
          userId: user.id,
          displayName:
            user.profile?.displayName ||
            composeDisplayNameFromProfile(user.profile) ||
            user.email ||
            "Пользователь",
          // BUG 3: пустой user-аватар → фолбэк на фото связанной граф-персоны.
          photoUrl: this._resolveAvatarUrlForUser(
            db,
            user.id,
            user.profile?.photoUrl,
          ),
          // Last time the user was seen online. Updated on socket
          // disconnect via markUserSeenAt() — used by clients to render
          // "был(а) N минут назад" subtitles. Falls back to user updated/
          // created timestamp when never online.
          lastSeenAt:
            user.lastSeenAt || user.updatedAt || user.createdAt || null,
        };
      })
      .filter(Boolean);
    const branchRoots = Array.isArray(chat.branchRootPersonIds)
      ? chat.branchRootPersonIds
          .map((personId) => {
            const person = db.persons.find((entry) => {
              return entry.id === personId && entry.treeId === chat.treeId;
            });
            if (!person) {
              return null;
            }
            return {
              personId: person.id,
              name: person.name || "Без имени",
              photoUrl: person.photoUrl || null,
            };
          })
          .filter(Boolean)
      : [];

    return {
      chat: normalizedChat,
      participants,
      branchRoots,
    };
  }

  async getChatDetails(chatId) {
    const db = await this._read();
    const chat = this._resolveChat(db, chatId);
    if (!chat) {
      return null;
    }
    return this._buildChatDetails(db, chat);
  }

  async ensureDirectChat(userIdA, userIdB) {
    const db = await this._read();
    const participantIds = normalizeParticipantIds([userIdA, userIdB]);
    if (participantIds.length !== 2) {
      return null;
    }

    const missingUser = participantIds.some((participantId) => {
      return !db.users.some((entry) => entry.id === participantId);
    });
    if (missingUser) {
      return undefined;
    }

    const chatId = participantIds.join("_");
    let chat = this._findStoredChat(db, chatId);
    if (!chat) {
      chat = createChatRecord({
        id: chatId,
        type: "direct",
        participantIds,
        createdBy: participantIds[0],
      });
      db.chats.push(chat);
      await this._write(db);
    }

    return structuredClone(chat);
  }

  async createGroupChat({
    title,
    participantIds,
    createdBy,
    treeId = null,
    branchRootPersonIds = [],
  }) {
    const db = await this._read();
    const normalizedParticipants = normalizeParticipantIds([
      createdBy,
      ...(Array.isArray(participantIds) ? participantIds : []),
    ]);

    if (!normalizedParticipants.includes(createdBy) ||
        normalizedParticipants.length < 3) {
      return false;
    }

    const missingUser = normalizedParticipants.some((participantId) => {
      return !db.users.some((entry) => entry.id === participantId);
    });
    if (missingUser) {
      return null;
    }

    const chat = createChatRecord({
      id: `chat_${crypto.randomUUID()}`,
      type: "group",
      participantIds: normalizedParticipants,
      title,
      createdBy,
      treeId,
      branchRootPersonIds,
    });
    db.chats.push(chat);
    await this._write(db);
    return structuredClone(chat);
  }

  async updateGroupChat(chatId, {title, photoUrl}) {
    const db = await this._read();
    const chat = this._findStoredChat(db, chatId);
    if (!chat) {
      return null;
    }
    if (chat.type !== "group") {
      return false;
    }

    const hasTitlePatch = title !== undefined;
    const hasPhotoPatch = photoUrl !== undefined;
    if (!hasTitlePatch && !hasPhotoPatch) {
      return undefined;
    }

    if (hasTitlePatch) {
      const normalizedTitle = normalizeNullableString(title);
      if (!normalizedTitle) {
        return undefined;
      }
      chat.title = normalizedTitle;
    }
    if (hasPhotoPatch) {
      const normalizedPhotoUrl = normalizeNullableString(photoUrl);
      if (!normalizedPhotoUrl) {
        return undefined;
      }
      chat.photoUrl = normalizedPhotoUrl;
    }

    chat.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(chat);
  }

  async addGroupParticipants(chatId, participantIds) {
    const db = await this._read();
    const chat = this._findStoredChat(db, chatId);
    if (!chat) {
      return null;
    }
    if (chat.type !== "group") {
      return false;
    }

    const nextParticipantIds = normalizeParticipantIds([
      ...(chat.participantIds || []),
      ...(Array.isArray(participantIds) ? participantIds : []),
    ]);
    if (nextParticipantIds.length <= normalizeParticipantIds(chat.participantIds).length) {
      return undefined;
    }

    const missingUser = nextParticipantIds.some((participantId) => {
      return !db.users.some((entry) => entry.id === participantId);
    });
    if (missingUser) {
      return null;
    }

    chat.participantIds = nextParticipantIds;
    chat.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(chat);
  }

  async removeGroupParticipant(chatId, participantId) {
    const db = await this._read();
    const chat = this._findStoredChat(db, chatId);
    if (!chat) {
      return null;
    }
    if (chat.type !== "group") {
      return false;
    }

    const normalizedParticipantId = String(participantId || "").trim();
    if (!normalizedParticipantId) {
      return undefined;
    }

    const currentParticipantIds = normalizeParticipantIds(chat.participantIds || []);
    if (!currentParticipantIds.includes(normalizedParticipantId)) {
      return undefined;
    }

    const nextParticipantIds = currentParticipantIds.filter((entry) => {
      return entry !== normalizedParticipantId;
    });
    if (nextParticipantIds.length < 3) {
      return undefined;
    }

    chat.participantIds = nextParticipantIds;
    chat.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(chat);
  }

  // G2: самовыход из группового чата. Отдельный метод (не reuse
  // removeGroupParticipant) намеренно: у remove есть пол в 3 участника
  // — нельзя ужать группу ниже жизнеспособной. Но ПОКИНУТЬ юзер обязан
  // мочь всегда (Telegram-паритет), поэтому здесь пола нет: убираем
  // звонящего из любого размера. Возвращает: null — чат не найден,
  // false — это не group-чат, undefined — звонящего нет в участниках,
  // иначе обновлённый чат.
  async leaveGroupChat(chatId, userId) {
    const db = await this._read();
    const chat = this._findStoredChat(db, chatId);
    if (!chat) {
      return null;
    }
    if (chat.type !== "group") {
      return false;
    }

    const normalizedUserId = String(userId || "").trim();
    if (!normalizedUserId) {
      return undefined;
    }

    const currentParticipantIds = normalizeParticipantIds(chat.participantIds || []);
    if (!currentParticipantIds.includes(normalizedUserId)) {
      return undefined;
    }

    chat.participantIds = currentParticipantIds.filter((entry) => {
      return entry !== normalizedUserId;
    });
    chat.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(chat);
  }

  async createBranchChat({
    treeId,
    branchRootPersonIds,
    createdBy,
    title,
  }) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const treePersons = db.persons.filter((entry) => entry.treeId === treeId);
    const personIds = new Set(treePersons.map((entry) => entry.id));
    const normalizedRoots = normalizeParticipantIds(branchRootPersonIds).filter(
      (personId) => personIds.has(personId),
    );
    if (normalizedRoots.length === 0) {
      return null;
    }

    const treeRelations = db.relations.filter((entry) => entry.treeId === treeId);
    const snapshot = buildTreeGraphSnapshot({
      treeId,
      persons: treePersons,
      relations: treeRelations,
      viewerPersonId: null,
    });
    const branchBlock =
      chooseBranchBlockForPerson(snapshot, normalizedRoots[0]) || null;
    const visiblePersonIds = new Set(
      branchBlock?.memberPersonIds || normalizedRoots,
    );

    const participantIds = normalizeParticipantIds([
      createdBy,
      ...treePersons
        .filter((entry) => visiblePersonIds.has(entry.id))
        .map((entry) => String(entry.userId || "").trim())
        .filter(Boolean),
    ]);
    if (!participantIds.includes(createdBy) || participantIds.length < 2) {
      return false;
    }

    const normalizedTitle = normalizeNullableString(title);
    const existingChat = db.chats.find((entry) => {
      return (
        entry.type === "branch" &&
        entry.treeId === treeId &&
        sameNormalizedIds(entry.branchRootPersonIds || [], normalizedRoots)
      );
    });
    if (existingChat) {
      let hasChanges = false;
      if (!sameNormalizedIds(existingChat.participantIds || [], participantIds)) {
        existingChat.participantIds = participantIds;
        hasChanges = true;
      }
      if (normalizedTitle && normalizedTitle !== existingChat.title) {
        existingChat.title = normalizedTitle;
        hasChanges = true;
      }
      if (hasChanges) {
        existingChat.updatedAt = nowIso();
        await this._write(db);
      }
      return structuredClone(existingChat);
    }

    const chat = createChatRecord({
      id: `chat_${crypto.randomUUID()}`,
      type: "branch",
      participantIds,
      title: normalizedTitle,
      createdBy,
      treeId,
      branchRootPersonIds:
        branchBlock?.rootUnitId ? normalizedRoots : normalizedRoots,
    });
    db.chats.push(chat);
    await this._write(db);
    return structuredClone(chat);
  }

  async listChatMessages(chatId, {limit = null, beforeId = null, afterId = null} = {}) {
    const db = await this._read();
    const purgedChatIds = this._purgeExpiredMessages(db);
    if (purgedChatIds.size > 0) {
      // Ответ уже отфильтрован in-memory; физическая зачистка — фоновым
      // атомарным sweep'ом, не stale-записью с read-пути.
      this._syncChatUpdatedAt(db, purgedChatIds);
      this._schedulePurgeSweep();
    }
    const chat = this._resolveChat(db, chatId);
    if (!chat) {
      return [];
    }
    const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);
    const sortedMessages = db.messages
      .filter((message) => relatedChatIds.has(String(message.chatId || "").trim()))
      .sort(compareChatMessagesDescending);

    const normalizedBeforeId = normalizeNullableString(beforeId);
    const normalizedAfterId = normalizeNullableString(afterId);
    let pageSource = sortedMessages;
    if (normalizedBeforeId) {
      const cursorIndex = sortedMessages.findIndex(
        (message) => String(message?.id || "").trim() === normalizedBeforeId,
      );
      pageSource = cursorIndex < 0 ? [] : sortedMessages.slice(cursorIndex + 1);
    } else if (normalizedAfterId) {
      const cursorIndex = sortedMessages.findIndex(
        (message) => String(message?.id || "").trim() === normalizedAfterId,
      );
      pageSource = cursorIndex < 0 ? [] : sortedMessages.slice(0, cursorIndex);
    }

    const normalizedLimit = Number.isFinite(Number(limit))
      ? Math.max(0, Math.floor(Number(limit)))
      : null;
    return (normalizedLimit === null ? pageSource : pageSource.slice(0, normalizedLimit))
      .map((message) => attachMessageReactions(db, message));
  }

  async searchChatMessages({
    userId,
    query,
    chatId = null,
    limit = 50,
  } = {}) {
    const db = await this._read();
    const purgedChatIds = this._purgeExpiredMessages(db);
    if (purgedChatIds.size > 0) {
      this._syncChatUpdatedAt(db, purgedChatIds);
      this._schedulePurgeSweep();
    }

    const normalizedUserId = String(userId || "").trim();
    const terms = normalizeChatSearchQuery(query);
    if (!normalizedUserId || terms.length === 0) {
      return [];
    }

    const normalizedLimit = Math.min(
      Math.max(1, Number.parseInt(String(limit || "50"), 10) || 50),
      100,
    );
    const normalizedChatId = normalizeNullableString(chatId);
    let allowedChatIds = null;
    if (normalizedChatId) {
      const chat = this._resolveChat(db, normalizedChatId);
      if (!chat || !normalizeParticipantIds(chat.participantIds).includes(normalizedUserId)) {
        return [];
      }
      allowedChatIds = this._resolveEquivalentChatIds(normalizedChatId, chat);
    }

    const chatsById = new Map(
      (Array.isArray(db.chats) ? db.chats : [])
        .map((chat) => [String(chat?.id || "").trim(), chat])
        .filter(([id]) => id),
    );
    const results = [];
    const messages = (Array.isArray(db.messages) ? db.messages : [])
      .slice()
      .sort(compareChatMessagesDescending);

    for (const message of messages) {
      if (results.length >= normalizedLimit) {
        break;
      }
      const messageChatId = String(message?.chatId || "").trim();
      if (!messageChatId || (allowedChatIds && !allowedChatIds.has(messageChatId))) {
        continue;
      }
      const chat = chatsById.get(messageChatId);
      const participantIds = normalizeParticipantIds(
        Array.isArray(message?.participants) && message.participants.length > 0
          ? message.participants
          : chat?.participantIds,
      );
      if (!participantIds.includes(normalizedUserId)) {
        continue;
      }
      const expiresAt = normalizeOptionalIsoTimestamp(message?.expiresAt);
      if (expiresAt && expiresAt <= nowIso()) {
        continue;
      }
      const haystack = chatMessageSearchHaystack(message);
      if (!terms.every((term) => haystack.includes(term))) {
        continue;
      }
      results.push({
        messageId: message.id,
        chatId: messageChatId,
        senderId: message.senderId || "",
        senderName: message.senderName || "Участник",
        text: message.text || "",
        snippet: buildChatSearchSnippet(message, terms),
        matchedAt: message.timestamp,
      });
    }

    return structuredClone(results);
  }

  async addChatMessage({
    chatId,
    senderId,
    text,
    attachments = [],
    mediaUrls = [],
    imageUrl = null,
    clientMessageId = null,
    expiresAt = null,
    replyTo = null,
    call = null,
  }) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      let chat = this._resolveChat(db, chatId);
      if (!chat) {
        return skip(null);
      }

      if (!db.chats.some((entry) => entry.id === chat.id)) {
        db.chats.push(chat);
      }

      const participants = normalizeParticipantIds(chat.participantIds);
      if (!participants.includes(senderId) || participants.length < 2) {
        return skip(null);
      }

      const sender = db.users.find((entry) => entry.id === senderId);
      const normalizedText = String(text || "").trim();
      const normalizedAttachments = normalizeMessageAttachments({
        attachments,
        mediaUrls,
        imageUrl,
      });
      const normalizedMediaUrls = normalizedAttachments.map((entry) => entry.url);
      const normalizedImageUrl =
        normalizedAttachments.find((entry) => entry.type === "image")?.url ||
        normalizedAttachments[0]?.url ||
        null;
      const normalizedClientMessageId = String(clientMessageId || "").trim() || null;
      const normalizedExpiresAt = normalizeOptionalIsoTimestamp(expiresAt);
      const normalizedReplyTo = normalizeReplyReference(replyTo);
      const normalizedCall = normalizeChatMessageCall(call);
      if (
        !normalizedText &&
        normalizedAttachments.length === 0 &&
        !normalizedCall
      ) {
        return skip(false);
      }

      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);

      if (normalizedClientMessageId) {
        const existingMessage = db.messages.find(
          (entry) =>
            relatedChatIds.has(String(entry.chatId || "").trim()) &&
            entry.senderId === senderId &&
            entry.clientMessageId === normalizedClientMessageId,
        );
        if (existingMessage) {
          return skip({
            ...attachMessageReactions(db, existingMessage),
            _deduplicated: true,
          });
        }
      }

      const timestamp = nowIso();
      const message = {
        id: crypto.randomUUID(),
        chatId: chat.id,
        senderId,
        text: normalizedText,
        timestamp,
        isRead: false,
        participants,
        deliveredTo: [senderId],
        readBy: [senderId],
        senderName: sender?.profile?.displayName || "Пользователь",
        attachments: normalizedAttachments,
        imageUrl: normalizedImageUrl,
        mediaUrls: normalizedMediaUrls.length > 0 ? normalizedMediaUrls : null,
        clientMessageId: normalizedClientMessageId,
        expiresAt: normalizedExpiresAt,
        replyTo: normalizedReplyTo,
      };

      const storedChat = db.chats.find((entry) => entry.id === chat.id);
      if (storedChat) {
        storedChat.updatedAt = timestamp;
      }

      if (normalizedCall) {
        message.call = normalizedCall;
      }
      db.messages.push(message);
      if (purgedChatIds.size > 0) {
        purgedChatIds.add(chat.id);
        this._syncChatUpdatedAt(db, purgedChatIds);
      }
      return attachMessageReactions(db, message);
    });
  }

  async updateChatMessage({
    chatId,
    messageId,
    userId,
    text,
  }) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!chat || !chat.participantIds.includes(userId)) {
        return skip(false);
      }
      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);

      const message = db.messages.find(
        (entry) =>
          entry.id === messageId &&
          relatedChatIds.has(String(entry.chatId || "").trim()),
      );
      if (!message) {
        return skip(null);
      }
      if (message.senderId !== userId) {
        return skip(undefined);
      }

      const normalizedText = String(text || "").trim();
      const attachments = normalizeMessageAttachments(message);
      if (!normalizedText && attachments.length === 0) {
        return skip("EMPTY_MESSAGE");
      }

      message.text = normalizedText;
      message.updatedAt = nowIso();
      const storedChat = db.chats.find((entry) => entry.id === chat.id);
      if (storedChat) {
        storedChat.updatedAt = message.updatedAt;
      }
      if (purgedChatIds.size > 0) {
        purgedChatIds.add(chat.id);
        this._syncChatUpdatedAt(db, purgedChatIds);
      }
      return attachMessageReactions(db, message);
    });
  }

  async deleteChatMessage({
    chatId,
    messageId,
    userId,
  }) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!chat || !chat.participantIds.includes(userId)) {
        return skip(false);
      }
      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);

      const messageIndex = db.messages.findIndex(
        (entry) =>
          entry.id === messageId &&
          relatedChatIds.has(String(entry.chatId || "").trim()),
      );
      if (messageIndex === -1) {
        return skip(null);
      }

      const message = db.messages[messageIndex];
      if (message.senderId !== userId) {
        return skip(undefined);
      }

      db.messages.splice(messageIndex, 1);
      db.messageReactions = ensureMessageReactions(db).filter(
        (entry) => String(entry?.messageId || "").trim() !== message.id,
      );
      const pinCountBeforeDelete = ensureChatPins(db).length;
      db.chatPins = ensureChatPins(db).filter(
        (entry) => String(entry?.messageId || "").trim() !== message.id,
      );
      const clearedPinnedMessage = db.chatPins.length !== pinCountBeforeDelete;
      const storedChat = db.chats.find((entry) => entry.id === chat.id);
      if (storedChat) {
        storedChat.updatedAt = nowIso();
      }
      purgedChatIds.add(chat.id);
      this._syncChatUpdatedAt(db, purgedChatIds);
      const deletedMessage = attachMessageReactions(db, message);
      if (clearedPinnedMessage) {
        deletedMessage._clearedPinnedMessage = true;
      }
      return deletedMessage;
    });
  }

  async toggleChatMessageReaction({
    chatId,
    messageId,
    userId,
    emoji,
  }) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!chat || !chat.participantIds.includes(userId)) {
        return skip(false);
      }
      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);
      const message = db.messages.find(
        (entry) =>
          entry.id === messageId &&
          relatedChatIds.has(String(entry.chatId || "").trim()),
      );
      if (!message) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return null;
        }
        return skip(null);
      }

      const normalizedEmoji = normalizeReactionEmoji(emoji);
      if (!normalizedEmoji) {
        return skip("INVALID_EMOJI");
      }

      const reactions = ensureMessageReactions(db);
      const existingIndex = reactions.findIndex(
        (entry) =>
          String(entry?.messageId || "").trim() === message.id &&
          String(entry?.userId || "").trim() === userId &&
          normalizeReactionEmoji(entry?.emoji) === normalizedEmoji,
      );

      let added = false;
      if (existingIndex >= 0) {
        reactions.splice(existingIndex, 1);
      } else {
        reactions.push({
          messageId: message.id,
          userId,
          emoji: normalizedEmoji,
          createdAt: nowIso(),
        });
        added = true;
      }

      if (purgedChatIds.size > 0) {
        this._syncChatUpdatedAt(db, purgedChatIds);
      }

      return {
        chatId: message.chatId || chat.id,
        messageId: message.id,
        reactions: aggregateMessageReactions(db, message.id),
        added,
      };
    });
  }

  async markChatMessageDelivered({
    chatId,
    messageId,
    userIds = [],
  }) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!chat) {
        return skip(false);
      }
      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);
      const message = db.messages.find(
        (entry) =>
          entry.id === messageId &&
          relatedChatIds.has(String(entry.chatId || "").trim()),
      );
      if (!message) {
        if (purgedChatIds.size > 0) {
          this._syncChatUpdatedAt(db, purgedChatIds);
          return null;
        }
        return skip(null);
      }

      const participantIds = normalizeParticipantIds(chat.participantIds);
      const recipientIds = normalizeParticipantIds(userIds).filter(
        (userId) => participantIds.includes(userId) && userId !== message.senderId,
      );
      if (recipientIds.length === 0) {
        return skip({
          chatId: message.chatId || chat.id,
          messageId: message.id,
          deliveredTo: normalizeParticipantIds(message.deliveredTo),
          changedUserIds: [],
        });
      }

      const deliveredTo = normalizeParticipantIds(message.deliveredTo);
      let changed = false;
      for (const userId of recipientIds) {
        if (!deliveredTo.includes(userId)) {
          deliveredTo.push(userId);
          changed = true;
        }
      }
      message.deliveredTo = deliveredTo;

      if (purgedChatIds.size > 0) {
        this._syncChatUpdatedAt(db, purgedChatIds);
      }

      const result = {
        chatId: message.chatId || chat.id,
        messageId: message.id,
        deliveredTo: normalizeParticipantIds(message.deliveredTo),
        changedUserIds: changed ? recipientIds : [],
      };
      if (changed || purgedChatIds.size > 0) {
        return result;
      }
      return skip(result);
    });
  }

  async markChatAsRead(chatId, userId) {
    return this._mutate((db, skip) => {
      const purgedChatIds = this._purgeExpiredMessages(db);
      const chat = this._resolveChat(db, chatId);
      if (!chat || !chat.participantIds.includes(userId)) {
        return skip(false);
      }
      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);

      let changed = false;
      const readMessageIds = [];

      for (const message of db.messages) {
        if (
          relatedChatIds.has(String(message.chatId || "").trim()) &&
          message.senderId !== userId
        ) {
          const deliveredTo = normalizeParticipantIds(message.deliveredTo);
          if (!deliveredTo.includes(userId)) {
            deliveredTo.push(userId);
            message.deliveredTo = deliveredTo;
            changed = true;
          }

          const readBy = normalizeParticipantIds(message.readBy);
          if (!readBy.includes(userId)) {
            readBy.push(userId);
            message.readBy = readBy;
            readMessageIds.push(message.id);
            changed = true;
          }

          if (message.isRead !== true) {
            message.isRead = true;
            changed = true;
          }
        }
      }

      if (purgedChatIds.size > 0) {
        this._syncChatUpdatedAt(db, purgedChatIds);
      }

      const result = {
        changed,
        chatId: chat.id,
        userId,
        messageIds: readMessageIds,
      };
      if (changed || purgedChatIds.size > 0) {
        return result;
      }
      return skip(result);
    });
  }

  async createCallInvite({
    chatId,
    initiatorId,
    recipientId,
    participantIds: requestedParticipantIds = null,
    mediaMode,
    originatedBySessionId = null,
  }) {
    return this._mutate((db, skip) => {
      const chat = this._resolveChat(db, chatId);
      if (!chat) {
        return skip(null);
      }

      const chatParticipantIds = normalizeParticipantIds(chat.participantIds || []);
      const participantIds = normalizeParticipantIds(
        Array.isArray(requestedParticipantIds) && requestedParticipantIds.length > 0
          ? requestedParticipantIds
          : chatParticipantIds,
      );
      if (
        !participantIds.includes(initiatorId) ||
        participantIds.some((participantId) => !chatParticipantIds.includes(participantId))
      ) {
        return skip(false);
      }
      if (chat.type === "direct" && participantIds.length !== 2) {
        return skip(false);
      }
      if ((chat.type === "group" || chat.type === "branch") && participantIds.length < 2) {
        return skip(false);
      }
      if (chat.type !== "direct" && chat.type !== "group" && chat.type !== "branch") {
        return skip(false);
      }

      const normalizedRecipientId =
        normalizeNullableString(recipientId) ||
        participantIds.find((participantId) => participantId !== initiatorId) ||
        "";
      if (!normalizedRecipientId || !participantIds.includes(normalizedRecipientId)) {
        return skip(false);
      }

      const hasBusyCall = db.calls
        .map((entry) => normalizeStoredCall(entry))
        .filter(Boolean)
        .some((call) => {
          if (!isCallBusyState(call.state)) {
            return false;
          }
          return (
            call.participantIds.includes(initiatorId) ||
            call.participantIds.includes(recipientId)
          );
        });
      if (hasBusyCall) {
        return skip("BUSY");
      }

      const call = createCallRecord({
        chatId,
        initiatorId,
        recipientId: normalizedRecipientId,
        participantIds,
        mediaMode,
        originatedBySessionId,
      });
      db.calls.push(call);
      return structuredClone(call);
    });
  }

  async findCall(callId) {
    const db = await this._read();
    const call = db.calls
      .map((entry) => normalizeStoredCall(entry))
      .find((entry) => entry && entry.id === callId);
    return call ? structuredClone(call) : null;
  }

  async findActiveCall({userId, chatId = null} = {}) {
    const normalizedUserId = String(userId || "").trim();
    const normalizedChatId = String(chatId || "").trim();
    if (!normalizedUserId) {
      return null;
    }

    const db = await this._read();
    const statePriority = {
      active: 0,
      ringing: 1,
    };
    const activeCalls = db.calls
      .map((entry) => normalizeStoredCall(entry))
      .filter((call) => {
        if (!call || !isCallBusyState(call.state)) {
          return false;
        }
        if (!call.participantIds.includes(normalizedUserId)) {
          return false;
        }
        if (normalizedChatId && call.chatId !== normalizedChatId) {
          return false;
        }
        return true;
      })
      .sort((left, right) => {
        const leftPriority = statePriority[left.state] ?? 99;
        const rightPriority = statePriority[right.state] ?? 99;
        if (leftPriority != rightPriority) {
          return leftPriority - rightPriority;
        }
        return new Date(right.updatedAt) - new Date(left.updatedAt);
      });

    return activeCalls.length > 0 ? structuredClone(activeCalls[0]) : null;
  }

  // Discovery for group late-join: the freshest active/ringing call in a chat,
  // IGNORING participantIds — so a chat member who wasn't pre-invited can find
  // (and then POST /join) the call. Access is gated by the CALLER at the app
  // layer (chat membership); this method purposely does NOT filter by
  // participantIds. Kept distinct from findActiveCall, whose participantIds
  // filter drives busy-state and MUST stay strict (a chat member must not be
  // marked "busy" merely because their chat has a call they haven't joined).
  async findActiveCallForChat(chatId) {
    const normalizedChatId = String(chatId || "").trim();
    if (!normalizedChatId) {
      return null;
    }
    const db = await this._read();
    const statePriority = {
      active: 0,
      ringing: 1,
    };
    const calls = db.calls
      .map((entry) => normalizeStoredCall(entry))
      .filter(
        (call) =>
          call &&
          isCallBusyState(call.state) &&
          call.chatId === normalizedChatId,
      )
      .sort((left, right) => {
        const leftPriority = statePriority[left.state] ?? 99;
        const rightPriority = statePriority[right.state] ?? 99;
        if (leftPriority != rightPriority) {
          return leftPriority - rightPriority;
        }
        return new Date(right.updatedAt) - new Date(left.updatedAt);
      });
    return calls.length > 0 ? structuredClone(calls[0]) : null;
  }

  async listRingingCalls() {
    const db = await this._read();
    return db.calls
      .map((entry) => normalizeStoredCall(entry))
      .filter((call) => call && call.state === "ringing")
      .map((call) => structuredClone(call));
  }

  async acceptCall({
    callId,
    userId,
    roomName,
    sessionByUserId,
    acceptedBySessionId = null,
  }) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      if (!call.participantIds.includes(userId) || call.initiatorId === userId) {
        return skip(false);
      }
      if (call.state !== "ringing") {
        return skip(undefined);
      }

      const timestamp = nowIso();
      storedCall.metrics = normalizeCallMetrics(storedCall.metrics);
      storedCall.state = "active";
      storedCall.roomName = normalizeNullableString(roomName);
      storedCall.sessionByUserId = normalizeCallSessionMap(sessionByUserId);
      // First joiner populates the N-way map; the scalars stay filled too for
      // back-compat (in-flight records + old clients that read acceptedBy*).
      storedCall.joinedSessionByUserId = normalizeJoinedSessionMap({
        [userId]: acceptedBySessionId,
      });
      storedCall.acceptedByUserId = userId;
      storedCall.acceptedBySessionId = normalizeNullableString(acceptedBySessionId);
      storedCall.acceptedAt = timestamp;
      storedCall.updatedAt = timestamp;
      storedCall.endedAt = null;
      storedCall.endedReason = null;
      storedCall.metrics.acceptLatencyMs = Math.max(
        0,
        new Date(timestamp).getTime() - new Date(call.createdAt).getTime(),
      );
      storedCall.metrics.connectedParticipantIds = [];
      storedCall.metrics.lastWebhookEvent = null;
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  // Group late-join: merge a participant's freshly-minted session into the
  // call (sessionByUserId + joinedSessionByUserId). Works on an ACTIVE call
  // (does NOT require state==='ringing'), and on the FIRST joiner flips
  // ringing -> active (filling the scalar back-compat fields). Idempotent per
  // (user, session): re-adding the same pair just re-writes the same values.
  async addCallParticipantSession({callId, userId, sessionId, session}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      const normalizedUserId = String(userId || "").trim();
      if (!normalizedUserId || !call.participantIds.includes(normalizedUserId)) {
        return skip(false);
      }
      if (isCallTerminalState(call.state)) {
        return skip(undefined);
      }

      const timestamp = nowIso();
      const normalizedSessionId = normalizeNullableString(sessionId);
      const normalizedSession = normalizeCallSession(session);

      storedCall.metrics = normalizeCallMetrics(storedCall.metrics);
      storedCall.sessionByUserId = normalizeCallSessionMap(storedCall.sessionByUserId);
      storedCall.joinedSessionByUserId = normalizeJoinedSessionMap(
        storedCall.joinedSessionByUserId,
      );

      if (normalizedSession) {
        storedCall.sessionByUserId[normalizedUserId] = normalizedSession;
        if (!normalizeNullableString(storedCall.roomName)) {
          storedCall.roomName = normalizedSession.roomName;
        }
      }
      if (normalizedSessionId) {
        storedCall.joinedSessionByUserId[normalizedUserId] = normalizedSessionId;
      }

      if (call.state === "ringing") {
        // First joiner makes the call active. Scalars are set once (the first
        // joiner wins) so old clients still resolve the owning session.
        storedCall.state = "active";
        storedCall.acceptedAt = storedCall.acceptedAt || timestamp;
        storedCall.endedAt = null;
        storedCall.endedReason = null;
        if (!normalizeNullableString(storedCall.acceptedByUserId)) {
          storedCall.acceptedByUserId = normalizedUserId;
          storedCall.acceptedBySessionId = normalizedSessionId;
        }
        if (
          storedCall.metrics.acceptLatencyMs === null ||
          storedCall.metrics.acceptLatencyMs === undefined
        ) {
          storedCall.metrics.acceptLatencyMs = Math.max(
            0,
            new Date(timestamp).getTime() - new Date(call.createdAt).getTime(),
          );
        }
      }

      storedCall.updatedAt = timestamp;
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  async markCallRoomJoinFailure({callId, reason = null}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }

      storedCall.metrics = normalizeCallMetrics(storedCall.metrics);
      storedCall.metrics.roomJoinFailureCount += 1;
      storedCall.metrics.lastRoomJoinFailureReason = normalizeNullableString(reason);
      storedCall.updatedAt = nowIso();
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  async rejectCall({callId, userId}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      if (!call.participantIds.includes(userId) || call.initiatorId === userId) {
        return skip(false);
      }
      if (call.state !== "ringing") {
        return skip(undefined);
      }

      const timestamp = nowIso();
      storedCall.state = "rejected";
      storedCall.updatedAt = timestamp;
      storedCall.endedAt = timestamp;
      storedCall.endedReason = "rejected";
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  async cancelCall({callId, userId}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      if (call.initiatorId !== userId) {
        return skip(false);
      }
      if (call.state !== "ringing") {
        return skip(undefined);
      }

      const timestamp = nowIso();
      storedCall.state = "cancelled";
      storedCall.updatedAt = timestamp;
      storedCall.endedAt = timestamp;
      storedCall.endedReason = "cancelled";
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  async markCallMissed({callId, reason = "missed"}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      if (call.state !== "ringing") {
        return skip(undefined);
      }

      const timestamp = nowIso();
      storedCall.state = "missed";
      storedCall.updatedAt = timestamp;
      storedCall.endedAt = timestamp;
      storedCall.endedReason = normalizeNullableString(reason) || "missed";
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  async hangupCall({callId, userId}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => String(entry?.id || "") === callId);
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      if (!call.participantIds.includes(userId)) {
        return skip(false);
      }
      if (call.state !== "active") {
        return skip(undefined);
      }

      const timestamp = nowIso();
      const normalizedUserId = String(userId || "").trim();
      storedCall.sessionByUserId = normalizeCallSessionMap(storedCall.sessionByUserId);
      storedCall.joinedSessionByUserId = normalizeJoinedSessionMap(
        storedCall.joinedSessionByUserId,
      );

      // Group call: one participant leaving is NOT the end — drop their session
      // and keep the call active while anyone else is still connected. Mirrors
      // the webhook participant_left path. The 1:1 case (≤2 participants) ends
      // the call as before. ended only when the LAST participant leaves.
      if (call.participantIds.length > 2) {
        delete storedCall.joinedSessionByUserId[normalizedUserId];
        delete storedCall.sessionByUserId[normalizedUserId];
        // Hand the scalar back-compat fields off to a remaining joiner so old
        // clients still resolve an owning session (or clear them if none left).
        if (normalizeNullableString(storedCall.acceptedByUserId) === normalizedUserId) {
          const remainingJoiner = Object.keys(storedCall.joinedSessionByUserId)[0];
          if (remainingJoiner) {
            storedCall.acceptedByUserId = remainingJoiner;
            storedCall.acceptedBySessionId =
              storedCall.joinedSessionByUserId[remainingJoiner];
          } else {
            storedCall.acceptedByUserId = null;
            storedCall.acceptedBySessionId = null;
          }
        }
        const someoneStillConnected =
          Object.keys(storedCall.sessionByUserId).length > 0;
        if (someoneStillConnected) {
          storedCall.updatedAt = timestamp;
          return structuredClone(normalizeStoredCall(storedCall));
        }
      }

      storedCall.state = "ended";
      storedCall.updatedAt = timestamp;
      storedCall.endedAt = timestamp;
      storedCall.endedReason = "hangup";
      return structuredClone(normalizeStoredCall(storedCall));
    });
  }

  // GP3: grow a live call's invite list (add-mid-call). Chat-membership of the
  // new ids is validated by the caller (POST /v1/calls/:id/add). This ONLY
  // extends participantIds — it deliberately does NOT touch sessionByUserId /
  // joinedSessionByUserId, so the last-leaves teardown in hangupCall
  // (someoneStillConnected) is unaffected: the call still ends only when the
  // last JOINED participant leaves, never because the roster grew.
  async addCallParticipants({callId, userIds}) {
    return this._mutate((db, skip) => {
      const storedCall = db.calls.find(
        (entry) => String(entry?.id || "") === callId,
      );
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call) {
        return skip(null);
      }
      if (call.state !== "active" && call.state !== "ringing") {
        return skip(undefined);
      }
      const existing = normalizeParticipantIds(storedCall.participantIds || []);
      const additions = normalizeParticipantIds(userIds || []).filter(
        (participantId) => !existing.includes(participantId),
      );
      if (additions.length === 0) {
        return skip(false);
      }
      storedCall.participantIds = [...existing, ...additions];
      storedCall.updatedAt = nowIso();
      return {
        call: structuredClone(normalizeStoredCall(storedCall)),
        addedUserIds: additions,
      };
    });
  }

  async applyCallWebhook({roomName, event, participantIdentity = null}) {
    const normalizedRoomName = String(roomName || "").trim();
    if (!normalizedRoomName) {
      return null;
    }

    return this._mutate((db, skip) => {
      const storedCall = db.calls.find((entry) => {
        return normalizeNullableString(entry?.roomName) === normalizedRoomName;
      });
      const call = normalizeStoredCall(storedCall);
      if (!storedCall || !call || isCallTerminalState(call.state)) {
        return skip(call ? structuredClone(call) : null);
      }

      const normalizedEvent = String(event || "").trim();
      const normalizedParticipantIdentity = String(participantIdentity || "").trim();
      const timestamp = nowIso();
      storedCall.metrics = normalizeCallMetrics(storedCall.metrics);
      storedCall.metrics.lastWebhookEvent = normalizedEvent || null;

      if (normalizedEvent === "participant_joined" && call.state === "active") {
        if (normalizedParticipantIdentity) {
          const wasConnected = storedCall.metrics.connectedParticipantIds.includes(
            normalizedParticipantIdentity,
          );
          if (wasConnected) {
            storedCall.metrics.reconnectCount += 1;
          } else {
            storedCall.metrics.connectedParticipantIds = normalizeParticipantIds([
              ...storedCall.metrics.connectedParticipantIds,
              normalizedParticipantIdentity,
            ]);
          }
        }
        storedCall.updatedAt = timestamp;
        return structuredClone(normalizeStoredCall(storedCall));
      }

      if (normalizedEvent === "participant_connection_aborted" && call.state === "ringing") {
        storedCall.state = "missed";
        storedCall.updatedAt = timestamp;
        storedCall.endedAt = timestamp;
        storedCall.endedReason = normalizedParticipantIdentity || "missed";
        return structuredClone(normalizeStoredCall(storedCall));
      }

      if (normalizedEvent === "participant_left" || normalizedEvent === "room_finished") {
        if (normalizedParticipantIdentity) {
          storedCall.metrics.connectedParticipantIds =
            storedCall.metrics.connectedParticipantIds.filter(
              (value) => value !== normalizedParticipantIdentity,
            );
        }
        if (
          normalizedEvent === "participant_left" &&
          call.participantIds.length > 2 &&
          storedCall.metrics.connectedParticipantIds.length > 0
        ) {
          storedCall.updatedAt = timestamp;
          return structuredClone(normalizeStoredCall(storedCall));
        }
        storedCall.state = "ended";
        storedCall.updatedAt = timestamp;
        storedCall.endedAt = timestamp;
        storedCall.endedReason = normalizedParticipantIdentity || normalizedEvent;
        return structuredClone(normalizeStoredCall(storedCall));
      }

      if (normalizedEvent) {
        storedCall.updatedAt = timestamp;
        return structuredClone(normalizeStoredCall(storedCall));
      }

      return skip(structuredClone(call));
    });
  }

  async listChatPreviews(userId) {
    const db = await this._read();
    const purgedChatIds = this._purgeExpiredMessages(db);
    if (purgedChatIds.size > 0) {
      this._syncChatUpdatedAt(db, purgedChatIds);
      this._schedulePurgeSweep();
    }
    const relatedChats = new Map();
    const userById = new Map(
      db.users.map((entry) => [String(entry.id || "").trim(), entry]),
    );
    const previews = new Map();

    for (const chat of db.chats) {
      if (Array.isArray(chat.participantIds) && chat.participantIds.includes(userId)) {
        relatedChats.set(chat.id, chat);
      }
    }

    for (const message of db.messages) {
      if (relatedChats.has(message.chatId)) {
        continue;
      }
      const resolvedChat = this._resolveChat(db, message.chatId);
      if (resolvedChat && resolvedChat.participantIds.includes(userId)) {
        relatedChats.set(resolvedChat.id, resolvedChat);
      }
    }

    for (const chat of relatedChats.values()) {
      const participants = normalizeParticipantIds(chat.participantIds);
      const isGroup = chat.type === "group" || chat.type === "branch";
      const otherUserId = isGroup
        ? ""
        : participants.find((participant) => participant !== userId) || "";
      const preview = {
        chatId: chat.id,
        userId,
        type: chat.type || "direct",
        title: chat.title || null,
        photoUrl: isGroup ? chat.photoUrl || null : null,
        participantIds: participants,
        otherUserId,
        otherUserName: "Пользователь",
        otherUserPhotoUrl: null,
        lastMessage: "",
        lastMessageTime: chat.updatedAt || chat.createdAt || "",
        unreadCount: 0,
        lastMessageSenderId: "",
      };

      if (isGroup) {
        if (!preview.photoUrl && chat.type === "branch") {
          const rootIds = normalizeParticipantIds(chat.branchRootPersonIds);
          const rootPerson = db.persons.find((person) => {
            return (
              rootIds.includes(String(person?.id || "").trim()) &&
              String(person?.treeId || "").trim() ===
                String(chat.treeId || "").trim() &&
              (String(person?.primaryPhotoUrl || "").trim() ||
                String(person?.photoUrl || "").trim())
            );
          });
          if (rootPerson) {
            preview.photoUrl =
              String(rootPerson.primaryPhotoUrl || rootPerson.photoUrl || "")
                .trim() || null;
          }
        }
        const otherParticipantNames = [];
        for (const participantId of participants) {
          if (participantId === userId) {
            continue;
          }
          const participant = userById.get(participantId) || null;
          const participantName =
            participant?.profile?.displayName || participant?.email || "";
          if (!participantName) {
            continue;
          }
          otherParticipantNames.push(participantName);
          if (otherParticipantNames.length >= 3) {
            break;
          }
        }
        preview.otherUserName =
          chat.title ||
          (otherParticipantNames.length > 0
            ? otherParticipantNames.join(", ")
            : "Групповой чат");
      } else {
        const otherUser = userById.get(otherUserId) || null;
        if (otherUser) {
          preview.otherUserName =
            otherUser.profile?.displayName || otherUser.email || "Пользователь";
          preview.otherUserPhotoUrl = otherUser.profile?.photoUrl || null;
        }

        // Fallback: if the other user has no profile photo (or no account at all),
        // find their tree-person card and use its primaryPhotoUrl instead.
        // This covers offline-profile chats where the person has a tree photo
        // but hasn't registered an account yet.
        if (!preview.otherUserPhotoUrl && otherUserId) {
          const linkedPerson = db.persons.find((p) => {
            const personUserId = String(p.userId || "").trim();
            return (
              personUserId === otherUserId &&
              String(p.primaryPhotoUrl || "").trim()
            );
          });
          if (linkedPerson?.primaryPhotoUrl) {
            preview.otherUserPhotoUrl = String(linkedPerson.primaryPhotoUrl).trim();
          }
        }
      }

      previews.set(chat.id, preview);
    }

    for (const message of db.messages) {
      let resolvedChatId = String(message.chatId || "").trim();
      let preview = previews.get(resolvedChatId) || null;

      if (!preview) {
        const resolvedChat = this._resolveChat(db, message.chatId);
        if (!resolvedChat || !previews.has(resolvedChat.id)) {
          continue;
        }
        resolvedChatId = resolvedChat.id;
        preview = previews.get(resolvedChatId) || null;
      }

      if (!preview) {
        continue;
      }

      const messageTimestamp = String(message.timestamp || "").trim();
      const lastMessageTimestamp = String(preview.lastMessageTime || "").trim();
      if (
        !preview.lastMessage ||
        !lastMessageTimestamp ||
        messageTimestamp.localeCompare(lastMessageTimestamp) >= 0
      ) {
        preview.lastMessage = describeMessagePreview(message);
        preview.lastMessageTime = messageTimestamp;
        preview.lastMessageSenderId = message.senderId;
      }

      if (message.senderId !== userId && !isMessageReadByUser(message, userId)) {
        preview.unreadCount += 1;
      }
    }

    return Array.from(previews.values())
      .sort((left, right) =>
        String(right.lastMessageTime || "").localeCompare(
          String(left.lastMessageTime || ""),
        ),
      )
      .map((preview) => structuredClone(preview));
  }

  async countUnreadChatMessages(userId) {
    const previews = await this.listChatPreviews(userId);
    return previews.reduce((sum, preview) => {
      return sum + Number(preview?.unreadCount || 0);
    }, 0);
  }

  async listRelatedChatParticipantIds(userId) {
    const db = await this._read();
    const relatedParticipantIds = new Set();

    for (const chat of db.chats) {
      if (!Array.isArray(chat.participantIds) || !chat.participantIds.includes(userId)) {
        continue;
      }
      for (const participantId of chat.participantIds) {
        if (participantId && participantId !== userId) {
          relatedParticipantIds.add(participantId);
        }
      }
    }

    return Array.from(relatedParticipantIds);
  }

  // SPEED-2: read-пути (история чата, поиск, превью) больше НЕ пишут
  // whole-doc сами — их stale-запись после TTL-purge могла затереть
  // конкурентную _mutate-мутацию (тот же lost-update класс, что у GP3).
  // Ответ фильтруется in-memory как раньше; ФИЗИЧЕСКУЮ зачистку протухших
  // сообщений делает этот фоновый атомарный sweep: _mutate читает свежее
  // состояние в очереди, skip() держит «нечего чистить» без записи.
  _schedulePurgeSweep() {
    if (this._purgeSweepScheduled) {
      return;
    }
    this._purgeSweepScheduled = true;
    Promise.resolve()
      .then(() =>
        this._mutate((db, skip) => {
          const purgedChatIds = this._purgeExpiredMessages(db);
          if (purgedChatIds.size === 0) {
            return skip(undefined);
          }
          this._syncChatUpdatedAt(db, purgedChatIds);
          return undefined;
        }),
      )
      .catch((error) => {
        // Best-effort: протухшее вычистит следующий sweep или любая мутация —
        // но хроническую проблему (пул, oversized row) надо ВИДЕТЬ в логах.
        console.warn(
          "[store] purge sweep failed",
          error?.message || error,
        );
      })
      .then(() => {
        this._purgeSweepScheduled = false;
      });
  }

  _purgeExpiredMessages(db) {
    const expiredChatIds = new Set();
    const expiredMessageIds = new Set();
    const referenceTimeMs = Date.now();
    db.messages = db.messages.filter((message) => {
      if (isExpiredAt(message.expiresAt, referenceTimeMs)) {
        if (message.chatId) {
          expiredChatIds.add(message.chatId);
        }
        if (message.id) {
          expiredMessageIds.add(message.id);
        }
        return false;
      }
      return true;
    });
    if (expiredMessageIds.size > 0) {
      db.messageReactions = ensureMessageReactions(db).filter(
        (entry) => !expiredMessageIds.has(String(entry?.messageId || "").trim()),
      );
      db.chatPins = ensureChatPins(db).filter(
        (entry) => !expiredMessageIds.has(String(entry?.messageId || "").trim()),
      );
    }
    return expiredChatIds;
  }

  _syncChatUpdatedAt(db, chatIds) {
    for (const chatId of chatIds) {
      const chat = db.chats.find((entry) => entry.id === chatId);
      if (!chat) {
        continue;
      }
      const relatedChatIds = this._resolveEquivalentChatIds(chatId, chat);

      const latestMessage = db.messages
        .filter((entry) => relatedChatIds.has(String(entry.chatId || "").trim()))
        .sort((left, right) =>
          String(right.timestamp || "").localeCompare(String(left.timestamp || "")),
        )[0];

      chat.updatedAt = latestMessage?.timestamp || chat.createdAt || chat.updatedAt;
    }
  }

  async createProfileContribution({
    treeId,
    personId,
    authorUserId,
    message = null,
    fields = {},
  }) {
    const db = await this._read();
    db.profileContributions = Array.isArray(db.profileContributions)
      ? db.profileContributions
      : [];

    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person || !person.userId) {
      return null;
    }

    const targetUser = db.users.find((entry) => entry.id === person.userId);
    if (!targetUser) {
      return null;
    }
    if (
      normalizeProfileContributionPolicy(
        targetUser.profile?.profileContributionPolicy,
      ) !== "suggestions"
    ) {
      return false;
    }

    const normalizedFields = normalizeProfileContributionFields(fields);
    if (Object.keys(normalizedFields).length === 0) {
      return undefined;
    }

    const contribution = {
      id: crypto.randomUUID(),
      treeId,
      personId,
      targetUserId: person.userId,
      authorUserId: normalizeNullableString(authorUserId),
      message: normalizeNullableString(message),
      fields: normalizedFields,
      status: "pending",
      createdAt: nowIso(),
      updatedAt: nowIso(),
      respondedAt: null,
      responderUserId: null,
    };

    db.profileContributions.unshift(contribution);
    await this._write(db);
    return structuredClone(contribution);
  }

  async listProfileContributions(targetUserId, {status = null} = {}) {
    const db = await this._read();
    db.profileContributions = Array.isArray(db.profileContributions)
      ? db.profileContributions
      : [];

    return db.profileContributions
      .filter((entry) => {
        if (entry.targetUserId !== targetUserId) {
          return false;
        }
        if (status && entry.status !== status) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .map((entry) => structuredClone(entry));
  }

  async respondToProfileContribution(targetUserId, contributionId, {
    accept,
  }) {
    const db = await this._read();
    db.profileContributions = Array.isArray(db.profileContributions)
      ? db.profileContributions
      : [];

    const contribution = db.profileContributions.find(
      (entry) =>
        entry.id === contributionId &&
        entry.targetUserId === targetUserId &&
        entry.status === "pending",
    );
    if (!contribution) {
      return null;
    }

    let updatedUser = null;
    if (accept === true) {
      updatedUser = await this.updateProfile(targetUserId, (profile) => {
        const nextProfile = {
          ...profile,
          ...normalizeProfileContributionFields(contribution.fields),
        };
        nextProfile.displayName =
          composeDisplayNameFromProfile(nextProfile) || profile.displayName || "";
        return nextProfile;
      });
    }

    const nextDb = accept === true ? await this._read() : db;
    nextDb.profileContributions = Array.isArray(nextDb.profileContributions)
      ? nextDb.profileContributions
      : [];
    const storedContribution = nextDb.profileContributions.find(
      (entry) => entry.id === contributionId,
    );
    if (!storedContribution) {
      return null;
    }

    storedContribution.status = accept === true ? "accepted" : "rejected";
    storedContribution.respondedAt = nowIso();
    storedContribution.updatedAt = storedContribution.respondedAt;
    storedContribution.responderUserId = targetUserId;
    await this._write(nextDb);

    return {
      contribution: structuredClone(storedContribution),
      user: updatedUser,
    };
  }

  async listProfileNotes(userId) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const notes = Array.isArray(user.profileNotes) ? user.profileNotes : [];
    return notes
      .slice()
      .sort((left, right) => {
        return String(right.createdAt || "").localeCompare(
          String(left.createdAt || ""),
        );
      })
      .map((note) => structuredClone(note));
  }

  async addProfileNote(userId, {title, content}) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const note = createProfileNote({title, content});
    user.profileNotes = Array.isArray(user.profileNotes) ? user.profileNotes : [];
    user.profileNotes.unshift(note);
    user.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(note);
  }

  async updateProfileNote(userId, noteId, {title, content}) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    user.profileNotes = Array.isArray(user.profileNotes) ? user.profileNotes : [];
    const note = user.profileNotes.find((entry) => entry.id === noteId);
    if (!note) {
      return undefined;
    }

    note.title = String(title || note.title || "").trim();
    note.content = String(content || note.content || "").trim();
    note.updatedAt = nowIso();
    user.updatedAt = nowIso();
    await this._write(db);
    return structuredClone(note);
  }

  async deleteProfileNote(userId, noteId) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    user.profileNotes = Array.isArray(user.profileNotes) ? user.profileNotes : [];
    const initialLength = user.profileNotes.length;
    user.profileNotes = user.profileNotes.filter((entry) => entry.id !== noteId);
    if (user.profileNotes.length === initialLength) {
      return false;
    }

    user.updatedAt = nowIso();
    await this._write(db);
    return true;
  }

  async searchUsers({query, limit}) {
    const db = await this._read();
    const normalizedQuery = String(query || "").trim().toLowerCase();
    if (!normalizedQuery) {
      return [];
    }

    return db.users
      .filter((user) => {
        const profile = user.profile || {};
        return (
          String(user.email || "").toLowerCase().includes(normalizedQuery) ||
          String(profile.displayName || "")
            .toLowerCase()
            .includes(normalizedQuery) ||
          String(profile.username || "")
            .toLowerCase()
            .includes(normalizedQuery) ||
          String(profile.firstName || "")
            .toLowerCase()
            .includes(normalizedQuery) ||
          String(profile.lastName || "")
            .toLowerCase()
            .includes(normalizedQuery) ||
          String(profile.middleName || "")
            .toLowerCase()
            .includes(normalizedQuery) ||
          String(profile.maidenName || "")
            .toLowerCase()
            .includes(normalizedQuery) ||
          String(profile.birthPlace || "")
            .toLowerCase()
            .includes(normalizedQuery)
        );
      })
      .slice(0, limit)
      .map((user) => structuredClone(user));
  }

  async searchUsersByField({field, value, limit}) {
    const db = await this._read();
    const normalizedValue = String(value || "").trim().toLowerCase();
    if (!normalizedValue) {
      return [];
    }

    return db.users
      .filter((user) => {
        if (field === "email") {
          return String(user.email || "").toLowerCase() === normalizedValue;
        }

        return (
          String(user.profile?.[field] || "").toLowerCase() === normalizedValue
        );
      })
      .slice(0, limit)
      .map((user) => structuredClone(user));
  }

  // ── Phase 6 chunk 1: onboarding + kinship-checks ────────────────

  /// State-based idempotent seed (DECISIONS.md 2026-05-13). User
  /// retry на network fail → returns existing tree. Incomplete
  /// previous attempt → replaced (transaction rollback).
  ///
  /// payload = {
  ///   profile: {name, gender, birthDate},
  ///   relatives: [{name, gender, birthDate, relationToMe}],
  /// }
  /// relationToMe ∈ {'mother','father','sibling','child','grandmother','grandfather'}.
  async seedOnboarding({userId, payload}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return {error: "NO_USER"};
    const db = await this._read();
    const user = db.users.find((u) => u.id === normalizedUser);
    if (!user) return {error: "USER_NOT_FOUND"};

    // State-based idempotency check.
    const existingState = (db.onboardingStates || []).find(
      (s) => s.userId === normalizedUser,
    );
    if (existingState && existingState.completed === true) {
      // Idempotent re-call — return existing tree.
      return {
        treeId: existingState.treeId,
        personIds: existingState.personIds || [],
        idempotent: true,
      };
    }

    // Incomplete previous attempt → replace. Wipe previous tree's
    // persons + relations to avoid ghost tree.
    if (existingState && existingState.treeId) {
      const prevTreeId = existingState.treeId;
      db.persons = (db.persons || []).filter((p) => p.treeId !== prevTreeId);
      db.relations = (db.relations || []).filter(
        (r) => r.treeId !== prevTreeId,
      );
      db.trees = (db.trees || []).filter((t) => t.id !== prevTreeId);
    }

    // Apply profile to user record (additive — не затирать существующее).
    const profile = payload?.profile || {};
    user.profile = user.profile || {};
    if (profile.name) user.profile.displayName = String(profile.name).trim();
    if (profile.gender) user.profile.gender = String(profile.gender);
    if (profile.birthDate) {
      user.profile.birthDate = String(profile.birthDate);
    }

    // Create tree.
    const treeId = crypto.randomUUID();
    const now = nowIso();
    const tree = {
      id: treeId,
      name: "Моя семья",
      description: "",
      creatorId: normalizedUser,
      memberIds: [normalizedUser],
      members: [normalizedUser],
      createdAt: now,
      updatedAt: now,
      isPrivate: true,
    };
    db.trees = db.trees || [];
    db.trees.push(tree);

    // Create self-person.
    const selfIdentity = this._ensureUserIdentity(db, normalizedUser);
    const selfPerson = {
      id: crypto.randomUUID(),
      treeId,
      userId: normalizedUser,
      identityId: selfIdentity?.id || null,
      name: String(profile.name || user.profile?.displayName || "").trim(),
      gender: String(profile.gender || "unknown"),
      birthDate: profile.birthDate || null,
      isAlive: true,
      createdAt: now,
      updatedAt: now,
      creatorId: normalizedUser,
    };
    db.persons = db.persons || [];
    db.persons.push(selfPerson);

    // Create relatives + relations.
    const relatives = Array.isArray(payload?.relatives) ? payload.relatives : [];
    const createdPersonIds = [selfPerson.id];
    db.relations = db.relations || [];
    for (const rel of relatives) {
      const relativeId = crypto.randomUUID();
      const relativePerson = {
        id: relativeId,
        treeId,
        userId: null,
        identityId: null, // No identity-matching during wizard (Q9).
        name: String(rel.name || "").trim(),
        gender: String(rel.gender || "unknown"),
        birthDate: rel.birthDate || null,
        isAlive: true,
        createdAt: now,
        updatedAt: now,
        creatorId: normalizedUser,
      };
      db.persons.push(relativePerson);
      createdPersonIds.push(relativeId);

      // Encode relation per relationToMe (relative → self).
      const relationToMe = String(rel.relationToMe || "other");
      const relationPair = this._inferRelationPair(relationToMe);
      if (relationPair) {
        db.relations.push({
          id: crypto.randomUUID(),
          treeId,
          person1Id: relativeId,
          person2Id: selfPerson.id,
          relation1to2: relationPair.relativeToSelf,
          relation2to1: relationPair.selfToRelative,
          isConfirmed: true,
          createdAt: now,
          createdBy: normalizedUser,
        });
      }
    }

    // Persist onboarding state.
    db.onboardingStates = db.onboardingStates || [];
    const stateIndex = db.onboardingStates.findIndex(
      (s) => s.userId === normalizedUser,
    );
    const state = {
      userId: normalizedUser,
      completed: true,
      currentStep: "done",
      treeId,
      personIds: createdPersonIds,
      completedAt: now,
      updatedAt: now,
    };
    if (stateIndex >= 0) {
      db.onboardingStates[stateIndex] = state;
    } else {
      db.onboardingStates.push(state);
    }

    await this._write(db);
    // Write-through: seedOnboarding записывает финальное состояние
    // wizard'а (`completed: true`) через собственный code path, не
    // через `updateOnboardingState`. Без явной синхронизации
    // hasIncompleteOnboarding после login возвращает stale `true`
    // (regression caught by auth-onboarding-redirect.test.js
    // "login after seed completes → requiresOnboarding=false").
    // Идемпотентный early-return выше cache не трогает — он опирается
    // на уже кэшированное `false` от предыдущего seed.
    this._onboardingIncompleteCache.set(normalizedUser, false);
    return {treeId, personIds: createdPersonIds, idempotent: false};
  }

  _inferRelationPair(relationToMe) {
    switch (relationToMe) {
      case "mother":
      case "father":
        return {relativeToSelf: "parent", selfToRelative: "child"};
      case "sibling":
        return {relativeToSelf: "sibling", selfToRelative: "sibling"};
      case "child":
        return {relativeToSelf: "child", selfToRelative: "parent"};
      case "grandmother":
      case "grandfather":
        return {relativeToSelf: "grandparent", selfToRelative: "grandchild"};
      case "spouse":
        return {relativeToSelf: "spouse", selfToRelative: "spouse"};
      default:
        return null;
    }
  }

  async getOnboardingState({userId}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return null;
    const db = await this._read();
    const state = (db.onboardingStates || []).find(
      (s) => s.userId === normalizedUser,
    );
    if (!state) {
      return {
        userId: normalizedUser,
        completed: false,
        currentStep: "welcome",
        treeId: null,
        personIds: [],
        // Ship Q1: skipped state default false. Field added for
        // mama-unblock — user может попросить «Пропустить» wizard,
        // backend marks skipped=true чтобы `hasIncompleteOnboarding`
        // returns false (session.requiresOnboarding=false → no
        // forced redirect). Wizard остаётся resumable.
        skipped: false,
        skippedAt: null,
      };
    }
    // Backward-compat: existing pre-Q1 records без skipped field —
    // default к false без mutating storage.
    return {
      ...structuredClone(state),
      skipped: state.skipped === true,
      skippedAt: state.skippedAt ?? null,
    };
  }

  /// Phase 6 chunk 4a: distinguishes «mid-wizard user» from «legacy
  /// user без onboarding record». Returns true ТОЛЬКО для existing
  /// `onboardingStates` row с `completed=false`. Legacy users
  /// (no record) → false (existing tree → no redirect).
  ///
  /// `getOnboardingState` нельзя re-use потому что он fills default
  /// `{completed: false}` для missing records — would incorrectly
  /// flag every legacy user as needing wizard.
  async hasIncompleteOnboarding({userId}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return false;
    // Cached lookup keeps `/v1/auth/session` на cache-only hot path.
    // Endpoint вызывается клиентом на каждом router-tick'е; лишний
    // `_read` нарушает invariant api.test.js:13345 «auth session
    // endpoint can serve from cached auth context». Cache is
    // write-through через `updateOnboardingState` и invalidated в
    // `_forgetUser`; cache miss → fall back to `_read` (legacy users
    // ИЛИ users существовавшие ДО первого reader'а, например после
    // restart процесса).
    const cached = this._onboardingIncompleteCache.get(normalizedUser);
    if (cached !== undefined) {
      return cached;
    }
    const db = await this._read();
    const state = (db.onboardingStates || []).find(
      (s) => s.userId === normalizedUser,
    );
    // Ship Q1: skipped users treated как «not requiring onboarding»
    // (session.requiresOnboarding=false). Wizard accessible via direct
    // nav (banner CTA на home), но не блокирует main app navigation.
    // Без этого мама stuck в wizard — issue #1 reported 2026-05-25.
    const result = state
      ? state.completed !== true && state.skipped !== true
      : false;
    this._onboardingIncompleteCache.set(normalizedUser, result);
    return result;
  }

  async updateOnboardingState({userId, currentStep}) {
    const normalizedUser = normalizeNullableString(userId);
    const normalizedStep = String(currentStep || "").trim();
    const validSteps = ["welcome", "profile", "relatives", "finish", "done"];
    if (!normalizedUser || !validSteps.includes(normalizedStep)) {
      return null;
    }
    const db = await this._read();
    db.onboardingStates = db.onboardingStates || [];
    const idx = db.onboardingStates.findIndex(
      (s) => s.userId === normalizedUser,
    );
    const now = nowIso();
    if (idx >= 0) {
      db.onboardingStates[idx].currentStep = normalizedStep;
      db.onboardingStates[idx].updatedAt = now;
      if (normalizedStep === "done") {
        db.onboardingStates[idx].completed = true;
        // Ship Q1: completion overrides skip — wizard finished, clear
        // skipped flag чтобы state semantics consistent (skipped=true
        // означает «I haven't done wizard yet, deferred»; completed=true
        // implies wizard finished, regardless of prior skip).
        db.onboardingStates[idx].skipped = false;
        db.onboardingStates[idx].skippedAt = null;
      }
    } else {
      db.onboardingStates.push({
        userId: normalizedUser,
        completed: normalizedStep === "done",
        currentStep: normalizedStep,
        treeId: null,
        personIds: [],
        updatedAt: now,
        skipped: false,
        skippedAt: null,
      });
    }
    await this._write(db);
    const persisted = db.onboardingStates.find(
      (s) => s.userId === normalizedUser,
    );
    // Write-through: keep `_onboardingIncompleteCache` consistent с
    // нового состояния (см. комментарий в `hasIncompleteOnboarding`).
    this._onboardingIncompleteCache.set(
      normalizedUser,
      persisted.completed !== true && persisted.skipped !== true,
    );
    return structuredClone(persisted);
  }

  /// Ship Q1 (2026-05-25): user explicitly defers wizard. Sets
  /// skipped=true, skippedAt=now atomically. Idempotent — re-calling
  /// no-ops если already skipped. completed=true takes precedence
  /// (skipping after completion = no-op, completion stays).
  ///
  /// Effect: `hasIncompleteOnboarding` returns false → session
  /// .requiresOnboarding=false → main app accessible. Wizard
  /// resumable via direct nav (home banner CTA).
  async skipOnboardingState({userId}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return null;
    const db = await this._read();
    db.onboardingStates = db.onboardingStates || [];
    const idx = db.onboardingStates.findIndex(
      (s) => s.userId === normalizedUser,
    );
    const now = nowIso();
    let state;
    if (idx >= 0) {
      // No-op если уже completed (completion takes precedence)
      if (db.onboardingStates[idx].completed === true) {
        state = db.onboardingStates[idx];
      } else {
        if (db.onboardingStates[idx].skipped !== true) {
          db.onboardingStates[idx].skipped = true;
          db.onboardingStates[idx].skippedAt = now;
          db.onboardingStates[idx].updatedAt = now;
          await this._write(db);
        }
        state = db.onboardingStates[idx];
      }
    } else {
      // No prior record — create one с skipped=true, step=welcome
      state = {
        userId: normalizedUser,
        completed: false,
        currentStep: "welcome",
        treeId: null,
        personIds: [],
        updatedAt: now,
        skipped: true,
        skippedAt: now,
      };
      db.onboardingStates.push(state);
      await this._write(db);
    }
    this._onboardingIncompleteCache.set(
      normalizedUser,
      state.completed !== true && state.skipped !== true,
    );
    return structuredClone(state);
  }

  // ── Kinship checks (BFS «мы родственники?») ─────────────────────

  static get _kinshipCheckTtlMs() {
    return 14 * 86_400_000; // 14 days
  }

  static get _kinshipRejectionCooldownMs() {
    return 30 * 86_400_000; // 30 days anti-harassment
  }

  /// On-read expiry mutation — sweeps pending → expired когда now >
  /// expiresAt. Notifications dispatched at endpoint layer (store
  /// returns ids of newly-expired для caller to notify).
  _sweepExpiredKinshipChecks(db) {
    const now = Date.now();
    const newlyExpired = [];
    for (const check of db.kinshipChecks || []) {
      if (check.status !== "pending") continue;
      const expiresAt = new Date(check.expiresAt || 0).getTime();
      if (Number.isFinite(expiresAt) && now > expiresAt) {
        check.status = "expired";
        check.expiredAt = nowIso();
        newlyExpired.push(check.id);
      }
    }
    return newlyExpired;
  }

  async createKinshipCheck({initiatorUserId, targetUserId}) {
    const normalizedInitiator = normalizeNullableString(initiatorUserId);
    const normalizedTarget = normalizeNullableString(targetUserId);
    if (!normalizedInitiator || !normalizedTarget) {
      return {error: "INVALID_INPUT"};
    }
    if (normalizedInitiator === normalizedTarget) {
      return {error: "SELF_CHECK_FORBIDDEN"};
    }
    const db = await this._read();
    const targetUser = db.users.find((u) => u.id === normalizedTarget);
    if (!targetUser) return {error: "TARGET_NOT_FOUND"};

    // Lazy expiry sweep before duplicate/cooldown checks.
    this._sweepExpiredKinshipChecks(db);

    // Idempotency: same pending pair → return existing.
    const existingPending = (db.kinshipChecks || []).find(
      (c) =>
        c.initiatorUserId === normalizedInitiator &&
        c.targetUserId === normalizedTarget &&
        c.status === "pending",
    );
    if (existingPending) {
      await this._write(db); // persist sweep results
      return {check: structuredClone(existingPending), created: false};
    }

    // Anti-harassment: 30d cooldown after rejection.
    const lastRejected = (db.kinshipChecks || [])
      .filter(
        (c) =>
          c.initiatorUserId === normalizedInitiator &&
          c.targetUserId === normalizedTarget &&
          c.status === "rejected",
      )
      .sort(
        (a, b) =>
          new Date(b.respondedAt || 0).getTime() -
          new Date(a.respondedAt || 0).getTime(),
      )[0];
    if (lastRejected) {
      const elapsed =
        Date.now() - new Date(lastRejected.respondedAt || 0).getTime();
      if (elapsed < FileStore._kinshipRejectionCooldownMs) {
        return {
          error: "REJECTION_COOLDOWN",
          retryAfterMs: FileStore._kinshipRejectionCooldownMs - elapsed,
        };
      }
    }

    const now = nowIso();
    const check = {
      id: crypto.randomUUID(),
      initiatorUserId: normalizedInitiator,
      targetUserId: normalizedTarget,
      status: "pending",
      createdAt: now,
      expiresAt: new Date(
        Date.now() + FileStore._kinshipCheckTtlMs,
      ).toISOString(),
      respondedAt: null,
      expiredAt: null,
      // Phase 6.5: initiator revocation timestamp. Stays null до
      // initiator вызывает /v1/kinship-checks/:id/revoke.
      revokedAt: null,
      result: null,
    };
    db.kinshipChecks = db.kinshipChecks || [];
    db.kinshipChecks.push(check);
    await this._write(db);
    return {check: structuredClone(check), created: true};
  }

  async listKinshipChecksForUser({userId, role, status}) {
    const normalizedUser = normalizeNullableString(userId);
    if (!normalizedUser) return [];
    const normalizedRole = role === "target" ? "target" : "initiator";
    const db = await this._read();
    const newlyExpired = this._sweepExpiredKinshipChecks(db);
    if (newlyExpired.length > 0) await this._write(db);

    const field =
      normalizedRole === "target" ? "targetUserId" : "initiatorUserId";
    let filtered = (db.kinshipChecks || []).filter(
      (c) => c[field] === normalizedUser,
    );
    if (status) {
      filtered = filtered.filter((c) => c.status === String(status));
    }
    return filtered.map((c) => structuredClone(c));
  }

  async findKinshipCheck({checkId}) {
    const normalizedId = normalizeNullableString(checkId);
    if (!normalizedId) return null;
    const db = await this._read();
    this._sweepExpiredKinshipChecks(db);
    const check = (db.kinshipChecks || []).find((c) => c.id === normalizedId);
    if (!check) return null;
    return structuredClone(check);
  }

  /// Respond to pending check. Decision ∈ {'accepted','rejected'}.
  /// On accept — compute BFS via findBloodRelation(maxDepth=4) +
  /// store result. On reject — mark rejected.
  /// Permission: only target can respond. Caller must verify
  /// req.auth.user.id === check.targetUserId.
  async respondToKinshipCheck({checkId, decision}) {
    const normalizedId = normalizeNullableString(checkId);
    const normalizedDecision = String(decision || "").trim();
    if (!normalizedId || !["accepted", "rejected"].includes(normalizedDecision)) {
      return {error: "INVALID_INPUT"};
    }
    const db = await this._read();
    this._sweepExpiredKinshipChecks(db);
    const check = (db.kinshipChecks || []).find((c) => c.id === normalizedId);
    if (!check) return {error: "NOT_FOUND"};
    if (check.status !== "pending") {
      return {error: "NOT_PENDING", currentStatus: check.status};
    }

    const now = nowIso();
    check.status = normalizedDecision;
    check.respondedAt = now;

    if (normalizedDecision === "accepted") {
      // Compute BFS на 4 hops cap (Q10 decision).
      const initiatorSelfId = this._selfGraphPersonIdForUser(
        db,
        check.initiatorUserId,
      );
      const targetSelfId = this._selfGraphPersonIdForUser(
        db,
        check.targetUserId,
      );
      if (!initiatorSelfId || !targetSelfId) {
        check.result = {found: false, label: "Не удалось определить связь", degree: 0};
      } else {
        const path = this._findBloodRelationBetween(
          db,
          initiatorSelfId,
          targetSelfId,
          {maxDepth: FileStore._connectedVisibilityMaxHops},
        );
        if (path === null) {
          check.result = {
            found: false,
            label: "Связь не найдена",
            degree: 0,
            chain: [],
            edges: [],
          };
        } else {
          check.result = {
            found: true,
            label: path.label,
            degree: path.degree,
            chain: path.chain,
            edges: path.edges,
          };
        }
      }
    }

    await this._write(db);
    return {check: structuredClone(check)};
  }

  /// Phase 6.5: initiator revokes own pending request. Permission:
  /// only initiator. Pre-condition: status === "pending". State
  /// transition: pending → revoked (final). On success — caller
  /// (route handler) dispatches `kinship_check_revoked` notification
  /// к target.
  ///
  /// Errors: INVALID_INPUT, NOT_FOUND, NOT_INITIATOR, NOT_PENDING.
  /// Re-revoke (status='revoked') returns NOT_PENDING с
  /// currentStatus='revoked' — guards против double notification
  /// dispatch при network retry.
  async revokeKinshipCheck({checkId, initiatorUserId}) {
    const normalizedId = normalizeNullableString(checkId);
    const normalizedInitiator = normalizeNullableString(initiatorUserId);
    if (!normalizedId || !normalizedInitiator) {
      return {error: "INVALID_INPUT"};
    }
    const db = await this._read();
    this._sweepExpiredKinshipChecks(db);
    const check = (db.kinshipChecks || []).find((c) => c.id === normalizedId);
    if (!check) return {error: "NOT_FOUND"};
    if (check.initiatorUserId !== normalizedInitiator) {
      return {error: "NOT_INITIATOR"};
    }
    if (check.status !== "pending") {
      return {error: "NOT_PENDING", currentStatus: check.status};
    }

    const now = nowIso();
    check.status = "revoked";
    check.revokedAt = now;

    await this._write(db);
    return {check: structuredClone(check)};
  }

  // ── Retention for unbounded LOG / history collections ─────────────
  // These are NOT soft-delete tombstones (that is hardDeleteExpired's
  // job) but append-only logs/history that bloat the whole-document blob.
  // The store rewrites the ENTIRE blob on every write, so persist latency
  // ∝ total blob size — a prod blob measured 8 MB gave ~2.5 s message-send
  // ack, ~1.6 s of it just re-serialising the blob (see
  // docs/speed_measurement.md). Trimming these by age/cap shrinks the blob
  // and speeds up EVERY write app-wide.
  //
  // Mutates `db` in place ONLY when !dryRun; always returns counts so a dry
  // run reports what it WOULD trim. Pure in-memory — no nested store calls
  // (runs inside hardDeleteExpired, which owns the single _read/_write).
  _sweepUnboundedLogs(db, retention = {}, {nowTs, dryRun = false} = {}) {
    const HOUR = 3_600_000;
    const DAY = 86_400_000;
    const counts = {
      callsTerminal: 0,
      pushDeliveries: 0,
      notificationsSilent: 0,
      notificationsRead: 0,
      notificationsUnread: 0,
      treeChangeDetailsStripped: 0,
    };
    const parseTs = (value) => {
      const t = value ? Date.parse(value) : NaN;
      return Number.isFinite(t) ? t : null;
    };
    // A newest-N cap. Returns null for 0 / negative / non-numeric so the cap
    // is DISABLED (matching the "0 disables an individual trim" config
    // contract) instead of slice(0) wiping the whole collection.
    const positiveIntOrNull = (value) => {
      const n = Math.floor(Number(value));
      return Number.isFinite(n) && n > 0 ? n : null;
    };

    // ── db.calls: terminal-only TTL + newest-N cap. Busy calls
    //   (ringing/active) are NEVER trimmed — dropping a live call breaks
    //   busy-detection / resume / join / webhook teardown. The durable
    //   user-facing call log lives in db.messages (call payload), not here.
    const callsTtlMs =
      Math.max(0, Number(retention.callsTerminalHours ?? 24)) * HOUR;
    const callsMax = positiveIntOrNull(retention.callsTerminalMax ?? 500);
    if (Array.isArray(db.calls) && db.calls.length) {
      // null when no parseable timestamp — such a call is never TTL-trimmed
      // (we never delete on an unknown age), only cap-trimmed as oldest.
      const callTs = (c) =>
        parseTs(c.updatedAt) ?? parseTs(c.endedAt) ?? parseTs(c.createdAt);
      const remove = new Set();
      for (const call of db.calls) {
        if (!isCallTerminalState(call.state)) continue; // keep busy calls
        const ts = callTs(call);
        if (callsTtlMs > 0 && ts !== null && nowTs - ts > callsTtlMs) {
          remove.add(call);
        }
      }
      // Cap: among still-surviving terminal calls, keep only newest callsMax.
      // callsMax === null (knob 0 / non-numeric) DISABLES the cap.
      if (callsMax !== null) {
        const survivingTerminal = db.calls
          .filter((c) => isCallTerminalState(c.state) && !remove.has(c))
          .sort((a, b) => (callTs(b) ?? 0) - (callTs(a) ?? 0));
        for (const call of survivingTerminal.slice(callsMax)) remove.add(call);
      }
      counts.callsTerminal = remove.size;
      if (!dryRun && remove.size) {
        db.calls = db.calls.filter((c) => !remove.has(c));
      }
    }

    // ── db.pushDeliveries: pure telemetry log. Age TTL + newest-N cap.
    //   No user feature reads it back (only an ops debug endpoint).
    const pushTtlMs =
      Math.max(0, Number(retention.pushDeliveriesDays ?? 7)) * DAY;
    const pushMax = positiveIntOrNull(retention.pushDeliveriesMax ?? 2000);
    if (Array.isArray(db.pushDeliveries) && db.pushDeliveries.length) {
      const pdTs = (d) => parseTs(d.createdAt) ?? parseTs(d.updatedAt);
      const remove = new Set();
      for (const delivery of db.pushDeliveries) {
        const ts = pdTs(delivery);
        if (pushTtlMs > 0 && ts !== null && nowTs - ts > pushTtlMs) {
          remove.add(delivery);
        }
      }
      // pushMax === null (knob 0 / non-numeric) DISABLES the cap.
      if (pushMax !== null) {
        const surviving = db.pushDeliveries
          .filter((d) => !remove.has(d))
          .sort((a, b) => (pdTs(b) ?? 0) - (pdTs(a) ?? 0));
        for (const delivery of surviving.slice(pushMax)) remove.add(delivery);
      }
      counts.pushDeliveries = remove.size;
      if (!dryRun && remove.size) {
        db.pushDeliveries = db.pushDeliveries.filter((d) => !remove.has(d));
      }
    }

    // ── db.notifications: mixed. The feature shows only the newest ≤50
    //   UNREAD per user, so all three windows sit far past any live item:
    //     • silent:true  (tree_mutated / call_ended pings) — transient,
    //       already delivered via realtime+push → drop after 48h.
    //     • read (readAt set) — no read-history screen re-reads them → 30d.
    //     • unread — stale beyond a year → 365d (generous safety margin).
    const notifSilentMs =
      Math.max(0, Number(retention.notifSilentHours ?? 48)) * HOUR;
    const notifReadMs =
      Math.max(0, Number(retention.notifReadDays ?? 30)) * DAY;
    const notifUnreadMs =
      Math.max(0, Number(retention.notifUnreadDays ?? 365)) * DAY;
    if (Array.isArray(db.notifications) && db.notifications.length) {
      const remove = new Set();
      for (const notif of db.notifications) {
        const createdTs = parseTs(notif.createdAt);
        // Never delete a notification we cannot age (missing/unparseable
        // createdAt) — a live unread item must never be silently removed.
        if (createdTs === null) continue;
        const age = nowTs - createdTs;
        if (notif.silent === true) {
          if (notifSilentMs > 0 && age > notifSilentMs) {
            remove.add(notif);
            counts.notificationsSilent += 1;
          }
        } else if (notif.readAt) {
          // Возраст прочитанного — от readAt (см. Postgres-sweep): иначе
          // массовое «Прочитать всё» отправляло бы старый бэклог под
          // 30-дневное окно в первый же ночной проход.
          const readTs = parseTs(notif.readAt);
          const readAge = readTs === null ? age : nowTs - readTs;
          if (notifReadMs > 0 && readAge > notifReadMs) {
            remove.add(notif);
            counts.notificationsRead += 1;
          }
        } else if (notifUnreadMs > 0 && age > notifUnreadMs) {
          remove.add(notif);
          counts.notificationsUnread += 1;
        }
      }
      if (!dryRun && remove.size) {
        db.notifications = db.notifications.filter((n) => !remove.has(n));
      }
    }

    // ── db.treeChangeRecords: feature-backing HISTORY, but the byte driver
    //   is the full before/after/mergedFrom entity snapshots embedded on
    //   high-churn person.*/relation.* records (3.5 MB in prod). The client
    //   history sheet renders only type + names + timestamps — it NEVER
    //   reads details.before/after — so stripping those heavy keys from old
    //   NON-article records is invisible, KEEPS the record (timeline intact),
    //   and reclaims the bulk. article.* records (biography edit provenance —
    //   family-memory north-star) are left fully intact.
    const treeDetailMs =
      Math.max(0, Number(retention.treeChangeDetailDays ?? 30)) * DAY;
    if (treeDetailMs > 0) {
      counts.treeChangeDetailsStripped += this._stripTreeChangeDetails(db, {
        cutoffTs: nowTs - treeDetailMs,
        dryRun,
      });
    }

    return counts;
  }

  // ── Phase 3.6: hard-delete background job ─────────────────────────
  // Sweeps physically deleted entries past their retention window:
  //   * `graphPersons`    — Path A explicit `hardDeleteScheduledAt`
  //                         set к deletedAt+30d; Path B
  //                         (`_reconcilePersonIdentities`) leaves null,
  //                         fallback на deletedAt + retentionDays.
  //   * `graphRelations`  — reconciliation tombstones, age-based.
  //   * `branches`        — reconciliation tombstones, age-based.
  //   * `personIdentities` — `_propagateIdentityFields` orphan
  //                          cleanup, age-based.
  //   * `branchPersonViews` — no own `deletedAt`; orphan-cleaned за
  //                            branches/graphPersons удалёнными в same
  //                            run.
  //
  // Hybrid eligibility: explicit `hardDeleteScheduledAt` wins, fallback
  // на `deletedAt + retention`. Backwards-compat с Path A + forward-
  // compat с custom per-entity extensions (e.g. user-requested
  // window).
  //
  // Order (application-level, не FK): leaf first → root last.
  //   `graphRelations` → `branches` → `personIdentities` →
  //   `graphPersons` → `branchPersonViews` (orphans от вышепроцессенных).
  //   Budget cap может halt mid-collection; partial state OK,
  //   reconciliation cleans dangling refs on next state load.
  //
  // Single full-state pass: `_read` → mutate в памяти → `_write`.
  // Atomic per document-storage (FileStore JSON write, PostgresStore
  // single-row UPDATE — all-or-nothing).
  //
  // See DECISIONS.md 2026-05-18 «Phase 3.6 hard-delete background job»
  // для альтернатив (A1 middleware inject отвергнут), rollout
  // sequence (master toggle → first-run-dry → live), risks.
  async hardDeleteExpired({
    now = new Date(),
    retentionDays = 30,
    auditRetentionDays = 90,
    maxPerRun = 10_000,
    dryRun = false,
    runId = null,
    logRetention = {},
  } = {}) {
    const startedAt = now instanceof Date ? now : new Date(now);
    const startedTs = startedAt.getTime();
    const retentionMs = retentionDays * 86_400_000;
    const auditRetentionMs = auditRetentionDays * 86_400_000;
    const effectiveRunId = runId || crypto.randomUUID();

    // Route the whole read→compute→mutate→write through _mutate so this daily
    // job serializes against every other _mutate writer (message-send, calls,
    // notifications). Otherwise its whole-blob overwrite — built on a snapshot
    // read OUTSIDE the lock — could clobber a message that was concurrently
    // appended + ack'd (the store-wide lost-update the _mutate primitive
    // closes). applyFn is pure in-memory (no awaits / nested store calls);
    // dry-run returns via skip() so it stays a pure read (no write).
    return this._mutate((db, skip) => {
    // Hybrid eligibility: explicit `hardDeleteScheduledAt` wins; иначе
    // age-based fallback (`deletedAt + retention`). Без `deletedAt` —
    // entity не soft-deleted, не eligible.
    const isEligible = (entity) => {
      if (!entity || !entity.deletedAt) return false;
      const explicit = entity.hardDeleteScheduledAt
        ? Date.parse(entity.hardDeleteScheduledAt)
        : NaN;
      const fallback = Date.parse(entity.deletedAt) + retentionMs;
      const scheduledTs = Number.isFinite(explicit) ? explicit : fallback;
      return Number.isFinite(scheduledTs) && scheduledTs < startedTs;
    };

    const buildAuditEntry = (entityType, entity) => ({
      runId: effectiveRunId,
      entityType,
      entityId: entity.id,
      deletedAt: entity.deletedAt,
      scheduledAt:
        entity.hardDeleteScheduledAt ||
        new Date(Date.parse(entity.deletedAt) + retentionMs).toISOString(),
      hardDeletedAt: startedAt.toISOString(),
    });

    let budget = Math.max(0, Math.floor(maxPerRun));
    const newAuditEntries = [];
    const deletedCounts = {
      graphPersons: 0,
      graphRelations: 0,
      branches: 0,
      personIdentities: 0,
      branchPersonViews: 0,
      // Ship Q4a (2026-05-28): deletedPersons snapshot collection
      // swept by same job. Path 2 architecture (ec12804) — physical
      // erasure after retention + 3h floor (earliestHardDelete).
      deletedPersons: 0,
      // Ship Q4a (2026-05-28, Ship 30b): deletedPosts swept same way.
      deletedPosts: 0,
      auditPruned: 0,
    };
    const sampleIds = {};
    const removeIdsByType = {
      graphRelation: new Set(),
      branch: new Set(),
      personIdentity: new Set(),
      graphPerson: new Set(),
      branchPersonView: new Set(),
    };

    // Explicit map — irregular plurals: branch→branches,
    // personIdentity→personIdentities (naive `${type}s` ломается).
    const collectionKeyByType = {
      graphRelation: "graphRelations",
      branch: "branches",
      personIdentity: "personIdentities",
      graphPerson: "graphPersons",
      branchPersonView: "branchPersonViews",
    };

    const takeEligible = (collection, entityType) => {
      const collectionKey = collectionKeyByType[entityType];
      for (const entity of collection || []) {
        if (budget <= 0) break;
        if (!isEligible(entity)) continue;
        newAuditEntries.push(buildAuditEntry(entityType, entity));
        removeIdsByType[entityType].add(entity.id);
        deletedCounts[collectionKey] += 1;
        if (!sampleIds[entityType]) sampleIds[entityType] = [];
        if (sampleIds[entityType].length < 5) {
          sampleIds[entityType].push(entity.id);
        }
        budget -= 1;
      }
    };

    takeEligible(db.graphRelations, "graphRelation");
    takeEligible(db.branches, "branch");
    takeEligible(db.personIdentities, "personIdentity");
    takeEligible(db.graphPersons, "graphPerson");

    // Ship Q4a (2026-05-28): deletedPersons sweep. Eligible rows:
    //   • restoredAt == null
    //   • hardDeleteScheduledAt < now (per existing isEligible)
    //   • earliestHardDelete < now (3h floor protection — defends
    //     against мисconfigured retention env)
    const removeDeletedPersonIds = new Set();
    for (const row of db.deletedPersons || []) {
      if (budget <= 0) break;
      if (row.restoredAt) continue;
      // Reuse isEligible — deletedPersons rows carry deletedAt +
      // hardDeleteScheduledAt в той же shape as graph entities.
      if (!isEligible(row)) continue;
      // Floor check — never purge before earliestHardDelete.
      if (
        row.earliestHardDelete &&
        Date.parse(row.earliestHardDelete) > startedTs
      ) {
        continue;
      }
      newAuditEntries.push({
        runId: effectiveRunId,
        entityType: "deletedPerson",
        entityId: row.id,
        deletedAt: row.deletedAt,
        scheduledAt: row.hardDeleteScheduledAt,
        hardDeletedAt: startedAt.toISOString(),
      });
      removeDeletedPersonIds.add(row.id);
      deletedCounts.deletedPersons += 1;
      if (!sampleIds.deletedPerson) sampleIds.deletedPerson = [];
      if (sampleIds.deletedPerson.length < 5) {
        sampleIds.deletedPerson.push(row.id);
      }
      budget -= 1;
    }

    // Ship Q4a (2026-05-28, Ship 30b): same sweep для deletedPosts.
    // Identical eligibility logic (3h floor + retention) — copy-paste
    // of persons block. Posts data sleeker (post + comments +
    // reactions snapshot), so physical erasure removes whole row.
    const removeDeletedPostIds = new Set();
    for (const row of db.deletedPosts || []) {
      if (budget <= 0) break;
      if (row.restoredAt) continue;
      if (!isEligible(row)) continue;
      if (
        row.earliestHardDelete &&
        Date.parse(row.earliestHardDelete) > startedTs
      ) {
        continue;
      }
      newAuditEntries.push({
        runId: effectiveRunId,
        entityType: "deletedPost",
        entityId: row.id,
        deletedAt: row.deletedAt,
        scheduledAt: row.hardDeleteScheduledAt,
        hardDeletedAt: startedAt.toISOString(),
      });
      removeDeletedPostIds.add(row.id);
      deletedCounts.deletedPosts += 1;
      if (!sampleIds.deletedPost) sampleIds.deletedPost = [];
      if (sampleIds.deletedPost.length < 5) {
        sampleIds.deletedPost.push(row.id);
      }
      budget -= 1;
    }

    // Orphan cleanup для branchPersonViews — views ссылающиеся на
    // branches/graphPersons удалёнными в этом run. Views не имеют
    // собственного `deletedAt`, потому отдельный path.
    for (const view of db.branchPersonViews || []) {
      if (budget <= 0) break;
      const isOrphaned =
        removeIdsByType.branch.has(view.branchId) ||
        removeIdsByType.graphPerson.has(view.graphPersonId);
      if (!isOrphaned) continue;
      const viewKey =
        view.id ?? `${view.branchId || ""}:${view.graphPersonId || ""}`;
      newAuditEntries.push({
        runId: effectiveRunId,
        entityType: "branchPersonView",
        entityId: viewKey,
        deletedAt: null,
        scheduledAt: null,
        hardDeletedAt: startedAt.toISOString(),
      });
      removeIdsByType.branchPersonView.add(viewKey);
      deletedCounts.branchPersonViews += 1;
      if (!sampleIds.branchPersonView) sampleIds.branchPersonView = [];
      if (sampleIds.branchPersonView.length < 5) {
        sampleIds.branchPersonView.push(viewKey);
      }
      budget -= 1;
    }

    // Audit prune — entries старше `auditRetentionDays` от now.
    const auditPrune = this._pruneHardDeleteAudit(db, {
      cutoffTs: startedTs - auditRetentionMs,
      dryRun,
    });
    const survivingAudit = auditPrune.surviving;
    deletedCounts.auditPruned += auditPrune.pruned;

    const totalDeleted =
      deletedCounts.graphPersons +
      deletedCounts.graphRelations +
      deletedCounts.branches +
      deletedCounts.personIdentities +
      deletedCounts.branchPersonViews +
      deletedCounts.deletedPersons +
      deletedCounts.deletedPosts;

    // Retention for unbounded log/history collections (blob-shrink). Mutates
    // db in place when !dryRun; the single _write below persists it alongside
    // the tombstone sweep. Runs regardless of the maxPerRun tombstone budget
    // (its own cheap O(n) filters), so large log collections never starve
    // graph-tombstone cleanup.
    const logCounts = this._sweepUnboundedLogs(db, logRetention, {
      nowTs: startedTs,
      dryRun,
    });

    const finishedAt = new Date();
    const summary = {
      runId: effectiveRunId,
      startedAt: startedAt.toISOString(),
      finishedAt: finishedAt.toISOString(),
      durationMs: finishedAt.getTime() - startedTs,
      dryRun,
      deleted: deletedCounts,
      logRetention: logCounts,
      sampleIds,
      capHit: budget <= 0 && totalDeleted >= Math.max(0, Math.floor(maxPerRun)),
      lastRunAt: dryRun
        ? db.hardDeleteLastRunAt || null
        : startedAt.toISOString(),
    };

    // Dry-run: report counts without persisting. skip() keeps it a pure read
    // (and _sweepUnboundedLogs already no-op'd its own mutations under dryRun).
    if (dryRun) return skip(summary);

    db.graphRelations = (db.graphRelations || []).filter(
      (r) => !removeIdsByType.graphRelation.has(r.id),
    );
    db.branches = (db.branches || []).filter(
      (b) => !removeIdsByType.branch.has(b.id),
    );
    db.personIdentities = (db.personIdentities || []).filter(
      (pi) => !removeIdsByType.personIdentity.has(pi.id),
    );
    db.graphPersons = (db.graphPersons || []).filter(
      (gp) => !removeIdsByType.graphPerson.has(gp.id),
    );
    db.branchPersonViews = (db.branchPersonViews || []).filter((v) => {
      const key = v.id ?? `${v.branchId || ""}:${v.graphPersonId || ""}`;
      return !removeIdsByType.branchPersonView.has(key);
    });
    // Ship Q4a: physically erase deletedPersons rows past retention
    // + floor. Snapshot data permanently gone — recovery impossible
    // beyond этого point.
    db.deletedPersons = (db.deletedPersons || []).filter(
      (r) => !removeDeletedPersonIds.has(r.id),
    );
    // Ship Q4a (Ship 30b): same для deletedPosts.
    db.deletedPosts = (db.deletedPosts || []).filter(
      (r) => !removeDeletedPostIds.has(r.id),
    );
    db.hardDeleteAudit = [...survivingAudit, ...newAuditEntries];
    db.hardDeleteLastRunAt = startedAt.toISOString();
    return summary;
    });
  }
}

module.exports = {
  EMPTY_DB,
  stripTreeChangeRecordDetails,
  isHardDeleteAuditEntryExpired,
  FileStore,
  buildCommentReactionNotificationPlan,
  buildCommentReplyNotificationPlan,
  buildPostReactionNotificationPlan,
  buildStoryReactionNotificationPlan,
  computeNotificationCoalesceKey,
  decodeNotificationCursor,
  encodeNotificationCursor,
  createNotificationRecord,
  createPushDeliveryRecord,
  composeDisplayNameFromProfile,
  buildChatSearchSnippet,
  buildTreeGraphSnapshot,
  buildGraphWarnings,
  buildBranchVisiblePersonIds,
  buildPersonRecord,
  buildCallParticipantIdentity,
  chatMessageSearchHaystack,
  cloneUserWithAuthState,
  collectMessageMediaUrls,
  compareChatMessagesDescending,
  createChatDraftRecord,
  createChatPinRecord,
  createChatRecord,
  createPersonIdentityRecord,
  createPostRecord,
  createTreeChangeRecord,
  deriveSessionPublicId,
  describeMessagePreview,
  isExpiredAt,
  isMessageReadByUser,
  normalizeChatMessageCall,
  normalizeChatSearchQuery,
  normalizeDbState,
  normalizeNullableString,
  normalizeOptionalIsoTimestamp,
  normalizeReactionEmoji,
  normalizeSessionDeviceContext,
  normalizeParticipantIds,
  normalizePhoneNumber,
  normalizeStoredCall,
  nowIso,
  parseCallParticipantIdentity,
  parseDirectParticipantsFromChatId,
  SESSION_TOUCH_MIN_INTERVAL_MS,
  verifyPassword,
};
