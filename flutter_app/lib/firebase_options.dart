import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAdcl_IWkukKlA17vjJlNFoZtej2H_7brY',
    appId: '1:124181657638:web:0952026408e42efb9e8ee7',
    messagingSenderId: '124181657638',
    projectId: 'mine-pulse',
    authDomain: 'mine-pulse.firebaseapp.com',
    databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
    storageBucket: 'mine-pulse.firebasestorage.app',
    measurementId: 'G-XMT2LES1RH',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDaDrIaz_O6KdOFkzWfLlJGfrZd_VOkg4Y',
    appId: '1:124181657638:android:d8c4d5a61d37c61d9e8ee7',
    messagingSenderId: '124181657638',
    projectId: 'mine-pulse',
    databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
    storageBucket: 'mine-pulse.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAexgx32Jjm0vk3lO2GacByy4aetEOiYDw',
    appId: '1:124181657638:ios:a5d4587837fc54929e8ee7',
    messagingSenderId: '124181657638',
    projectId: 'mine-pulse',
    databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
    storageBucket: 'mine-pulse.firebasestorage.app',
    iosBundleId: 'com.example.subterraguard',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAexgx32Jjm0vk3lO2GacByy4aetEOiYDw',
    appId: '1:124181657638:ios:a5d4587837fc54929e8ee7',
    messagingSenderId: '124181657638',
    projectId: 'mine-pulse',
    databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
    storageBucket: 'mine-pulse.firebasestorage.app',
    iosBundleId: 'com.example.subterraguard',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAdcl_IWkukKlA17vjJlNFoZtej2H_7brY',
    appId: '1:124181657638:web:1296850205fc9ab79e8ee7',
    messagingSenderId: '124181657638',
    projectId: 'mine-pulse',
    authDomain: 'mine-pulse.firebaseapp.com',
    databaseURL: 'https://mine-pulse-default-rtdb.firebaseio.com',
    storageBucket: 'mine-pulse.firebasestorage.app',
    measurementId: 'G-31M4RFER58',
  );
}
