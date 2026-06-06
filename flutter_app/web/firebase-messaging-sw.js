importScripts('https://www.gstatic.com/firebasejs/9.22.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/9.22.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyAdcl_IWkukKlA17vjJlNFoZtej2H_7brY',
  authDomain: 'mine-pulse.firebaseapp.com',
  databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
  projectId: 'mine-pulse',
  storageBucket: 'mine-pulse.firebasestorage.app',
  messagingSenderId: '124181657638',
  appId: '1:124181657638:web:a13037355596d40a9e8ee7',
  measurementId: 'G-YVC0G9WDCW',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage(function(payload) {
  const notificationTitle = payload.notification?.title || 'Mine Pulse Alert';
  const notificationOptions = {
    body: payload.notification?.body || '',
    icon: '/favicon.jpeg',
  };

  return self.registration.showNotification(notificationTitle, notificationOptions);
});
