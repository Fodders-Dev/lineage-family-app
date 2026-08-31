#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import {setTimeout as delay} from "node:timers/promises";

import {chromium} from "playwright";
import {fetchWithHttpFallback} from "./http_request_with_fallback.mjs";

const SESSION_STORAGE_KEY = "custom_api_session_v1";
const LEGACY_SHARED_PREFERENCES_PREFIX = "flutter.";
const TRANSIENT_FETCH_RETRY_LIMIT = 3;
const TRANSIENT_FETCH_RETRY_DELAY_MS = 1_000;
const TRANSIENT_HTTP_STATUS_CODES = new Set([408, 429, 502, 503, 504]);

function parseArgs(argv) {
  const options = {
    baseUrl: process.env.RODNYA_SMOKE_BASE_URL || "https://rodnya-tree.ru",
    apiUrl: process.env.RODNYA_SMOKE_API_URL || "",
    email: process.env.RODNYA_SMOKE_EMAIL || "",
    password: process.env.RODNYA_SMOKE_PASSWORD || "",
    partnerEmail: process.env.RODNYA_SMOKE_PARTNER_EMAIL || "",
    partnerPassword: process.env.RODNYA_SMOKE_PARTNER_PASSWORD || "",
    displayName: process.env.RODNYA_SMOKE_DISPLAY_NAME || "Rodnya Smoke",
    treeName: process.env.RODNYA_SMOKE_TREE_NAME || "Rodnya Smoke Tree",
    claimUrl: process.env.RODNYA_SMOKE_CLAIM_URL || "",
    inviteUrl: process.env.RODNYA_SMOKE_INVITE_URL || "",
    fixtureTreeId: process.env.RODNYA_SMOKE_FIXTURE_TREE_ID || "",
    suite: process.env.RODNYA_SMOKE_SUITE || "all",
    autoRegister:
      String(process.env.RODNYA_SMOKE_AUTO_REGISTER || "").trim() === "1",
    keepFixtures:
      String(process.env.RODNYA_SMOKE_KEEP_FIXTURES || "").trim() === "1",
    outputJson:
      process.env.RODNYA_SMOKE_OUTPUT_JSON ||
      path.join(process.cwd(), "output", "playwright", "prod-route-smoke.json"),
    chromiumExecutablePath:
      process.env.RODNYA_SMOKE_CHROMIUM_EXECUTABLE_PATH || "",
    chromiumChannel: process.env.RODNYA_SMOKE_CHROMIUM_CHANNEL || "",
    headed: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const nextValue = argv[index + 1];
    switch (token) {
      case "--base-url":
        options.baseUrl = nextValue || options.baseUrl;
        index += 1;
        break;
      case "--api-url":
        options.apiUrl = nextValue || options.apiUrl;
        index += 1;
        break;
      case "--email":
        options.email = nextValue || options.email;
        index += 1;
        break;
      case "--password":
        options.password = nextValue || options.password;
        index += 1;
        break;
      case "--partner-email":
        options.partnerEmail = nextValue || options.partnerEmail;
        index += 1;
        break;
      case "--partner-password":
        options.partnerPassword = nextValue || options.partnerPassword;
        index += 1;
        break;
      case "--display-name":
        options.displayName = nextValue || options.displayName;
        index += 1;
        break;
      case "--tree-name":
        options.treeName = nextValue || options.treeName;
        index += 1;
        break;
      case "--claim-url":
        options.claimUrl = nextValue || options.claimUrl;
        index += 1;
        break;
      case "--invite-url":
        options.inviteUrl = nextValue || options.inviteUrl;
        index += 1;
        break;
      case "--fixture-tree-id":
        options.fixtureTreeId = nextValue || options.fixtureTreeId;
        index += 1;
        break;
      case "--output-json":
        options.outputJson = nextValue || options.outputJson;
        index += 1;
        break;
      case "--suite":
        options.suite = nextValue || options.suite;
        index += 1;
        break;
      case "--chromium-executable-path":
        options.chromiumExecutablePath =
          nextValue || options.chromiumExecutablePath;
        index += 1;
        break;
      case "--chromium-channel":
        options.chromiumChannel = nextValue || options.chromiumChannel;
        index += 1;
        break;
      case "--auto-register":
        options.autoRegister = true;
        break;
      case "--keep-fixtures":
        options.keepFixtures = true;
        break;
      case "--headed":
        options.headed = true;
        break;
      default:
        break;
    }
  }

  return options;
}

function ensureAbsoluteUrl(baseUrl, hashPath) {
  if (/^https?:\/\//i.test(hashPath)) {
    return hashPath;
  }
  const normalizedBaseUrl = String(baseUrl || "").replace(/\/+$/, "");
  const normalizedHashPath = String(hashPath || "").startsWith("#")
    ? String(hashPath)
    : `#${String(hashPath || "").startsWith("/") ? "" : "/"}${String(
        hashPath || "",
      )}`;
  return `${normalizedBaseUrl}/${normalizedHashPath}`;
}

function deriveApiUrl(baseUrl, explicitApiUrl) {
  if (explicitApiUrl) {
    return explicitApiUrl;
  }

  const parsedBaseUrl = new URL(baseUrl);
  if (
    parsedBaseUrl.hostname === "127.0.0.1" ||
    parsedBaseUrl.hostname === "localhost"
  ) {
    return `${parsedBaseUrl.protocol}//${parsedBaseUrl.hostname}:8080`;
  }
  if (parsedBaseUrl.hostname.startsWith("api.")) {
    return `${parsedBaseUrl.protocol}//${parsedBaseUrl.hostname}`;
  }
  return `${parsedBaseUrl.protocol}//api.${parsedBaseUrl.hostname}`;
}

function slugify(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9а-я]+/gi, "-")
    .replace(/^-+|-+$/g, "") || "route";
}

function buildSessionPayload(loginPayload) {
  const session = loginPayload?.session && typeof loginPayload.session === "object"
    ? loginPayload.session
    : loginPayload;
  const user = loginPayload?.user && typeof loginPayload.user === "object"
    ? loginPayload.user
    : session;
  const profileStatus =
    loginPayload?.profileStatus && typeof loginPayload.profileStatus === "object"
      ? loginPayload.profileStatus
      : {};
  const providerIds = Array.isArray(user?.providerIds)
    ? user.providerIds.map((value) => String(value))
    : Array.isArray(session?.providerIds)
      ? session.providerIds.map((value) => String(value))
      : [];
  return {
    accessToken: String(session?.accessToken || loginPayload?.accessToken || ""),
    refreshToken:
      session?.refreshToken != null
        ? String(session.refreshToken)
        : loginPayload?.refreshToken != null
          ? String(loginPayload.refreshToken)
          : null,
    userId: String(user?.id || session?.userId || loginPayload?.userId || ""),
    email: user?.email != null ? String(user.email) : null,
    displayName:
      user?.displayName != null ? String(user.displayName) : null,
    photoUrl:
      user?.photoUrl != null
        ? String(user.photoUrl)
        : user?.photoURL != null
          ? String(user.photoURL)
          : null,
    providerIds,
    isProfileComplete: profileStatus?.isComplete === true,
    missingFields: Array.isArray(profileStatus?.missingFields)
      ? profileStatus.missingFields.map((value) => String(value))
      : [],
  };
}

function buildWebSessionStorageEntries(authenticatedSession) {
  const sessionJson = JSON.stringify(authenticatedSession);
  return [
    {
      key: `${LEGACY_SHARED_PREFERENCES_PREFIX}${SESSION_STORAGE_KEY}`,
      value: JSON.stringify(sessionJson),
    },
    {
      key: SESSION_STORAGE_KEY,
      value: sessionJson,
    },
  ];
}

async function createBrowserPage(browser, storageEntries = []) {
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
  });
  if (storageEntries.length > 0) {
    await context.addInitScript(
      ({entries}) => {
        for (const entry of entries) {
          window.localStorage.setItem(entry.key, entry.value);
        }
      },
      {entries: storageEntries},
    );
  }
  const page = await context.newPage();
  return {context, page};
}

function derivePartnerCredentials({email, password}) {
  const normalizedEmail = String(email || "").trim().toLowerCase();
  const [localPart, domainPart] = normalizedEmail.split("@");
  const safeLocalPart = localPart || "rodnya-smoke";
  const safeDomainPart = domainPart || "rodnya-tree.ru";
  const partnerLocalPart = safeLocalPart.includes("+")
    ? `${safeLocalPart}-chat`
    : `${safeLocalPart}+chat`;
  return {
    email: `${partnerLocalPart}@${safeDomainPart}`,
    password: `${String(password || "secret123")}!chat`,
  };
}

function isTransientFetchError(error) {
  if (!error) {
    return false;
  }
  const message = String(error.message || "").toLowerCase();
  return (
    error.name === "TypeError" ||
    message.includes("fetch failed") ||
    message.includes("networkerror") ||
    message.includes("socket") ||
    message.includes("timed out") ||
    message.includes("econnreset") ||
    message.includes("econnrefused")
  );
}

function isTransientHttpStatus(status) {
  return TRANSIENT_HTTP_STATUS_CODES.has(Number(status));
}

function smokeFetchRetryLabel(input, init) {
  const method = String(init?.method || "GET").toUpperCase();
  let target = String(input || "");
  try {
    const parsed = new URL(target);
    target = `${parsed.origin}${parsed.pathname}`;
  } catch (_) {
    target = target.split("?")[0] || "request";
  }
  return `${method} ${target}`;
}

async function drainRetryResponse(response) {
  try {
    if (typeof response?.arrayBuffer === "function") {
      await response.arrayBuffer();
      return;
    }
    if (typeof response?.text === "function") {
      await response.text();
    }
  } catch (_) {
    // Ignore cleanup failures before retrying the smoke request.
  }
}

async function smokeFetch(input, init, {retries = TRANSIENT_FETCH_RETRY_LIMIT} = {}) {
  let lastError = null;
  const retryLabel = smokeFetchRetryLabel(input, init);
  for (let attempt = 1; attempt <= retries; attempt += 1) {
    try {
      const response = await fetchWithHttpFallback(input, init, {retries: 1});
      if (
        response.ok ||
        !isTransientHttpStatus(response.status) ||
        attempt >= retries
      ) {
        return response;
      }
      console.warn(
        `[prod-route-smoke] transient HTTP ${response.status} from ${retryLabel}; retrying (${attempt}/${retries})`,
      );
      await drainRetryResponse(response);
      await delay(TRANSIENT_FETCH_RETRY_DELAY_MS * attempt);
    } catch (error) {
      lastError = error;
      if (attempt >= retries || !isTransientFetchError(error)) {
        throw error;
      }
      console.warn(
        `[prod-route-smoke] transient fetch error from ${retryLabel}; retrying (${attempt}/${retries})`,
      );
      await delay(TRANSIENT_FETCH_RETRY_DELAY_MS * attempt);
    }
  }
  throw lastError;
}

async function loginViaApi({apiUrl, email, password}) {
  const response = await smokeFetch(`${apiUrl.replace(/\/+$/, "")}/v1/auth/login`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify({email, password}),
  });
  if (!response.ok) {
    const bodyText = await response.text();
    const error = new Error(
      `Smoke login failed with ${response.status}: ${bodyText || "empty body"}`,
    );
    error.statusCode = response.status;
    throw error;
  }
  const payload = await response.json();
  const session = buildSessionPayload(payload);
  if (!session.accessToken || !session.userId) {
    throw new Error("Smoke login did not return a valid custom_api_session_v1 payload.");
  }
  return {payload, session};
}

async function registerViaApi({apiUrl, email, password, displayName}) {
  const response = await smokeFetch(
    `${apiUrl.replace(/\/+$/, "")}/v1/auth/register`,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({email, password, displayName}),
    },
  );
  if (!response.ok) {
    const bodyText = await response.text();
    const error = new Error(
      `Smoke register failed with ${response.status}: ${bodyText || "empty body"}`,
    );
    error.statusCode = response.status;
    throw error;
  }
  const payload = await response.json();
  const session = buildSessionPayload(payload);
  if (!session.accessToken || !session.userId) {
    throw new Error(
      "Smoke register did not return a valid custom_api_session_v1 payload.",
    );
  }
  return {payload, session};
}

async function ensureAuthenticatedSession({
  apiUrl,
  email,
  password,
  displayName,
  autoRegister,
}) {
  try {
    const loginResult = await loginViaApi({apiUrl, email, password});
    return {
      ...loginResult,
      accountCreated: false,
    };
  } catch (error) {
    if (!autoRegister || error?.statusCode !== 401) {
      throw error;
    }

    try {
      const registerResult = await registerViaApi({
        apiUrl,
        email,
        password,
        displayName,
      });
      return {
        ...registerResult,
        accountCreated: true,
      };
    } catch (registerError) {
      if (registerError?.statusCode !== 409) {
        throw registerError;
      }

      const loginResult = await loginViaApi({apiUrl, email, password});
      return {
        ...loginResult,
        accountCreated: false,
      };
    }
  }
}

function deriveSmokeProfileBootstrap({email, displayName}) {
  const normalizedEmail = String(email || "").trim().toLowerCase();
  const usernameSeed = normalizedEmail.split("@")[0] || "rodnya-smoke";
  const display = String(displayName || "").trim() || "Rodnya Smoke";
  const parts = display.split(/\s+/).filter(Boolean);
  return {
    firstName: parts[0] || "Rodnya",
    lastName: parts.slice(1).join(" ") || "Smoke",
    username: usernameSeed.replace(/[^a-z0-9_]+/gi, "").toLowerCase(),
  };
}

async function completeProfileViaApi({
  apiUrl,
  accessToken,
  email,
  displayName,
  force = false,
  isProfileComplete = false,
}) {
  if (!force && isProfileComplete) {
    return null;
  }
  const bootstrap = deriveSmokeProfileBootstrap({email, displayName});
  const response = await smokeFetch(
    `${apiUrl.replace(/\/+$/, "")}/v1/profile/me/bootstrap`,
    {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({
        email,
        firstName: bootstrap.firstName,
        lastName: bootstrap.lastName,
        username: bootstrap.username,
        countryName: "Россия",
      }),
    },
  );
  if (!response.ok) {
    throw new Error(
      `Smoke profile bootstrap failed with ${response.status}: ${await response.text()}`,
    );
  }
  return response.json();
}

async function fetchPrimaryTree({apiUrl, accessToken}) {
  const response = await smokeFetch(`${apiUrl.replace(/\/+$/, "")}/v1/trees`, {
    headers: {
      authorization: `Bearer ${accessToken}`,
      accept: "application/json",
    },
  });
  if (!response.ok) {
    throw new Error(`Tree list request failed with ${response.status}.`);
  }
  const payload = await response.json();
  const trees = Array.isArray(payload?.trees) ? payload.trees : [];
  const firstTree = trees[0];
  if (!firstTree?.id) {
    return null;
  }
  return {
    id: String(firstTree.id),
    name: String(firstTree.name || ""),
  };
}

async function createTreeViaApi({
  apiUrl,
  accessToken,
  name,
  description = "Disposable smoke tree.",
}) {
  const response = await smokeFetch(`${apiUrl.replace(/\/+$/, "")}/v1/trees`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify({
      name,
      description,
      isPrivate: true,
      kind: "family",
    }),
  });
  if (!response.ok) {
    throw new Error(`Tree fixture creation failed with ${response.status}.`);
  }
  const payload = await response.json();
  const treeId = String(payload?.tree?.id || "").trim();
  if (!treeId) {
    throw new Error("Tree fixture creation did not return tree.id.");
  }
  return {
    id: treeId,
    name: String(payload?.tree?.name || name || ""),
  };
}

async function ensurePrimaryTree({
  apiUrl,
  accessToken,
  preferredTreeId,
  treeName,
}) {
  if (preferredTreeId) {
    return {
      tree: {id: String(preferredTreeId), name: ""},
      created: false,
    };
  }

  const existingTree = await fetchPrimaryTree({apiUrl, accessToken});
  if (existingTree?.id) {
    return {
      tree: existingTree,
      created: false,
    };
  }

  return {
    tree: await createTreeViaApi({
      apiUrl,
      accessToken,
      name: treeName,
    }),
    created: true,
  };
}

async function createPersonFixture({
  apiUrl,
  accessToken,
  treeId,
  label,
  familySummary = "Auto-created disposable smoke fixture.",
}) {
  const response = await smokeFetch(
    `${apiUrl.replace(/\/+$/, "")}/v1/trees/${encodeURIComponent(treeId)}/persons`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({
        name: `${label} ${new Date().toISOString().slice(0, 19)}`,
        gender: "unknown",
        isAlive: true,
        familySummary,
      }),
    },
  );
  if (!response.ok) {
    throw new Error(`Fixture person creation failed with ${response.status}.`);
  }
  const payload = await response.json();
  const personId = String(payload?.person?.id || "").trim();
  if (!personId) {
    throw new Error("Fixture person creation did not return person.id.");
  }
  return {
    treeId,
    personId,
    personName: payload?.person?.name || null,
  };
}

async function fetchTreePersons({apiUrl, accessToken, treeId}) {
  const response = await smokeFetch(
    `${apiUrl.replace(/\/+$/, "")}/v1/trees/${encodeURIComponent(treeId)}/persons`,
    {
      headers: {
        authorization: `Bearer ${accessToken}`,
        accept: "application/json",
      },
    },
  );
  if (!response.ok) {
    throw new Error(`Fixture person list failed with ${response.status}.`);
  }
  const payload = await response.json();
  return Array.isArray(payload?.persons) ? payload.persons : [];
}

async function createDirectChatFixture({
  apiUrl,
  accessToken,
  otherUserId,
}) {
  const response = await smokeFetch(
    `${apiUrl.replace(/\/+$/, "")}/v1/chats/direct`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({otherUserId}),
    },
  );
  if (!response.ok) {
    throw new Error(`Direct chat fixture failed with ${response.status}.`);
  }
  const payload = await response.json();
  const chatId = String(payload?.chatId || payload?.chat?.id || "").trim();
  if (!chatId) {
    throw new Error("Direct chat fixture did not return chatId.");
  }
  return {
    chatId,
    otherUserId,
  };
}

async function deletePersonFixture({apiUrl, accessToken, treeId, personId}) {
  const response = await smokeFetch(
    `${apiUrl.replace(/\/+$/, "")}/v1/trees/${encodeURIComponent(
      treeId,
    )}/persons/${encodeURIComponent(personId)}`,
    {
      method: "DELETE",
      headers: {
        authorization: `Bearer ${accessToken}`,
        accept: "application/json",
      },
    },
  );
  if (response.status === 204 || response.status === 404) {
    return {
      ok: true,
      statusCode: response.status,
    };
  }
  return {
    ok: false,
    statusCode: response.status,
    body: await response.text(),
  };
}

async function deletePersonFixtures({apiUrl, accessToken, treeId, personIds}) {
  const cleanup = [];
  for (const personId of personIds) {
    if (!personId) {
      continue;
    }
    cleanup.push(
      await deletePersonFixture({
        apiUrl,
        accessToken,
        treeId,
        personId,
      }),
    );
  }
  return cleanup;
}

async function createRouteFixtures({
  apiUrl,
  accessToken,
  treeId,
  baseUrl,
  currentUserEmail,
  currentUserPassword,
  partnerEmail,
  partnerPassword,
  autoRegister,
}) {
  const relativeDetailsFixture = await createPersonFixture({
    apiUrl,
    accessToken,
    treeId,
    label: "Smoke Relative",
  });
  const inviteFixture = await createPersonFixture({
    apiUrl,
    accessToken,
    treeId,
    label: "Smoke Invite",
  });
  const claimFixture = await createPersonFixture({
    apiUrl,
    accessToken,
    treeId,
    label: "Smoke Claim",
  });

  const resolvedPartnerCredentials =
    partnerEmail && partnerPassword
      ? {email: partnerEmail, password: partnerPassword}
      : derivePartnerCredentials({
          email: currentUserEmail,
          password: currentUserPassword,
        });
  const partnerSessionResult = await ensureAuthenticatedSession({
    apiUrl,
    email: resolvedPartnerCredentials.email,
    password: resolvedPartnerCredentials.password,
    displayName: "Rodnya Smoke Partner",
    autoRegister,
  });
  await completeProfileViaApi({
    apiUrl,
    accessToken: partnerSessionResult.session.accessToken,
    email: resolvedPartnerCredentials.email,
    displayName: "Rodnya Smoke Partner",
    isProfileComplete: partnerSessionResult.session.isProfileComplete === true,
  });

  let chatFixture = null;
  try {
    chatFixture = await createDirectChatFixture({
      apiUrl,
      accessToken,
      otherUserId: String(partnerSessionResult.session.userId),
    });
  } catch (_) {
    chatFixture = null;
  }

  const inviteUrl = ensureAbsoluteUrl(
    baseUrl,
    `/invite?treeId=${encodeURIComponent(treeId)}&personId=${encodeURIComponent(
      inviteFixture.personId,
    )}`,
  );
  const claimUrl = ensureAbsoluteUrl(
    baseUrl,
    `/invite?treeId=${encodeURIComponent(treeId)}&personId=${encodeURIComponent(
      claimFixture.personId,
    )}&claim=1`,
  );

  return {
    treeId,
    personId: relativeDetailsFixture.personId,
    personName: relativeDetailsFixture.personName,
    invitePersonId: inviteFixture.personId,
    claimPersonId: claimFixture.personId,
    inviteUrl,
    claimUrl,
    chatId: chatFixture?.chatId || null,
    chatOtherUserId: chatFixture?.otherUserId || null,
    partnerUserId: partnerSessionResult.session.userId,
    partnerEmail: resolvedPartnerCredentials.email,
    partnerAccountCreated: partnerSessionResult.accountCreated === true,
  };
}

async function waitForFlutterShell(page) {
  await page.waitForFunction(
    () => {
      const flutterView = document.querySelector("flutter-view");
      const glassPane = document.querySelector("flt-glass-pane");
      if (flutterView && glassPane) {
        return true;
      }

      const bodyText = String(document.body?.innerText || "").trim();
      return /Вход|Регистрация|Создать аккаунт|Родня/i.test(bodyText);
    },
    undefined,
    {timeout: 30_000},
  );
}

function normalizePageError(error) {
  return {
    message: String(error?.message || error || ""),
    stack: String(error?.stack || ""),
  };
}

function isIgnorablePageError(routeName, errorInfo) {
  if (
    !["login", "invite-flow", "claim-flow"].includes(routeName)
  ) {
    return false;
  }

  // Flutter web's main.dart.js bridge re-throws third-party SDK
  // (FedCM / Google Identity Services) failures as a bare "Error".
  // On anonymous smoke runs the SDK has no session to work with,
  // so this fires deterministically — and the stack is the SDK's
  // own, NOT main.dart.js (the original check was too tight and
  // missed exactly this case). The login UX path falls through to
  // the manual-credentials form regardless, which is what the
  // smoke verifies via `final=#/login`.
  return errorInfo.message === "Error";
}

// Allow-list of console.error messages that are noise from third-
// party SDKs we can't silence at the source. Each pattern is the
// exact text the browser emits; keep them tight (anchored regexes)
// so we don't accidentally swallow a real Flutter error that
// happens to share a substring.
const IGNORABLE_CONSOLE_MESSAGE_PATTERNS = [
  // FedCM / Google Identity Services / Credential Management API
  // emits this when the browser session has no cached account for
  // the configured provider. Anonymous smoke runs use a fresh
  // browser context → no cached accounts → the error always fires.
  // The real "no provider available" UX path lands the user on
  // the manual-credentials form, which IS what the smoke verifies
  // by `final=#/login`. Authenticated runs don't hit this because
  // the provider has the user's session already.
  /^Provider's accounts list is empty\.?$/,
  // Same root cause, different SDK chatter. GIS logs the FedCM
  // network failure when no FedCM provider can issue a token for
  // an unauthenticated browser. Harmless; the smoke verifies the
  // fallback by landing on `#/login`.
  /^\[GSI_LOGGER\]:.*FedCM get\(\).*NetworkError.*Error retrieving a token\.?$/,
];

function isIgnorableConsoleError(message) {
  return IGNORABLE_CONSOLE_MESSAGE_PATTERNS.some((pattern) =>
    pattern.test(message),
  );
}

// Chromium surfaces request *cancellations* as net::ERR_ABORTED. These
// are not server/network failures: the browser or the Flutter web
// engine deliberately cancelled an in-flight request (a superseded
// navigation, an AbortController, a font/asset refetch during startup).
// They fire non-deterministically on slow cold-start loads — exactly
// the flake that reddened the [anonymous] login route post-deploy while
// the route itself loaded fine (final=#/login, empty statusCodes). A
// genuine same-origin failure still surfaces as a connection-level
// error (ERR_CONNECTION_*, ERR_NAME_NOT_RESOLVED, ERR_TIMED_OUT, …),
// which is intentionally NOT matched here and still fails the route.
const IGNORABLE_REQUEST_FAILURE_PATTERNS = [/net::ERR_ABORTED/i];

function isIgnorableFailedRequest(errorText) {
  return IGNORABLE_REQUEST_FAILURE_PATTERNS.some((pattern) =>
    pattern.test(String(errorText || "")),
  );
}

async function withRouteMetrics(page, config, routeName, targetUrl, task) {
  const baseOrigin = new URL(config.baseUrl).origin;
  const routeMetrics = {
    name: routeName,
    targetUrl,
    startedAt: new Date().toISOString(),
    requestCount: 0,
    sameOriginRequestCount: 0,
    consoleErrors: [],
    ignoredConsoleErrors: [],
    pageErrors: [],
    ignoredPageErrors: [],
    failedRequests: [],
    ignoredFailedRequests: [],
    statusCodes: [],
  };
  const startedAtMs = Date.now();

  const onRequest = (request) => {
    routeMetrics.requestCount += 1;
    if (request.url().startsWith(baseOrigin)) {
      routeMetrics.sameOriginRequestCount += 1;
    }
  };
  const onResponse = (response) => {
    if (response.url().startsWith(baseOrigin) && response.status() >= 400) {
      routeMetrics.statusCodes.push({
        url: response.url(),
        status: response.status(),
      });
    }
  };
  const onRequestFailed = (request) => {
    const entry = {
      url: request.url(),
      errorText: request.failure()?.errorText || "requestfailed",
    };
    if (isIgnorableFailedRequest(entry.errorText)) {
      routeMetrics.ignoredFailedRequests.push(entry);
      return;
    }
    routeMetrics.failedRequests.push(entry);
  };
  const onConsole = (message) => {
    if (message.type() === "error") {
      const text = message.text();
      if (isIgnorableConsoleError(text)) {
        routeMetrics.ignoredConsoleErrors.push(text);
        return;
      }
      routeMetrics.consoleErrors.push(text);
    }
  };
  const onPageError = (error) => {
    const errorInfo = normalizePageError(error);
    if (isIgnorablePageError(routeName, errorInfo)) {
      routeMetrics.ignoredPageErrors.push(errorInfo.message);
      return;
    }
    routeMetrics.pageErrors.push(errorInfo.message);
  };

  page.on("request", onRequest);
  page.on("response", onResponse);
  page.on("requestfailed", onRequestFailed);
  page.on("console", onConsole);
  page.on("pageerror", onPageError);

  try {
    await task(routeMetrics);
    routeMetrics.ok =
      routeMetrics.consoleErrors.length === 0 &&
      routeMetrics.pageErrors.length === 0 &&
      routeMetrics.failedRequests.filter((entry) =>
        entry.url.startsWith(baseOrigin),
      ).length === 0;
  } catch (error) {
    routeMetrics.ok = false;
    routeMetrics.failure = String(error?.message || error);
    const screenshotPath = path.join(
      path.dirname(config.outputJson),
      `${slugify(routeName)}-failure.png`,
    );
    await fs.mkdir(path.dirname(screenshotPath), {recursive: true});
    await page.screenshot({path: screenshotPath, fullPage: true}).catch(() => {});
    routeMetrics.failureScreenshot = screenshotPath;
  } finally {
    routeMetrics.durationMs = Date.now() - startedAtMs;
    routeMetrics.finalUrl = page.url();
    routeMetrics.finalHash = await page
      .evaluate(() => window.location.hash)
      .catch(() => "");
    page.off("request", onRequest);
    page.off("response", onResponse);
    page.off("requestfailed", onRequestFailed);
    page.off("console", onConsole);
    page.off("pageerror", onPageError);
  }

  return routeMetrics;
}

async function openRoute(page, config, routeName, hashPath, verify) {
  const targetUrl = ensureAbsoluteUrl(config.baseUrl, hashPath);
  return withRouteMetrics(page, config, routeName, targetUrl, async () => {
    await page.goto(targetUrl, {waitUntil: "domcontentloaded"});
    await waitForFlutterShell(page);
    await page.waitForTimeout(1400);
    await verify();
  });
}

async function openExternalUrl(page, config, routeName, fullUrl, verify) {
  return withRouteMetrics(page, config, routeName, fullUrl, async () => {
    await page.goto(fullUrl, {waitUntil: "domcontentloaded"});
    await waitForFlutterShell(page);
    await page.waitForTimeout(1400);
    await verify();
  });
}

async function main() {
  const config = parseArgs(process.argv.slice(2));
  config.baseUrl = config.baseUrl.replace(/\/+$/, "");
  config.apiUrl = deriveApiUrl(config.baseUrl, config.apiUrl);
  config.suite = ["all", "anonymous", "authenticated"].includes(config.suite)
    ? config.suite
    : "all";

  const outputDir = path.dirname(config.outputJson);
  await fs.mkdir(outputDir, {recursive: true});

  const launchOptions = {
    headless: !config.headed,
  };
  if (config.chromiumExecutablePath) {
    launchOptions.executablePath = config.chromiumExecutablePath;
  } else if (config.chromiumChannel) {
    launchOptions.channel = config.chromiumChannel;
  }

  const browser = await chromium.launch(launchOptions);
  let {context, page} = await createBrowserPage(browser);

  const results = {
    generatedAt: new Date().toISOString(),
    baseUrl: config.baseUrl,
    apiUrl: config.apiUrl,
    suite: config.suite,
    routes: [],
    skipped: [],
    suites: {
      anonymous: {routes: [], skipped: []},
      authenticated: {routes: [], skipped: []},
    },
    fixtures: null,
    auth: null,
  };
  const addRoute = (suiteName, route) => {
    results.routes.push(route);
    if (suiteName && results.suites[suiteName]) {
      results.suites[suiteName].routes.push(route);
    }
  };
  const addSkip = (suiteName, message) => {
    results.skipped.push(message);
    if (suiteName && results.suites[suiteName]) {
      results.suites[suiteName].skipped.push(message);
    }
  };

  try {
    const canRunAuthenticatedSuite = Boolean(config.email && config.password);
    let authenticatedSession = null;
    let primaryTree = null;
    let createdAuthAccount = false;

    const shouldPrepareAnonymousFixtures =
      config.suite !== "authenticated" &&
      canRunAuthenticatedSuite &&
      (!config.inviteUrl || !config.claimUrl);
    const shouldPrepareAuthenticatedSuite =
      config.suite !== "anonymous" && canRunAuthenticatedSuite;
    const shouldPrepareRouteFixtures =
      shouldPrepareAnonymousFixtures || shouldPrepareAuthenticatedSuite;

    if (shouldPrepareRouteFixtures) {
      const loginResult = await ensureAuthenticatedSession({
        apiUrl: config.apiUrl,
        email: config.email,
        password: config.password,
        displayName: config.displayName,
        autoRegister: config.autoRegister,
      });
      authenticatedSession = loginResult.session;
      createdAuthAccount = loginResult.accountCreated === true;
      await completeProfileViaApi({
        apiUrl: config.apiUrl,
        accessToken: authenticatedSession.accessToken,
        email: config.email,
        displayName: config.displayName,
        isProfileComplete: authenticatedSession.isProfileComplete === true,
      });
      const ensuredTree = await ensurePrimaryTree({
        apiUrl: config.apiUrl,
        accessToken: authenticatedSession.accessToken,
        preferredTreeId: config.fixtureTreeId,
        treeName: config.treeName,
      });
      primaryTree = ensuredTree.tree;
      results.auth = {
        email: config.email,
        accountCreated: createdAuthAccount,
        userId: authenticatedSession.userId,
        treeCreated: ensuredTree.created === true,
        treeId: primaryTree?.id || null,
      };
    }

    if (shouldPrepareRouteFixtures) {
      const fixtureTreeId = primaryTree?.id || "";
      if (!fixtureTreeId) {
        if (shouldPrepareAnonymousFixtures) {
          addSkip(
            "anonymous",
            "Invite/claim fixtures skipped: set RODNYA_SMOKE_FIXTURE_TREE_ID or provide an authenticated smoke account with a tree.",
          );
        }
        if (shouldPrepareAuthenticatedSuite) {
          addSkip(
            "authenticated",
            "Relative/chat fixtures skipped: authenticated smoke account has no writable tree.",
          );
        }
      } else {
        const fixtures = await createRouteFixtures({
          apiUrl: config.apiUrl,
          accessToken: authenticatedSession.accessToken,
          treeId: fixtureTreeId,
          baseUrl: config.baseUrl,
          currentUserEmail: config.email,
          currentUserPassword: config.password,
          partnerEmail: config.partnerEmail,
          partnerPassword: config.partnerPassword,
          autoRegister: config.autoRegister,
        });
        results.fixtures = fixtures;
        if (!config.inviteUrl) {
          config.inviteUrl = fixtures.inviteUrl;
        }
        if (!config.claimUrl) {
          config.claimUrl = fixtures.claimUrl;
        }
      }
    }

    if (config.suite !== "authenticated") {
      const loginRoute = await openRoute(
        page,
        config,
        "login",
        "/login",
        async () => {
          await page.waitForFunction(
            () => window.location.hash.startsWith("#/login"),
            undefined,
            {timeout: 15_000},
          );
        },
      );
      addRoute("anonymous", loginRoute);
    }

    if (config.suite !== "anonymous" && !canRunAuthenticatedSuite) {
      addSkip(
        "authenticated",
        "Protected route suite skipped: set RODNYA_SMOKE_EMAIL and RODNYA_SMOKE_PASSWORD.",
      );
    } else if (config.suite !== "anonymous") {
      const authStorageEntries = buildWebSessionStorageEntries(
        authenticatedSession,
      );
      await context.close();
      ({context, page} = await createBrowserPage(browser, authStorageEntries));

      const authenticatedRoutes = [
        {
          name: "home",
          path: "/",
          verify: async () => {
            await page.waitForFunction(
              () => !window.location.hash.startsWith("#/login"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          name: "relatives",
          path: "/relatives",
          verify: async () => {
            await page.waitForFunction(
              // SC2 merge: /relatives redirects → #/family?view=list
              () =>
                window.location.hash.startsWith("#/family") &&
                window.location.hash.includes("view=list"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          name: "chats",
          path: "/chats",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/chats"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          name: "profile",
          path: "/profile",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/profile"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          name: "settings",
          path: "/profile/settings",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/profile/settings"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          name: "notifications",
          path: "/notifications",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/notifications"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          name: "create-post",
          path: "/post/create",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/post/create"),
              undefined,
              {timeout: 15_000},
            );
          },
        },
        {
          // Telegram-style multi-device session management screen.
          // Shipped in commit b9eb0d8 — landing route for the
          // "Профиль → Безопасность → Активные сеансы" entry.
          name: "sessions",
          path: "/profile/sessions",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/profile/sessions"),
              undefined,
              {timeout: 15_000},
            );
            // Sessions screen lazy-loads via API — give it a beat to
            // hydrate before the next route navigates away.
            await page.waitForTimeout(800);
          },
        },
        {
          // QR-login display screen for the "log in by QR" flow on a
          // device that's already authenticated. Shipped in b9eb0d8.
          name: "qr-login-display",
          path: "/auth/qr",
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/auth/qr"),
              undefined,
              {timeout: 15_000},
            );
            await page.waitForTimeout(800);
          },
        },
        {
          // QR scanner screen — entered from the sessions screen to
          // bind a new device. Smoke just verifies it loads (the camera
          // permission prompt happens browser-side and is harmless on
          // headless CI).
          name: "qr-login-scan",
          path: "/profile/sessions/scan",
          verify: async () => {
            await page.waitForFunction(
              () =>
                window.location.hash.startsWith("#/profile/sessions/scan"),
              undefined,
              {timeout: 15_000},
            );
            await page.waitForTimeout(800);
          },
        },
      ];

      if (primaryTree?.id) {
        authenticatedRoutes.splice(1, 0, {
          name: "tree",
          path: `/tree/view/${encodeURIComponent(primaryTree.id)}${
            primaryTree.name
              ? `?name=${encodeURIComponent(primaryTree.name)}`
              : ""
          }`,
          verify: async () => {
            await page.waitForFunction(
              // Дерево снова отдельная вкладка: /tree/view/:id → #/tree?tree=…
              () =>
                window.location.hash.startsWith("#/tree") &&
                window.location.hash.includes("tree="),
              undefined,
              {timeout: 15_000},
            );
            await page.waitForTimeout(1200);
          },
        });
      } else {
        addSkip(
          "authenticated",
          "Tree route skipped: authenticated smoke account has no tree membership.",
        );
      }

      if (results.fixtures?.personId) {
        authenticatedRoutes.push({
          name: "relative-details",
          path: `/relative/details/${encodeURIComponent(results.fixtures.personId)}`,
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/relative/details/"),
              undefined,
              {timeout: 15_000},
            );
            await page.waitForTimeout(1200);
          },
        });
      } else {
        addSkip(
          "authenticated",
          "Relative details route skipped: smoke fixture person was not created.",
        );
      }

      if (results.fixtures?.chatId) {
        authenticatedRoutes.push({
          name: "chat-view",
          path: `/chats/view/${encodeURIComponent(results.fixtures.chatId)}`,
          verify: async () => {
            await page.waitForFunction(
              () => window.location.hash.startsWith("#/chats/view/"),
              undefined,
              {timeout: 15_000},
            );
          },
        });
      } else {
        addSkip(
          "authenticated",
          "Chat route skipped: direct-chat fixture was not created.",
        );
      }

      for (const route of authenticatedRoutes) {
        const routeResult = await openRoute(
          page,
          config,
          route.name,
          route.path,
          route.verify,
        );
        addRoute("authenticated", routeResult);
      }

      if (config.inviteUrl) {
        addRoute(
          "authenticated",
          await openExternalUrl(
            page,
            config,
            "invite-flow-authenticated",
            config.inviteUrl,
            async () => {
              await page.waitForFunction(
                () => !window.location.hash.startsWith("#/login"),
                undefined,
                {timeout: 15_000},
              );
            },
          ),
        );
      } else {
        addSkip(
          "authenticated",
          "Invite flow skipped: disposable invite fixture was not created.",
        );
      }

      if (config.claimUrl) {
        addRoute(
          "authenticated",
          await openExternalUrl(
            page,
            config,
            "claim-flow-authenticated",
            config.claimUrl,
            async () => {
              await page.waitForFunction(
                () => !window.location.hash.startsWith("#/login"),
                undefined,
                {timeout: 15_000},
              );
            },
          ),
        );
      } else {
        addSkip(
          "authenticated",
          "Claim flow skipped: disposable claim fixture was not created.",
        );
      }
    }

    if (config.suite === "all") {
      await context.close();
      ({context, page} = await createBrowserPage(browser));
    }

    if (config.suite !== "authenticated" && config.inviteUrl) {
      addRoute(
        "anonymous",
        await openExternalUrl(
          page,
          config,
          "invite-flow",
          config.inviteUrl,
          async () => {
            await page.waitForTimeout(1200);
          },
        ),
      );
    } else if (config.suite !== "authenticated") {
      addSkip(
        "anonymous",
        "Invite flow skipped: set RODNYA_SMOKE_INVITE_URL for a disposable invite link.",
      );
    }

    if (config.suite !== "authenticated" && config.claimUrl) {
      addRoute(
        "anonymous",
        await openExternalUrl(
          page,
          config,
          "claim-flow",
          config.claimUrl,
          async () => {
            await page.waitForTimeout(1200);
          },
        ),
      );
    } else if (config.suite !== "authenticated") {
      addSkip(
        "anonymous",
        "Claim flow skipped: set RODNYA_SMOKE_CLAIM_URL for a disposable claim link.",
      );
    }

    if (authenticatedSession && results.fixtures?.treeId && !config.keepFixtures) {
      results.fixtures.cleanup = await deletePersonFixtures({
        apiUrl: config.apiUrl,
        accessToken: authenticatedSession.accessToken,
        treeId: results.fixtures.treeId,
        personIds: [
          results.fixtures.personId,
          results.fixtures.invitePersonId,
          results.fixtures.claimPersonId,
        ],
      });
    } else if (results.fixtures?.personId && config.keepFixtures) {
      results.fixtures.cleanup = {
        ok: true,
        skipped: true,
        reason: "RODNYA_SMOKE_KEEP_FIXTURES=1",
      };
    }
  } finally {
    await browser.close();
  }

  const summarizeRoutes = (routes) => ({
    routeCount: routes.length,
    failedRoutes: routes.filter((entry) => entry.ok === false).map(
      (entry) => entry.name,
    ),
    startupRouteDurationMs:
      routes.find((entry) => entry.name === "login")?.durationMs ?? null,
    startupRouteRequests:
      routes.find((entry) => entry.name === "login")?.requestCount ?? null,
    totalSameOriginRequests: routes.reduce(
      (sum, entry) => sum + (entry.sameOriginRequestCount || 0),
      0,
    ),
  });

  results.summary = {
    routeCount: results.routes.length,
    failedRoutes: results.routes
      .filter((entry) => entry.ok === false)
      .map((entry) => entry.name),
    startupRouteDurationMs:
      results.routes.find((entry) => entry.name === "login")?.durationMs ?? null,
    startupRouteRequests:
      results.routes.find((entry) => entry.name === "login")?.requestCount ?? null,
    totalSameOriginRequests: results.routes.reduce(
      (sum, entry) => sum + (entry.sameOriginRequestCount || 0),
      0,
    ),
    suites: {
      anonymous: summarizeRoutes(results.suites.anonymous.routes),
      authenticated: summarizeRoutes(results.suites.authenticated.routes),
    },
  };

  await fs.writeFile(config.outputJson, JSON.stringify(results, null, 2));

  for (const route of results.routes) {
    const suiteName =
      results.suites.anonymous.routes.includes(route) ? "anonymous" : "authenticated";
    const prefix = route.ok ? "PASS" : "FAIL";
    console.log(
      `${prefix} [${suiteName}] ${route.name}: ${route.durationMs} ms, requests=${route.requestCount}, same-origin=${route.sameOriginRequestCount}, final=${route.finalHash || route.finalUrl}`,
    );
    if (route.failure) {
      console.log(`  reason: ${route.failure}`);
    }
  }
  for (const message of results.skipped) {
    console.log(`SKIP ${message}`);
  }
  console.log(`Smoke report: ${config.outputJson}`);

  if (results.summary.failedRoutes.length > 0) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`[prod-route-smoke] ${error?.stack || error}`);
  process.exitCode = 1;
});
