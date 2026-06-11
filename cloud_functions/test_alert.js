const admin = require('firebase-admin');

admin.initializeApp();

async function addSampleAlert() {
  const db = admin.firestore();

  const alert = {
    location: 'node1',
    message: 'High CO level detected',
    type: 'gas',
    resolved: false,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  };

  const docRef = await db.collection('alerts').add(alert);
  console.log('Alert added with ID:', docRef.id);
}

addSampleAlert().catch((error) => {
  console.error('Error adding alert:', error);
  process.exit(1);
});
