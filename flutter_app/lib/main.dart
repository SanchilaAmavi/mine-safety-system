import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GLOBALS
// ─────────────────────────────────────────────────────────────────────────────

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

const AndroidNotificationChannel _mineAlertChannel = AndroidNotificationChannel(
  'mine_alert_channel',
  'Mine Alerts',
  description: 'Mine safety alert notifications',
  importance: Importance.max,
);

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ─────────────────────────────────────────────────────────────────────────────
// ALERT HISTORY MANAGER
// Singleton that tracks which alerts were previously active.
// When an alert disappears from the live feed it is moved to history.
// ─────────────────────────────────────────────────────────────────────────────

class AlertHistoryManager {
  AlertHistoryManager._();
  static final AlertHistoryManager instance = AlertHistoryManager._();

  final List<AlertEvent> _historicalAlerts = [];
  final Map<String, AlertEvent> _lastActiveAlerts = {};
  final Set<String> _currentAlertKeys = {};

  List<AlertEvent> get historicalAlerts =>
      List.unmodifiable(_historicalAlerts);

  /// Call this every time a fresh list of current alerts is available.
  /// Alerts that were active last time but are gone now → moved to history.
  void updateCurrentAlerts(List<AlertEvent> newAlerts) {
    final relevantNew = newAlerts.where((a) =>
        a.severity == AlertSeverity.critical ||
        a.severity == AlertSeverity.warning);

    final newKeys = relevantNew
        .map((a) => '${a.mineId}__${a.title}')
        .toSet();

    // Anything previously active that is no longer present → push to history
    for (final oldKey in _currentAlertKeys) {
      if (!newKeys.contains(oldKey)) {
        final gone = _lastActiveAlerts[oldKey];
        if (gone != null) {
          final alreadyStored = _historicalAlerts.any((h) =>
              '${h.mineId}__${h.title}' == oldKey &&
              h.timestamp == gone.timestamp);
          if (!alreadyStored) {
            _historicalAlerts.insert(0, gone);
          }
        }
      }
    }

    // Update tracking maps
    _lastActiveAlerts.clear();
    for (final a in relevantNew) {
      _lastActiveAlerts['${a.mineId}__${a.title}'] = a;
    }
    _currentAlertKeys
      ..clear()
      ..addAll(newKeys);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND MESSAGE HANDLER
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);
  await flutterLocalNotificationsPlugin.initialize(initSettings);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_mineAlertChannel);

  final title = message.notification?.title ?? 'Mine Safety Alert';
  final body = message.notification?.body ?? 'A new hazard event was detected.';

  await flutterLocalNotificationsPlugin.show(
    message.hashCode,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'mine_alert_channel',
        'Mine Alerts',
        channelDescription: 'Mine safety alert notifications',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  bool firebaseAvailable = true;
  try {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);
    }
  } catch (error) {
    firebaseAvailable = false;
    debugPrint('Firebase initialization failed: $error');
  }
  runApp(MinePulseApp(firebaseAvailable: firebaseAvailable));
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT APP
// ─────────────────────────────────────────────────────────────────────────────

class MinePulseApp extends StatefulWidget {
  const MinePulseApp({super.key, required this.firebaseAvailable});
  final bool firebaseAvailable;

  @override
  State<MinePulseApp> createState() => _MinePulseAppState();
}

class _MinePulseAppState extends State<MinePulseApp> {
  FirebaseMessaging? _messaging;

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
  }

  Future<void> _initializeNotifications() async {
    if (!widget.firebaseAvailable) return;

    _messaging = FirebaseMessaging.instance;
    await _requestPermission();

    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    if (!kIsWeb) {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidSettings);
      await flutterLocalNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (details) {
          debugPrint('Notification tapped: ${details.payload}');
        },
      );
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_mineAlertChannel);
    }

    try {
      final token = await _messaging!.getToken();
      debugPrint('🔥 FCM TOKEN: $token');
    } catch (e) {
      debugPrint('ERROR getting FCM token: $e');
    }

    try {
      await _messaging!.subscribeToTopic('mine_alerts');
      debugPrint('✅ Subscribed to mine_alerts topic');
    } catch (e) {
      debugPrint('ERROR subscribing to topic: $e');
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final title = message.notification?.title ?? 'Mine Safety Alert';
      final body =
          message.notification?.body ?? 'A new hazard event was detected.';
      if (!kIsWeb) {
        flutterLocalNotificationsPlugin.show(
          message.hashCode,
          title,
          body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'mine_alert_channel',
              'Mine Alerts',
              channelDescription: 'Mine safety alert notifications',
              importance: Importance.max,
              priority: Priority.high,
              playSound: true,
              enableVibration: true,
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
      }
      _showInAppAlert(title, body);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Notification tapped from background');
    });

    final initialMessage =
        await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App opened from terminated via notification');
    }

    _listenToFirestoreAlerts();
  }

  void _listenToFirestoreAlerts() {
    bool isFirstLoad = true;
    FirebaseFirestore.instance
        .collection('alerts')
        .where('inAlert', isEqualTo: true)
        .snapshots()
        .listen((snapshot) {
      if (isFirstLoad) {
        isFirstLoad = false;
        return;
      }
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data();
          if (data == null) continue;
          final title = data['title']?.toString() ?? 'Mine Alert';
          final body = data['message']?.toString() ?? 'New alert detected.';
          debugPrint('🔴 Firestore alert: $title — $body');
          if (!kIsWeb) {
            flutterLocalNotificationsPlugin.show(
              change.doc.hashCode,
              title,
              body,
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'mine_alert_channel',
                  'Mine Alerts',
                  channelDescription: 'Mine safety alert notifications',
                  importance: Importance.max,
                  priority: Priority.high,
                  playSound: true,
                  enableVibration: true,
                  icon: '@mipmap/ic_launcher',
                ),
              ),
            );
          }
          _showInAppAlert(title, body);
        }
      }
    }, onError: (e) => debugPrint('Firestore listener error: $e'));
  }

  void _showInAppAlert(String title, String body) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('🚨 $title'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestPermission() async {
    if (_messaging == null) return;
    final settings = await _messaging!.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('🔔 Notification permission: ${settings.authorizationStatus}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Mine Pulse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF1F6FFF),
          secondary: Color(0xFFFFC857),
          surface: Color(0xFFFFFFFF),
          onPrimary: Colors.white,
          onSecondary: Color(0xFF11253B),
          onSurface: Color(0xFF142A45),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F8FC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0057FF),
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        cardColor: const Color(0xFFFFFFFF),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFE5ECF6)),
          ),
          margin: const EdgeInsets.symmetric(vertical: 8),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFFFFFFFF),
          selectedItemColor: Color(0xFF0057FF),
          unselectedItemColor: Color(0xFF6E7A8C),
          selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600),
          unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w400),
          type: BottomNavigationBarType.fixed,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFFF4F8FF),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide.none,
          ),
          hintStyle: TextStyle(color: Color(0xFF7A8CAD)),
          labelStyle: TextStyle(color: Color(0xFF142A45)),
          contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Color(0xFF142A45)),
          bodyMedium: TextStyle(color: Color(0xFF3D5481)),
          titleLarge:
              TextStyle(color: Color(0xFF142A45), fontWeight: FontWeight.w600),
        ),
      ),
      home: HomeScreen(firebaseAvailable: widget.firebaseAvailable),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.firebaseAvailable});
  final bool firebaseAvailable;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _emergencyNumber = '112';
  static const String _emergencySmsTemplate =
      'Emergency at mine site. Please respond immediately.';

  int _selectedIndex = 0;
  DatabaseReference? statusRef;
  Position? _currentPosition;
  String? _locationStatus;

  @override
  void initState() {
    super.initState();
    if (widget.firebaseAvailable) {
      statusRef = FirebaseDatabase.instance.ref('status');
    }
    _loadCurrentLocation();
  }

  Future<void> _loadCurrentLocation() async {
    final position = await _determinePosition();
    if (position != null) setState(() => _currentPosition = position);
  }

  Future<Position?> _determinePosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _locationStatus =
            'GPS is disabled. Enable device location for exact map placement.');
        return null;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() => _locationStatus =
            'Location permission denied. Allow access in app settings.');
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best);
      setState(() => _locationStatus =
          'Phone located at ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}');
      return position;
    } catch (error) {
      setState(() =>
          _locationStatus = 'Unable to determine current location: $error');
      return null;
    }
  }

  Future<void> _openPhoneDialer(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      return;
    }
    _showToast('Unable to open phone dialer.');
  }

  Future<void> _sendEmergencySms(String number, String message) async {
    final uri =
        Uri(scheme: 'sms', path: number, queryParameters: {'body': message});
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      return;
    }
    _showToast('Unable to open messaging app.');
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mine Pulse'), centerTitle: true),
      body: widget.firebaseAvailable ? _buildFirebaseBody() : _buildDemoBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openPhoneDialer(_emergencyNumber),
        backgroundColor: const Color(0xFFD62828),
        icon: const Icon(Icons.warning_amber_rounded),
        label: const Text(
          '🚨 EMERGENCY SOS',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      extendBody: true,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        selectedItemColor: const Color(0xFF0057FF),
        unselectedItemColor: const Color(0xFF6E7A8C),
        backgroundColor: const Color(0xFFFFFFFF),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications_active), label: 'Alerts'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart), label: 'Analytics'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings), label: 'Settings'),
        ],
        onTap: (index) => setState(() => _selectedIndex = index),
      ),
    );
  }

  Widget _buildFirebaseBody() {
    if (statusRef == null) {
      return _buildTabContent(
        [],
        [],
        dataLabel: 'Mine Pulse is not connected to telemetry.',
        currentPosition: _currentPosition,
        locationStatus: _locationStatus,
        onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
        onEmergencySms: () =>
            _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
      );
    }

    return StreamBuilder<DatabaseEvent>(
      stream: statusRef!.onValue,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Unable to load live mine data. Check your Firebase configuration.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Connecting to Mine Pulse cloud telemetry...',
                    style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }

        List<MineStatus> mines = [];
        if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
          final value =
              snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
          mines = value.entries.map((entry) {
            final mine = Map<String, dynamic>.from(entry.value as Map);
            return MineStatus(
              id: entry.key.toString(),
              mq4: mine['mq4']?.toString() ?? 'N/A',
              mq7: mine['mq7']?.toString() ?? 'N/A',
              water: mine['water']?.toString() ?? 'N/A',
              rssi: mine['rssi']?.toString() ?? 'N/A',
              battery: mine['battery']?.toString() ?? 'Unknown',
              active: mine['inAlert'] == true,
              latitude: mine['latitude'] is double
                  ? mine['latitude'] as double
                  : 37.7749,
              longitude: mine['longitude'] is double
                  ? mine['longitude'] as double
                  : -122.4194,
            );
          }).toList();
        }

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('alerts')
              .orderBy('time', descending: true)
              .snapshots(),
          builder: (context, fsSnapshot) {
            final sensorAlerts = _generateAlerts(mines);

            final firestoreAlerts = <AlertEvent>[];
            if (fsSnapshot.hasData) {
              for (final doc in fsSnapshot.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                if (data['inAlert'] != true) continue;
                final severityStr = data['severity']?.toString() ?? 'Info';
                final severity = severityStr == 'Critical'
                    ? AlertSeverity.critical
                    : severityStr == 'Warning'
                        ? AlertSeverity.warning
                        : AlertSeverity.info;

                DateTime? alertTime;
                if (data['time'] != null) {
                  try {
                    if (data['time'] is Timestamp) {
                      alertTime = (data['time'] as Timestamp).toDate();
                    }
                  } catch (_) {}
                }

                firestoreAlerts.add(AlertEvent(
                  mineId: 'manual',
                  title: data['title']?.toString() ?? 'Mine Alert',
                  description:
                      data['message']?.toString() ?? 'No details provided.',
                  severity: severity,
                  timestamp: alertTime ?? DateTime.now(),
                ));
              }
            }

            final allAlerts = [...firestoreAlerts, ...sensorAlerts];

            // ── Update history whenever the live alert set changes ──────────
            AlertHistoryManager.instance.updateCurrentAlerts(allAlerts);

            return _buildTabContent(
              mines,
              allAlerts,
              dataLabel: mines.isEmpty
                  ? 'No mine devices connected. Showing manual alerts.'
                  : 'Live Security Overview',
              currentPosition: _currentPosition,
              locationStatus: _locationStatus,
              onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
              onEmergencySms: () =>
                  _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
            );
          },
        );
      },
    );
  }

  Widget _buildDemoBody() {
    return _buildTabContent(
      [],
      [],
      dataLabel: 'Mine Pulse is running without a telemetry connection.',
      currentPosition: _currentPosition,
      locationStatus: _locationStatus,
      onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
      onEmergencySms: () =>
          _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
    );
  }

  Widget _buildTabContent(
    List<MineStatus> mines,
    List<AlertEvent> alerts, {
    required String dataLabel,
    bool demoMode = false,
    Position? currentPosition,
    String? locationStatus,
    required VoidCallback onEmergencyCall,
    required VoidCallback onEmergencySms,
  }) {
    switch (_selectedIndex) {
      case 0:
        return DashboardTab(
          mines: mines,
          alerts: alerts,
          dataLabel: dataLabel,
          demoMode: demoMode,
          currentPosition: currentPosition,
          locationStatus: locationStatus,
          onEmergencyCall: onEmergencyCall,
          onEmergencySms: onEmergencySms,
        );
      case 1:
        return AlertsTab(alerts: alerts, mines: mines, demoMode: demoMode);
      case 2:
        return AnalyticsTab(alerts: alerts, mines: mines);
      case 3:
        return MapTab(
          mines: mines,
          alerts: alerts,
          currentPosition: currentPosition,
          locationStatus: locationStatus,
          onRefreshLocation: _loadCurrentLocation,
        );
      default:
        return SettingsTab(
          onEmergencyCall: onEmergencyCall,
          onEmergencySms: onEmergencySms,
          userEmail: null,
          onSignOut: null,
        );
    }
  }

  List<AlertEvent> _generateAlerts(List<MineStatus> mines) {
    final now = DateTime.now();
    final alerts = <AlertEvent>[];
    for (final mine in mines) {
      final mq4 =
          int.tryParse(mine.mq4.replaceAll(RegExp('[^0-9-]'), '')) ?? 0;
      final mq7 =
          int.tryParse(mine.mq7.replaceAll(RegExp('[^0-9-]'), '')) ?? 0;
      final rssi =
          int.tryParse(mine.rssi.replaceAll(RegExp('[^0-9-]'), '')) ?? 0;

      if (mq4 >= 35) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: '💨 Methane alarm',
          description:
              'Methane levels exceeded safe limits at node ${mine.id}. Immediate evacuation and ventilation check required.',
          severity: AlertSeverity.critical,
          hazardType: 'Methane gas',
          exposureTime: '0–5 min before unsafe exposure',
          hazardLevel: '🔴 Critical',
          location: 'Node ${mine.id} · underground drift',
          workers: 'Shift team + rescue standby',
          recommendedAction:
              'Evacuate, ventilate, and verify gas extraction systems immediately.',
          timestamp: now,
        ));
      } else if (mq4 >= 25) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: '⚠️ Methane elevated',
          description:
              'Methane levels are elevated at node ${mine.id}. Monitor closely and prepare to act.',
          severity: AlertSeverity.warning,
          hazardType: 'Methane gas',
          exposureTime: '5–15 min for monitoring and response',
          hazardLevel: '🟡 Warning',
          location: 'Node ${mine.id} · ventilation route',
          workers: 'Shift team',
          recommendedAction:
              'Increase monitoring and prepare ventilation response.',
          timestamp: now,
        ));
      }

      if (mq7 >= 18) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: '🫁 Carbon monoxide alert',
          description:
              'Carbon monoxide concentration is above normal levels at node ${mine.id}. Respiratory protection is advised.',
          severity: AlertSeverity.critical,
          hazardType: 'Carbon monoxide',
          exposureTime: 'Under 10 min for high exposure',
          hazardLevel: '🔴 Critical',
          location: 'Node ${mine.id} · working face',
          workers: 'All miners in zone',
          recommendedAction:
              'Stop work, activate rescue support, and check all breathing systems.',
          timestamp: now,
        ));
      }

      if (mine.water.toLowerCase() == 'high') {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: '💧 Water ingress detected',
          description:
              'High water level reported at node ${mine.id}. Check drainage and avoid low-lying sections.',
          severity: AlertSeverity.warning,
          hazardType: 'Water ingress',
          exposureTime: '15–30 min before equipment risk',
          hazardLevel: '🟡 Warning',
          location: 'Node ${mine.id} · low-level tunnel',
          workers: 'Maintenance crew',
          recommendedAction:
              'Inspect pumps, isolate the affected section, and reroute traffic.',
          timestamp: now,
        ));
      }

      if (rssi != 0 && rssi <= -80) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: '📶 Poor signal quality',
          description:
              'Signal strength is weak at node ${mine.id}. Confirm gateway connectivity and replace antennas if necessary.',
          severity: AlertSeverity.info,
          hazardType: 'Communication loss',
          exposureTime: 'Ongoing monitoring required',
          hazardLevel: '🔵 Moderate',
          location: 'Node ${mine.id} · surface gateway path',
          workers: 'Telemetry team',
          recommendedAction:
              'Inspect antenna alignment and confirm gateway connectivity.',
          timestamp: now,
        ));
      }

      if (mine.active && alerts.where((a) => a.mineId == mine.id).isEmpty) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: '🚩 Active alert',
          description:
              'Node ${mine.id} has reported an alert state. Investigate the source and follow emergency procedures.',
          severity: AlertSeverity.warning,
          hazardType: 'General hazard',
          exposureTime: 'Immediate response required',
          hazardLevel: '🟡 Warning',
          location: 'Node ${mine.id}',
          workers: 'Site supervisor',
          recommendedAction:
              'Dispatch the response team, verify the source, and notify control.',
          timestamp: now,
        ));
      }
    }

    if (alerts.isEmpty) {
      alerts.add(AlertEvent(
        mineId: 'system',
        title: '✅ All systems stable',
        description:
            'No active hazards detected. Continue routine monitoring and maintain safe operations.',
        severity: AlertSeverity.safe,
        timestamp: now,
      ));
    }
    return alerts;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _formatTimestamp(DateTime dt) {
  final months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour = dt.hour > 12
      ? dt.hour - 12
      : (dt.hour == 0 ? 12 : dt.hour);
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  final min = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${months[dt.month - 1]} ${dt.year} · $hour:$min $ampm';
}

// ─────────────────────────────────────────────────────────────────────────────
// DASHBOARD TAB
// ─────────────────────────────────────────────────────────────────────────────

class DashboardTab extends StatelessWidget {
  const DashboardTab({
    super.key,
    required this.mines,
    required this.alerts,
    required this.dataLabel,
    required this.demoMode,
    this.currentPosition,
    this.locationStatus,
    required this.onEmergencyCall,
    required this.onEmergencySms,
  });

  final List<MineStatus> mines;
  final List<AlertEvent> alerts;
  final String dataLabel;
  final bool demoMode;
  final Position? currentPosition;
  final String? locationStatus;
  final VoidCallback onEmergencyCall;
  final VoidCallback onEmergencySms;

  @override
  Widget build(BuildContext context) {
    // Only critical and warning alerts are "active"
    final activeAlerts = alerts
        .where((item) =>
            item.severity == AlertSeverity.critical ||
            item.severity == AlertSeverity.warning)
        .toList();

    // Resolved alerts from the history manager
    final historicalAlerts = AlertHistoryManager.instance.historicalAlerts;

    final hasActive = activeAlerts.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        // ── Hero card ──────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFFFFFF), Color(0xFFF4F8FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE2EAF7)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/favicon.jpeg',
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Mine Pulse',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF142A45),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          demoMode
                              ? 'Demo mode: no live Firebase data.'
                              : 'Connected to live monitoring.',
                          style: const TextStyle(
                              fontSize: 14, color: Color(0xFF3D5481)),
                        ),
                        if (locationStatus != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            locationStatus!,
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF3D5481)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Status banner ─────────────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 16),
                decoration: BoxDecoration(
                  color: hasActive
                      ? const Color(0xFFFFEBEB)
                      : const Color(0xFFE8F8EE),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: hasActive
                        ? const Color(0xFFFF5C5C)
                        : const Color(0xFF57D27A),
                    width: 1.4,
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      hasActive ? '🚨' : '✅',
                      style: const TextStyle(fontSize: 32),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasActive
                                ? '${activeAlerts.length} Active Alert${activeAlerts.length == 1 ? '' : 's'}'
                                : 'No Active Alerts',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: hasActive
                                  ? const Color(0xFFD62828)
                                  : const Color(0xFF2E9E57),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            hasActive
                                ? 'Immediate attention required on the mine network.'
                                : 'All monitored nodes are operating safely.',
                            style: TextStyle(
                              fontSize: 13,
                              color: hasActive
                                  ? const Color(0xFF7A1C1C)
                                  : const Color(0xFF1A6B3A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        // ── ACTIVE ALERTS (new / current) ──────────────────────────────────
        _SectionHeader(
          emoji: '🔴',
          title: 'Active Alerts',
          count: activeAlerts.isNotEmpty ? activeAlerts.length : null,
          countColor: const Color(0xFFD62828),
        ),
        const SizedBox(height: 10),
        if (activeAlerts.isNotEmpty)
          ...activeAlerts.map((alert) => AlertTile(alert: alert))
        else
          _EmptyStateCard(
            emoji: '✅',
            message:
                'No active alerts detected. The mine network is stable or not yet connected.',
          ),
        const SizedBox(height: 22),

        // ── EMERGENCY ACTIONS ──────────────────────────────────────────────
        EmergencyActionsCard(onCall: onEmergencyCall, onSms: onEmergencySms),
        const SizedBox(height: 22),

        // ── ALERT HISTORY (resolved alerts shown on dashboard) ─────────────
        _SectionHeader(
          emoji: '🕐',
          title: 'Alert History',
          count: historicalAlerts.isNotEmpty ? historicalAlerts.length : null,
          countColor: const Color(0xFF6E7A8C),
        ),
        const SizedBox(height: 4),
        const Text(
          'Previous alerts that have since cleared.',
          style: TextStyle(fontSize: 13, color: Color(0xFF8FA6C0)),
        ),
        const SizedBox(height: 10),
        if (historicalAlerts.isNotEmpty)
          ...historicalAlerts
              .take(5)
              .map((alert) => _HistoryCard(alert: alert))
        else
          _EmptyStateCard(
            emoji: '📋',
            message:
                'No resolved alerts yet. Previous alerts will appear here once they clear.',
          ),
        const SizedBox(height: 22),

        // ── MINE TELEMETRY ─────────────────────────────────────────────────
        const _SectionHeader(emoji: '⚙️', title: 'Mine Telemetry'),
        const SizedBox(height: 10),
        if (mines.isNotEmpty)
          ...mines.map((mine) => MineCard(status: mine))
        else
          _EmptyStateCard(
            emoji: '📡',
            message:
                'No telemetry records available until underground nodes connect to the surface gateway.',
          ),
      ],
    );
  }
}

// ── Reusable section header ───────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.emoji,
    required this.title,
    this.count,
    this.countColor,
  });

  final String emoji;
  final String title;
  final int? count;
  final Color? countColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '$emoji $title',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: countColor ?? const Color(0xFF6E7A8C),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Reusable empty state card ────────────────────────────────────────────────

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({required this.emoji, required this.message});
  final String emoji;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '$emoji  $message',
          style: const TextStyle(color: Color(0xFF5D6E84), fontSize: 15),
        ),
      ),
    );
  }
}

// ── History card (compact, shows "Resolved" badge, tappable for full detail) ─

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.alert});
  final AlertEvent alert;

  String get _severityEmoji {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return '🔴';
      case AlertSeverity.warning:
        return '🟡';
      case AlertSeverity.info:
        return '🔵';
      default:
        return '🟢';
    }
  }

  Color get _borderColor {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return const Color(0xFFFF5C5C);
      case AlertSeverity.warning:
        return const Color(0xFFFFC107);
      case AlertSeverity.info:
        return const Color(0xFF5C9BFF);
      default:
        return const Color(0xFF57D27A);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFF9FBFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: _borderColor.withAlpha(70)),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => AlertTile(alert: alert).showDetails(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_severityEmoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            alert.title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF142A45),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE6EEF8),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '✔ Resolved',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF5D6E84),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Node ${alert.mineId} · ${_formatTimestamp(alert.timestamp)}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF9BAEC8)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alert.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF5D6E84)),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: Color(0xFFB0C5E2), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAP TAB
// ─────────────────────────────────────────────────────────────────────────────

class MapTab extends StatelessWidget {
  const MapTab({
    super.key,
    required this.mines,
    required this.alerts,
    this.currentPosition,
    this.locationStatus,
    required this.onRefreshLocation,
  });

  final List<MineStatus> mines;
  final List<AlertEvent> alerts;
  final Position? currentPosition;
  final String? locationStatus;
  final Future<void> Function() onRefreshLocation;

  @override
  Widget build(BuildContext context) {
    final center = currentPosition != null
        ? LatLng(currentPosition!.latitude, currentPosition!.longitude)
        : mines.isNotEmpty
            ? LatLng(mines.first.latitude, mines.first.longitude)
            : const LatLng(37.4275, -122.1697);

    final markers = mines.map((mine) {
      final isAlert = alerts.any((alert) =>
          alert.mineId == mine.id && alert.severity != AlertSeverity.safe);
      return Marker(
        width: 120,
        height: 110,
        point: LatLng(mine.latitude, mine.longitude),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isAlert ? Icons.location_on : Icons.location_on_outlined,
              color: isAlert ? Colors.redAccent : Colors.lightBlueAccent,
              size: 38,
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const BoxDecoration(
                color: Color(0xFF0F1D2C),
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
              child: Text(
                'Node ${mine.id}',
                style:
                    const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }).toList();

    if (currentPosition != null) {
      markers.add(Marker(
        width: 120,
        height: 110,
        point:
            LatLng(currentPosition!.latitude, currentPosition!.longitude),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.my_location,
                color: Color(0xFF57D27A), size: 38),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const BoxDecoration(
                color: Color(0xFF0F1D2C),
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
              child: const Text(
                'You',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      ));
    }

    return Column(
      children: [
        Expanded(
          child: FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 12.0),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mine_pulse',
              ),
              MarkerLayer(markers: markers),
            ],
          ),
        ),
        Container(
          color: const Color(0xFFF4F8FF),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Live map shows your phone and mine node locations with real positioning.',
                      style: TextStyle(color: Color(0xFF142A45)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.my_location,
                        color: Color(0xFF0057FF)),
                    tooltip: 'Refresh device location',
                    onPressed: () async => await onRefreshLocation(),
                  ),
                ],
              ),
              if (locationStatus != null) ...[
                const SizedBox(height: 8),
                Text(
                  locationStatus!,
                  style: const TextStyle(
                      color: Color(0xFF3D5481), fontSize: 14),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Emergency actions are available in the Safety tab.',
                style: TextStyle(color: Color(0xFF3D5481)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERTS TAB
// ─────────────────────────────────────────────────────────────────────────────

class AlertsTab extends StatelessWidget {
  const AlertsTab({
    super.key,
    required this.alerts,
    required this.mines,
    required this.demoMode,
  });

  final List<AlertEvent> alerts;
  final List<MineStatus> mines;
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    final activeAlerts = alerts
        .where((item) =>
            item.severity == AlertSeverity.critical ||
            item.severity == AlertSeverity.warning)
        .toList();

    // Combine manager history + full sensor history, de-duplicated
    final resolvedHistory = AlertHistoryManager.instance.historicalAlerts;
    final combined = [...resolvedHistory, ...alerts.reversed];
    final seen = <String>{};
    final dedupedHistory = combined.where((a) {
      final key = '${a.mineId}__${a.title}__${a.timestamp}';
      return seen.add(key);
    }).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text(
          '🔔 Alert Center',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        if (demoMode)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF112A41),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              'Demo mode: These notifications represent how Mine Pulse surfaces warnings, hazards, and operational alerts.',
              style: TextStyle(color: Color(0xFFB0C5E2)),
            ),
          ),
        const SizedBox(height: 12),

        // Active alerts
        _SectionHeader(
          emoji: '🔴',
          title: 'Active Alerts',
          count: activeAlerts.isNotEmpty ? activeAlerts.length : null,
          countColor: const Color(0xFFD62828),
        ),
        const SizedBox(height: 8),
        if (activeAlerts.isEmpty)
          const Text(
            '✅ All systems stable. No active danger alerts at this time.',
            style: TextStyle(fontSize: 15, color: Color(0xFF5D6E84)),
          ),
        ...activeAlerts.map((alert) => AlertTile(alert: alert)),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('✅ All active alerts acknowledged.')),
            );
          },
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Acknowledge Alerts'),
        ),
        const SizedBox(height: 24),

        // Alert history
        _SectionHeader(
          emoji: '🕐',
          title: 'Alert History',
          count: dedupedHistory.isNotEmpty ? dedupedHistory.length : null,
          countColor: const Color(0xFF6E7A8C),
        ),
        const SizedBox(height: 10),
        if (dedupedHistory.isEmpty)
          const Text(
            '📋 No alert history yet.',
            style: TextStyle(fontSize: 15, color: Color(0xFF5D6E84)),
          ),
        ...dedupedHistory
            .take(10)
            .map((alert) => _AlertHistoryCard(alert: alert)),
      ],
    );
  }
}

/// Tappable alert history card for the Alerts tab
class _AlertHistoryCard extends StatelessWidget {
  const _AlertHistoryCard({required this.alert});
  final AlertEvent alert;

  String get _severityEmoji {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return '🔴';
      case AlertSeverity.warning:
        return '🟡';
      case AlertSeverity.info:
        return '🔵';
      default:
        return '🟢';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => AlertTile(alert: alert).showDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(_severityEmoji,
                      style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      alert.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF142A45),
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFF5D6E84)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Node ${alert.mineId} · ${alert.severity}',
                style: const TextStyle(
                    color: Color(0xFF8FA6C0), fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                _formatTimestamp(alert.timestamp),
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF9BAEC8)),
              ),
              const SizedBox(height: 8),
              Text(
                alert.description,
                style: const TextStyle(
                    color: Color(0xFF3D5481), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ANALYTICS TAB
// ─────────────────────────────────────────────────────────────────────────────

class AnalyticsTab extends StatelessWidget {
  const AnalyticsTab({super.key, required this.alerts, required this.mines});

  final List<AlertEvent> alerts;
  final List<MineStatus> mines;

  @override
  Widget build(BuildContext context) {
    final critical =
        alerts.where((a) => a.severity == AlertSeverity.critical).length;
    final warning =
        alerts.where((a) => a.severity == AlertSeverity.warning).length;
    final info =
        alerts.where((a) => a.severity == AlertSeverity.info).length;
    final total = alerts.length;
    final methaneAlerts =
        alerts.where((a) => a.title.toLowerCase().contains('methane')).length;
    final carbonAlerts =
        alerts.where((a) => a.title.toLowerCase().contains('carbon')).length;
    final waterAlerts =
        alerts.where((a) => a.title.toLowerCase().contains('water')).length;
    final signalAlerts =
        alerts.where((a) => a.title.toLowerCase().contains('signal')).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text(
          '📊 Analytics',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Real-time graphs and key trends for the mine safety network.',
          style: TextStyle(fontSize: 15, color: Color(0xFF5D6E84)),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _SummaryCard(
                label: '🔴 Critical',
                value: critical.toString(),
                color: const Color(0xFFFF5C5C),
              ),
            ),
            Expanded(
              child: _SummaryCard(
                label: '🟡 Warning',
                value: warning.toString(),
                color: const Color(0xFFFFC107),
              ),
            ),
            Expanded(
              child: _SummaryCard(
                label: '🔵 Info',
                value: info.toString(),
                color: const Color(0xFF5C9BFF),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _AnalyticsCard(
          title: '☣️ Hazard Type Distribution',
          subtitle: 'Number of alerts per hazard category',
          child: _BarChart(
            bars: [
              _BarData('💨 CH₄', methaneAlerts, const Color(0xFFFF7043)),
              _BarData('🫁 CO', carbonAlerts, const Color(0xFF42A5F5)),
              _BarData('💧 Water', waterAlerts, const Color(0xFF66BB6A)),
              _BarData('📶 Signal', signalAlerts, const Color(0xFFAB47BC)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _AnalyticsCard(
          title: '📈 Alert Severity Breakdown',
          subtitle: 'Proportion of each severity level',
          child: _SeverityStackedBar(
              critical: critical, warning: warning, info: info),
        ),
        const SizedBox(height: 16),
        _AnalyticsCard(
          title: '📶 Node Signal Quality',
          subtitle: 'RSSI signal strength per node (higher = better)',
          child: _NodeSignalBarChart(mines: mines),
        ),
        const SizedBox(height: 16),
        _AnalyticsCard(
          title: '🔬 Sensor Readings per Node',
          subtitle: 'Current MQ-4 (methane) and MQ-7 (CO) values',
          child: _SensorGroupedBars(mines: mines),
        ),
        const SizedBox(height: 22),
        const Text(
          '📋 Activity Summary',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          color: const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Weekly reports estimate network performance and alert patterns using current telemetry.',
                  style: TextStyle(color: Color(0xFF5D6E84)),
                ),
                const SizedBox(height: 14),
                Text(
                  '⚙️ Tracked nodes: ${mines.length}',
                  style: const TextStyle(
                      fontSize: 16, color: Color(0xFF142A45)),
                ),
                const SizedBox(height: 6),
                Text(
                  '🔔 Total alerts: $total',
                  style: const TextStyle(
                      fontSize: 16, color: Color(0xFF142A45)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Analytics helpers ─────────────────────────────────────────────────────────

class _AnalyticsCard extends StatelessWidget {
  const _AnalyticsCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF142A45))),
            const SizedBox(height: 4),
            Text(subtitle,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF8FA6C0))),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _BarData {
  const _BarData(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.bars});
  final List<_BarData> bars;

  @override
  Widget build(BuildContext context) {
    final maxVal =
        bars.fold<int>(1, (prev, b) => b.value > prev ? b.value : prev);
    return SizedBox(
      height: 160,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: bars.map((bar) {
          final fraction =
              maxVal == 0 ? 0.05 : (bar.value / maxVal).clamp(0.05, 1.0);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    bar.value.toString(),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: bar.color),
                  ),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOut,
                    height: 120 * fraction,
                    decoration: BoxDecoration(
                      color: bar.color,
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    bar.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF5D6E84)),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SeverityStackedBar extends StatelessWidget {
  const _SeverityStackedBar(
      {required this.critical, required this.warning, required this.info});
  final int critical;
  final int warning;
  final int info;

  @override
  Widget build(BuildContext context) {
    final total = (critical + warning + info).toDouble();
    final safeTotal = total == 0 ? 1.0 : total;

    Widget segment(int count, Color color) {
      return Expanded(
        flex: count == 0 ? 0 : ((count / safeTotal) * 100).round(),
        child: count == 0
            ? const SizedBox.shrink()
            : Container(
                height: 36,
                color: color,
                alignment: Alignment.center,
                child: Text(count.toString(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: total == 0
              ? Container(
                  height: 36,
                  color: const Color(0xFFE6F0FF),
                  alignment: Alignment.center,
                  child: const Text('No alerts',
                      style: TextStyle(color: Color(0xFF8FA6C0))),
                )
              : Row(children: [
                  segment(critical, const Color(0xFFFF5C5C)),
                  segment(warning, const Color(0xFFFFC107)),
                  segment(info, const Color(0xFF5C9BFF)),
                ]),
        ),
        const SizedBox(height: 12),
        const Row(
          children: [
            _LegendDot(color: Color(0xFFFF5C5C), label: '🔴 Critical'),
            SizedBox(width: 16),
            _LegendDot(color: Color(0xFFFFC107), label: '🟡 Warning'),
            SizedBox(width: 16),
            _LegendDot(color: Color(0xFF5C9BFF), label: '🔵 Info'),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF5D6E84))),
      ],
    );
  }
}

class _NodeSignalBarChart extends StatelessWidget {
  const _NodeSignalBarChart({required this.mines});
  final List<MineStatus> mines;

  @override
  Widget build(BuildContext context) {
    if (mines.isEmpty) {
      return const Text('📡 No nodes connected.',
          style: TextStyle(color: Color(0xFF8FA6C0)));
    }
    return Column(
      children: mines.map((mine) {
        final rssi =
            int.tryParse(mine.rssi.replaceAll(RegExp('[^0-9-]'), '')) ??
                -100;
        final fraction = ((rssi + 120) / 60).clamp(0.0, 1.0);
        final barColor = fraction > 0.6
            ? const Color(0xFF57D27A)
            : fraction > 0.3
                ? const Color(0xFFFFC107)
                : const Color(0xFFFF5C5C);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Node ${mine.id.toUpperCase()}',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF142A45))),
                  Text('${mine.rssi} dBm',
                      style: TextStyle(
                          fontSize: 13,
                          color: barColor,
                          fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 14,
                  color: barColor,
                  backgroundColor: const Color(0xFFE6F0FF),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _SensorGroupedBars extends StatelessWidget {
  const _SensorGroupedBars({required this.mines});
  final List<MineStatus> mines;

  @override
  Widget build(BuildContext context) {
    if (mines.isEmpty) {
      return const Text('🔬 No sensor data available.',
          style: TextStyle(color: Color(0xFF8FA6C0)));
    }

    int maxVal = 1;
    for (final m in mines) {
      final mq4 = int.tryParse(m.mq4.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
      final mq7 = int.tryParse(m.mq7.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
      if (mq4 > maxVal) maxVal = mq4;
      if (mq7 > maxVal) maxVal = mq7;
    }

    return Column(
      children: [
        const Row(
          children: [
            _LegendDot(
                color: Color(0xFFFF7043), label: '💨 MQ-4 Methane (ppm)'),
            SizedBox(width: 16),
            _LegendDot(color: Color(0xFF42A5F5), label: '🫁 MQ-7 CO (ppm)'),
          ],
        ),
        const SizedBox(height: 12),
        ...mines.map((mine) {
          final mq4Val =
              int.tryParse(mine.mq4.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
          final mq7Val =
              int.tryParse(mine.mq7.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
          final mq4Frac = (mq4Val / maxVal).clamp(0.0, 1.0);
          final mq7Frac = (mq7Val / maxVal).clamp(0.0, 1.0);

          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Node ${mine.id.toUpperCase()}',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF142A45))),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(
                      width: 28,
                      child: Text('CH₄',
                          style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFFF7043),
                              fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: mq4Frac == 0 ? 0.02 : mq4Frac,
                          minHeight: 12,
                          color: const Color(0xFFFF7043),
                          backgroundColor: const Color(0xFFE6F0FF),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(mine.mq4,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF5D6E84))),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(
                      width: 28,
                      child: Text('CO',
                          style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF42A5F5),
                              fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: mq7Frac == 0 ? 0.02 : mq7Frac,
                          minHeight: 12,
                          color: const Color(0xFF42A5F5),
                          backgroundColor: const Color(0xFFE6F0FF),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(mine.mq7,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF5D6E84))),
                  ],
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS TAB
// ─────────────────────────────────────────────────────────────────────────────

class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.onEmergencyCall,
    required this.onEmergencySms,
    this.userEmail,
    this.onSignOut,
  });

  final VoidCallback onEmergencyCall;
  final VoidCallback onEmergencySms;
  final String? userEmail;
  final Future<void> Function()? onSignOut;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _pushAlerts = true;
  bool _smsAlerts = true;
  bool _liveMap = true;
  final TextEditingController _emergencyNumberController =
      TextEditingController(text: '112');
  final TextEditingController _methaneThresholdController =
      TextEditingController(text: '35');
  final TextEditingController _coThresholdController =
      TextEditingController(text: '18');
  final TextEditingController _workersController =
      TextEditingController(text: '24');
  DateTime _selectedDate = DateTime.now();

  @override
  void dispose() {
    _emergencyNumberController.dispose();
    _methaneThresholdController.dispose();
    _coThresholdController.dispose();
    _workersController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text(
          '⚙️ System Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: '🎚️ Alert Thresholds',
          children: [
            TextField(
              controller: _methaneThresholdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '💨 Methane threshold (ppm)',
                filled: true,
                fillColor: Color(0xFFF4F8FF),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _coThresholdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '🫁 CO threshold (ppm)',
                filled: true,
                fillColor: Color(0xFFF4F8FF),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: '📞 Emergency Contacts',
          children: [
            TextField(
              controller: _emergencyNumberController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: '📱 Primary SMS number',
                filled: true,
                fillColor: Color(0xFFF4F8FF),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.call),
                    label: const Text('🚨 Quick SOS'),
                    onPressed: widget.onEmergencyCall,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.message),
                    label: const Text('✉️ Send SMS'),
                    onPressed: widget.onEmergencySms,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: '👷 Daily Workforce Update',
          children: [
            TextField(
              controller: _workersController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '👷 Workers on duty today',
                filled: true,
                fillColor: Color(0xFFF4F8FF),
              ),
            ),
            const SizedBox(height: 10),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2024),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _selectedDate = picked);
                }
              },
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F8FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today,
                        color: Color(0xFF0057FF)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '📅 Date: ${_selectedDate.day.toString().padLeft(2, '0')}/${_selectedDate.month.toString().padLeft(2, '0')}/${_selectedDate.year}',
                        style: const TextStyle(
                            color: Color(0xFF142A45), fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '👷 Workers recorded: ${_workersController.text.isEmpty ? '0' : _workersController.text} on ${_selectedDate.toLocal().toString().split(' ')[0]}',
              style:
                  const TextStyle(color: Color(0xFF5D6E84), fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: '🔧 Operational Controls',
          children: [
            SwitchListTile(
              title: const Text('🔔 Push notifications'),
              value: _pushAlerts,
              onChanged: (value) => setState(() => _pushAlerts = value),
            ),
            SwitchListTile(
              title: const Text('📱 SMS alerts'),
              value: _smsAlerts,
              onChanged: (value) => setState(() => _smsAlerts = value),
            ),
            SwitchListTile(
              title: const Text('🗺️ Live map updates'),
              value: _liveMap,
              onChanged: (value) => setState(() => _liveMap = value),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: '👤 Account',
          children: [
            ListTile(
              title: const Text('Signed in as'),
              subtitle: Text(widget.userEmail ?? 'Not signed in'),
              leading: const Icon(Icons.person_outline),
            ),
            if (widget.onSignOut != null)
              ElevatedButton.icon(
                icon: const Icon(Icons.logout),
                label: const Text('Sign Out'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await widget.onSignOut!();
                  if (!mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(
                        content: Text('✅ Signed out successfully.')),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF142A45))),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class EmergencyActionsCard extends StatelessWidget {
  const EmergencyActionsCard(
      {super.key, required this.onCall, required this.onSms});
  final VoidCallback onCall;
  final VoidCallback onSms;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🚨 Emergency Contact',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF142A45)),
            ),
            const SizedBox(height: 10),
            const Text(
              'Use the emergency call or message actions below to notify surface command and rescue teams immediately.',
              style: TextStyle(fontSize: 16, color: Color(0xFF5D6E84)),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.call),
                    label: const Text('📞 Call'),
                    onPressed: onCall,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.message),
                    label: const Text('✉️ Message'),
                    onPressed: onSms,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(
      {required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF142A45),
                  fontWeight: FontWeight.w600,
                  fontSize: 12)),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────────────────

class AlertEvent {
  AlertEvent({
    required this.mineId,
    required this.title,
    required this.description,
    required this.severity,
    this.hazardType = 'Hazard',
    this.exposureTime = 'Monitor continuously',
    this.hazardLevel = 'Moderate',
    this.location = 'Mine site',
    this.workers = 'Team not yet set',
    this.recommendedAction = 'Follow standard emergency procedure',
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String mineId;
  final String title;
  final String description;
  final String severity;
  final String hazardType;
  final String exposureTime;
  final String hazardLevel;
  final String location;
  final String workers;
  final String recommendedAction;
  final DateTime timestamp;
}

class AlertSeverity {
  static const String critical = 'Critical';
  static const String warning = 'Warning';
  static const String info = 'Info';
  static const String safe = 'Safe';
}

class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.alert});
  final AlertEvent alert;

  void showDetails(BuildContext context) {
    final severityEmoji = alert.severity == AlertSeverity.critical
        ? '🔴'
        : alert.severity == AlertSeverity.warning
            ? '🟡'
            : alert.severity == AlertSeverity.info
                ? '🔵'
                : '🟢';

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$severityEmoji ${alert.title}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('🕐 Date & Time', _formatTimestamp(alert.timestamp)),
              _detailRow('☣️ Hazard type', alert.hazardType),
              _detailRow('⚠️ Level', alert.hazardLevel),
              _detailRow('⏱️ Exposure time', alert.exposureTime),
              _detailRow('📍 Node', alert.mineId),
              _detailRow('🗺️ Location', alert.location),
              _detailRow('👷 Workers', alert.workers),
              const SizedBox(height: 8),
              Text(alert.description,
                  style: const TextStyle(color: Color(0xFF142A45))),
              const SizedBox(height: 8),
              Text(
                '✅ Recommended: ${alert.recommendedAction}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, color: Color(0xFF0057FF)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = alert.severity == AlertSeverity.critical
        ? const Color(0xFFFFEBEE)
        : alert.severity == AlertSeverity.warning
            ? const Color(0xFFFFF4E5)
            : const Color(0xFFE8F3FF);

    final iconColor = alert.severity == AlertSeverity.critical
        ? const Color(0xFFD62828)
        : alert.severity == AlertSeverity.warning
            ? const Color(0xFFB66D00)
            : const Color(0xFF0057FF);

    final icon = alert.severity == AlertSeverity.critical
        ? Icons.dangerous
        : alert.severity == AlertSeverity.warning
            ? Icons.warning_amber
            : Icons.info_outline;

    final badgeColor = alert.severity == AlertSeverity.critical
        ? const Color(0xFFD62828)
        : alert.severity == AlertSeverity.warning
            ? const Color(0xFFB66D00)
            : const Color(0xFF0057FF);

    final badgeEmoji = alert.severity == AlertSeverity.critical
        ? '🔴'
        : alert.severity == AlertSeverity.warning
            ? '🟡'
            : '🔵';

    return Card(
      color: bg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      alert.title,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF142A45)),
                    ),
                  ),
                  // Severity badge with emoji
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeColor.withAlpha(30),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: badgeColor.withAlpha(120)),
                    ),
                    child: Text(
                      '$badgeEmoji ${alert.severity}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: badgeColor),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, color: Color(0xFF5D6E84)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('📍 ', style: TextStyle(fontSize: 13)),
                  Text('Node: ${alert.mineId} · ${alert.hazardType}',
                      style: const TextStyle(color: Color(0xFF5D6E84))),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('🕐 ', style: TextStyle(fontSize: 11)),
                  Text(
                    _formatTimestamp(alert.timestamp),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF9BAEC8)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(alert.description,
                  style: const TextStyle(
                      fontSize: 15, color: Color(0xFF142A45))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Color(0xFF5D6E84))),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Color(0xFF142A45))),
          ),
        ],
      ),
    );
  }
}

class MineStatus {
  MineStatus({
    required this.id,
    required this.mq4,
    required this.mq7,
    required this.water,
    required this.rssi,
    this.battery = 'Unknown',
    required this.active,
    this.latitude = 37.4275,
    this.longitude = -122.1697,
    this.online = true,
  });

  final String id;
  final String mq4;
  final String mq7;
  final String water;
  final String rssi;
  final String battery;
  final bool active;
  final bool online;
  final double latitude;
  final double longitude;
}

class MineCard extends StatelessWidget {
  const MineCard({super.key, required this.status});
  final MineStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '⛏️ Mine ${status.id.toUpperCase()}',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF142A45)),
                ),
                Chip(
                  backgroundColor: status.active
                      ? const Color(0xFFFF5C5C)
                      : const Color(0xFF57D27A),
                  label: Text(
                    status.active ? '🚨 ALERT' : '✅ SAFE',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('💨 Methane: ${status.mq4} ppm',
                style: const TextStyle(
                    fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('🫁 Carbon monoxide: ${status.mq7} ppm',
                style: const TextStyle(
                    fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('💧 Water level: ${status.water}',
                style: const TextStyle(
                    fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('📶 Signal RSSI: ${status.rssi} dBm',
                style: const TextStyle(color: Color(0xFF5D6E84))),
            const SizedBox(height: 8),
            Text('🔋 Battery: ${status.battery}',
                style: const TextStyle(
                    fontSize: 16, color: Color(0xFF57D27A))),
          ],
        ),
      ),
    );
  }
}