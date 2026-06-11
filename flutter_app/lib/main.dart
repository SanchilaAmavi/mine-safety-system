import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'firebase_options.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  debugPrint('Background message received: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool firebaseAvailable = true;

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    }
  } catch (error) {
    firebaseAvailable = false;
    debugPrint('Firebase initialization failed: $error');
  }

  runApp(MinePulseApp(firebaseAvailable: firebaseAvailable));
}

class MinePulseApp extends StatefulWidget {
  const MinePulseApp({super.key, required this.firebaseAvailable});

  final bool firebaseAvailable;

  @override
  State<MinePulseApp> createState() => _MinePulseAppState();
}

class _MinePulseAppState extends State<MinePulseApp> {
  FirebaseMessaging? _messaging;
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
  }

  Future<void> _initializeNotifications() async {
    if (!widget.firebaseAvailable) return;

    _messaging = FirebaseMessaging.instance;
    await _requestPermission();
    final token = await _messaging!.getToken();
    debugPrint('FCM token: $token');
    await _messaging!.subscribeToTopic('mine_alerts');
    await _subscribeToAlerts();

    if (!kIsWeb) {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: androidSettings);
      await _notifications.initialize(settings: settings);
    }

    FirebaseMessaging.onMessage.listen((message) {
      final title = message.notification?.title ?? 'Mine Safety Alert';
      final body = message.notification?.body ?? 'A new hazard event was detected.';
      if (!kIsWeb) {
        _showNotification(title, body);
      }
    });
  }

  Future<void> _requestPermission() async {
    if (_messaging == null) return;
    final settings = await _messaging!.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('Firebase messaging permission denied. Notifications may not appear.');
    }
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'mine_alert_channel',
      'Mine Alerts',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    const platformDetails = NotificationDetails(android: androidDetails);
    await _notifications.show(
      id: 0,
      title: title,
      body: body,
      notificationDetails: platformDetails,
    );
  }

  Future<void> _subscribeToAlerts() async {
    if (_messaging == null) return;
    await _messaging!.subscribeToTopic('mine_alerts');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mine Pulse',
      theme: ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF0057FF),
          secondary: Color(0xFFF5B700),
          surface: Color(0xFFFFFFFF),
          onPrimary: Colors.white,
          onSecondary: Colors.black,
          onSurface: Color(0xFF142A45),
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F8FF),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0057FF),
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        cardColor: const Color(0xFFFFFFFF),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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
          titleLarge: TextStyle(color: Color(0xFF142A45), fontWeight: FontWeight.w600),
        ),
      ),
      home: HomeScreen(firebaseAvailable: widget.firebaseAvailable),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.firebaseAvailable});

  final bool firebaseAvailable;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _emergencyNumber = '112';
  static const String _emergencySmsTemplate = 'Emergency at mine site. Please respond immediately.';

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
    if (position != null) {
      setState(() => _currentPosition = position);
    }
  }

  Future<Position?> _determinePosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _locationStatus = 'GPS is disabled. Enable device location for exact map placement.');
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        setState(() => _locationStatus = 'Location permission denied. Allow access in app settings.');
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      setState(() => _locationStatus = 'Phone located at ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}');
      return position;
    } catch (error) {
      setState(() => _locationStatus = 'Unable to determine current location: $error');
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
    final uri = Uri(scheme: 'sms', path: number, queryParameters: {'body': message});
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      return;
    }
    _showToast('Unable to open messaging app.');
  }


  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mine Pulse'),
        centerTitle: true,
      ),
      body: widget.firebaseAvailable ? _buildFirebaseBody() : _buildDemoBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openPhoneDialer(_emergencyNumber),
        backgroundColor: const Color(0xFF0057FF),
        icon: const Icon(Icons.warning),
        label: const Text('EMERGENCY SOS'),
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
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications_active), label: 'Alerts'),
          BottomNavigationBarItem(icon: Icon(Icons.device_hub), label: 'Nodes'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Analytics'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
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
        onEmergencySms: () => _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
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
                'Unable to load live mine data. Check your Firebase configuration and make sure the surface gateway is uploading telemetry.',
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
                Text(
                  'Connecting to Mine Pulse cloud telemetry...',
                  style: TextStyle(fontSize: 16),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data?.snapshot.value == null) {
          return _buildTabContent(
            [],
            [],
            dataLabel: 'No mine devices are connected currently.',
            currentPosition: _currentPosition,
            locationStatus: _locationStatus,
            onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
            onEmergencySms: () => _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
          );
        }

        final value = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
        final mines = value.entries.map((entry) {
          final mine = Map<String, dynamic>.from(entry.value as Map);
          return MineStatus(
            id: entry.key.toString(),
            mq4: mine['mq4']?.toString() ?? 'N/A',
            mq7: mine['mq7']?.toString() ?? 'N/A',
            water: mine['water']?.toString() ?? 'N/A',
            rssi: mine['rssi']?.toString() ?? 'N/A',
            battery: mine['battery']?.toString() ?? 'Unknown',
            active: mine['inAlert'] == true,
            latitude: mine['latitude'] is double ? mine['latitude'] as double : 37.7749,
            longitude: mine['longitude'] is double ? mine['longitude'] as double : -122.4194,
          );
        }).toList();

        final alerts = _generateAlerts(mines);
        return _buildTabContent(
          mines,
          alerts,
          dataLabel: 'Live Security Overview',
          currentPosition: _currentPosition,
          locationStatus: _locationStatus,
          onEmergencyCall: () => _openPhoneDialer(_emergencyNumber),
          onEmergencySms: () => _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
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
      onEmergencySms: () => _sendEmergencySms(_emergencyNumber, _emergencySmsTemplate),
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
        return NodesTab(mines: mines, demoMode: demoMode);
      case 3:
        return AnalyticsTab(alerts: alerts, mines: mines);
      case 4:
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
    final alerts = <AlertEvent>[];
    for (final mine in mines) {
      final mq4 = int.tryParse(mine.mq4.replaceAll(RegExp('[^0-9-]'), '')) ?? 0;
      final mq7 = int.tryParse(mine.mq7.replaceAll(RegExp('[^0-9-]'), '')) ?? 0;
      final rssi = int.tryParse(mine.rssi.replaceAll(RegExp('[^0-9-]'), '')) ?? 0;
      if (mq4 >= 35) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: 'Methane alarm',
          description: 'Methane levels exceeded safe limits at node ${mine.id}. Immediate evacuation and ventilation check required.',
          severity: AlertSeverity.critical,
        ));
      } else if (mq4 >= 25) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: 'Methane elevated',
          description: 'Methane levels are elevated at node ${mine.id}. Monitor closely and prepare to act.',
          severity: AlertSeverity.warning,
        ));
      }
      if (mq7 >= 18) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: 'Carbon monoxide alert',
          description: 'Carbon monoxide concentration is above normal levels at node ${mine.id}. Respiratory protection is advised.',
          severity: AlertSeverity.critical,
        ));
      }
      if (mine.water.toLowerCase() == 'high') {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: 'Water ingress detected',
          description: 'High water level reported at node ${mine.id}. Check drainage and avoid low-lying sections.',
          severity: AlertSeverity.warning,
        ));
      }
      if (rssi != 0 && rssi <= -80) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: 'Poor signal quality',
          description: 'Signal strength is weak at node ${mine.id}. Confirm gateway connectivity and replace antennas if necessary.',
          severity: AlertSeverity.info,
        ));
      }
      if (mine.active && alerts.where((alert) => alert.mineId == mine.id).isEmpty) {
        alerts.add(AlertEvent(
          mineId: mine.id,
          title: 'Active alert',
          description: 'Node ${mine.id} has reported an alert state. Investigate the source and follow emergency procedures.',
          severity: AlertSeverity.warning,
        ));
      }
    }
    if (alerts.isEmpty) {
      alerts.add(AlertEvent(
        mineId: 'system',
        title: 'All systems stable',
        description: 'No active hazards detected. Continue routine monitoring and maintain safe operations.',
        severity: AlertSeverity.safe,
      ));
    }
    return alerts;
  }
}

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
    final activeAlerts = alerts.where((item) => item.severity == AlertSeverity.critical || item.severity == AlertSeverity.warning).toList();
    final safeMines = mines.where((mine) => !mine.active).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFF),
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(color: Color(0x14000000), blurRadius: 20, offset: Offset(0, 10)),
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
                        const Text('Mine Pulse', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
                        const SizedBox(height: 6),
                        const Text('Operational mine safety monitoring with live alert visibility.', style: TextStyle(fontSize: 15, color: Color(0xFF586C8B))),
                        const SizedBox(height: 12),
                        Text(demoMode ? 'Demo mode: no live Firebase data.' : 'Connected to live monitoring.', style: const TextStyle(fontSize: 14, color: Color(0xFF3D5481))),
                        if (locationStatus != null) ...[
                          const SizedBox(height: 12),
                          Text(locationStatus!, style: const TextStyle(fontSize: 14, color: Color(0xFF3D5481))),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/dashboard_hero.png',
                  fit: BoxFit.cover,
                  height: 160,
                  width: double.infinity,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _SummaryCard(label: 'Active alerts', value: activeAlerts.length.toString(), color: activeAlerts.isNotEmpty ? const Color(0xFFFF5C5C) : const Color(0xFF57D27A)),
                  _SummaryCard(label: 'Safe nodes', value: safeMines.toString(), color: const Color(0xFF57D27A)),
                  _SummaryCard(label: 'Total nodes', value: mines.length.toString(), color: const Color(0xFF5C9BFF)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (mines.isEmpty)
          const Card(
            color: Color(0xFFFFFFFF),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No devices connected', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
                  SizedBox(height: 8),
                  Text('Your phone location is available on the Map tab. Live mine telemetry will appear here once your gateway and underground nodes connect.', style: TextStyle(color: Color(0xFF6E7A8C), fontSize: 15)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 18),
        EmergencyActionsCard(onCall: onEmergencyCall, onSms: onEmergencySms),
        const SizedBox(height: 22),
        if (activeAlerts.isNotEmpty) ...[
          const Text('Active Alerts', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          ...activeAlerts.take(3).map((alert) => AlertTile(alert: alert)),
        ] else
          Card(
            color: const Color(0xFFFFFFFF),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No active alerts detected. The mine network is stable or not yet connected.', style: TextStyle(color: Color(0xFF5D6E84), fontSize: 15)),
            ),
          ),
        const SizedBox(height: 22),
        const Text('Mine Telemetry', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        if (mines.isNotEmpty)
          ...mines.map((mine) => MineCard(status: mine))
        else
          Card(
            color: const Color(0xFFFFFFFF),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No telemetry records are available until underground nodes connect to the surface gateway.', style: TextStyle(color: Color(0xFF5D6E84), fontSize: 15)),
            ),
          ),
      ],
    );
  }
}

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
      final isAlert = alerts.any((alert) => alert.mineId == mine.id && alert.severity != AlertSeverity.safe);
      return Marker(
        width: 120,
        height: 110,
        point: LatLng(mine.latitude, mine.longitude),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isAlert ? Icons.location_on : Icons.location_on_outlined, color: isAlert ? Colors.redAccent : Colors.lightBlueAccent, size: 38),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const BoxDecoration(color: Color(0xFF0F1D2C), borderRadius: BorderRadius.all(Radius.circular(8))),
              child: Text('Node ${mine.id}', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ),
      );
    }).toList();

    if (currentPosition != null) {
      markers.add(
        Marker(
          width: 120,
          height: 110,
          point: LatLng(currentPosition!.latitude, currentPosition!.longitude),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.my_location, color: Color(0xFF57D27A), size: 38),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: const BoxDecoration(color: Color(0xFF0F1D2C), borderRadius: BorderRadius.all(Radius.circular(8))),
                child: const Text('You', style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 12.0),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.example.subterraguard',
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
                  const Expanded(child: Text('Live map shows your phone and mine node locations with real positioning.', style: TextStyle(color: Color(0xFF142A45)))),
                  IconButton(
                    icon: const Icon(Icons.my_location, color: Color(0xFF0057FF)),
                    tooltip: 'Refresh device location',
                    onPressed: () async => await onRefreshLocation(),
                  ),
                ],
              ),
              if (locationStatus != null) ...[
                const SizedBox(height: 8),
                Text(locationStatus!, style: const TextStyle(color: Color(0xFF3D5481), fontSize: 14)),
              ],
              const SizedBox(height: 8),
              const Text('Emergency actions are available in the Safety tab.', style: TextStyle(color: Color(0xFF3D5481))),
            ],
          ),
        ),
      ],
    );
  }
}

class AlertsTab extends StatelessWidget {
  const AlertsTab({super.key, required this.alerts, required this.mines, required this.demoMode});

  final List<AlertEvent> alerts;
  final List<MineStatus> mines;
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    final activeAlerts = alerts.where((item) => item.severity == AlertSeverity.critical || item.severity == AlertSeverity.warning).toList();
    final history = alerts.reversed.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Alert Center', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        if (demoMode)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF112A41), borderRadius: BorderRadius.circular(14)),
            child: const Text('Demo mode: These notifications represent how Mine Pulse surfaces warnings, hazards, and operational alerts.', style: TextStyle(color: Color(0xFFB0C5E2))),
          ),
        const SizedBox(height: 12),
        if (activeAlerts.isEmpty)
          const Text('All systems stable. No active danger alerts at this time.', style: TextStyle(fontSize: 16, color: Color(0xFF5D6E84))),
        ...activeAlerts.map((alert) => AlertTile(alert: alert)),
        const SizedBox(height: 18),
        ElevatedButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All active alerts acknowledged.')));
          },
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Acknowledge Alerts'),
        ),
        const SizedBox(height: 24),
        const Text('Alert History', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        ...history.take(5).map((alert) => Card(
              color: const Color(0xFFFFFFFF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(alert.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
                    const SizedBox(height: 6),
                    Text('Node ${alert.mineId} · ${alert.severity}', style: const TextStyle(color: Color(0xFF8FA6C0))),
                    const SizedBox(height: 8),
                    Text(alert.description, style: const TextStyle(color: Color(0xFF3D5481))),
                  ],
                ),
              ),
            )),
        const SizedBox(height: 24),
        const Text('SMS Alert Logs', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        ..._buildMessageFeed(),
      ],
    );
  }

  List<Widget> _buildMessageFeed() {
    final messages = [
      'SMS sent to control center: A1 methane warning.',
      'SMS delivered to rescue team: Node B2 status update.',
      'Supervisor acknowledged the last alert at 14:12.',
    ];
    return messages
        .map((message) => Card(
              color: const Color(0xFFFFFFFF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(message, style: const TextStyle(fontSize: 16, color: Color(0xFF3D5481))),
              ),
            ))
        .toList();
  }
}

class NodesTab extends StatelessWidget {
  const NodesTab({super.key, required this.mines, required this.demoMode});

  final List<MineStatus> mines;
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Node Monitoring', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        if (demoMode)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF112A41), borderRadius: BorderRadius.circular(14)),
            child: const Text('Demo mode active. These nodes display sample telemetry for Mine Pulse monitoring.', style: TextStyle(color: Color(0xFFB0C5E2))),
          ),
        const SizedBox(height: 14),
        ...mines.map((mine) => _NodeStatusCard(node: mine)),
      ],
    );
  }
}

class _NodeStatusCard extends StatelessWidget {
  const _NodeStatusCard({required this.node});

  final MineStatus node;

  Color get batteryColor {
    final batteryLevel = int.tryParse(node.battery.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
    if (batteryLevel >= 75) return const Color(0xFF57D27A);
    if (batteryLevel >= 40) return const Color(0xFFFFC107);
    return const Color(0xFFFF5C5C);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Node ${node.id.toUpperCase()}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
                Chip(
                  backgroundColor: node.active ? const Color(0xFFFF5C5C) : const Color(0xFF57D27A),
                  label: Text(node.active ? 'ALERT' : 'SAFE', style: const TextStyle(color: Colors.white)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Methane: ${node.mq4} ppm', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 6),
            Text('Carbon monoxide: ${node.mq7} ppm', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 6),
            Text('Water level: ${node.water}', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 6),
            Text('Signal RSSI: ${node.rssi} dBm', style: const TextStyle(fontSize: 16, color: Color(0xFF5D6E84))),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('Battery: ${node.battery}', style: TextStyle(fontSize: 16, color: batteryColor, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Flexible(child: Text('Position: ${node.latitude.toStringAsFixed(4)}, ${node.longitude.toStringAsFixed(4)}', style: const TextStyle(fontSize: 14, color: Color(0xFF5D6E84)))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AnalyticsTab extends StatelessWidget {
  const AnalyticsTab({super.key, required this.alerts, required this.mines});

  final List<AlertEvent> alerts;
  final List<MineStatus> mines;

  @override
  Widget build(BuildContext context) {
    final critical = alerts.where((alert) => alert.severity == AlertSeverity.critical).length;
    final warning = alerts.where((alert) => alert.severity == AlertSeverity.warning).length;
    final info = alerts.where((alert) => alert.severity == AlertSeverity.info).length;
    final total = alerts.length;
    final methaneAlerts = alerts.where((alert) => alert.title.toLowerCase().contains('methane')).length;
    final carbonAlerts = alerts.where((alert) => alert.title.toLowerCase().contains('carbon')).length;
    final waterAlerts = alerts.where((alert) => alert.title.toLowerCase().contains('water')).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Analytics', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('Real-time graphs and key trends for the mine safety network.', style: TextStyle(fontSize: 16, color: Color(0xFFB0C5E2))),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(child: _SummaryCard(label: 'Critical', value: critical.toString(), color: const Color(0xFFFF5C5C))),
            Expanded(child: _SummaryCard(label: 'Warning', value: warning.toString(), color: const Color(0xFFFFC107))),
            Expanded(child: _SummaryCard(label: 'Info', value: info.toString(), color: const Color(0xFF5C9BFF))),
          ],
        ),
        const SizedBox(height: 22),
        const Text('Alert Trends', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _TrendBar(label: 'Methane', value: methaneAlerts, color: const Color(0xFFFF7043)),
        _TrendBar(label: 'Carbon Monoxide', value: carbonAlerts, color: const Color(0xFF42A5F5)),
        _TrendBar(label: 'Water', value: waterAlerts, color: const Color(0xFF66BB6A)),
        const SizedBox(height: 22),
        const Text('Node Signal Distribution', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ...mines.map((mine) => _SignalTrendRow(node: mine)),
        const SizedBox(height: 22),
        const Text('Activity Summary', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Card(
          color: const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Weekly reports estimate network performance and alert patterns using current telemetry.', style: TextStyle(color: Color(0xFF5D6E84))),
                const SizedBox(height: 14),
                Text('Tracked nodes: ${mines.length}', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
                const SizedBox(height: 6),
                Text('Total alerts: $total', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.onEmergencyCall, required this.onEmergencySms, this.userEmail, this.onSignOut});

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
  final TextEditingController _emergencyNumberController = TextEditingController(text: '112');
  final TextEditingController _methaneThresholdController = TextEditingController(text: '35');
  final TextEditingController _coThresholdController = TextEditingController(text: '18');

  @override
  void dispose() {
    _emergencyNumberController.dispose();
    _methaneThresholdController.dispose();
    _coThresholdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('System Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _SettingsSection(
          title: 'Alert Thresholds',
          children: [
            TextField(
              controller: _methaneThresholdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Methane threshold (ppm)',
                filled: true,
                fillColor: Color(0xFFF4F8FF),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _coThresholdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'CO threshold (ppm)',
                filled: true,
                fillColor: Color(0xFFF4F8FF),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: 'Emergency Contacts',
          children: [
            TextField(
              controller: _emergencyNumberController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Primary SMS number',
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
                    label: const Text('Quick SOS'),
                    onPressed: widget.onEmergencyCall,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.message),
                    label: const Text('Send SMS'),
                    onPressed: widget.onEmergencySms,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: 'Operational Controls',
          children: [
            SwitchListTile(
              title: const Text('Push notifications'),
              value: _pushAlerts,
              onChanged: (value) => setState(() => _pushAlerts = value),
            ),
            SwitchListTile(
              title: const Text('SMS alerts'),
              value: _smsAlerts,
              onChanged: (value) => setState(() => _smsAlerts = value),
            ),
            SwitchListTile(
              title: const Text('Live map updates'),
              value: _liveMap,
              onChanged: (value) => setState(() => _liveMap = value),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: 'Account',
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
                  messenger.showSnackBar(const SnackBar(content: Text('Signed out successfully.')));
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _TrendBar extends StatelessWidget {
  const _TrendBar({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            Text(value.toString(), style: const TextStyle(color: Color(0xFF5D6E84), fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 12,
          decoration: BoxDecoration(color: const Color(0xFFE6F0FF), borderRadius: BorderRadius.circular(8)),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value > 0 ? (value / (value + 5)).clamp(0.1, 1.0) : 0.05,
            child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8))),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _SignalTrendRow extends StatelessWidget {
  const _SignalTrendRow({required this.node});

  final MineStatus node;

  @override
  Widget build(BuildContext context) {
    final rssi = int.tryParse(node.rssi.replaceAll(RegExp('[^0-9-]'), '')) ?? -100;
    final signalStrength = ((rssi + 120) / 60).clamp(0.0, 1.0);
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Node ${node.id.toUpperCase()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('Signal quality: ${node.rssi} dBm', style: const TextStyle(color: Color(0xFF5D6E84))),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: signalStrength, color: const Color(0xFF5C9BFF), backgroundColor: const Color(0xFFE6F0FF)),
          ],
        ),
      ),
    );
  }
}

class EmergencyActionsCard extends StatelessWidget {
  const EmergencyActionsCard({super.key, required this.onCall, required this.onSms});

  final VoidCallback onCall;
  final VoidCallback onSms;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Emergency Contact', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
            const SizedBox(height: 10),
            const Text('Use the emergency call or message actions below to notify surface command and rescue teams immediately.', style: TextStyle(fontSize: 16, color: Color(0xFF5D6E84))),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.call),
                    label: const Text('Call'),
                    onPressed: onCall,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.message),
                    label: const Text('Message'),
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
  const _SummaryCard({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withAlpha((color.a * 255.0 * 0.16).round().clamp(0, 255)), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF142A45), fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class AlertEvent {
  AlertEvent({required this.mineId, required this.title, required this.description, required this.severity});

  final String mineId;
  final String title;
  final String description;
  final String severity;
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 22),
                const SizedBox(width: 10),
                Expanded(child: Text(alert.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45)))),
              ],
            ),
            const SizedBox(height: 8),
            Text('Node: ${alert.mineId}', style: const TextStyle(color: Color(0xFF5D6E84))),
            const SizedBox(height: 8),
            Text(alert.description, style: const TextStyle(fontSize: 15, color: Color(0xFF142A45))),
          ],
        ),
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
  });

  final String id;
  final String mq4;
  final String mq7;
  final String water;
  final String rssi;
  final String battery;
  final bool active;
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Mine ${status.id.toUpperCase()}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF142A45))),
                Chip(
                  backgroundColor: status.active ? const Color(0xFFFF5C5C) : const Color(0xFF57D27A),
                  label: Text(status.active ? 'ALERT' : 'SAFE', style: const TextStyle(color: Colors.white)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Methane: ${status.mq4} ppm', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('Carbon monoxide: ${status.mq7} ppm', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('Water level: ${status.water}', style: const TextStyle(fontSize: 16, color: Color(0xFF142A45))),
            const SizedBox(height: 8),
            Text('Signal RSSI: ${status.rssi} dBm', style: const TextStyle(color: Color(0xFF5D6E84))),
            const SizedBox(height: 8),
            Text('Battery: ${status.battery}', style: const TextStyle(fontSize: 16, color: Color(0xFF57D27A))),
          ],
        ),
      ),
    );
  }
}
