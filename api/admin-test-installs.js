const {
  isKvConfigured,
  kvGet,
  kvSetJson,
  sendJson
} = require("./_analytics");

const ADMIN_TOKEN = process.env.ADMIN_TOKEN || process.env.CINEWALL_ADMIN_TOKEN || "";
const TEST_INSTALLS_KEY = "cinewall:test-installs";

function parseToken(req) {
  const authHeader = String(req.headers.authorization || "");
  if (authHeader.toLowerCase().startsWith("bearer ")) {
    return authHeader.slice(7).trim();
  }

  const customHeader = String(req.headers["x-admin-token"] || "").trim();
  if (customHeader) return customHeader;

  const requestURL = new URL(req.url || "/", "https://cinewall-site.vercel.app");
  return String(requestURL.searchParams.get("token") || "").trim();
}

async function loadRecord() {
  const record = await kvGet(TEST_INSTALLS_KEY).catch(() => null);
  const hashes = Array.isArray(record?.installHashes) ? record.installHashes : [];
  return {
    installHashes: hashes.map((value) => String(value || "").trim()).filter(Boolean)
  };
}

module.exports = async (req, res) => {
  if (req.method === "OPTIONS") {
    return sendJson(res, 200, { ok: true });
  }

  if (!ADMIN_TOKEN) {
    return sendJson(res, 503, {
      success: false,
      message: "Set ADMIN_TOKEN in Vercel before using the dashboard."
    });
  }

  if (parseToken(req) !== ADMIN_TOKEN) {
    return sendJson(res, 401, {
      success: false,
      message: "Unauthorized."
    });
  }

  if (!isKvConfigured()) {
    return sendJson(res, 503, {
      success: false,
      message: "Analytics storage is not configured."
    });
  }

  if (req.method === "GET") {
    const record = await loadRecord();
    return sendJson(res, 200, {
      success: true,
      installHashes: record.installHashes
    });
  }

  if (req.method !== "POST") {
    return sendJson(res, 405, {
      success: false,
      message: "Method not allowed."
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

  const installHash = String(body.install_hash || "").trim();
  const action = String(body.action || "add").trim().toLowerCase();

  if (!installHash) {
    return sendJson(res, 400, {
      success: false,
      message: "An install hash is required."
    });
  }

  const record = await loadRecord();
  const hashes = new Set(record.installHashes);

  if (action === "remove") {
    hashes.delete(installHash);
  } else {
    hashes.add(installHash);
  }

  const nextRecord = {
    installHashes: Array.from(hashes).sort(),
    updatedAt: new Date().toISOString()
  };

  await kvSetJson(TEST_INSTALLS_KEY, nextRecord, 365 * 24 * 60 * 60, false);

  return sendJson(res, 200, {
    success: true,
    installHashes: nextRecord.installHashes
  });
};
