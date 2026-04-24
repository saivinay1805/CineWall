const crypto = require("crypto");

const TRIAL_LENGTH_SECONDS = 7 * 24 * 60 * 60;
const TRIAL_RETENTION_SECONDS = 365 * 24 * 60 * 60;
const KV_REST_API_URL = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL || "";
const KV_REST_API_TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN || "";

function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
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
    throw new Error("The trial store returned an invalid response.");
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
    throw new Error("Stored trial data is invalid.");
  }
}

async function kvCreateTrial(key, record) {
  const results = await kvPipeline([[
    "SET",
    key,
    JSON.stringify(record),
    "EX",
    String(TRIAL_RETENTION_SECONDS),
    "NX"
  ]]);
  const outcome = results[0];
  if (!outcome || outcome.error) {
    throw new Error(outcome?.error || "The trial could not be created.");
  }
  return outcome.result === "OK";
}

function buildTrialKey(installId) {
  const digest = crypto.createHash("sha256").update(installId).digest("hex");
  return `cinewall:trial:${digest}`;
}

function normalizeTrialRecord(record) {
  if (!record?.startedAt || !record?.expiresAt) return null;
  return {
    startedAt: String(record.startedAt),
    expiresAt: String(record.expiresAt),
    deviceName: String(record.deviceName || "Mac"),
    version: Number(record.version || 1)
  };
}

function serializeStatus(record) {
  const normalized = normalizeTrialRecord(record);
  if (!normalized) {
    return {
      success: true,
      source: "server",
      trial_active: false,
      has_consumed: false,
      started_at: null,
      expires_at: null
    };
  }

  const expiresAt = new Date(normalized.expiresAt);
  const active = Number.isFinite(expiresAt.getTime()) && expiresAt.getTime() > Date.now();

  return {
    success: true,
    source: "server",
    trial_active: active,
    has_consumed: true,
    started_at: normalized.startedAt,
    expires_at: normalized.expiresAt
  };
}

module.exports = async (req, res) => {
  if (req.method === "OPTIONS") {
    return sendJson(res, 200, { ok: true });
  }

  if (req.method !== "POST") {
    return sendJson(res, 405, {
      success: false,
      message: "Method not allowed."
    });
  }

  if (!isKvConfigured()) {
    return sendJson(res, 503, {
      success: false,
      message: "Trial storage is not configured yet. Add KV_REST_API_URL and KV_REST_API_TOKEN in Vercel."
    });
  }

  let body = {};
  try {
    body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
  } catch {
    return sendJson(res, 400, {
      success: false,
      message: "Invalid JSON payload."
    });
  }

  const installId = String(body.install_id || "").trim();
  const deviceName = String(body.device_name || "Mac").trim() || "Mac";
  const action = String(body.action || "status").trim().toLowerCase();

  if (!installId) {
    return sendJson(res, 400, {
      success: false,
      message: "An install ID is required."
    });
  }

  if (!["status", "start"].includes(action)) {
    return sendJson(res, 400, {
      success: false,
      message: "Invalid trial action."
    });
  }

  const key = buildTrialKey(installId);

  try {
    let record = await kvGet(key);

    if (!record && action === "start") {
      const startedAt = new Date();
      const expiresAt = new Date(startedAt.getTime() + TRIAL_LENGTH_SECONDS * 1000);
      const created = await kvCreateTrial(key, {
        version: 1,
        startedAt: startedAt.toISOString(),
        expiresAt: expiresAt.toISOString(),
        deviceName
      });

      if (created) {
        record = {
          version: 1,
          startedAt: startedAt.toISOString(),
          expiresAt: expiresAt.toISOString(),
          deviceName
        };
      } else {
        record = await kvGet(key);
      }
    }

    return sendJson(res, 200, serializeStatus(record));
  } catch (error) {
    return sendJson(res, 500, {
      success: false,
      message: error?.message || "The trial service failed."
    });
  }
};
