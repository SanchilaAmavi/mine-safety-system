import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.6.0/firebase-app.js';
import { getDatabase, ref, onValue } from 'https://www.gstatic.com/firebasejs/10.6.0/firebase-database.js';

const firebaseConfig = {
  apiKey: '<API_KEY>',
  authDomain: '<PROJECT_ID>.firebaseapp.com',
  databaseURL: 'https://<PROJECT_ID>.default-rtdb.firebaseio.com',
  projectId: '<PROJECT_ID>',
  storageBucket: '<PROJECT_ID>.appspot.com',
  messagingSenderId: '<SENDER_ID>',
  appId: '<APP_ID>'
};

const app = initializeApp(firebaseConfig);
const db = getDatabase(app);

const statusContainer = document.getElementById('mineStatusCards');
const alertHistory = document.getElementById('alertHistory');
const lastUpdatedText = document.getElementById('lastUpdated');
const connectionStatus = document.getElementById('connectionStatus');
const summaryCard = document.getElementById('summaryCard');

function formatTime(timestamp) {
  const date = new Date(timestamp);
  return date.toLocaleString();
}

function renderMineCard(nodeId, data) {
  const card = document.createElement('div');
  card.className = 'status-card';

  const title = document.createElement('h2');
  title.textContent = `Mine ${nodeId}`;
  card.appendChild(title);

  const badge = document.createElement('div');
  badge.className = `badge ${data.inAlert ? 'badge-danger' : 'badge-success'}`;
  badge.textContent = data.inAlert ? 'ALERT' : 'SAFE';
  card.appendChild(badge);

  const list = document.createElement('div');
  list.className = 'detail-list';
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

onValue(ref(db, 'status'), (snapshot) => {
  const value = snapshot.val() || {};
  statusContainer.innerHTML = '';

  const mineIds = ['mine1', 'mine2'];
  mineIds.forEach((mineId) => {
    const mine = value[mineId] || {};
    statusContainer.appendChild(renderMineCard(mineId.replace('mine', ''), mine));
  });

  connectionStatus.textContent = 'Connected to Firebase';
  lastUpdatedText.textContent = `Updated at ${new Date().toLocaleTimeString()}`;
});

onValue(ref(db, 'alerts'), (snapshot) => {
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

window.setTimeout(() => {
  if (!connectionStatus.textContent) {
    connectionStatus.textContent = 'Waiting for Firebase connection...';
  }
}, 2000);
