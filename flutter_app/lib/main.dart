import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
// ALERT SEVERITY
// ─────────────────────────────────────────────────────────────────────────────

class AlertSeverity {
  static const String critical = 'Critical';
  static const String warning  = 'Warning';
  static const String info     = 'Info';
  static const String safe     = 'Safe';
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
    this.hazardType           = 'Hazard',
    this.exposureTime         = 'Monitor continuously',
    this.hazardLevel          = 'Moderate',
    this.location             = 'Mine site',
    this.workers              = 'Response team',
    this.recommendedAction    = 'Follow standard emergency procedure',
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String   mineId, title, description, severity;
  final String   hazardType, exposureTime, hazardLevel;
  final String   location, workers, recommendedAction;
  final DateTime timestamp;
}

class MineStatus {
  MineStatus({
    required this.id,
    required this.name,
    required this.mq4,
    required this.mq7,
    required this.water,
    required this.rssi,
    this.battery   = 'Unknown',
    required this.active,
    this.latitude  = 6.775904,
    this.longitude = 80.32928,
    this.online    = true,
    // FIX: store the real server timestamp from Firebase
    this.serverTimestamp,
    this.hazardCh4  = '',
    this.hazardCo   = '',
    this.hazardWater = '',
  });

  final String   id, name, water, battery;
  final String   hazardCh4, hazardCo, hazardWater;
  final int      mq4, mq7, rssi;
  final bool     active, online;
  final double   latitude, longitude;
  // FIX: real DateTime from server — null if node never connected
  final DateTime? serverTimestamp;
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERT TIMESTAMP REGISTRY
// Stores the FIRST time an alert key was seen this session.
// Once stored, the timestamp never changes — so reopening the app does NOT
// reset the displayed time (the server timestamp is used when available).
// ─────────────────────────────────────────────────────────────────────────────

class AlertTimestampRegistry {
  AlertTimestampRegistry._();
  static final AlertTimestampRegistry instance = AlertTimestampRegistry._();

  final Map<String, DateTime> _firstSeen = {};

  /// If [serverTime] is provided and the key is not yet registered, uses
  /// [serverTime] as the canonical timestamp (from Firebase).  Otherwise
  /// falls back to DateTime.now().
  DateTime getOrRegister(String key, {DateTime? serverTime}) {
    return _firstSeen.putIfAbsent(key, () => serverTime ?? DateTime.now());
  }

  void release(String key) => _firstSeen.remove(key);
  bool isRegistered(String key) => _firstSeen.containsKey(key);
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERT HISTORY MANAGER
// ─────────────────────────────────────────────────────────────────────────────

class _ActiveRecord {
  _ActiveRecord(this.alert, this.firstSeenAt);
  final AlertEvent alert;
  final DateTime   firstSeenAt;
}

class AlertHistoryManager {
  AlertHistoryManager._();
  static final AlertHistoryManager instance = AlertHistoryManager._();

  final Map<String, _ActiveRecord> _active  = {};
  final List<AlertEvent>           _history = [];

  List<AlertEvent> get historicalAlerts => List.unmodifiable(_history);

  void updateCurrentAlerts(List<AlertEvent> newAlerts) {
    final relevant = newAlerts.where((a) =>
        a.severity == AlertSeverity.critical ||
        a.severity == AlertSeverity.warning).toList();

    final newKeys = relevant.map((a) => '${a.mineId}__${a.title}').toSet();

    // Alerts that disappeared → move to history
    final disappeared = _active.keys.where((k) => !newKeys.contains(k)).toList();
    for (final k in disappeared) {
      final rec = _active.remove(k)!;
      _addToHistory(rec.alert);
      AlertTimestampRegistry.instance.release(k);
    }

    // Register new active alerts
    for (final a in relevant) {
      final k = '${a.mineId}__${a.title}';
      if (!_active.containsKey(k)) {
        _active[k] = _ActiveRecord(a, a.timestamp);
      }
    }
  }

  List<AlertEvent> get activeAlerts =>
      _active.values.map((e) => e.alert).toList();

  void _addToHistory(AlertEvent a) {
    final k = '${a.mineId}__${a.title}';
    final alreadyIn = _history.any((h) =>
        '${h.mineId}__${h.title}' == k && h.timestamp == a.timestamp);
    if (!alreadyIn) _history.insert(0, a);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND MESSAGE HANDLER
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings    = InitializationSettings(android: androidSettings);
  await flutterLocalNotificationsPlugin.initialize(initSettings);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_mineAlertChannel);

  await flutterLocalNotificationsPlugin.show(
    message.hashCode,
    message.notification?.title ?? 'Mine Safety Alert',
    message.notification?.body  ?? 'A new hazard event was detected.',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'mine_alert_channel', 'Mine Alerts',
        channelDescription: 'Mine safety alert notifications',
        importance: Importance.max, priority: Priority.high,
        playSound: true, enableVibration: true,
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
      alert: true, badge: true, sound: true,
    );

    if (!kIsWeb) {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidSettings);
      await flutterLocalNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (details) =>
            debugPrint('Notification tapped: ${details.payload}'),
      );
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_mineAlertChannel);
    }

    try {
      final token = await _messaging!.getToken();
      debugPrint('FCM TOKEN: $token');
    } catch (e) {
      debugPrint('ERROR getting FCM token: $e');
    }

    try {
      await _messaging!.subscribeToTopic('mine_alerts');
      debugPrint('Subscribed to mine_alerts topic');
    } catch (e) {
      debugPrint('ERROR subscribing to topic: $e');
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final title = message.notification?.title ?? 'Mine Safety Alert';
      final body  = message.notification?.body  ?? 'A new hazard event.';
      if (!kIsWeb) {
        flutterLocalNotificationsPlugin.show(
          message.hashCode, title, body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'mine_alert_channel', 'Mine Alerts',
              channelDescription: 'Mine safety alert notifications',
              importance: Importance.max, priority: Priority.high,
              playSound: true, enableVibration: true,
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
      }
      _showInAppAlert(title, body);
    });
  }

  void _showInAppAlert(String title, String body) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'))
        ],
      ),
    );
  }

  Future<void> _requestPermission() async {
    if (_messaging == null) return;
    final settings = await _messaging!
        .requestPermission(alert: true, badge: true, sound: true);
    debugPrint('Notification permission: ${settings.authorizationStatus}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Mine Pulse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(
          primary:     Color(0xFF1F6FFF),
          secondary:   Color(0xFFFFC857),
          surface:     Color(0xFFFFFFFF),
          onPrimary:   Colors.white,
          onSecondary: Color(0xFF11253B),
          onSurface:   Color(0xFF142A45),
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
          backgroundColor:      Color(0xFFFFFFFF),
          selectedItemColor:    Color(0xFF0057FF),
          unselectedItemColor:  Color(0xFF6E7A8C),
          selectedLabelStyle:   TextStyle(fontWeight: FontWeight.w600),
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
          hintStyle:    TextStyle(color: Color(0xFF7A8CAD)),
          labelStyle:   TextStyle(color: Color(0xFF142A45)),
          contentPadding:
              EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        ),
        textTheme: const TextTheme(
          bodyLarge:  TextStyle(color: Color(0xFF142A45)),
          bodyMedium: TextStyle(color: Color(0xFF3D5481)),
          titleLarge: TextStyle(
              color: Color(0xFF142A45), fontWeight: FontWeight.w600),
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
  static const String _emergencyNumber      = '119';
  static const String _emergencySmsTemplate =
      'Emergency at mine site. Please respond immediately.';

  int _selectedIndex = 0;

  // FIX: Listen to /status directly — the ESP32 writes to /status/mine1,
  // /status/mine2.  We stream the entire /status node so any child change
  // (mine1 OR mine2 OR mine3) immediately triggers a rebuild.
  DatabaseReference? _statusRef;

  Position? _currentPosition;
  String?   _locationStatus;

  // Static device catalogue — maps nodeKey to display metadata.
  // nodeKey MUST match exactly what the ESP32 writes under /status/
  // e.g.  /status/mine1  →  nodeKey: 'mine1'
  static const List<_StaticDevice> _staticDevices = [
    _StaticDevice(id: 'MP-001', nodeKey: 'mine1', name: 'Node MINE 1', lat: 6.775904,  lng: 80.32928),
    _StaticDevice(id: 'MP-002', nodeKey: 'mine2', name: 'Node MINE 2', lat: 6.733712,  lng: 80.277296),
    _StaticDevice(id: 'MP-003', nodeKey: 'mine3', name: 'Node MINE 3', lat: 6.729672,  lng: 80.33507),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.firebaseAvailable) {
      // FIX: keepSynced ensures the RTDB local cache is always up-to-date
      // so the first frame after opening the app shows stale cached data
      // instantly while the live update arrives within milliseconds.
      _statusRef = FirebaseDatabase.instance.ref('status');
      _statusRef!.keepSynced(true);
    }
    _loadCurrentLocation();
  }

  Future<void> _loadCurrentLocation() async {
    final pos = await _determinePosition();
    if (pos != null && mounted) setState(() => _currentPosition = pos);
  }

  Future<Position?> _determinePosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) setState(() => _locationStatus = 'GPS disabled. Enable location services.');
        return null;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) setState(() => _locationStatus = 'Location permission denied.');
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best);
      if (mounted) {
        setState(() => _locationStatus =
            'Phone located at ${pos.latitude.toStringAsFixed(5)}, '
            '${pos.longitude.toStringAsFixed(5)}');
      }
      return pos;
    } catch (e) {
      if (mounted) setState(() => _locationStatus = 'Unable to determine current location.');
      return null;
    }
  }

  Future<void> _openPhoneDialer(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    if (await canLaunchUrl(uri)) { await launchUrl(uri); return; }
    _showToast('Unable to open phone dialer.');
  }

  Future<void> _sendEmergencySms(String number, String message) async {
    final uri = Uri(scheme: 'sms', path: number,
        queryParameters: {'body': message});
    if (await canLaunchUrl(uri)) { await launchUrl(uri); return; }
    _showToast('Unable to open messaging app.');
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Parse a single /status/<nodeKey> node ───────────────────────────────
  //
  // FIX — timestamp handling:
  //   The ESP32 writes  "timestamp": (int)millis()  which is uptime ms, NOT
  //   Unix epoch.  We detect this by checking whether the value is smaller
  //   than a reasonable Unix epoch floor (year 2020 = 1577836800000 ms).
  //   If it looks like uptime, we fall back to DateTime.now() so that at
  //   least the first-seen time is correct.  The CORRECT long-term fix is
  //   to use Firebase ServerValue.timestamp on the ESP32 side — see the
  //   companion Arduino fix below.
  MineStatus _parseNode(_StaticDevice device, Map<dynamic, dynamic> statusMap) {
    final raw = statusMap[device.nodeKey];

    if (raw == null) {
      debugPrint('[RTDB] ${device.id}: key "${device.nodeKey}" not found. '
          'Available: ${statusMap.keys.toList()}');
      return MineStatus(
        id: device.id, name: device.name,
        mq4: 0, mq7: 0, rssi: 0,
        water: 'Normal', battery: 'N/A',
        active: false, online: false,
        latitude: device.lat, longitude: device.lng,
      );
    }

    final data = Map<String, dynamic>.from(raw as Map);
    debugPrint('[RTDB] ${device.id} raw data: $data');

    // ── Sensor values ────────────────────────────────────────────────────────
    final mq4Val   = _firstOf(data, ['mq4',  'MQ4',  'ch4',  'methane']);
    final mq7Val   = _firstOf(data, ['mq7',  'MQ7',  'co',   'carbon_monoxide']);
    final rssiVal  = _firstOf(data, ['rssi', 'RSSI', 'signal']);
    final battVal  = _firstOf(data, ['battery', 'Battery', 'batt', 'vbat']);

    // ── Water level ──────────────────────────────────────────────────────────
    String waterStr = 'Normal';
    final waterRaw = _firstOf(data, ['water', 'Water', 'waterLevel', 'water_level']);
    if (waterRaw != null) {
      if (waterRaw is int || waterRaw is double) {
        waterStr = (waterRaw as num) > 100 ? 'HIGH' : 'Normal';
      } else {
        final s = waterRaw.toString().toUpperCase().trim();
        waterStr = (s.contains('HIGH') || s == '1' || s == 'TRUE') ? 'HIGH' : 'Normal';
      }
    }
    final hazardWaterRaw = data['hazard_water']?.toString().toUpperCase().trim() ?? '';
    if (hazardWaterRaw.contains('HIGH') || hazardWaterRaw == '1' || hazardWaterRaw == 'TRUE') {
      waterStr = 'HIGH';
    }
    if (data['water_ingress'] == true || data['water_ingress'] == 1) waterStr = 'HIGH';

    // ── Hazard flags ─────────────────────────────────────────────────────────
    final hazardCh4  = (data['hazard_ch4']  ?? '').toString();
    final hazardCo   = (data['hazard_co']   ?? '').toString();
    final hazardWater = waterStr == 'HIGH' ? 'WATER LEVEL HIGH' : '';

    final bool ch4Alert = hazardCh4.isNotEmpty  && hazardCh4.toLowerCase()  != 'false';
    final bool coAlert  = hazardCo.isNotEmpty   && hazardCo.toLowerCase()   != 'false';
    final bool inAlert  = data['inAlert'] == true || data['alert'] == true;

    // ── FIX: Timestamp — convert server value to real DateTime ───────────────
    // ESP32 currently writes millis() (uptime). Values < 1_577_836_800_000
    // (Jan 2020 Unix ms) are treated as uptime and ignored.
    // When ESP32 is updated to write ServerValue.timestamp, this code
    // automatically uses the correct value.
    DateTime? serverTs;
    final tsRaw = data['timestamp'];
    if (tsRaw != null) {
      final tsInt = tsRaw is int ? tsRaw : int.tryParse(tsRaw.toString()) ?? 0;
      // Unix epoch in ms for 2020-01-01 = 1_577_836_800_000
      if (tsInt > 1577836800000) {
        serverTs = DateTime.fromMillisecondsSinceEpoch(tsInt);
      }
      // else: uptime millis — ignore, fall back to registry
    }

    return MineStatus(
      id:        device.id,
      name:      device.name,
      mq4:       _toInt(mq4Val),
      mq7:       _toInt(mq7Val),
      water:     waterStr,
      rssi:      _toInt(rssiVal),
      battery:   battVal?.toString() ?? 'N/A',
      active:    inAlert || ch4Alert || coAlert || waterStr == 'HIGH',
      online:    true,
      latitude:  device.lat,
      longitude: device.lng,
      serverTimestamp: serverTs,
      hazardCh4:   hazardCh4,
      hazardCo:    hazardCo,
      hazardWater: hazardWater,
    );
  }

  int _toInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    return int.tryParse(value.toString().replaceAll(RegExp(r'[^0-9\-]'), '')) ?? 0;
  }

  dynamic _firstOf(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      if (map.containsKey(k) && map[k] != null) return map[k];
    }
    return null;
  }

  // ── Generate alerts from live sensor status ────────────────────────────────
  //
  // FIX: Timestamp passed from MineStatus.serverTimestamp so alert cards
  // always show the actual sensor-event time, not the app-open time.
  //
  // Thresholds (match ESP32 firmware defaults):
  //   Methane critical: mq4 >= 100 ppm
  //   Methane warning : mq4 >= 50  ppm
  //   CO critical     : mq7 >= 150 ppm   (was 200 — lowered to match real sensor)
  //   CO warning      : mq7 >= 75  ppm
  List<AlertEvent> _generateAlerts(List<MineStatus> mines) {
    final alerts  = <AlertEvent>[];
    final registry = AlertTimestampRegistry.instance;

    for (final mine in mines) {
      // Skip nodes that truly have no data (never connected)
      final hasNoData = mine.mq4 == 0 &&
          mine.mq7 == 0 &&
          mine.water == 'Normal' &&
          !mine.active &&
          !mine.online;
      if (hasNoData) continue;

      final mq4  = mine.mq4.toDouble();
      final mq7  = mine.mq7.toDouble();
      final rssi = mine.rssi;
      // FIX: use server timestamp when available, else first-seen time
      final sTs = mine.serverTimestamp;

      // ── Methane ──────────────────────────────────────────────────────────
      if (mine.active && mq4 >= 100) {
        final key = '${mine.id}__Methane Alarm';
        final ts  = registry.getOrRegister(key, serverTime: sTs);
        alerts.add(AlertEvent(
          mineId:            mine.id,
          title:             'Methane Alarm',
          description:       'Methane critically high at ${mine.name} (${mine.mq4} ppm). '
                             'Immediate evacuation required.',
          severity:          AlertSeverity.critical,
          hazardType:        'Methane gas',
          exposureTime:      '0–5 min before unsafe exposure',
          hazardLevel:       'Critical',
          location:          '${mine.name} – underground drift',
          workers:           'Shift team + rescue standby',
          recommendedAction: 'Evacuate, ventilate, verify gas extraction systems.',
          timestamp:         ts,
        ));
      } else {
        registry.release('${mine.id}__Methane Alarm');

        if (mine.active && mq4 >= 50) {
          final key = '${mine.id}__Methane Elevated';
          final ts  = registry.getOrRegister(key, serverTime: sTs);
          alerts.add(AlertEvent(
            mineId:            mine.id,
            title:             'Methane Elevated',
            description:       'Methane rising at ${mine.name} (${mine.mq4} ppm). '
                               'Monitor closely and prepare to act.',
            severity:          AlertSeverity.warning,
            hazardType:        'Methane gas',
            exposureTime:      '5–15 min for monitoring and response',
            hazardLevel:       'Warning',
            location:          '${mine.name} – ventilation route',
            workers:           'Shift team',
            recommendedAction: 'Increase monitoring and prepare ventilation response.',
            timestamp:         ts,
          ));
        } else {
          registry.release('${mine.id}__Methane Elevated');
        }
      }

      // ── CO ───────────────────────────────────────────────────────────────
      if (mine.active && mq7 >= 150) {
        final key = '${mine.id}__Carbon Monoxide Alert';
        final ts  = registry.getOrRegister(key, serverTime: sTs);
        alerts.add(AlertEvent(
          mineId:            mine.id,
          title:             'Carbon Monoxide Alert',
          description:       'CO critically high at ${mine.name} (${mine.mq7} ppm). '
                             'Respiratory protection required immediately.',
          severity:          AlertSeverity.critical,
          hazardType:        'Carbon monoxide',
          exposureTime:      'Under 10 min for high exposure',
          hazardLevel:       'Critical',
          location:          '${mine.name} – working face',
          workers:           'All miners in zone',
          recommendedAction: 'Stop work, activate rescue, check breathing systems.',
          timestamp:         ts,
        ));
      } else {
        registry.release('${mine.id}__Carbon Monoxide Alert');

        if (mine.active && mq7 >= 75) {
          final key = '${mine.id}__CO Elevated';
          final ts  = registry.getOrRegister(key, serverTime: sTs);
          alerts.add(AlertEvent(
            mineId:            mine.id,
            title:             'CO Elevated',
            description:       'Carbon monoxide elevated at ${mine.name} (${mine.mq7} ppm). '
                               'Monitor workers closely.',
            severity:          AlertSeverity.warning,
            hazardType:        'Carbon monoxide',
            exposureTime:      '10–30 min monitoring window',
            hazardLevel:       'Warning',
            location:          '${mine.name} – working face',
            workers:           'Shift team',
            recommendedAction: 'Increase ventilation, monitor breathing.',
            timestamp:         ts,
          ));
        } else {
          registry.release('${mine.id}__CO Elevated');
        }
      }

      // ── Water ─────────────────────────────────────────────────────────────
      if (mine.active && mine.water.toUpperCase().contains('HIGH')) {
        final key = '${mine.id}__Water Ingress Detected';
        final ts  = registry.getOrRegister(key, serverTime: sTs);
        alerts.add(AlertEvent(
          mineId:            mine.id,
          title:             'Water Ingress Detected',
          description:       'High water level at ${mine.name}. '
                             'Check drainage immediately.',
          severity:          AlertSeverity.critical,
          hazardType:        'Water ingress',
          exposureTime:      '15–30 min before equipment risk',
          hazardLevel:       'Critical',
          location:          '${mine.name} – low-level tunnel',
          workers:           'Maintenance crew',
          recommendedAction: 'Inspect pumps, isolate section, reroute personnel.',
          timestamp:         ts,
        ));
      } else {
        registry.release('${mine.id}__Water Ingress Detected');
      }

      // ── Signal quality ────────────────────────────────────────────────────
      if (rssi != 0 && rssi <= -80) {
        final key = '${mine.id}__Poor Signal Quality';
        final ts  = registry.getOrRegister(key, serverTime: sTs);
        alerts.add(AlertEvent(
          mineId:            mine.id,
          title:             'Poor Signal Quality',
          description:       'Weak signal at ${mine.name} (${mine.rssi} dBm). '
                             'Check gateway connectivity.',
          severity:          AlertSeverity.info,
          hazardType:        'Communication loss',
          exposureTime:      'Ongoing monitoring required',
          hazardLevel:       'Info',
          location:          '${mine.name} – surface gateway path',
          workers:           'Telemetry team',
          recommendedAction: 'Inspect antenna alignment and gateway connectivity.',
          timestamp:         ts,
        ));
      } else {
        registry.release('${mine.id}__Poor Signal Quality');
      }
    }

    if (alerts.where((a) =>
        a.severity == AlertSeverity.critical ||
        a.severity == AlertSeverity.warning).isEmpty) {
      alerts.add(AlertEvent(
        mineId:      'system',
        title:       'All Systems Stable',
        description: 'No active hazards detected. Continue routine monitoring.',
        severity:    AlertSeverity.safe,
        timestamp:   DateTime.now(),
      ));
    }
    return alerts;
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mine Pulse'), centerTitle: true),
      body: widget.firebaseAvailable
          ? _buildFirebaseBody()
          : _buildDemoBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openPhoneDialer(_emergencyNumber),
        backgroundColor: const Color(0xFFD62828),
        icon: const Icon(Icons.warning_amber_rounded),
        label: const Text('EMERGENCY SOS',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5)),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      extendBody: true,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        selectedItemColor:   const Color(0xFF0057FF),
        unselectedItemColor: const Color(0xFF6E7A8C),
        backgroundColor:     const Color(0xFFFFFFFF),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard),            label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications_active), label: 'Alerts'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart),            label: 'Analytics'),
          BottomNavigationBarItem(icon: Icon(Icons.map),                  label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.settings),             label: 'Settings'),
        ],
        onTap: (i) => setState(() => _selectedIndex = i),
      ),
    );
  }

  // FIX: Stream /status only — no Firestore dependency.
  // The ESP32 writes ALERT data directly to /status/mine1 with inAlert=true,
  // so we only need one stream.  Firestore is no longer used.
  Widget _buildFirebaseBody() {
    if (_statusRef == null) {
      return _buildTabContent([], [],
        dataLabel: 'Mine Pulse is not connected to telemetry.',
      );
    }

    return StreamBuilder<DatabaseEvent>(
      stream: _statusRef!.onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'RTDB Error: ${snap.error}\n\n'
                'Check Firebase rules and database URL.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        // FIX: Show cached data immediately while waiting for live update.
        // ConnectionState.waiting only appears on first connect; after that
        // the stream always has data from the local RTDB cache.
        if (snap.connectionState == ConnectionState.waiting &&
            !snap.hasData) {
          return const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to Mine Pulse cloud telemetry...'),
            ]),
          );
        }

        Map<dynamic, dynamic> statusMap = {};
        if (snap.hasData && snap.data?.snapshot.value != null) {
          final val = snap.data!.snapshot.value;
          if (val is Map) statusMap = val;
          debugPrint('[RTDB] status keys: ${statusMap.keys.toList()}');
        } else {
          debugPrint('[RTDB] status snapshot is null or empty');
        }

        final mines = _staticDevices
            .map((d) => _parseNode(d, statusMap))
            .toList();

        final alerts = _generateAlerts(mines);
        AlertHistoryManager.instance.updateCurrentAlerts(alerts);

        return _buildTabContent(
          mines, alerts,
          dataLabel: 'Live Security Overview',
        );
      },
    );
  }

  Widget _buildDemoBody() {
    return _buildTabContent([], [],
      dataLabel: 'Mine Pulse is running without a telemetry connection.',
      demoMode: true,
    );
  }

  Widget _buildTabContent(
    List<MineStatus> mines,
    List<AlertEvent> alerts, {
    required String dataLabel,
    bool demoMode = false,
  }) {
    switch (_selectedIndex) {
      case 0:
        return DashboardTab(
          mines: mines, alerts: alerts, dataLabel: dataLabel,
          demoMode: demoMode,
          currentPosition: _currentPosition,
          locationStatus:  _locationStatus,
          onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
          onEmergencySms:  () => _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
        );
      case 1:
        return AlertsTab(alerts: alerts, mines: mines, demoMode: demoMode);
      case 2:
        return AnalyticsTab(alerts: alerts, mines: mines);
      case 3:
        return MapTab(
          mines: mines, alerts: alerts,
          currentPosition: _currentPosition,
          locationStatus:  _locationStatus,
          onRefreshLocation: _loadCurrentLocation,
        );
      default:
        return SettingsTab(
          onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
          onEmergencySms:  () => _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
          userEmail: null, onSignOut: null,
        );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STATIC DEVICE MODEL
// ─────────────────────────────────────────────────────────────────────────────

class _StaticDevice {
  const _StaticDevice({
    required this.id,
    required this.nodeKey,
    required this.name,
    required this.lat,
    required this.lng,
  });
  final String id, nodeKey, name;
  final double lat, lng;
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _formatTimestamp(DateTime dt) {
  const months = ['Jan','Feb','Mar','Apr','May','Jun',
                  'Jul','Aug','Sep','Oct','Nov','Dec'];
  final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  final min  = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${months[dt.month - 1]} ${dt.year} · $hour:$min $ampm';
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.count, this.countColor});
  final String title;
  final int?   count;
  final Color? countColor;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      if (count != null) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: countColor ?? const Color(0xFF6E7A8C),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text('$count',
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ],
    ]);
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message,
            style: const TextStyle(color: Color(0xFF5D6E84), fontSize: 15)),
      ),
    );
  }
}

class EmergencyActionsCard extends StatelessWidget {
  const EmergencyActionsCard(
      {super.key, required this.onCall, required this.onSms});
  final VoidCallback onCall, onSms;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Emergency Contact',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
          const SizedBox(height: 10),
          const Text(
              'Contact surface command and rescue teams immediately in case of emergency.',
              style: TextStyle(fontSize: 15, color: Color(0xFF5D6E84))),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: ElevatedButton.icon(
                    icon: const Icon(Icons.call),
                    label: const Text('Call'),
                    onPressed: onCall)),
            const SizedBox(width: 12),
            Expanded(
                child: ElevatedButton.icon(
                    icon: const Icon(Icons.message),
                    label: const Text('Message'),
                    onPressed: onSms)),
          ]),
        ]),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(
      {required this.label, required this.value, required this.color});
  final String label, value;
  final Color  color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:  const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        color.withAlpha(40),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                color: Color(0xFF142A45), fontWeight: FontWeight.w600, fontSize: 12)),
        const SizedBox(height: 8),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 20, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERT TILE
// ─────────────────────────────────────────────────────────────────────────────

class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.alert});
  final AlertEvent alert;

  void showDetails(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(alert.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('Date & Time', _formatTimestamp(alert.timestamp)),
              _detailRow('Hazard type', alert.hazardType),
              _detailRow('Level',       alert.hazardLevel),
              _detailRow('Exposure',    alert.exposureTime),
              _detailRow('Node',        alert.mineId),
              _detailRow('Location',    alert.location),
              _detailRow('Workers',     alert.workers),
              const SizedBox(height: 8),
              Text(alert.description,
                  style: const TextStyle(color: Color(0xFF142A45))),
              const SizedBox(height: 8),
              Text('Recommended: ${alert.recommendedAction}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Color(0xFF0057FF))),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'))
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

    return Card(
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(alert.title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold,
                          color: Color(0xFF142A45)))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color:        iconColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: iconColor.withAlpha(120)),
                ),
                child: Text(alert.severity,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold, color: iconColor)),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: Color(0xFF5D6E84)),
            ]),
            const SizedBox(height: 6),
            Text('Node: ${alert.mineId} · ${alert.hazardType}',
                style: const TextStyle(color: Color(0xFF5D6E84), fontSize: 13)),
            const SizedBox(height: 4),
            Text(_formatTimestamp(alert.timestamp),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9BAEC8))),
            const SizedBox(height: 8),
            Text(alert.description,
                style: const TextStyle(fontSize: 15, color: Color(0xFF142A45))),
          ]),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label: ',
            style: const TextStyle(
                fontWeight: FontWeight.w700, color: Color(0xFF5D6E84))),
        Expanded(
            child: Text(value,
                style: const TextStyle(color: Color(0xFF142A45)))),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MINE CARD
// ─────────────────────────────────────────────────────────────────────────────

class MineCard extends StatelessWidget {
  const MineCard({super.key, required this.status});
  final MineStatus status;

  @override
  Widget build(BuildContext context) {
    final onlineBadgeColor = status.online
        ? const Color(0xFF57D27A)
        : const Color(0xFF9AA9BE);
    final onlineBadgeLabel = status.online ? 'ONLINE' : 'OFFLINE';

    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(status.name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold,
                          color: Color(0xFF142A45))),
                  Text(status.id,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF8FA6C0))),
                ]),
              ),
              Row(children: [
                if (status.active)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEBEB),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('ALERT',
                        style: TextStyle(
                            color: Color(0xFFD62828),
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                Chip(
                  backgroundColor: onlineBadgeColor,
                  label: Text(onlineBadgeLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ]),
            ],
          ),
          const SizedBox(height: 12),
          if (status.online) ...[
            _SensorRow(label: 'Methane (MQ-4)', value: '${status.mq4} ppm',  color: const Color(0xFFFF7043)),
            _SensorRow(label: 'CO (MQ-7)',      value: '${status.mq7} ppm',  color: const Color(0xFF42A5F5)),
            _SensorRow(label: 'Water level',    value: status.water,          color: const Color(0xFF45B7D1)),
            _SensorRow(label: 'Signal RSSI',    value: '${status.rssi} dBm', color: const Color(0xFF2E7DFF)),
            _SensorRow(label: 'Battery',        value: status.battery,        color: const Color(0xFF57D27A)),
            if (status.serverTimestamp != null) ...[
              const SizedBox(height: 6),
              Text(
                'Last update: ${_formatTimestamp(status.serverTimestamp!)}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9BAEC8)),
              ),
            ],
          ] else
            const Text('Device offline — no live telemetry available.',
                style: TextStyle(color: Color(0xFF9AA9BE), fontSize: 14)),
        ]),
      ),
    );
  }
}

class _SensorRow extends StatelessWidget {
  const _SensorRow({required this.label, required this.value, required this.color});
  final String label, value;
  final Color  color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(fontSize: 14, color: Color(0xFF5D6E84))),
          ]),
          Text(value,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF142A45))),
        ],
      ),
    );
  }
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
  final bool   demoMode;
  final Position? currentPosition;
  final String?   locationStatus;
  final VoidCallback onEmergencyCall, onEmergencySms;

  @override
  Widget build(BuildContext context) {
    final activeAlerts = AlertHistoryManager.instance.activeAlerts
        .where((a) =>
            a.severity == AlertSeverity.critical ||
            a.severity == AlertSeverity.warning)
        .toList();
    final hasActive = activeAlerts.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        // ── Header card ──────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFFFFFF), Color(0xFFF4F8FF)],
              begin: Alignment.topLeft,
              end:   Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE2EAF7)),
            boxShadow: const [
              BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 12))
            ],
          ),
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset('assets/favicon.jpeg',
                    width: 72, height: 72, fit: BoxFit.cover),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Mine Pulse',
                      style: TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w800,
                          color: Color(0xFF142A45))),
                  const SizedBox(height: 8),
                  Text(
                      demoMode
                          ? 'Demo mode — no live data.'
                          : 'Connected to live monitoring.',
                      style: const TextStyle(fontSize: 14, color: Color(0xFF3D5481))),
                  if (locationStatus != null) ...[
                    const SizedBox(height: 6),
                    Text(locationStatus!,
                        style: const TextStyle(fontSize: 13, color: Color(0xFF3D5481))),
                  ],
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            // Alert status banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: hasActive ? const Color(0xFFFFEBEB) : const Color(0xFFE8F8EE),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasActive ? const Color(0xFFFF5C5C) : const Color(0xFF57D27A),
                  width: 1.2,
                ),
              ),
              child: Row(children: [
                Icon(
                  hasActive ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                  color: hasActive ? const Color(0xFFD62828) : const Color(0xFF2E9E57),
                  size: 30,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      hasActive
                          ? '${activeAlerts.length} Active Alert'
                              '${activeAlerts.length == 1 ? '' : 's'}'
                          : 'No Active Alerts',
                      style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold,
                        color: hasActive
                            ? const Color(0xFFD62828)
                            : const Color(0xFF2E9E57),
                      ),
                    ),
                    const SizedBox(height: 3),
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
                  ]),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 22),
        _SectionHeader(
          title:      'Active Alerts',
          count:      activeAlerts.isNotEmpty ? activeAlerts.length : null,
          countColor: const Color(0xFFD62828),
        ),
        const SizedBox(height: 10),
        if (activeAlerts.isNotEmpty)
          ...activeAlerts.map((a) => AlertTile(alert: a))
        else
          const _EmptyStateCard(
              message: 'No active alerts detected. The mine network is stable.'),
        const SizedBox(height: 22),
        EmergencyActionsCard(onCall: onEmergencyCall, onSms: onEmergencySms),
        const SizedBox(height: 22),
        const _SectionHeader(title: 'Mine Telemetry'),
        const SizedBox(height: 10),
        if (mines.isNotEmpty)
          ...mines.map((m) => MineCard(status: m))
        else
          const _EmptyStateCard(
              message: 'No telemetry until underground nodes connect.'),
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
    final activeAlerts = AlertHistoryManager.instance.activeAlerts
        .where((a) =>
            a.severity == AlertSeverity.critical ||
            a.severity == AlertSeverity.warning)
        .toList();
    final history = AlertHistoryManager.instance.historicalAlerts;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Alert Center',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Active alerts clear automatically when sensors return to safe levels.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9BAEC8)),
        ),
        const SizedBox(height: 16),
        _SectionHeader(
          title:      'Active Alerts',
          count:      activeAlerts.isNotEmpty ? activeAlerts.length : null,
          countColor: const Color(0xFFD62828),
        ),
        const SizedBox(height: 10),
        if (activeAlerts.isEmpty)
          const _EmptyStateCard(message: 'All systems stable. No active alerts.')
        else
          ...activeAlerts.map((a) => AlertTile(alert: a)),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('All active alerts acknowledged.')));
          },
          icon:  const Icon(Icons.check_circle_outline),
          label: const Text('Acknowledge All Alerts'),
        ),
        const SizedBox(height: 24),
        _SectionHeader(
          title:      'Alert History',
          count:      history.isNotEmpty ? history.length : null,
          countColor: const Color(0xFF6E7A8C),
        ),
        const SizedBox(height: 6),
        const Text(
          'Cleared alerts are kept here permanently for this session.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9BAEC8)),
        ),
        const SizedBox(height: 10),
        if (history.isEmpty)
          const _EmptyStateCard(
              message: 'No alert history yet. '
                  'Cleared alerts will appear here once sensors return to safe levels.')
        else
          ...history.map((a) => _AlertHistoryCard(alert: a)),
      ],
    );
  }
}

class _AlertHistoryCard extends StatelessWidget {
  const _AlertHistoryCard({required this.alert});
  final AlertEvent alert;

  Color get _borderColor {
    switch (alert.severity) {
      case AlertSeverity.critical: return const Color(0xFFFF5C5C);
      case AlertSeverity.warning:  return const Color(0xFFFFC107);
      case AlertSeverity.info:     return const Color(0xFF5C9BFF);
      default:                     return const Color(0xFF57D27A);
    }
  }

  IconData get _icon {
    switch (alert.severity) {
      case AlertSeverity.critical: return Icons.dangerous;
      case AlertSeverity.warning:  return Icons.warning_amber;
      default:                     return Icons.info_outline;
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
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_icon, color: _borderColor, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(alert.title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold,
                            color: Color(0xFF142A45))),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6EEF8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Resolved',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFF5D6E84),
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 3),
                Text('Node ${alert.mineId} · ${_formatTimestamp(alert.timestamp)}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9BAEC8))),
                const SizedBox(height: 4),
                Text(alert.description,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF5D6E84))),
              ]),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFB0C5E2), size: 20),
          ]),
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
  final String?   locationStatus;
  final Future<void> Function() onRefreshLocation;

  static const _deviceLocation = LatLng(6.775904, 80.32928);

  @override
  Widget build(BuildContext context) {
    final center = currentPosition != null
        ? LatLng(currentPosition!.latitude, currentPosition!.longitude)
        : _deviceLocation;

    final markers = <Marker>[];

    markers.add(Marker(
      width: 130, height: 80,
      point: _deviceLocation,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.location_on, color: Color(0xFF2E7DFF), size: 36),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
              color: const Color(0xFF0F1D2C),
              borderRadius: BorderRadius.circular(8)),
          child: const Text('MP-001 Device',
              style: TextStyle(color: Colors.white, fontSize: 11)),
        ),
      ]),
    ));

    for (final mine in mines) {
      if (!mine.online) continue;
      if (mine.id == 'MP-001') continue;
      final isAlert = alerts.any((a) =>
          a.mineId == mine.id && a.severity != AlertSeverity.safe);
      markers.add(Marker(
        width: 130, height: 80,
        point: LatLng(mine.latitude, mine.longitude),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            isAlert ? Icons.warning_amber_rounded : Icons.location_on_outlined,
            color: isAlert ? Colors.redAccent : Colors.lightBlueAccent,
            size: 34,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
                color: const Color(0xFF0F1D2C),
                borderRadius: BorderRadius.circular(8)),
            child: Text(mine.name,
                style: const TextStyle(color: Colors.white, fontSize: 10)),
          ),
        ]),
      ));
    }

    if (currentPosition != null) {
      final userLoc = LatLng(currentPosition!.latitude, currentPosition!.longitude);
      if ((userLoc.latitude - _deviceLocation.latitude).abs() > 0.001 ||
          (userLoc.longitude - _deviceLocation.longitude).abs() > 0.001) {
        markers.add(Marker(
          width: 100, height: 80,
          point: userLoc,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.my_location, color: Color(0xFF57D27A), size: 34),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                  color: const Color(0xFF0F1D2C),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('You',
                  style: TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ]),
        ));
      }
    }

    return Column(children: [
      Expanded(
        child: FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 12.0),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.mine_pulse',
            ),
            MarkerLayer(markers: markers),
          ],
        ),
      ),
      Container(
        color: const Color(0xFFF4F8FF),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Text('Mine site: Kuruwita, Ratnapura, Sri Lanka',
                  style: TextStyle(
                      color: Color(0xFF142A45), fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.my_location, color: Color(0xFF0057FF)),
              tooltip: 'Refresh location',
              onPressed: () async => await onRefreshLocation(),
            ),
          ]),
          if (locationStatus != null) ...[
            const SizedBox(height: 4),
            Text(locationStatus!,
                style: const TextStyle(color: Color(0xFF3D5481), fontSize: 13)),
          ],
        ]),
      ),
    ]);
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
    final activeAlerts = AlertHistoryManager.instance.activeAlerts;
    final critical = activeAlerts.where((a) => a.severity == AlertSeverity.critical).length;
    final warning  = activeAlerts.where((a) => a.severity == AlertSeverity.warning).length;
    final total    = activeAlerts.length;
    final methane  = activeAlerts.where((a) => a.title.toLowerCase().contains('methane')).length;
    final carbon   = activeAlerts.where((a) => a.title.toLowerCase().contains('carbon')).length;
    final water    = activeAlerts.where((a) => a.title.toLowerCase().contains('water')).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Analytics',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Real-time trends for the mine safety network.',
            style: TextStyle(fontSize: 15, color: Color(0xFF5D6E84))),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _SummaryCard(label: 'Critical', value: critical.toString(), color: const Color(0xFFFF5C5C))),
          Expanded(child: _SummaryCard(label: 'Warning',  value: warning.toString(),  color: const Color(0xFFFFC107))),
          Expanded(child: _SummaryCard(label: 'Total',    value: total.toString(),    color: const Color(0xFF5C9BFF))),
        ]),
        const SizedBox(height: 22),
        _AnalyticsCard(
          title:    'Hazard Type Distribution',
          subtitle: 'Number of alerts per hazard category',
          child: _BarChart(bars: [
            _BarData('Methane', methane, const Color(0xFFFF7043)),
            _BarData('CO',      carbon,  const Color(0xFF42A5F5)),
            _BarData('Water',   water,   const Color(0xFF66BB6A)),
          ]),
        ),
        const SizedBox(height: 16),
        _AnalyticsCard(
          title:    'Alert Severity Breakdown',
          subtitle: 'Proportion of critical vs warning alerts',
          child:    _SeverityStackedBar(critical: critical, warning: warning),
        ),
        const SizedBox(height: 16),
        _AnalyticsCard(
          title:    'Sensor Readings per Node',
          subtitle: 'Current MQ-4 (methane) and MQ-7 (CO) values',
          child:    _SensorGroupedBars(mines: mines),
        ),
        const SizedBox(height: 22),
        const Text('Activity Summary',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Card(
          color: const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Network performance based on current telemetry.',
                  style: TextStyle(color: Color(0xFF5D6E84))),
              const SizedBox(height: 14),
              Text('Tracked nodes: ${mines.length}',
                  style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
              const SizedBox(height: 6),
              Text('Active alerts: $total',
                  style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            ]),
          ),
        ),
      ],
    );
  }
}

class _AnalyticsCard extends StatelessWidget {
  const _AnalyticsCard({required this.title, required this.subtitle, required this.child});
  final String title, subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
          const SizedBox(height: 4),
          Text(subtitle,
              style: const TextStyle(fontSize: 13, color: Color(0xFF8FA6C0))),
          const SizedBox(height: 16),
          child,
        ]),
      ),
    );
  }
}

class _BarData {
  const _BarData(this.label, this.value, this.color);
  final String label;
  final int    value;
  final Color  color;
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.bars});
  final List<_BarData> bars;

  @override
  Widget build(BuildContext context) {
    final maxVal = bars.fold<int>(1, (prev, b) => b.value > prev ? b.value : prev);
    const chartHeight = 80.0;

    return SizedBox(
      height: chartHeight + 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: bars.map((bar) {
          final frac = maxVal == 0 ? 0.05 : (bar.value / maxVal).clamp(0.05, 1.0);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(bar.value.toString(),
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold, color: bar.color)),
                  const SizedBox(height: 4),
                  Container(
                    height: chartHeight * frac,
                    decoration: BoxDecoration(
                      color: bar.color,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(bar.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF5D6E84))),
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
  const _SeverityStackedBar({required this.critical, required this.warning});
  final int critical, warning;

  @override
  Widget build(BuildContext context) {
    final total     = (critical + warning).toDouble();
    final safeTotal = total == 0 ? 1.0 : total;

    Widget seg(int count, Color color) => Expanded(
          flex: count == 0 ? 0 : ((count / safeTotal) * 100).round(),
          child: count == 0
              ? const SizedBox.shrink()
              : Container(
                  height: 36, color: color,
                  alignment: Alignment.center,
                  child: Text(count.toString(),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: total == 0
            ? Container(
                height: 36, color: const Color(0xFFE6F0FF),
                alignment: Alignment.center,
                child: const Text('No alerts',
                    style: TextStyle(color: Color(0xFF8FA6C0))))
            : Row(children: [
                seg(critical, const Color(0xFFFF5C5C)),
                seg(warning,  const Color(0xFFFFC107)),
              ]),
      ),
      const SizedBox(height: 12),
      const Row(children: [
        _LegendDot(color: Color(0xFFFF5C5C), label: 'Critical'),
        SizedBox(width: 16),
        _LegendDot(color: Color(0xFFFFC107), label: 'Warning'),
      ]),
    ]);
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color  color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF5D6E84))),
    ]);
  }
}

class _SensorGroupedBars extends StatelessWidget {
  const _SensorGroupedBars({required this.mines});
  final List<MineStatus> mines;

  @override
  Widget build(BuildContext context) {
    final online = mines.where((m) => m.online).toList();
    if (online.isEmpty) {
      return const Text('No sensor data available.',
          style: TextStyle(color: Color(0xFF8FA6C0)));
    }

    int maxVal = 1;
    for (final m in online) {
      if (m.mq4 > maxVal) maxVal = m.mq4;
      if (m.mq7 > maxVal) maxVal = m.mq7;
    }

    return Column(children: [
      const Row(children: [
        _LegendDot(color: Color(0xFFFF7043), label: 'MQ-4 Methane (ppm)'),
        SizedBox(width: 16),
        _LegendDot(color: Color(0xFF42A5F5), label: 'MQ-7 CO (ppm)'),
      ]),
      const SizedBox(height: 12),
      ...online.map((mine) {
        final f4 = (mine.mq4 / maxVal).clamp(0.0, 1.0);
        final f7 = (mine.mq7 / maxVal).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mine.name,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: Color(0xFF142A45))),
            const SizedBox(height: 6),
            Row(children: [
              const SizedBox(width: 28,
                  child: Text('CH4',
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFFFF7043),
                          fontWeight: FontWeight.bold))),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: f4 == 0 ? 0.02 : f4,
                  minHeight: 12,
                  color: const Color(0xFFFF7043),
                  backgroundColor: const Color(0xFFE6F0FF),
                ),
              )),
              const SizedBox(width: 8),
              Text('${mine.mq4} ppm',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF5D6E84))),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const SizedBox(width: 28,
                  child: Text('CO',
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFF42A5F5),
                          fontWeight: FontWeight.bold))),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: f7 == 0 ? 0.02 : f7,
                  minHeight: 12,
                  color: const Color(0xFF42A5F5),
                  backgroundColor: const Color(0xFFE6F0FF),
                ),
              )),
              const SizedBox(width: 8),
              Text('${mine.mq7} ppm',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF5D6E84))),
            ]),
          ]),
        );
      }),
    ]);
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
  final VoidCallback onEmergencyCall, onEmergencySms;
  final String?      userEmail;
  final Future<void> Function()? onSignOut;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _pushAlerts = true;
  bool _smsAlerts  = true;
  bool _liveMap    = true;
  final _emergencyCtrl = TextEditingController(text: '119');
  final _methaneCtrl   = TextEditingController(text: '100');
  final _coCtrl        = TextEditingController(text: '150');
  final _workersCtrl   = TextEditingController(text: '24');
  DateTime _selectedDate = DateTime.now();
  bool _workersSaved     = false;

  @override
  void dispose() {
    _emergencyCtrl.dispose();
    _methaneCtrl.dispose();
    _coCtrl.dispose();
    _workersCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('System Settings',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _SettingsSection(title: 'Alert Thresholds', children: [
          TextField(
              controller: _methaneCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Methane threshold (ppm) — default 100',
                  filled: true, fillColor: Color(0xFFF4F8FF))),
          const SizedBox(height: 10),
          TextField(
              controller: _coCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'CO threshold (ppm) — default 150',
                  filled: true, fillColor: Color(0xFFF4F8FF))),
        ]),
        const SizedBox(height: 12),
        _SettingsSection(title: 'Emergency Contacts', children: [
          TextField(
              controller: _emergencyCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Primary SMS number',
                  filled: true, fillColor: Color(0xFFF4F8FF))),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
                icon: const Icon(Icons.call),
                label: const Text('Quick SOS'),
                onPressed: widget.onEmergencyCall)),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton.icon(
                icon: const Icon(Icons.message),
                label: const Text('Message'),
                onPressed: widget.onEmergencySms)),
          ]),
        ]),
        const SizedBox(height: 12),
        _SettingsSection(title: 'Daily Workforce Update', children: [
          TextField(
            controller: _workersCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Workers on duty today',
                filled: true, fillColor: Color(0xFFF4F8FF)),
            onChanged: (_) => setState(() => _workersSaved = false),
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
                setState(() { _selectedDate = picked; _workersSaved = false; });
              }
            },
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0xFFF4F8FF),
                  borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                const Icon(Icons.calendar_today, color: Color(0xFF0057FF)),
                const SizedBox(width: 10),
                Text(
                  'Date: '
                  '${_selectedDate.day.toString().padLeft(2, '0')}/'
                  '${_selectedDate.month.toString().padLeft(2, '0')}/'
                  '${_selectedDate.year}',
                  style: const TextStyle(color: Color(0xFF142A45), fontSize: 15),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.save),
              label: Text(_workersSaved ? 'Saved!' : 'Save Workforce Record'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _workersSaved ? const Color(0xFF57D27A) : null),
              onPressed: () {
                setState(() => _workersSaved = true);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                    'Saved: ${_workersCtrl.text.isEmpty ? '0' : _workersCtrl.text}'
                    ' workers on '
                    '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
                  ),
                ));
              },
            ),
          ),
          if (_workersSaved) ...[
            const SizedBox(height: 6),
            Text(
              'Record saved: ${_workersCtrl.text} workers on '
              '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
              style: const TextStyle(color: Color(0xFF57D27A), fontSize: 13),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        _SettingsSection(title: 'Operational Controls', children: [
          SwitchListTile(
              title: const Text('Push notifications'),
              value: _pushAlerts,
              onChanged: (v) => setState(() => _pushAlerts = v)),
          SwitchListTile(
              title: const Text('SMS alerts'),
              value: _smsAlerts,
              onChanged: (v) => setState(() => _smsAlerts = v)),
          SwitchListTile(
              title: const Text('Live map updates'),
              value: _liveMap,
              onChanged: (v) => setState(() => _liveMap = v)),
        ]),
        const SizedBox(height: 12),
        _SettingsSection(title: 'Account', children: [
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
                    const SnackBar(content: Text('Signed out successfully.')));
              },
            ),
        ]),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});
  final String       title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }
}