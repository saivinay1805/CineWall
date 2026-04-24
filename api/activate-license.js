const LICENSE_API_BASE = "https://api.lemonsqueezy.com/v1/licenses";
const DEFAULT_PRODUCT_NAME = "CineWall Pro Lifetime";

function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.end(JSON.stringify(body));
}

async function callLicenseApi(path, params) {
  const response = await fetch(`${LICENSE_API_BASE}${path}`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: new URLSearchParams(params)
  });

  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    return {
      ok: false,
      data: data ?? {
        error: "The license service returned an invalid response."
      }
    };
  }

  return { ok: true, data };
}

function normalizeProductGuard() {
  return {
    expectedName: process.env.LEMON_PRODUCT_NAME || DEFAULT_PRODUCT_NAME,
    expectedId: process.env.LEMON_PRODUCT_ID || ""
  };
}

function isExpectedProduct(meta, guardConfig) {
  if (!meta) return false;
  if (guardConfig.expectedId) {
    return String(meta.product_id) === String(guardConfig.expectedId);
  }
  return meta.product_name === guardConfig.expectedName;
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

  let body = {};
  try {
    body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
  } catch {
    return sendJson(res, 400, {
      success: false,
      message: "Invalid JSON payload."
    });
  }

  const licenseKey = String(body.license_key || "").trim();
  const instanceName = String(body.device_name || "Mac").trim() || "Mac";
  const productSlug = String(body.product || "").trim();

  if (!licenseKey) {
    return sendJson(res, 400, {
      success: false,
      message: "A license key is required."
    });
  }

  if (productSlug && productSlug !== "cinewall-pro") {
    return sendJson(res, 400, {
      success: false,
      message: "Invalid product request."
    });
  }

  const guardConfig = normalizeProductGuard();

  try {
    const validate = await callLicenseApi("/validate", {
      license_key: licenseKey
    });

    if (!validate.ok || !validate.data?.valid) {
      return sendJson(res, 200, {
        success: false,
        message: validate.data?.error || "That license key is invalid or could not be verified."
      });
    }

    if (!isExpectedProduct(validate.data.meta, guardConfig)) {
      return sendJson(res, 403, {
        success: false,
        message: "This license key does not belong to CineWall Pro."
      });
    }

    const activation = await callLicenseApi("/activate", {
      license_key: licenseKey,
      instance_name: instanceName
    });

    if (activation.ok && activation.data?.activated) {
      return sendJson(res, 200, {
        success: true,
        message: "License activated.",
        instance_id: activation.data.instance?.id ?? null,
        product_name: activation.data.meta?.product_name ?? null
      });
    }

    return sendJson(res, 200, {
      success: false,
      message: activation.data?.error || "That license key could not be activated."
    });
  } catch (error) {
    return sendJson(res, 500, {
      success: false,
      message: error?.message || "The activation service failed."
    });
  }
};
