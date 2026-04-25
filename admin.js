const authSection = document.getElementById("admin-auth");
const contentSection = document.getElementById("admin-content");
const authMessage = document.getElementById("admin-auth-message");
const tokenInput = document.getElementById("admin-token");
const loginButton = document.getElementById("admin-login");
const refreshButton = document.getElementById("admin-refresh");
const adminNote = document.getElementById("admin-note");

function formatNumber(value) {
  return new Intl.NumberFormat("en-US").format(Number(value || 0));
}

function formatPercent(value) {
  if (value === null || value === undefined) return "N/A";
  return `${(value * 100).toFixed(1)}%`;
}

function formatDate(value) {
  if (!value) return "Unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return date.toLocaleString();
}

function renderSummaryCards(data) {
  const summary = document.getElementById("admin-summary");
  const cards = [
    { label: "GitHub Downloads", value: formatNumber(data.github.totalDownloads), tone: "blue" },
    { label: "Trial Starts", value: formatNumber(data.trials.totalStarts), tone: "green" },
    { label: "Active Trials", value: formatNumber(data.trials.active), tone: "teal" },
    { label: "Successful Activations", value: formatNumber(data.activations.totalSuccessfulActivations), tone: "gold" },
    { label: "Download to Trial", value: formatPercent(data.conversion.downloadToTrialRate), tone: "violet" },
    { label: "Trial to Activation", value: formatPercent(data.conversion.trialToActivationRate), tone: "rose" }
  ];

  summary.innerHTML = cards.map((card) => `
    <article class="admin-stat admin-tone-${card.tone}">
      <p>${card.label}</p>
      <strong>${card.value}</strong>
    </article>
  `).join("");
}

function renderBarList(targetID, items) {
  const host = document.getElementById(targetID);
  if (!items.length) {
    host.innerHTML = `<p class="admin-empty">No data yet.</p>`;
    return;
  }

  const max = Math.max(...items.map((item) => item.count), 1);
  host.innerHTML = items.map((item) => `
    <div class="admin-bar-row">
      <div class="admin-bar-meta">
        <span>${item.label}</span>
        <strong>${formatNumber(item.count)}</strong>
      </div>
      <div class="admin-bar-track">
        <div class="admin-bar-fill" style="width:${(item.count / max) * 100}%"></div>
      </div>
    </div>
  `).join("");
}

function renderPills(targetID, items) {
  const host = document.getElementById(targetID);
  if (!items.length) {
    host.innerHTML = `<p class="admin-empty">No data yet.</p>`;
    return;
  }

  host.innerHTML = items.map((item) => `
    <div class="admin-pill">
      <span>${item.label}</span>
      <strong>${formatNumber(item.count)}</strong>
    </div>
  `).join("");
}

function renderTable(targetID, records, columns) {
  const host = document.getElementById(targetID);
  if (!records.length) {
    host.innerHTML = `<p class="admin-empty">Nothing recorded yet.</p>`;
    return;
  }

  const head = columns.map((column) => `<th>${column.label}</th>`).join("");
  const body = records.map((record) => `
    <tr>
      ${columns.map((column) => `<td>${column.render(record)}</td>`).join("")}
    </tr>
  `).join("");

  host.innerHTML = `
    <table>
      <thead><tr>${head}</tr></thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

function renderDashboard(data) {
  document.getElementById("admin-generated").textContent = `Updated ${formatDate(data.generatedAt)}`;
  adminNote.textContent = data.notes?.excludedTestInstalls
    ? `Ignoring ${formatNumber(data.notes.excludedTestInstalls)} test install${data.notes.excludedTestInstalls === 1 ? "" : "s"} from conversion stats.`
    : "Conversion stats are currently using all recorded installs.";
  renderSummaryCards(data);
  renderBarList("trial-os-chart", data.trials.byOSVersion);
  renderPills("trial-arch-chart", data.trials.byArchitecture);
  renderBarList("activation-os-chart", data.activations.byOSVersion);
  renderPills("activation-arch-chart", data.activations.byArchitecture);

  renderTable("recent-trials", data.trials.recent, [
    { label: "Started", render: (record) => formatDate(record.startedAt) },
    { label: "macOS", render: (record) => record.osVersion || "Unknown" },
    { label: "CPU", render: (record) => record.architecture || "Unknown" },
    { label: "App", render: (record) => record.appVersion || "Unknown" },
    {
      label: "Type",
      render: (record) => record.isTest ? `<span class="admin-badge">Test</span>` : "Live"
    },
    {
      label: "Action",
      render: (record) => record.installHash
        ? `<button class="admin-inline-btn" data-install-hash="${record.installHash}" data-action="${record.isTest ? "remove" : "add"}">${record.isTest ? "Unmark Test" : "Mark Test"}</button>`
        : "N/A"
    }
  ]);

  renderTable("recent-activations", data.activations.recent, [
    { label: "Activated", render: (record) => formatDate(record.activatedAt) },
    { label: "macOS", render: (record) => record.osVersion || "Unknown" },
    { label: "CPU", render: (record) => record.architecture || "Unknown" },
    { label: "App", render: (record) => record.appVersion || "Unknown" },
    {
      label: "Type",
      render: (record) => record.isTest ? `<span class="admin-badge">Test</span>` : "Live"
    },
    {
      label: "Action",
      render: (record) => record.installHash
        ? `<button class="admin-inline-btn" data-install-hash="${record.installHash}" data-action="${record.isTest ? "remove" : "add"}">${record.isTest ? "Unmark Test" : "Mark Test"}</button>`
        : "N/A"
    }
  ]);

  renderTable("github-releases", data.github.releases, [
    { label: "Release", render: (record) => record.name || record.tag || "Untitled" },
    { label: "Published", render: (record) => formatDate(record.publishedAt) },
    { label: "Downloads", render: (record) => formatNumber(record.downloads) }
  ]);
}

async function loadDashboard(token) {
  authMessage.textContent = "Loading dashboard...";

  const response = await fetch("/api/admin-stats", {
    headers: {
      Authorization: `Bearer ${token}`
    }
  });

  const data = await response.json().catch(() => null);

  if (!response.ok || !data?.success) {
    throw new Error(data?.message || "The dashboard could not be loaded.");
  }

  sessionStorage.setItem("cinewallAdminToken", token);
  authSection.classList.add("hidden");
  contentSection.classList.remove("hidden");
  renderDashboard(data);
  authMessage.textContent = "This page stays private by requiring your token before the API responds.";
}

async function updateTestInstall(installHash, action) {
  const token = sessionStorage.getItem("cinewallAdminToken") || "";
  if (!token) throw new Error("Missing admin token.");

  const response = await fetch("/api/admin-test-installs", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      install_hash: installHash,
      action
    })
  });

  const data = await response.json().catch(() => null);
  if (!response.ok || !data?.success) {
    throw new Error(data?.message || "The install flag could not be updated.");
  }
}

async function handleLogin() {
  const token = tokenInput.value.trim();
  if (!token) {
    authMessage.textContent = "Enter your admin token first.";
    return;
  }

  try {
    await loadDashboard(token);
  } catch (error) {
    authMessage.textContent = error.message;
    contentSection.classList.add("hidden");
    authSection.classList.remove("hidden");
  }
}

loginButton?.addEventListener("click", handleLogin);
tokenInput?.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    handleLogin();
  }
});

refreshButton?.addEventListener("click", async () => {
  const token = sessionStorage.getItem("cinewallAdminToken") || "";
  if (!token) return;

  try {
    await loadDashboard(token);
  } catch (error) {
    document.getElementById("admin-generated").textContent = error.message;
  }
});

document.addEventListener("click", async (event) => {
  const button = event.target.closest(".admin-inline-btn");
  if (!button) return;

  const installHash = String(button.dataset.installHash || "").trim();
  const action = String(button.dataset.action || "add").trim();
  if (!installHash) return;

  const originalText = button.textContent;
  button.disabled = true;
  button.textContent = "Saving...";

  try {
    await updateTestInstall(installHash, action);
    const token = sessionStorage.getItem("cinewallAdminToken") || "";
    await loadDashboard(token);
  } catch (error) {
    document.getElementById("admin-generated").textContent = error.message;
    button.disabled = false;
    button.textContent = originalText;
  }
});

const savedToken = sessionStorage.getItem("cinewallAdminToken");
if (savedToken) {
  loadDashboard(savedToken).catch((error) => {
    authMessage.textContent = error.message;
    sessionStorage.removeItem("cinewallAdminToken");
  });
}
