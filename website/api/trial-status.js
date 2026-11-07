const TRIAL_LENGTH_SECONDS = 7 * 24 * 60 * 60;
const TRIAL_RETENTION_SECONDS = 365 * 24 * 60 * 60;
const {
  buildTrialKey,
  isKvConfigured,
  kvGet,
  kvSetJson,
  normalizeClientMeta,
  sendJson
} = require("./_analytics");

function normalizeTrialRecord(record) {
  if (!record?.startedAt || !record?.expiresAt) return null;
  return {
    startedAt: String(record.startedAt),
    expiresAt: String(record.expiresAt),
    deviceName: String(record.deviceName || "Mac"),
    osVersion: String(record.osVersion || "Unknown"),
    architecture: String(record.architecture || "Unknown"),
    appVersion: String(record.appVersion || "Unknown"),
    installHash: String(record.installHash || ""),
    version: Number(record.version || 1)
  };
}

function enrichTrialRecord(record, clientMeta) {
  return {
    ...record,
    deviceName: record.deviceName || clientMeta.deviceName,
    osVersion: record.osVersion || clientMeta.osVersion,
    architecture: record.architecture || clientMeta.architecture,
    appVersion: record.appVersion || clientMeta.appVersion,
    installHash: record.installHash || clientMeta.installHash
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
  const clientMeta = normalizeClientMeta(body);
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
      const freshRecord = {
        version: 1,
        startedAt: startedAt.toISOString(),
        expiresAt: expiresAt.toISOString(),
        deviceName: clientMeta.deviceName,
        osVersion: clientMeta.osVersion,
        architecture: clientMeta.architecture,
        appVersion: clientMeta.appVersion,
        installHash: clientMeta.installHash
      };
      const created = await kvSetJson(key, freshRecord, TRIAL_RETENTION_SECONDS, true);

      if (created) {
        record = freshRecord;
      } else {
        record = await kvGet(key);
      }
    }

    if (record) {
      const enrichedRecord = enrichTrialRecord(record, clientMeta);
      if (JSON.stringify(enrichedRecord) !== JSON.stringify(record)) {
        await kvSetJson(key, enrichedRecord, TRIAL_RETENTION_SECONDS, false);
        record = enrichedRecord;
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
