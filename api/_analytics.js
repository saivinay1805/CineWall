const crypto = require("crypto");

const DEFAULT_RETENTION_SECONDS = 365 * 24 * 60 * 60;
const KV_REST_API_URL = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL || "";
const KV_REST_API_TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN || "";

function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Admin-Token");
  res.end(JSON.stringify(body));
}

function isKvConfigured() {
  return KV_REST_API_URL && KV_REST_API_TOKEN;
}

async function kvPipeline(commands) {
  const response = await fetch(`${KV_REST_API_URL}/pipeline`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${KV_REST_API_TOKEN}`,
      Accept: "application/json",
      "Content-Type": "application/json"
    },
    body: JSON.stringify(commands)
  });

  const data = await response.json().catch(() => null);
  if (!response.ok || !Array.isArray(data)) {
    throw new Error("The analytics store returned an invalid response.");
  }

  return data;
}

async function kvGet(key) {
  const results = await kvPipeline([["GET", key]]);
  const record = results[0];
  if (!record || record.error) {
    if (record?.error) {
      throw new Error(record.error);
    }
    return null;
  }

  if (!record.result) return null;

  try {
    return JSON.parse(record.result);
  } catch {
    throw new Error("Stored analytics data is invalid.");
  }
}

async function kvSetJson(key, record, ttlSeconds = DEFAULT_RETENTION_SECONDS, useNx = false) {
  const command = [
    "SET",
    key,
    JSON.stringify(record),
    "EX",
    String(ttlSeconds)
  ];

  if (useNx) {
    command.push("NX");
  }

  const results = await kvPipeline([command]);
  const outcome = results[0];
  if (!outcome || outcome.error) {
    throw new Error(outcome?.error || "The analytics store could not save the record.");
  }

  return outcome.result === "OK";
}

async function scanKeys(pattern) {
  let cursor = "0";
  const keys = [];

  do {
    const results = await kvPipeline([["SCAN", cursor, "MATCH", pattern, "COUNT", "200"]]);
    const response = results[0];
    if (!response || response.error) {
      throw new Error(response?.error || "The analytics store scan failed.");
    }

    const result = response.result || ["0", []];
    cursor = String(result[0] || "0");
    const batch = Array.isArray(result[1]) ? result[1] : [];
    keys.push(...batch);
  } while (cursor !== "0");

  return keys;
}

async function scanJsonRecords(pattern) {
  const keys = await scanKeys(pattern);
  if (!keys.length) return [];

  const results = await kvPipeline(keys.map((key) => ["GET", key]));
  const records = [];

  for (let index = 0; index < results.length; index += 1) {
    const entry = results[index];
    if (!entry || entry.error || !entry.result) continue;

    try {
      records.push(JSON.parse(entry.result));
    } catch {
      continue;
    }
  }

  return records;
}

function normalizeString(value) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function normalizeArchitecture(value) {
  const raw = normalizeString(value).toLowerCase();
  if (!raw) return "Unknown";
  if (raw.includes("apple") || raw.includes("silicon") || raw.includes("arm")) return "Apple Silicon";
  if (raw.includes("intel") || raw.includes("x86")) return "Intel";
  return value;
}

function normalizeOSVersion(value) {
  const raw = normalizeString(value);
  if (!raw) return "Unknown";
  return raw.replace(/\s+/g, " ");
}

function hashInstallID(installId) {
  return crypto.createHash("sha256").update(String(installId)).digest("hex");
}

function buildTrialKey(installId) {
  return `cinewall:trial:${hashInstallID(installId)}`;
}

function buildEventKey(prefix) {
  return `cinewall:${prefix}:${Date.now()}:${crypto.randomBytes(4).toString("hex")}`;
}

function normalizeClientMeta(body = {}) {
  const installId = normalizeString(body.install_id);

  return {
    installId,
    installHash: installId ? hashInstallID(installId) : "",
    deviceName: normalizeString(body.device_name) || "Mac",
    osVersion: normalizeOSVersion(body.os_version),
    architecture: normalizeArchitecture(body.architecture),
    appVersion: normalizeString(body.app_version) || "Unknown"
  };
}

async function logEvent(prefix, payload, ttlSeconds = DEFAULT_RETENTION_SECONDS) {
  if (!isKvConfigured()) return false;
  const key = buildEventKey(prefix);
  await kvSetJson(key, payload, ttlSeconds, false);
  return true;
}

module.exports = {
  DEFAULT_RETENTION_SECONDS,
  buildTrialKey,
  hashInstallID,
  isKvConfigured,
  kvGet,
  kvSetJson,
  logEvent,
  normalizeClientMeta,
  scanJsonRecords,
  sendJson
};
