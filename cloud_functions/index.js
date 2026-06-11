const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

exports.sendAlertNotification = functions.firestore
  .document('alerts/{alertId}')
  .onCreate(async (snap, context) => {
    const alert = snap.data() || {};

    if (alert.resolved === true) {
      return null;
    }

    const message = {
      notification: {
        title: getTitle(alert.type),
        body: alert.message || 'New mine alert received.',
      },
      data: {
        type: String(alert.type || 'general'),
        location: String(alert.location || 'mine'),
        alertId: String(context.params.alertId || ''),
      },
      topic: 'mine_alerts',
    };

    try {
      const response = await admin.messaging().send(message);
      console.log('Notification sent:', response);
      return null;
    } catch (error) {
      console.error('Notification error:', error);
      return null;
    }
  });

function getTitle(type) {
  switch (type) {
    case 'gas':
      return '⚠️ Gas Alert – Mine Pulse';
    case 'fire':
      return '🔥 Fire Alert – Mine Pulse';
    default:
      return '🚨 Mine Pulse Alert';
  }
}
