import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.0/firebase-app.js";
import {
  getDatabase, ref, onValue
} from "https://www.gstatic.com/firebasejs/10.12.0/firebase-database.js";
import {
  getFirestore, collection, addDoc, onSnapshot,
  query, orderBy, limit, serverTimestamp, Timestamp
} from "https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js";

// ── Firebase config ────────────────────────────────────────────
const firebaseConfig = {
  apiKey: 'AIzaSyAdcl_IWkukKlA17vjJlNFoZtej2H_7brY',
  authDomain: 'mine-pulse.firebaseapp.com',
  databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
  projectId: 'mine-pulse',
  storageBucket: 'mine-pulse.firebasestorage.app',
  messagingSenderId: '124181657638',
  appId: '1:124181657638:web:0952026408e42efb9e8ee7',
  measurementId: 'G-XMT2LES1RH'
};

const app = initializeApp(firebaseConfig);
const db  = getDatabase(app);
const fs  = getFirestore(app);

// ── Node IDs (RTDB paths: /status/mine1 etc.) ─────────────────
const NODE_IDS = ["mine1", "mine2", "mine3"];
const NODE_LABELS = {
  mine1: "Node A · Level 1",
  mine2: "Node B · Level 2",
  mine3: "Node C · Level 3"
};

// ── State ──────────────────────────────────────────────────────
const state = {
  nodes: {},          // { mine1: { inAlert, message, severity, title, ts } }
  activeAlerts: [],
  alertHistory: [],
  chartMQ4: null,
  chartMQ7: null,
  chartDist: null,
  chartHazard: null,
  chartNodes: null,
  mq4History: {},     // kept for chart structure compatibility
  mq7History: {},
  leafletMap: null,
  leafletMarkers: {},
  soundEnabled: true,
  notifEnabled: false,
  selectedAlertId: null
};

NODE_IDS.forEach(id => {
  state.mq4History[id] = [];
  state.mq7History[id] = [];
});

// ══════════════════════════════════════════════════════════════
//  NAVIGATION
// ══════════════════════════════════════════════════════════════
function initNav() {
  const navItems = document.querySelectorAll(".nav-item[data-view]");
  const panels   = document.querySelectorAll(".view-panel");
  const titles   = {
    overview:  ["Overview",  "Real-time mine safety telemetry"],
    alerts:    ["Alerts",    "Active hazards & historical log"],
    map:       ["Mine Map",  "Node geolocation · Kuruwita, Ratnapura"],
    analytics: ["Analytics", "Sensor statistics & trend analysis"],
    settings:  ["Settings",  "System configuration & thresholds"]
  };

  navItems.forEach(btn => {
    btn.addEventListener("click", () => {
      const view = btn.dataset.view;

      navItems.forEach(b => b.classList.remove("active"));
      btn.classList.add("active");

      panels.forEach(p => p.classList.remove("active"));
      const target = document.getElementById("view-" + view);
      if (target) target.classList.add("active");

      const [title, sub] = titles[view] || ["Mine Pulse", ""];
      document.getElementById("pageTitle").textContent    = title;
      document.getElementById("pageSubtitle").textContent = sub;

      if (view === "map" && !state.leafletMap) initMap();
      if (view === "analytics") setTimeout(redrawAnalyticsCharts, 100);
    });
  });
}

// ══════════════════════════════════════════════════════════════
//  CLOCK
// ══════════════════════════════════════════════════════════════
function initClock() {
  function tick() {
    const now = new Date();
    document.getElementById("clockDisplay").textContent =
      now.toLocaleTimeString("en-US", { hour12: false });
  }
  tick();
  setInterval(tick, 1000);
}

// ══════════════════════════════════════════════════════════════
//  RTDB LISTENER — reads YOUR mobile app structure
//  { inAlert, message, severity, title }
// ══════════════════════════════════════════════════════════════
function listenRTDB() {
  NODE_IDS.forEach(nodeId => {
    const nodeRef = ref(db, `status/${nodeId}`);

    onValue(nodeRef, snap => {
      const data = snap.val();
      if (!data) return;

      const prev = state.nodes[nodeId];

      // Store exactly what Firebase sends
      state.nodes[nodeId] = {
        id:       nodeId,
        inAlert:  data.inAlert  ?? false,
        message:  data.message  || "No message",
        severity: data.severity || "info",     // "warning" | "critical" | "info"
        title:    data.title    || "Status",
        ts:       Date.now()
      };

      // Transition: safe → alert
      if (data.inAlert && (!prev || !prev.inAlert)) {
        handleNewAlert(nodeId, state.nodes[nodeId]);
      }

      // Transition: alert → safe
      if (!data.inAlert && prev && prev.inAlert) {
        handleAlertCleared(nodeId);
      }

      renderOverview();
      updateMapMarker(nodeId);
      setConnectionStatus(true);

    }, err => {
      console.error("RTDB error:", err);
      setConnectionStatus(false);
    });
  });
}

// ══════════════════════════════════════════════════════════════
//  FIRESTORE — Alert log (shared with mobile app)
// ══════════════════════════════════════════════════════════════
function listenFirestoreAlerts() {
  const q = query(
    collection(fs, "alerts"),
    orderBy("timestamp", "desc"),
    limit(50)
  );
  onSnapshot(q, snap => {
    state.alertHistory = snap.docs.map(d => ({ id: d.id, ...d.data() }));
    renderAlertHistory();
    updateAnalyticsCounters();
  });
}

// ══════════════════════════════════════════════════════════════
//  WRITE TO FIRESTORE (shared log with mobile app)
// ══════════════════════════════════════════════════════════════
async function writeAlertToFirestore(nodeId, data) {
  try {
    await addDoc(collection(fs, "alerts"), {
      nodeId,
      title:    data.title   || "Alert",
      message:  data.message || "",
      severity: data.severity|| "info",
      inAlert:  true,
      source:   "web-dashboard",
      timestamp: serverTimestamp()
    });
  } catch (e) {
    console.warn("Firestore write failed:", e);
  }
}

// ══════════════════════════════════════════════════════════════
//  ALERT LOGIC — uses title/message/severity from Firebase
// ══════════════════════════════════════════════════════════════
function handleNewAlert(nodeId, data) {
  const alertObj = {
    id:       `${nodeId}-${Date.now()}`,
    nodeId,
    title:    data.title,
    message:  data.message,
    severity: data.severity,
    ts:       Date.now(),
    active:   true,
    label:    NODE_LABELS[nodeId] || nodeId
  };

  state.activeAlerts.unshift(alertObj);

  writeAlertToFirestore(nodeId, data);

  showToast(
    `🚨 ${data.title}`,
    `${NODE_LABELS[nodeId]}: ${data.message}`,
    data.severity === "critical" ? "danger" : "warning"
  );
  triggerBrowserNotification(nodeId, data.title, data.message);
  if (state.soundEnabled) playAlertSound();

  renderActiveAlerts();
  renderOverview();
}

function handleAlertCleared(nodeId) {
  state.activeAlerts = state.activeAlerts.filter(a => a.nodeId !== nodeId);
  showToast("✅ Alert Cleared", `${NODE_LABELS[nodeId]} returned to safe state.`, "info");
  renderActiveAlerts();
  renderOverview();
}

// ── Severity → CSS class / icon mapping ───────────────────────
function sevClass(severity) {
  if (severity === "critical") return "critical";
  if (severity === "warning")  return "warning";
  return "info";
}

function sevIcon(severity) {
  if (severity === "critical") return "🔴";
  if (severity === "warning")  return "🟡";
  return "🔵";
}

// ══════════════════════════════════════════════════════════════
//  RENDER — OVERVIEW (status banner + metrics + node cards)
// ══════════════════════════════════════════════════════════════
function renderOverview() {
  const nodes      = Object.values(state.nodes);
  const alertNodes = nodes.filter(n => n.inAlert);
  const safeNodes  = nodes.filter(n => !n.inAlert);

  setText("metricAlerts", alertNodes.length || "0");
  setText("metricSafe",   safeNodes.length  || "0");
  setText("metricOnline", nodes.length      || "0");

  const now = new Date();
  setText("metricTime", now.toLocaleTimeString("en-US", { hour12: false }));
  setText("metricDate", now.toLocaleDateString("en-GB", { day:"2-digit", month:"short", year:"numeric" }));

  // Status banner
  const banner      = document.getElementById("statusBanner");
  const bannerTitle = document.getElementById("bannerTitle");
  const bannerSub   = document.getElementById("bannerSub");

  if (alertNodes.length > 0) {
    banner.className        = "status-banner alert";
    bannerTitle.textContent = `⚠️ ${alertNodes.length} Active Alert${alertNodes.length > 1 ? "s" : ""} — Immediate Action Required`;
    bannerSub.textContent   = alertNodes.map(n =>
      `${NODE_LABELS[n.id] || n.id}: ${n.message}`
    ).join(" | ");

    let pulse = banner.querySelector(".banner-pulse");
    if (!pulse) {
      pulse = document.createElement("div");
      pulse.className = "banner-pulse";
      banner.appendChild(pulse);
    }
  } else {
    banner.className        = "status-banner safe";
    bannerTitle.textContent = "All Systems Stable";
    bannerSub.textContent   = "No active hazards detected. Continue routine monitoring.";
    const pulse = banner.querySelector(".banner-pulse");
    if (pulse) pulse.remove();
  }

  // Nav badge
  const badge = document.getElementById("navAlertBadge");
  if (alertNodes.length > 0) {
    badge.style.display = "";
    badge.textContent   = alertNodes.length;
  } else {
    badge.style.display = "none";
  }

  renderNodeCards();
  renderTrendCharts();
}

// ══════════════════════════════════════════════════════════════
//  RENDER — NODE CARDS (uses title/message/severity)
// ══════════════════════════════════════════════════════════════
function renderNodeCards() {
  const grid = document.getElementById("nodesGrid");
  if (!grid) return;

  if (Object.keys(state.nodes).length === 0) {
    grid.innerHTML = `<div class="node-card"><div class="empty-state"><div class="icon">📡</div>Connecting to nodes…</div></div>`;
    return;
  }

  grid.innerHTML = NODE_IDS.map(id => {
    const n = state.nodes[id];
    return n ? nodeCard(id, n) : nodeOfflineCard(id);
  }).join("");
}

function nodeCard(id, n) {
  const sev     = n.severity || "info";
  const inAlert = n.inAlert;
  const ts      = new Date(n.ts).toLocaleTimeString("en-US", { hour12: false });

  const statusPill = inAlert
    ? `<span class="pill pill-danger">⚠ ALERT</span>`
    : `<span class="pill pill-success">✓ SAFE</span>`;

  const sevColor = sev === "critical" ? "var(--danger)"
                 : sev === "warning"  ? "var(--warning)"
                 : "var(--accent)";

  const msgIcon = sev === "critical" ? "🔴" : sev === "warning" ? "🟡" : "🟢";

  return `
  <div class="node-card ${inAlert ? "in-alert" : ""}">
    <div class="node-header">
      <div>
        <div class="node-title">${NODE_LABELS[id]}</div>
        <div class="node-id">${id.toUpperCase()}</div>
      </div>
      <div class="node-badges">${statusPill}</div>
    </div>

    <div class="sensors">

      <!-- Title row -->
      <div class="sensor-row">
        <div class="sensor-top">
          <div class="sensor-name">
            <div class="sensor-dot" style="background:${sevColor}"></div>
            Alert Title
          </div>
          <div class="sensor-val" style="color:${sevColor}">
            ${n.title || "—"}
          </div>
        </div>
      </div>

      <!-- Message row -->
      <div class="sensor-row">
        <div class="sensor-top">
          <div class="sensor-name">
            <div class="sensor-dot" style="background:${sevColor}"></div>
            Message
          </div>
        </div>
        <div style="font-size:12px; color:var(--text-2); margin-top:4px; padding:8px 10px;
                    background:var(--surface-2); border-radius:8px; border:1px solid var(--border);">
          ${msgIcon} ${n.message || "No message"}
        </div>
      </div>

      <!-- Severity row -->
      <div class="sensor-row">
        <div class="sensor-top">
          <div class="sensor-name">
            <div class="sensor-dot" style="background:${sevColor}"></div>
            Severity
          </div>
          <div class="sensor-val" style="color:${sevColor}; text-transform:uppercase;">
            ${sev}
          </div>
        </div>
        <!-- Severity bar: critical=100%, warning=60%, info=30% -->
        <div class="sensor-bar-bg">
          <div class="sensor-bar-fill" style="
            width:${sev === "critical" ? "100" : sev === "warning" ? "60" : "30"}%;
            background:${sevColor};
          "></div>
        </div>
      </div>

    </div>

    <div class="node-footer">
      <span class="node-ts">Updated: ${ts}</span>
      <span class="pill ${sev === "critical" ? "pill-danger" : sev === "warning" ? "pill-warning" : "pill-muted"}"
            style="font-size:10px">${sev.toUpperCase()}</span>
    </div>
  </div>`;
}

function nodeOfflineCard(id) {
  return `
  <div class="node-card offline">
    <div class="node-header">
      <div>
        <div class="node-title">${NODE_LABELS[id]}</div>
        <div class="node-id">${id.toUpperCase()}</div>
      </div>
      <span class="pill pill-muted">OFFLINE</span>
    </div>
    <div class="empty-state" style="padding:20px 0">No data received</div>
  </div>`;
}

// ══════════════════════════════════════════════════════════════
//  RENDER — ALERTS TAB (active + history)
// ══════════════════════════════════════════════════════════════
function renderActiveAlerts() {
  const list  = document.getElementById("activeAlertsList");
  const count = document.getElementById("activeCount");
  if (!list) return;

  const liveAlerts = Object.values(state.nodes).filter(n => n.inAlert);

  if (liveAlerts.length === 0) {
    list.innerHTML = `<div class="empty-state"><div class="icon">✅</div>No active alerts — all nodes safe.</div>`;
    if (count) count.style.display = "none";
    return;
  }

  if (count) { count.style.display = ""; count.textContent = liveAlerts.length; }

  list.innerHTML = liveAlerts.map(n => alertRowHTML({
    nodeId:    n.id,
    title:     n.title,
    message:   n.message,
    severity:  n.severity,
    ts:        new Date(n.ts).toLocaleTimeString("en-US", { hour12: false }),
    isHistory: false
  })).join("");

  list.querySelectorAll(".alert-row").forEach(row => {
    row.addEventListener("click", () => {
      const nodeId = row.dataset.nodeid;
      showAlertDetail(nodeId, state.nodes[nodeId]);
    });
  });
}

function renderAlertHistory() {
  const list  = document.getElementById("alertHistoryList");
  const count = document.getElementById("historyCount");
  if (!list) return;

  if (state.alertHistory.length === 0) {
    list.innerHTML = `<div class="empty-state"><div class="icon">📂</div>No historical alerts yet.</div>`;
    if (count) count.textContent = "0";
    return;
  }

  if (count) count.textContent = state.alertHistory.length;

  list.innerHTML = state.alertHistory.slice(0, 20).map((a, idx) => alertRowHTML({
    nodeId:    a.nodeId,
    title:     a.title    || "Alert",
    message:   a.message  || "",
    severity:  a.severity || "info",
    ts:        a.timestamp?.toDate ? a.timestamp.toDate().toLocaleString("en-GB") : "—",
    isHistory: true,
    idx
  })).join("");

  list.querySelectorAll(".alert-row").forEach(row => {
    row.addEventListener("click", () => {
      const idx = parseInt(row.dataset.idx);
      showAlertDetail(null, state.alertHistory[idx], true);
    });
  });
}

function alertRowHTML({ nodeId, title, message, severity, ts, isHistory, idx }) {
  const sev   = sevClass(severity);
  const icon  = sevIcon(severity);
  const label = NODE_LABELS[nodeId] || nodeId || "Unknown Node";
  const extra = isHistory ? `data-idx="${idx}"` : `data-nodeid="${nodeId}"`;

  return `
  <div class="alert-row ${sev}" ${extra}>
    <div class="alert-icon">${icon}</div>
    <div>
      <div class="alert-title-text">${title}</div>
      <div class="alert-meta">${label} · ${ts}</div>
      <div class="alert-desc">${message}</div>
    </div>
    <span class="alert-sev sev-${sev}">${sev.toUpperCase()}</span>
  </div>`;
}

// ── Alert Detail Panel ─────────────────────────────────────────
function showAlertDetail(nodeId, data, isHistory = false) {
  const panel = document.getElementById("detailContent");
  if (!panel || !data) return;

  const label   = NODE_LABELS[nodeId || data.nodeId] || nodeId || "Unknown";
  const sev     = data.severity || "info";
  const sevCol  = sev === "critical" ? "var(--danger)" : sev === "warning" ? "var(--warning)" : "var(--accent)";
  const timeStr = isHistory
    ? (data.timestamp?.toDate ? data.timestamp.toDate().toLocaleString("en-GB") : "—")
    : new Date(data.ts || Date.now()).toLocaleString("en-GB");

  // Recommended actions based on message content
  let action = "• Monitor the node. Verify sensor readings on site.";
  const msg = (data.message || "").toLowerCase();
  if (msg.includes("co") || msg.includes("carbon")) {
    action = "• Carbon monoxide detected. Evacuate area immediately. Deploy SCBA equipment.";
  } else if (msg.includes("ch4") || msg.includes("methane") || msg.includes("gas")) {
    action = "• Methane/gas detected. Evacuate tunnel. Ventilate area. Check supply lines.";
  } else if (msg.includes("water") || msg.includes("flood")) {
    action = "• Water flooding risk. Activate pumps. Move equipment to higher ground.";
  } else if (sev === "critical") {
    action = "• Critical hazard. Evacuate immediately and contact mine safety officer.";
  }

  panel.innerHTML = `
  <div class="detail-content">
    <div class="detail-row">
      <span class="detail-key">Node</span>
      <span class="detail-val">${label}</span>
    </div>
    <div class="detail-row">
      <span class="detail-key">Title</span>
      <span class="detail-val" style="color:${sevCol}">${data.title || "—"}</span>
    </div>
    <div class="detail-row">
      <span class="detail-key">Message</span>
      <span class="detail-val">${data.message || "—"}</span>
    </div>
    <div class="detail-row">
      <span class="detail-key">Severity</span>
      <span class="detail-val" style="color:${sevCol};text-transform:uppercase">${sev}</span>
    </div>
    <div class="detail-row">
      <span class="detail-key">Time</span>
      <span class="detail-val">${timeStr}</span>
    </div>
    <div class="detail-row">
      <span class="detail-key">Source</span>
      <span class="detail-val">${isHistory ? "Historical" : "Live"}</span>
    </div>
    <div style="margin-top:12px;padding:12px;
                background:var(--danger-dim);
                border:1px solid rgba(255,77,77,0.25);
                border-radius:8px;font-size:12px;
                color:var(--text-2);line-height:1.8">
      <strong style="color:var(--text)">Recommended Action:</strong><br>${action}
    </div>
    ${!isHistory ? `<button class="detail-action" onclick="triggerSOS()">⚠️ Trigger Emergency SOS</button>` : ""}
  </div>`;
}

// ══════════════════════════════════════════════════════════════
//  ANALYTICS — updated to use severity field
// ══════════════════════════════════════════════════════════════
function updateAnalyticsCounters() {
  const critical = state.alertHistory.filter(a => a.severity === "critical").length;
  const warning  = state.alertHistory.filter(a => a.severity === "warning").length;
  setText("anCritical", critical);
  setText("anWarning",  warning);
  setText("anTotal",    state.alertHistory.length);

  renderSensorTable();
  redrawAnalyticsCharts();
}

function renderSensorTable() {
  const tbody = document.getElementById("sensorTableBody");
  if (!tbody) return;

  if (Object.keys(state.nodes).length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" style="color:var(--text-3);text-align:center;padding:20px">Waiting for data…</td></tr>`;
    return;
  }

  tbody.innerHTML = NODE_IDS.map(id => {
    const n = state.nodes[id];
    if (!n) return `<tr><td>${id}</td><td colspan="5" style="color:var(--text-3)">Offline</td></tr>`;
    const sev    = n.severity || "info";
    const sevCol = sev === "critical" ? "var(--danger)" : sev === "warning" ? "var(--warning)" : "var(--success)";
    const pill   = n.inAlert
      ? `<span class="pill pill-danger" style="font-size:10px">ALERT</span>`
      : `<span class="pill pill-success" style="font-size:10px">SAFE</span>`;
    return `
    <tr>
      <td>${NODE_LABELS[id]}</td>
      <td>${n.title || "—"}</td>
      <td colspan="2" style="color:${sevCol}">${n.message || "—"}</td>
      <td style="color:${sevCol};text-transform:uppercase">${sev}</td>
      <td>${pill}</td>
    </tr>`;
  }).join("");
}

// ══════════════════════════════════════════════════════════════
//  CHARTS
// ══════════════════════════════════════════════════════════════
const CHART_COLORS = {
  mine1: "#2e7dff",
  mine2: "#22c55e",
  mine3: "#ffb020"
};

function chartDefaults() {
  return {
    responsive: true, maintainAspectRatio: false,
    animation: { duration: 300 },
    plugins: { legend: { display: false } },
    scales: {
      x: { display: false },
      y: {
        grid: { color: "rgba(255,255,255,0.05)" },
        ticks: { color: "#4f6280", font: { size: 10 } }
      }
    }
  };
}

function initTrendCharts() {
  // Charts are kept for structure but severity-based data replaces ppm data
  const ctxDist = document.getElementById("chartDist")?.getContext("2d");

  if (ctxDist) {
    state.chartDist = new Chart(ctxDist, {
      type: "doughnut",
      data: {
        labels: ["Critical", "Warning", "Info", "Safe"],
        datasets: [{
          data: [0, 0, 0, 3],
          backgroundColor: ["#ff4d4d", "#ffb020", "#29b6f6", "#22c55e"],
          borderWidth: 2, borderColor: "#111827"
        }]
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { position: "bottom", labels: { color: "#8fa3bf", font: { size: 10 }, padding: 10 } } }
      }
    });
  }
}

function renderTrendCharts() {
  if (state.chartDist) {
    const critical = state.alertHistory.filter(a => a.severity === "critical").length;
    const warning  = state.alertHistory.filter(a => a.severity === "warning").length;
    const info     = state.alertHistory.filter(a => a.severity === "info").length;
    const safe     = Math.max(0, Object.values(state.nodes).filter(n => !n.inAlert).length);
    state.chartDist.data.datasets[0].data = [critical, warning, info, safe];
    state.chartDist.update("none");
  }
}

function redrawAnalyticsCharts() {
  const ctxH = document.getElementById("chartHazard")?.getContext("2d");
  const ctxN = document.getElementById("chartNodes")?.getContext("2d");

  if (ctxH && !state.chartHazard) {
    state.chartHazard = new Chart(ctxH, {
      type: "bar",
      data: {
        labels: ["Critical", "Warning", "Info"],
        datasets: [{
          label: "Alert Count",
          data: [0, 0, 0],
          backgroundColor: ["#ff4d4d", "#ffb020", "#29b6f6"],
          borderRadius: 6
        }]
      },
      options: { ...chartDefaults(), plugins: { legend: { display: false } } }
    });
  }

  if (ctxN && !state.chartNodes) {
    state.chartNodes = new Chart(ctxN, {
      type: "bar",
      data: {
        labels: NODE_IDS.map(id => NODE_LABELS[id]),
        datasets: [
          { label: "In Alert", data: [], backgroundColor: "#ff4d4d", borderRadius: 4 },
          { label: "Safe",     data: [], backgroundColor: "#22c55e", borderRadius: 4 }
        ]
      },
      options: {
        ...chartDefaults(),
        plugins: { legend: { display: true, labels: { color: "#8fa3bf", font: { size: 10 } } } },
        scales: {
          x: { ticks: { color: "#4f6280", font: { size: 10 } }, grid: { display: false } },
          y: { grid: { color: "rgba(255,255,255,0.05)" }, ticks: { color: "#4f6280", font: { size: 10 } } }
        }
      }
    });
  }

  if (state.chartHazard) {
    const critical = state.alertHistory.filter(a => a.severity === "critical").length;
    const warning  = state.alertHistory.filter(a => a.severity === "warning").length;
    const info     = state.alertHistory.filter(a => a.severity === "info").length;
    state.chartHazard.data.datasets[0].data = [critical, warning, info];
    state.chartHazard.update("none");
  }

  if (state.chartNodes) {
    state.chartNodes.data.datasets[0].data = NODE_IDS.map(id => state.nodes[id]?.inAlert ? 1 : 0);
    state.chartNodes.data.datasets[1].data = NODE_IDS.map(id => state.nodes[id] && !state.nodes[id].inAlert ? 1 : 0);
    state.chartNodes.update("none");
  }
}

// ══════════════════════════════════════════════════════════════
//  MAP (Leaflet)
// ══════════════════════════════════════════════════════════════
const NODE_COORDS = {
  mine1: [6.7850, 80.3640],
  mine2: [6.7870, 80.3670],
  mine3: [6.7830, 80.3610]
};

function initMap() {
  const mapEl = document.getElementById("leafletMap");
  if (!mapEl || state.leafletMap) return;

  state.leafletMap = L.map("leafletMap", {
    center: [6.786, 80.364],
    zoom: 16,
    zoomControl: true
  });

  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    attribution: "© OpenStreetMap contributors",
    maxZoom: 19
  }).addTo(state.leafletMap);

  L.circleMarker([6.7855, 80.3650], {
    radius: 12, fillColor: "#2e7dff", color: "#fff",
    weight: 2, fillOpacity: 0.9
  }).bindPopup("<b>Mine Pulse Gateway</b><br>Primary Device MP-001")
    .addTo(state.leafletMap);

  NODE_IDS.forEach(id => {
    const coords = NODE_COORDS[id];
    const marker = L.circleMarker(coords, {
      radius: 10, fillColor: "#8fa3bf", color: "#fff",
      weight: 2, fillOpacity: 0.85
    }).bindPopup(`<b>${NODE_LABELS[id]}</b><br>Loading…`)
      .addTo(state.leafletMap);
    state.leafletMarkers[id] = marker;
  });

  setTimeout(() => state.leafletMap.invalidateSize(), 200);
}

function updateMapMarker(nodeId) {
  if (!state.leafletMap) return;
  const marker = state.leafletMarkers[nodeId];
  const n      = state.nodes[nodeId];
  if (!marker || !n) return;

  const color = n.inAlert ? "#ff4d4d" : "#22c55e";
  marker.setStyle({ fillColor: color });
  marker.setPopupContent(`
    <b>${NODE_LABELS[nodeId]}</b><br>
    <b>${n.title}</b><br>
    ${n.message}<br>
    Severity: <b style="color:${color}">${n.severity?.toUpperCase()}</b><br>
    Status: <b style="color:${color}">${n.inAlert ? "ALERT" : "SAFE"}</b>
  `);
}

// ══════════════════════════════════════════════════════════════
//  NOTIFICATIONS & SOUND
// ══════════════════════════════════════════════════════════════
window.requestNotificationPermission = async function () {
  if (!("Notification" in window)) return;
  const perm = await Notification.requestPermission();
  state.notifEnabled = perm === "granted";
  const label = document.getElementById("notifLabel");
  if (label) label.textContent = state.notifEnabled ? "Alerts On" : "Enable Alerts";
  const status = document.getElementById("notifStatus");
  if (status) status.textContent = state.notifEnabled ? "Granted" : "Denied";
};

function triggerBrowserNotification(nodeId, title, message) {
  if (!state.notifEnabled || Notification.permission !== "granted") return;
  new Notification(`⚠️ ${title}`, {
    body: `${NODE_LABELS[nodeId]}: ${message}`,
    icon: "/favicon.ico"
  });
}

function playAlertSound() {
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    [880, 660, 880].forEach((freq, i) => {
      const osc  = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain); gain.connect(ctx.destination);
      osc.frequency.value = freq;
      osc.type = "square";
      gain.gain.setValueAtTime(0.12, ctx.currentTime + i * 0.25);
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + i * 0.25 + 0.2);
      osc.start(ctx.currentTime + i * 0.25);
      osc.stop(ctx.currentTime + i * 0.25 + 0.25);
    });
  } catch (e) {}
}

// ══════════════════════════════════════════════════════════════
//  SOS
// ══════════════════════════════════════════════════════════════
window.triggerSOS = function () {
  showToast("🆘 SOS TRIGGERED", "Emergency services notified. Evacuate mine immediately!", "danger");
  playAlertSound();
  if (state.notifEnabled) {
    new Notification("🆘 MINE PULSE SOS", {
      body: "Emergency SOS triggered from dashboard. Call 119 immediately."
    });
  }
};

// ══════════════════════════════════════════════════════════════
//  SETTINGS TOGGLES
// ══════════════════════════════════════════════════════════════
window.toggleSetting = function (el) {
  el.classList.toggle("on");
  const id = el.id;
  if (id === "toggleSound") state.soundEnabled = el.classList.contains("on");
  if (id === "toggleNotif") {
    if (el.classList.contains("on")) requestNotificationPermission();
    else state.notifEnabled = false;
  }
};

// ══════════════════════════════════════════════════════════════
//  TOAST
// ══════════════════════════════════════════════════════════════
function showToast(title, body, type = "danger") {
  const container = document.getElementById("toastContainer");
  if (!container) return;

  const t = document.createElement("div");
  t.className = `toast ${type}`;
  t.innerHTML = `
    <button class="toast-close" onclick="this.parentElement.remove()">×</button>
    <div class="toast-title">${title}</div>
    <div class="toast-body">${body}</div>`;
  container.appendChild(t);
  setTimeout(() => t.remove(), 6000);
}

// ══════════════════════════════════════════════════════════════
//  CONNECTION STATUS
// ══════════════════════════════════════════════════════════════
function setConnectionStatus(connected) {
  const dot   = document.getElementById("connDot");
  const label = document.getElementById("connLabel");
  if (!dot || !label) return;
  if (connected) {
    dot.className     = "conn-dot connected";
    label.textContent = "Live · Firebase";
  } else {
    dot.className     = "conn-dot error";
    label.textContent = "Disconnected";
  }
}

// ══════════════════════════════════════════════════════════════
//  HELPERS
// ══════════════════════════════════════════════════════════════
function setText(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = val;
}

// ══════════════════════════════════════════════════════════════
//  BOOT
// ══════════════════════════════════════════════════════════════
document.addEventListener("DOMContentLoaded", () => {
  initNav();
  initClock();
  initTrendCharts();
  listenRTDB();
  listenFirestoreAlerts();

  renderActiveAlerts();
  renderAlertHistory();

  const notifStatus = document.getElementById("notifStatus");
  if (notifStatus) {
    notifStatus.textContent = Notification.permission === "granted" ? "Granted" : "Not granted";
  }
});