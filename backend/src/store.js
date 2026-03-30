const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");

const EMPTY_DB = {
  users: [],
  sessions: [],
  trees: [],
  persons: [],
  relations: [],
  messages: [],
  relationRequests: [],
  treeInvitations: [],
  notifications: [],
  pushDevices: [],
  pushDeliveries: [],
};

function nowIso() {
  return new Date().toISOString();
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

function createNotificationRecord({userId, type, title, body, data = {}}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    userId,
    type: String(type || "generic"),
    title: String(title || "").trim(),
    body: String(body || "").trim(),
    data: data && typeof data === "object" ? structuredClone(data) : {},
    createdAt: timestamp,
    readAt: null,
  };
}

function createPushDeviceRecord({
  userId,
  provider,
  token,
  platform = "unknown",
}) {
  const timestamp = nowIso();
  return {
    id: crypto.randomUUID(),
    userId,
    provider: String(provider || "unknown").trim(),
    token: String(token || "").trim(),
    platform: String(platform || "unknown").trim(),
    createdAt: timestamp,
    updatedAt: timestamp,
    lastSeenAt: timestamp,
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
  };
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

function buildPersonRecord({
  treeId,
  creatorId,
  userId = null,
  personData = {},
}) {
  const createdAt = nowIso();
  const birthDate = normalizeIsoDate(personData.birthDate);
  const deathDate = normalizeIsoDate(personData.deathDate);

  return {
    id: crypto.randomUUID(),
    treeId,
    userId,
    name: fullNameFromPersonInput(personData),
    maidenName: normalizeNullableString(personData.maidenName),
    photoUrl: normalizeNullableString(personData.photoUrl),
    gender: String(personData.gender || "unknown"),
    birthDate,
    birthPlace: normalizeNullableString(personData.birthPlace),
    deathDate,
    deathPlace: normalizeNullableString(personData.deathPlace),
    bio: normalizeNullableString(personData.bio),
    isAlive: deathDate === null,
    creatorId,
    createdAt,
    updatedAt: createdAt,
    notes: normalizeNullableString(personData.notes),
  };
}

function hashPassword(password, salt = crypto.randomBytes(16).toString("hex")) {
  const derivedKey = crypto.scryptSync(password, salt, 64).toString("hex");
  return {
    salt,
    passwordHash: derivedKey,
  };
}

function verifyPassword(password, user) {
  const derivedKey = crypto
    .scryptSync(password, user.passwordSalt, 64)
    .toString("hex");

  return crypto.timingSafeEqual(
    Buffer.from(derivedKey, "hex"),
    Buffer.from(user.passwordHash, "hex"),
  );
}

class FileStore {
  constructor(dataPath) {
    this.dataPath = dataPath;
    this._writeQueue = Promise.resolve();
  }

  async initialize() {
    await fs.mkdir(path.dirname(this.dataPath), {recursive: true});

    try {
      await fs.access(this.dataPath);
    } catch {
      await fs.writeFile(
        this.dataPath,
        JSON.stringify(EMPTY_DB, null, 2),
        "utf8",
      );
    }
  }

  async _read() {
    await this.initialize();
    await this._writeQueue;
    const raw = await fs.readFile(this.dataPath, "utf8");
    const parsed = JSON.parse(raw);
    return {
      users: Array.isArray(parsed.users) ? parsed.users : [],
      sessions: Array.isArray(parsed.sessions) ? parsed.sessions : [],
      trees: Array.isArray(parsed.trees) ? parsed.trees : [],
      persons: Array.isArray(parsed.persons) ? parsed.persons : [],
      relations: Array.isArray(parsed.relations) ? parsed.relations : [],
      messages: Array.isArray(parsed.messages) ? parsed.messages : [],
      relationRequests: Array.isArray(parsed.relationRequests)
        ? parsed.relationRequests
        : [],
      treeInvitations: Array.isArray(parsed.treeInvitations)
        ? parsed.treeInvitations
        : [],
      notifications: Array.isArray(parsed.notifications) ? parsed.notifications : [],
      pushDevices: Array.isArray(parsed.pushDevices) ? parsed.pushDevices : [],
      pushDeliveries: Array.isArray(parsed.pushDeliveries)
        ? parsed.pushDeliveries
        : [],
    };
  }

  async _write(data) {
    this._writeQueue = this._writeQueue.then(async () => {
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

  async createUser({email, password, displayName}) {
    const db = await this._read();
    const normalizedEmail = String(email || "").trim().toLowerCase();

    if (db.users.some((user) => user.email === normalizedEmail)) {
      throw new Error("EMAIL_ALREADY_EXISTS");
    }

    const createdAt = nowIso();
    const {salt, passwordHash} = hashPassword(password);
    const userId = crypto.randomUUID();

    const nameParts = String(displayName || "")
      .trim()
      .split(/\s+/)
      .filter(Boolean);

    const user = {
      id: userId,
      email: normalizedEmail,
      passwordHash,
      passwordSalt: salt,
      providerIds: ["password"],
      createdAt,
      updatedAt: createdAt,
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
        countryCode: null,
        countryName: null,
        city: "",
        photoUrl: null,
        isPhoneVerified: false,
        gender: "unknown",
        maidenName: "",
        birthDate: null,
        createdAt,
        updatedAt: createdAt,
      },
      profileNotes: [],
    };

    db.users.push(user);
    await this._write(db);
    return structuredClone(user);
  }

  async authenticate(email, password) {
    const db = await this._read();
    const normalizedEmail = String(email || "").trim().toLowerCase();
    const user = db.users.find((entry) => entry.email === normalizedEmail);

    if (!user || !verifyPassword(password, user)) {
      return null;
    }

    return structuredClone(user);
  }

  async findUserById(userId) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    return user ? structuredClone(user) : null;
  }

  async createSession(userId) {
    const db = await this._read();
    const createdAt = nowIso();
    const token = crypto.randomBytes(32).toString("hex");
    const refreshToken = crypto.randomBytes(32).toString("hex");

    db.sessions = db.sessions.filter((session) => session.userId !== userId);
    db.sessions.push({
      token,
      refreshToken,
      userId,
      createdAt,
      lastSeenAt: createdAt,
    });

    await this._write(db);
    return {
      token,
      refreshToken,
    };
  }

  async findSession(token) {
    const db = await this._read();
    const session = db.sessions.find((entry) => entry.token === token);
    return session ? structuredClone(session) : null;
  }

  async touchSession(token) {
    const db = await this._read();
    const session = db.sessions.find((entry) => entry.token === token);
    if (!session) {
      return null;
    }

    session.lastSeenAt = nowIso();
    await this._write(db);
    return structuredClone(session);
  }

  async deleteSession(token) {
    const db = await this._read();
    db.sessions = db.sessions.filter((entry) => entry.token !== token);
    await this._write(db);
  }

  async deleteSessionsForUser(userId) {
    const db = await this._read();
    db.sessions = db.sessions.filter((entry) => entry.userId !== userId);
    await this._write(db);
  }

  async updateProfile(userId, updater) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const nextProfile = updater(structuredClone(user.profile));
    user.profile = {
      ...user.profile,
      ...nextProfile,
      id: user.id,
      email: user.email,
      updatedAt: nowIso(),
    };
    user.updatedAt = nowIso();

    await this._write(db);
    return structuredClone(user);
  }

  async deleteUser(userId) {
    const db = await this._read();
    db.users = db.users.filter((entry) => entry.id !== userId);
    db.sessions = db.sessions.filter((entry) => entry.userId !== userId);
    db.trees = db.trees.map((tree) => ({
      ...tree,
      memberIds: (tree.memberIds || []).filter((memberId) => memberId !== userId),
      members: (tree.members || []).filter((memberId) => memberId !== userId),
    }));
    db.persons = db.persons.filter((entry) => entry.userId !== userId);
    db.relationRequests = db.relationRequests.filter(
      (entry) => entry.senderId !== userId && entry.recipientId !== userId,
    );
    db.treeInvitations = db.treeInvitations.filter((entry) => entry.userId !== userId);
    db.notifications = db.notifications.filter((entry) => entry.userId !== userId);
    db.pushDevices = db.pushDevices.filter((entry) => entry.userId !== userId);
    db.pushDeliveries = db.pushDeliveries.filter((entry) => entry.userId !== userId);
    await this._write(db);
  }

  async createTree({creatorId, name, description, isPrivate}) {
    const db = await this._read();
    const createdAt = nowIso();
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
      publicSlug: null,
      isCertified: false,
      certificationNote: null,
    };

    const creator = db.users.find((entry) => entry.id === creatorId);
    const creatorProfile = creator?.profile || {};
    const creatorPerson = buildPersonRecord({
      treeId: tree.id,
      creatorId,
      userId: creatorId,
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
    db.persons.push(creatorPerson);
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

    if (changed) {
      tree.updatedAt = nowIso();
      await this._write(db);
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

    person.userId = userId;
    person.updatedAt = nowIso();
    if (!person.photoUrl && user.profile?.photoUrl) {
      person.photoUrl = user.profile.photoUrl;
    }
    if (!person.name) {
      person.name = composeDisplayNameFromProfile(user.profile);
    }

    tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    tree.members = Array.isArray(tree.members) ? tree.members : [];
    if (!tree.memberIds.includes(userId)) {
      tree.memberIds.push(userId);
    }
    if (!tree.members.includes(userId)) {
      tree.members.push(userId);
    }
    tree.updatedAt = nowIso();

    await this._write(db);
    return structuredClone(person);
  }

  async ensureUserPersonInTree({treeId, userId, creatorId = userId}) {
    const db = await this._read();
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (!tree) {
      return null;
    }

    const existingPerson = db.persons.find(
      (entry) => entry.treeId === treeId && entry.userId === userId,
    );
    if (existingPerson) {
      tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
      tree.members = Array.isArray(tree.members) ? tree.members : [];
      if (!tree.memberIds.includes(userId)) {
        tree.memberIds.push(userId);
      }
      if (!tree.members.includes(userId)) {
        tree.members.push(userId);
      }
      tree.updatedAt = nowIso();
      await this._write(db);
      return structuredClone(existingPerson);
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
        notes: profile.bio,
      },
    });

    db.persons.push(person);
    tree.memberIds = Array.isArray(tree.memberIds) ? tree.memberIds : [];
    tree.members = Array.isArray(tree.members) ? tree.members : [];
    if (!tree.memberIds.includes(userId)) {
      tree.memberIds.push(userId);
    }
    if (!tree.members.includes(userId)) {
      tree.members.push(userId);
    }
    tree.updatedAt = nowIso();

    await this._write(db);
    return structuredClone(person);
  }

  async listPersons(treeId) {
    const db = await this._read();
    return db.persons
      .filter((person) => person.treeId === treeId)
      .sort((left, right) => String(left.name || "").localeCompare(String(right.name || "")))
      .map((person) => structuredClone(person));
  }

  async findPerson(treeId, personId) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    return person ? structuredClone(person) : null;
  }

  async findPersonByUserId(treeId, userId) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.treeId === treeId && entry.userId === userId,
    );
    return person ? structuredClone(person) : null;
  }

  async createPerson({
    treeId,
    creatorId,
    personData,
    userId = null,
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
        return structuredClone(existingLinkedPerson);
      }
    }

    const person = buildPersonRecord({
      treeId,
      creatorId,
      personData,
      userId,
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
    }
    tree.updatedAt = nowIso();

    await this._write(db);
    return structuredClone(person);
  }

  async updatePerson(treeId, personId, personData) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

    const nextPerson = {
      ...person,
      ...personData,
    };
    nextPerson.name = fullNameFromPersonInput(nextPerson);
    nextPerson.maidenName = normalizeNullableString(nextPerson.maidenName);
    nextPerson.birthPlace = normalizeNullableString(nextPerson.birthPlace);
    nextPerson.deathPlace = normalizeNullableString(nextPerson.deathPlace);
    nextPerson.bio = normalizeNullableString(nextPerson.bio);
    nextPerson.notes = normalizeNullableString(nextPerson.notes);
    nextPerson.photoUrl = normalizeNullableString(nextPerson.photoUrl);
    nextPerson.birthDate = normalizeIsoDate(nextPerson.birthDate);
    nextPerson.deathDate = normalizeIsoDate(nextPerson.deathDate);
    nextPerson.isAlive = nextPerson.deathDate === null;
    nextPerson.updatedAt = nowIso();

    Object.assign(person, nextPerson);
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = nowIso();
    }
    await this._write(db);
    return structuredClone(person);
  }

  async deletePerson(treeId, personId) {
    const db = await this._read();
    const person = db.persons.find(
      (entry) => entry.id === personId && entry.treeId === treeId,
    );
    if (!person) {
      return null;
    }

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

    await this._write(db);
    return true;
  }

  async listRelations(treeId) {
    const db = await this._read();
    return db.relations
      .filter((relation) => relation.treeId === treeId)
      .map((relation) => structuredClone(relation));
  }

  async upsertRelation({
    treeId,
    person1Id,
    person2Id,
    relation1to2,
    relation2to1,
    isConfirmed = true,
    createdBy = null,
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

    const existingRelation = db.relations.find((entry) => {
      return (
        entry.treeId === treeId &&
        ((entry.person1Id === person1Id && entry.person2Id === person2Id) ||
          (entry.person1Id === person2Id && entry.person2Id === person1Id))
      );
    });

    const resolvedRelation2to1 =
      relation2to1 || relationMirror(relation1to2);

    if (existingRelation) {
      if (
        existingRelation.person1Id === person1Id &&
        existingRelation.person2Id === person2Id
      ) {
        existingRelation.relation1to2 = String(relation1to2 || "other");
        existingRelation.relation2to1 = String(resolvedRelation2to1 || "other");
      } else {
        existingRelation.relation1to2 = String(resolvedRelation2to1 || "other");
        existingRelation.relation2to1 = String(relation1to2 || "other");
      }
      existingRelation.isConfirmed = isConfirmed === true;
      existingRelation.updatedAt = nowIso();
      const tree = db.trees.find((entry) => entry.id === treeId);
      if (tree) {
        tree.updatedAt = nowIso();
      }
      await this._write(db);
      return structuredClone(existingRelation);
    }

    const timestamp = nowIso();
    const relation = {
      id: crypto.randomUUID(),
      treeId,
      person1Id,
      person2Id,
      relation1to2: String(relation1to2 || "other"),
      relation2to1: String(resolvedRelation2to1 || "other"),
      isConfirmed: isConfirmed === true,
      createdAt: timestamp,
      updatedAt: timestamp,
      createdBy,
    };

    db.relations.push(relation);
    const tree = db.trees.find((entry) => entry.id === treeId);
    if (tree) {
      tree.updatedAt = nowIso();
    }
    await this._write(db);
    return structuredClone(relation);
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

  async createNotification({userId, type, title, body, data}) {
    const db = await this._read();
    const user = db.users.find((entry) => entry.id === userId);
    if (!user) {
      return null;
    }

    const notification = createNotificationRecord({
      userId,
      type,
      title,
      body,
      data,
    });
    db.notifications.push(notification);
    await this._write(db);
    return structuredClone(notification);
  }

  async registerPushDevice({userId, provider, token, platform}) {
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
      await this._write(db);
      return structuredClone(existingDevice);
    }

    const device = createPushDeviceRecord({
      userId,
      provider: normalizedProvider,
      token: normalizedToken,
      platform,
    });
    db.pushDevices.push(device);
    await this._write(db);
    return structuredClone(device);
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

  async listNotifications(userId, {status = null, limit = 50} = {}) {
    const db = await this._read();
    return db.notifications
      .filter((entry) => {
        if (entry.userId !== userId) {
          return false;
        }
        if (status === "unread" && entry.readAt) {
          return false;
        }
        if (status === "read" && !entry.readAt) {
          return false;
        }
        return true;
      })
      .sort((left, right) =>
        String(right.createdAt || "").localeCompare(String(left.createdAt || "")),
      )
      .slice(0, limit)
      .map((entry) => structuredClone(entry));
  }

  async countUnreadNotifications(userId) {
    const db = await this._read();
    return db.notifications.filter((entry) => entry.userId === userId && !entry.readAt)
      .length;
  }

  async markNotificationRead(notificationId, userId) {
    const db = await this._read();
    const notification = db.notifications.find(
      (entry) => entry.id === notificationId && entry.userId === userId,
    );
    if (!notification) {
      return null;
    }

    if (!notification.readAt) {
      notification.readAt = nowIso();
      await this._write(db);
    }
    return structuredClone(notification);
  }

  async listChatMessages(chatId) {
    const db = await this._read();
    return db.messages
      .filter((message) => message.chatId === chatId)
      .sort((left, right) =>
        String(right.timestamp || "").localeCompare(String(left.timestamp || "")),
      )
      .map((message) => structuredClone(message));
  }

  async addChatMessage({chatId, senderId, text}) {
    const db = await this._read();
    const participants = String(chatId || "")
      .split("_")
      .map((value) => value.trim())
      .filter(Boolean);

    if (!participants.includes(senderId) || participants.length < 2) {
      return null;
    }

    const sender = db.users.find((entry) => entry.id === senderId);
    const timestamp = nowIso();
    const message = {
      id: crypto.randomUUID(),
      chatId,
      senderId,
      text: String(text || "").trim(),
      timestamp,
      isRead: false,
      participants,
      senderName: sender?.profile?.displayName || "Пользователь",
    };

    db.messages.push(message);
    await this._write(db);
    return structuredClone(message);
  }

  async markChatAsRead(chatId, userId) {
    const db = await this._read();
    let changed = false;

    for (const message of db.messages) {
      if (
        message.chatId === chatId &&
        message.senderId !== userId &&
        message.isRead !== true
      ) {
        message.isRead = true;
        changed = true;
      }
    }

    if (changed) {
      await this._write(db);
    }

    return changed;
  }

  async listChatPreviews(userId) {
    const db = await this._read();
    const previews = new Map();

    for (const message of db.messages) {
      const participants = Array.isArray(message.participants)
        ? message.participants
        : String(message.chatId || "")
            .split("_")
            .map((value) => value.trim())
            .filter(Boolean);

      if (!participants.includes(userId)) {
        continue;
      }

      const otherUserId = participants.find((participant) => participant !== userId);
      if (!otherUserId) {
        continue;
      }

      const existingPreview = previews.get(message.chatId);
      const shouldReplace =
        !existingPreview ||
        String(message.timestamp || "").localeCompare(
          String(existingPreview.lastMessageTime || ""),
        ) > 0;

      if (!existingPreview) {
        previews.set(message.chatId, {
          chatId: message.chatId,
          userId,
          otherUserId,
          otherUserName: "Пользователь",
          otherUserPhotoUrl: null,
          lastMessage: "",
          lastMessageTime: "",
          unreadCount: 0,
          lastMessageSenderId: "",
        });
      }

      const preview = previews.get(message.chatId);
      if (message.senderId !== userId && message.isRead !== true) {
        preview.unreadCount += 1;
      }

      if (shouldReplace) {
        preview.lastMessage = message.text;
        preview.lastMessageTime = message.timestamp;
        preview.lastMessageSenderId = message.senderId;
      }
    }

    for (const preview of previews.values()) {
      const otherUser = db.users.find((entry) => entry.id === preview.otherUserId);
      if (otherUser) {
        preview.otherUserName =
          otherUser.profile?.displayName || otherUser.email || "Пользователь";
        preview.otherUserPhotoUrl = otherUser.profile?.photoUrl || null;
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
          String(profile.phoneNumber || "")
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
}

module.exports = {
  FileStore,
};
