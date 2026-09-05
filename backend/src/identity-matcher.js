function normalizeNullableString(value) {
  const normalized = String(value || "").trim();
  return normalized ? normalized : null;
}

function normalizeName(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[^a-zа-я0-9\s-]/gi, " ")
    .replace(/\s+/g, " ");
  return normalized || null;
}

function normalizeNameTokens(value) {
  const normalized = normalizeName(value);
  if (!normalized) {
    return [];
  }
  return Array.from(new Set(normalized.split(/\s+/).filter(Boolean))).sort(
    (left, right) => left.localeCompare(right),
  );
}

function normalizeIsoDate(value) {
  const rawValue = String(value || "").trim();
  if (!rawValue) {
    return null;
  }
  const parsed = new Date(rawValue);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }
  return parsed.toISOString().slice(0, 10);
}

function normalizedBirthYear(value) {
  const date = normalizeIsoDate(value);
  return date ? date.slice(0, 4) : null;
}

function sameKnownValue(left, right) {
  const normalizedLeft = normalizeNullableString(left);
  const normalizedRight = normalizeNullableString(right);
  return normalizedLeft && normalizedRight && normalizedLeft === normalizedRight;
}

function tokenSimilarity(leftTokens, rightTokens) {
  if (leftTokens.length === 0 || rightTokens.length === 0) {
    return 0;
  }
  const rightSet = new Set(rightTokens);
  const sharedCount = leftTokens.filter((token) => rightSet.has(token)).length;
  return sharedCount / Math.max(leftTokens.length, rightTokens.length);
}

// Предвычисляет ВСЕ производные поля одного person'а, нужные
// scoreNormalizedPersons, ровно один раз. До этого рефакторинга
// scorePersonPair(left, right) заново гоняло normalizeName/
// normalizeNameTokens/normalizeIsoDate по ОБЕИМ сторонам на каждый
// вызов — а findCrossTreeIdentitySuggestions зовёт его N раз с одним
// и тем же sourcePerson (по разу на каждого кандидата), так что
// sourcePerson нормализовался N раз вместо одного. normalizeIsoDate
// вдобавок дублировался внутри одного вызова (напрямую для
// birthDate/deathDate и повторно внутри normalizedBirthYear) —
// до 4 повторных проходов по birthPlace на пару. Здесь каждое поле
// нормализуется один раз.
function normalizePersonForScoring(person) {
  const birthDate = normalizeIsoDate(person?.birthDate);
  return {
    name: normalizeName(person?.name),
    tokens: normalizeNameTokens(person?.name),
    birthDate,
    // normalizedBirthYear(value) эквивалентно normalizeIsoDate(value)
    // ?.slice(0,4) — переиспользуем уже посчитанный birthDate вместо
    // второго прохода по Date-парсингу с тем же входом.
    birthYear: birthDate ? birthDate.slice(0, 4) : null,
    gender: normalizeNullableString(person?.gender),
    birthPlace: normalizeNullableString(person?.birthPlace),
    deathDate: normalizeIsoDate(person?.deathDate),
  };
}

// Чистая функция скоринга поверх УЖЕ нормализованных person'ов.
// Идентична по семантике прежнему инлайновому телу scorePersonPair —
// вынесена, чтобы вызывающие циклы (within-tree O(n²), cross-tree
// O(n)) могли нормализовать каждого person'а один раз и переиспользовать
// результат, а не пересчитывать его на каждую пару.
function scoreNormalizedPersons(left, right) {
  const reasons = [];
  let score = 0;

  const nameExactMatch = Boolean(left.name && right.name && left.name === right.name);
  let nameSimilarity = 0;
  if (nameExactMatch) {
    score += 0.62;
    reasons.push("Совпадает ФИО");
  } else {
    nameSimilarity = tokenSimilarity(left.tokens, right.tokens);
    const minTokenCount = Math.min(left.tokens.length, right.tokens.length);
    if (nameSimilarity >= 0.85 && minTokenCount >= 2) {
      score += 0.42;
      reasons.push("Очень похожее имя");
    } else if (nameSimilarity >= 0.7 && minTokenCount >= 2) {
      score += 0.28;
      reasons.push("Похожее имя");
    }
  }

  if (left.birthDate && right.birthDate && left.birthDate === right.birthDate) {
    score += 0.28;
    reasons.push("Совпадает дата рождения");
  } else if (left.birthYear && right.birthYear && left.birthYear === right.birthYear) {
    score += 0.16;
    reasons.push("Совпадает год рождения");
  }

  if (left.gender && right.gender && left.gender === right.gender && left.gender !== "unknown") {
    score += 0.05;
    reasons.push("Совпадает пол");
  }

  if (left.birthPlace && right.birthPlace && left.birthPlace === right.birthPlace) {
    score += 0.06;
    reasons.push("Совпадает место рождения");
  }

  if (left.deathDate && right.deathDate && left.deathDate === right.deathDate) {
    score += 0.04;
    reasons.push("Совпадает дата смерти");
  }

  // nameExactMatch || nameSimilarity>=0.85 — тот же самый OR, что был
  // в оригинале (leftName===rightName || tokenSimilarity(...)>=0.85);
  // nameSimilarity переиспользуется из ветки выше вместо повторного
  // вызова tokenSimilarity.
  const hasStrongNameSignal = Boolean(
    left.name && right.name && (nameExactMatch || nameSimilarity >= 0.85),
  );
  const hasBiographicalSignal = Boolean(
    left.birthDate || right.birthDate || left.birthPlace || right.birthPlace,
  );

  if (!hasStrongNameSignal || !hasBiographicalSignal) {
    return null;
  }

  if (score < 0.78) {
    return null;
  }

  return {
    score: Math.min(0.99, Number(score.toFixed(2))),
    reasons,
  };
}

// Публичная форма для существующих вызывающих/тестов, которым нужно
// сравнить двух «сырых» person'ов за один вызов. Внутри — тонкая
// обёртка над normalizePersonForScoring + scoreNormalizedPersons.
function scorePersonPair(left, right) {
  return scoreNormalizedPersons(
    normalizePersonForScoring(left),
    normalizePersonForScoring(right),
  );
}

function findWithinTreeDuplicateCandidates({
  treeId,
  persons,
  limit = 20,
} = {}) {
  const normalizedTreeId = normalizeNullableString(treeId);
  if (!normalizedTreeId || !Array.isArray(persons)) {
    return [];
  }

  const treePersons = persons.filter((person) => {
    return (
      person &&
      typeof person === "object" &&
      person.treeId === normalizedTreeId &&
      normalizeNullableString(person.id) &&
      !normalizeNullableString(person.userId)
    );
  });

  // Нормализуем каждого person'а РОВНО ОДИН раз (O(n)) вместо того,
  // чтобы scorePersonPair пересчитывал normalizeName/normalizeIsoDate
  // и т.д. заново на каждую из O(n²) пар — на дереве из ~40 человек
  // это ~800 пар и раньше каждая заново нормализовала обе стороны.
  const normalizedPersons = treePersons.map(normalizePersonForScoring);

  const suggestions = [];
  for (let leftIndex = 0; leftIndex < treePersons.length; leftIndex += 1) {
    for (
      let rightIndex = leftIndex + 1;
      rightIndex < treePersons.length;
      rightIndex += 1
    ) {
      const left = treePersons[leftIndex];
      const right = treePersons[rightIndex];
      if (
        normalizeNullableString(left.identityId) &&
        normalizeNullableString(left.identityId) ===
          normalizeNullableString(right.identityId)
      ) {
        continue;
      }

      const match = scoreNormalizedPersons(
        normalizedPersons[leftIndex],
        normalizedPersons[rightIndex],
      );
      if (!match) {
        continue;
      }

      const [personA, personB] = [left, right].sort((a, b) =>
        String(a.id).localeCompare(String(b.id)),
      );
      suggestions.push({
        id: `${normalizedTreeId}:${personA.id}:${personB.id}`,
        treeId: normalizedTreeId,
        personA,
        personB,
        score: match.score,
        confidence: match.score >= 0.9 ? "high" : "medium",
        reasons: match.reasons,
      });
    }
  }

  return suggestions
    .sort((left, right) => {
      if (right.score !== left.score) {
        return right.score - left.score;
      }
      return left.id.localeCompare(right.id);
    })
    .slice(0, Math.max(0, Math.min(Number(limit) || 20, 100)));
}

// Phase 1.2 of unified-graph migration: cross-tree identity
// suggestions. For a single source person, score them against
// every person in the user's OTHER accessible trees and return
// medium+high confidence matches that aren't already linked or
// dismissed. Surfaces the user's natural duplicates without
// dragging them through 200 modal popups.
//
// Threshold tuning:
//   * 0.78+ score = surface (mid+high)
//   * < 0.78     = silent, never shown
//   * confidence = "high" when score >= 0.9, "medium" otherwise
// Mirrors within-tree scoring so the user sees consistent
// confidence levels across both surfaces.
function findCrossTreeIdentitySuggestions({
  sourcePerson,
  accessibleTrees,
  persons,
  dismissedTargetPersonIds = new Set(),
  limit = 10,
} = {}) {
  if (!sourcePerson || typeof sourcePerson !== "object") return [];
  if (!Array.isArray(persons) || !Array.isArray(accessibleTrees)) return [];
  const accessibleTreeIds = new Set(
    accessibleTrees.map((tree) => normalizeNullableString(tree?.id)).filter(Boolean),
  );
  const sourceTreeId = normalizeNullableString(sourcePerson.treeId);
  const sourcePersonId = normalizeNullableString(sourcePerson.id);
  if (!sourceTreeId || !sourcePersonId) return [];
  const sourceIdentityId = normalizeNullableString(sourcePerson.identityId);

  const treeNameById = new Map();
  for (const tree of accessibleTrees) {
    if (tree?.id) treeNameById.set(tree.id, tree.name || "");
  }

  // sourcePerson не меняется по ходу цикла, но раньше scorePersonPair
  // заново нормализовал его (normalizeName/tokens/даты) на КАЖДОГО
  // кандидата — то есть N раз для дерева из N всего persons в базе.
  // Нормализуем один раз здесь и сравниваем через scoreNormalizedPersons.
  const sourceNorm = normalizePersonForScoring(sourcePerson);

  const suggestions = [];
  for (const candidate of persons) {
    if (!candidate || typeof candidate !== "object") continue;
    const candidateTreeId = normalizeNullableString(candidate.treeId);
    if (!candidateTreeId || !accessibleTreeIds.has(candidateTreeId)) continue;
    // Skip persons in the source's own tree — within-tree
    // duplicates have their own surface (`/duplicates`).
    if (candidateTreeId === sourceTreeId) continue;
    const candidatePersonId = normalizeNullableString(candidate.id);
    if (!candidatePersonId) continue;
    // Skip if user already dismissed this exact pair.
    if (dismissedTargetPersonIds.has(candidatePersonId)) continue;
    // Skip if already linked via identityId — they're already
    // the "same human" in our model. (Phase 1.1 handles edit
    // propagation; the matcher only surfaces UNlinked candidates.)
    const candidateIdentityId = normalizeNullableString(candidate.identityId);
    if (
      sourceIdentityId &&
      candidateIdentityId &&
      sourceIdentityId === candidateIdentityId
    ) {
      continue;
    }

    const match = scoreNormalizedPersons(sourceNorm, normalizePersonForScoring(candidate));
    if (!match) continue;

    suggestions.push({
      sourcePersonId,
      sourceTreeId,
      targetPersonId: candidatePersonId,
      targetTreeId: candidateTreeId,
      targetTreeName: treeNameById.get(candidateTreeId) || "",
      targetPerson: candidate,
      score: match.score,
      confidence: match.score >= 0.9 ? "high" : "medium",
      reasons: match.reasons,
    });
  }

  return suggestions
    .sort((left, right) => {
      if (right.score !== left.score) return right.score - left.score;
      return left.targetPersonId.localeCompare(right.targetPersonId);
    })
    .slice(0, Math.max(0, Math.min(Number(limit) || 10, 50)));
}

module.exports = {
  findWithinTreeDuplicateCandidates,
  findCrossTreeIdentitySuggestions,
  normalizedBirthYear,
  scorePersonPair,
};
