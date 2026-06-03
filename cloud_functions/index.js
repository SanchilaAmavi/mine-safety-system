const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

exports.sendAlertNotification = functions.database
  .ref('/alerts/{mineId}/history/{pushId}')
  .onCreate(async (snapshot, context) => {
    const data = snapshot.val();
    const mineId = context.params.mineId;

    const hazards = [];
    if (data.flags & 0x04) hazards.push('Water');
    if (data.flags & 0x01) hazards.push('Methane');
    if (data.flags & 0x02) hazards.push('Carbon Monoxide');

    const body = hazards.length > 0 ? `${hazards.join(', ')} hazard detected` : 'Hazard detected';
    const message = {
      notification: {
        title: `SubterraGuard Alert ${mineId.toUpperCase()}`,
        body: body,
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
