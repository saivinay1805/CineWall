const {
  isKvConfigured,
  scanJsonRecords,
  sendJson
} = require("./_analytics");

const GITHUB_OWNER = process.env.GITHUB_OWNER || "saivinay1805";
const GITHUB_REPO = process.env.GITHUB_REPO || "CineWall-App";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || process.env.CINEWALL_ADMIN_TOKEN || "";

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

function tally(records, key) {
  const counts = new Map();

  for (const record of records) {
    const label = String(record[key] || "Unknown");
    counts.set(label, (counts.get(label) || 0) + 1);
  }

  return Array.from(counts.entries())
    .map(([label, count]) => ({ label, count }))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
}

function recent(records, key) {
  return [...records]
    .filter((record) => record[key])
    .sort((left, right) => new Date(right[key]).getTime() - new Date(left[key]).getTime())
    .slice(0, 10);
}

function uniqueInstallCount(records) {
  const installs = new Set(records.map((record) => String(record.installHash || "")).filter(Boolean));
  return installs.size;
}

async function fetchGitHubDownloads() {
  const response = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases`, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "cinewall-admin-dashboard"
    }
  });

  const data = await response.json().catch(() => []);
  if (!response.ok || !Array.isArray(data)) {
    throw new Error("GitHub release stats could not be loaded.");
  }

  const releases = data
    .filter((release) => !release.draft)
    .map((release) => {
      const assets = Array.isArray(release.assets) ? release.assets : [];
      return {
        name: release.name || release.tag_name || "Untitled Release",
        tag: release.tag_name || "",
        publishedAt: release.published_at || null,
        downloads: assets.reduce((sum, asset) => sum + Number(asset.download_count || 0), 0)
      };
    });

  const totalDownloads = releases.reduce((sum, release) => sum + release.downloads, 0);

  return {
    totalDownloads,
    latestRelease: releases[0] || null,
    releases: releases.slice(0, 6)
  };
}

module.exports = async (req, res) => {
  if (req.method === "OPTIONS") {
    return sendJson(res, 200, { ok: true });
  }

  if (req.method !== "GET") {
    return sendJson(res, 405, {
      success: false,
      message: "Method not allowed."
    });
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

  try {
    const github = await fetchGitHubDownloads();
    const trialRecords = isKvConfigured() ? await scanJsonRecords("cinewall:trial:*") : [];
    const activationRecords = isKvConfigured() ? await scanJsonRecords("cinewall:activation:*") : [];
    const now = Date.now();
    const activeTrials = trialRecords.filter((record) => new Date(record.expiresAt || 0).getTime() > now);

    const payload = {
      success: true,
      generatedAt: new Date().toISOString(),
      github,
      trials: {
        totalStarts: trialRecords.length,
        active: activeTrials.length,
        uniqueInstalls: uniqueInstallCount(trialRecords),
        byOSVersion: tally(trialRecords, "osVersion"),
        byArchitecture: tally(trialRecords, "architecture"),
        recent: recent(trialRecords, "startedAt")
      },
      activations: {
        totalSuccessfulActivations: activationRecords.length,
        uniqueInstalls: uniqueInstallCount(activationRecords),
        byOSVersion: tally(activationRecords, "osVersion"),
        byArchitecture: tally(activationRecords, "architecture"),
        recent: recent(activationRecords, "activatedAt")
      },
      conversion: {
        downloadToTrialRate: github.totalDownloads > 0 ? trialRecords.length / github.totalDownloads : null,
        trialToActivationRate: trialRecords.length > 0 ? activationRecords.length / trialRecords.length : null
      },
      notes: {
        kvConfigured: isKvConfigured(),
        trackingNote: "OS version and CPU breakdowns come from app-side analytics fields shipped with trial starts and successful activations."
      }
    };

    return sendJson(res, 200, payload);
  } catch (error) {
    return sendJson(res, 500, {
      success: false,
      message: error?.message || "The dashboard service failed."
    });
  }
};
