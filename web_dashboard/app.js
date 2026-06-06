import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.6.0/firebase-app.js';
import { getDatabase, ref, onValue } from 'https://www.gstatic.com/firebasejs/10.6.0/firebase-database.js';

const firebaseConfig = {
  apiKey: 'AIzaSyAdcl_IWkukKlA17vjJlNFoZtej2H_7brY',
  authDomain: 'mine-pulse.firebaseapp.com',
  databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
  projectId: 'mine-pulse',
  storageBucket: 'mine-pulse.appspot.com',
  messagingSenderId: '124181657638',
  appId: '1:124181657638:web:0952026408e42efb9e8ee7'
};

const app = initializeApp(firebaseConfig);
const db = getDatabase(app);

const statusContainer = document.getElementById('mineStatusCards');
const alertHistory = document.getElementById('alertHistory');
const lastUpdatedText = document.getElementById('lastUpdated');
const connectionStatus = document.getElementById('connectionStatus');
const metricActiveAlerts = document.getElementById('activeAlerts');
const metricSafeNodes = document.getElementById('safeNodes');
const metricTotalNodes = document.getElementById('totalNodes');
const dashboardContent = document.getElementById('dashboardContent');
let statusListener = null;
let alertsListener = null;

function formatTime(timestamp) {
  const date = new Date(timestamp);
  return date.toLocaleString();
}

function setDashboardVisible(visible) {
  if (!dashboardContent) return;
  dashboardContent.classList.toggle('hidden', !visible);
}


function clearDashboard() {
  statusContainer.innerHTML = '';
  alertHistory.innerHTML = '';
  metricActiveAlerts.textContent = '0';
  metricSafeNodes.textContent = '0';
  metricTotalNodes.textContent = '0';
  connectionStatus.textContent = 'Signed out. Please sign in to view live data.';
  lastUpdatedText.textContent = '';
}

function subscribeToDatabase() {
  if (statusListener || alertsListener) return;

  statusListener = onValue(ref(db, 'status'), (snapshot) => {
    const value = snapshot.val() || {};
    statusContainer.innerHTML = '';

    const mineIds = ['mine1', 'mine2'];
    mineIds.forEach((mineId) => {
      const mine = value[mineId] || {};
      statusContainer.appendChild(renderMineCard(mineId.replace('mine', ''), mine));
    });

    updateMetrics(value);
    connectionStatus.textContent = 'Connected to Firebase';
    lastUpdatedText.textContent = `Updated at ${new Date().toLocaleTimeString()}`;
  });

  alertsListener = onValue(ref(db, 'alerts'), (snapshot) => {
    const value = snapshot.val() || {};
    alertHistory.innerHTML = '';

    ['mine1', 'mine2'].forEach((mineId) => {
      const mineAlerts = value[mineId];
      if (!mineAlerts || !mineAlerts.history) return;
      const items = Object.values(mineAlerts.history).slice(-6).reverse();
      items.forEach((alert) => {
        alertHistory.appendChild(renderAlertEvent(mineId.replace('mine', ''), alert));
      });
    });
  });
}

function unsubscribeFromDatabase() {
  if (statusListener) {
    statusListener();
    statusListener = null;
  }
  if (alertsListener) {
    alertsListener();
    alertsListener = null;
  }
  clearDashboard();
}

function updateMetrics(statusData) {
  const mineIds = ['mine1', 'mine2'];
  const mines = mineIds.map((mineId) => statusData[mineId] || {});
  const active = mines.filter((node) => node.inAlert).length;
  const safe = mines.filter((node) => !node.inAlert).length;
  metricActiveAlerts.textContent = String(active);
  metricSafeNodes.textContent = String(safe);
  metricTotalNodes.textContent = String(mineIds.length);
}

function renderMineCard(nodeId, data) {
  const card = document.createElement('div');
  card.className = 'status-card';

  const title = document.createElement('h3');
  title.textContent = `Mine ${nodeId}`;
  card.appendChild(title);

  const badge = document.createElement('div');
  badge.className = `badge ${data.inAlert ? 'badge-danger' : 'badge-success'}`;
  badge.textContent = data.inAlert ? 'ALERT' : 'SAFE';
  card.appendChild(badge);

  const list = document.createElement('div');
  list.className = 'stat-row';
  list.innerHTML = `
    <div><strong>MQ-4:</strong> ${data.mq4 ?? 'N/A'}</div>
    <div><strong>MQ-7:</strong> ${data.mq7 ?? 'N/A'}</div>
    <div><strong>Water:</strong> ${data.water ?? 'N/A'}</div>
    <div><strong>RSSI:</strong> ${data.rssi ?? 'N/A'} dBm</div>
    <div><strong>Updated:</strong> ${data.updatedAt ? formatTime(data.updatedAt) : 'N/A'}</div>
  `;
  card.appendChild(list);
  return card;
}

function renderAlertEvent(nodeId, alert) {
  const row = document.createElement('div');
  row.className = 'history-item';

  const header = document.createElement('div');
  header.className = 'history-header';
  header.textContent = `Mine ${nodeId} alert at ${formatTime(alert.updatedAt || Date.now())}`;
  row.appendChild(header);

  const details = document.createElement('div');
  details.className = 'history-details';
  details.innerHTML = `
    <div><strong>MQ-4:</strong> ${alert.mq4 ?? 'N/A'}</div>
    <div><strong>MQ-7:</strong> ${alert.mq7 ?? 'N/A'}</div>
    <div><strong>Water:</strong> ${alert.water ?? 'N/A'}</div>
    <div><strong>RSSI:</strong> ${alert.rssi ?? 'N/A'} dBm</div>
  `;
  row.appendChild(details);
  return row;
}

subscribeToDatabase();

window.setTimeout(() => {
  if (!connectionStatus.textContent || connectionStatus.textContent === 'Waiting for Firebase...') {
    connectionStatus.textContent = 'Waiting for Firebase connection...';
  }
}, 2000);

