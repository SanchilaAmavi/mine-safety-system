import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  bool firebaseAvailable = true;

  try {
    await Firebase.initializeApp();
  } catch (error) {
    firebaseAvailable = false;
    debugPrint('Firebase initialization failed: $error');
  }

  runApp(SubterraGuardApp(firebaseAvailable: firebaseAvailable));
}

class SubterraGuardApp extends StatefulWidget {
  const SubterraGuardApp({super.key, required this.firebaseAvailable});

  final bool firebaseAvailable;

  @override
  State<SubterraGuardApp> createState() => _SubterraGuardAppState();
}

class _SubterraGuardAppState extends State<SubterraGuardApp> {
  FirebaseMessaging? _messaging;
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
    if (widget.firebaseAvailable) {
      _messaging = FirebaseMessaging.instance;
      _subscribeToAlerts();
    }
  }

  Future<void> _initializeNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(settings: settings);

    FirebaseMessaging.onMessage.listen((message) {
      final title = message.notification?.title ?? 'Mine Safety Alert';
      final body = message.notification?.body ?? 'A new hazard event was detected.';
      _showNotification(title, body);
    });
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
      title: 'SubterraGuard Pro',
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFF5B700),
          secondary: Color(0xFF57D27A),
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
  int _selectedIndex = 0;
  DatabaseReference? statusRef;

  @override
  void initState() {
    super.initState();
    if (widget.firebaseAvailable) {
      statusRef = FirebaseDatabase.instance.ref('status');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SubterraGuard Pro'),
        centerTitle: true,
      ),
      body: widget.firebaseAvailable ? _buildFirebaseBody() : _buildDemoBody(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        selectedItemColor: const Color(0xFFF5B700),
        unselectedItemColor: Colors.white70,
        backgroundColor: const Color(0xFF08121F),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.warning), label: 'Alerts'),
          BottomNavigationBarItem(icon: Icon(Icons.shield), label: 'Safety'),
        ],
        onTap: (index) => setState(() => _selectedIndex = index),
      ),
    );
  }

  Widget _buildFirebaseBody() {
    if (statusRef == null) {
      return _buildEmptyState();
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
                  'Connecting to SubterraGuard cloud telemetry...',
                  style: TextStyle(fontSize: 16),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data?.snapshot.value == null) {
          return _buildEmptyState();
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
            active: mine['inAlert'] == true,
            latitude: mine['latitude'] is double ? mine['latitude'] as double : 37.7749,
            longitude: mine['longitude'] is double ? mine['longitude'] as double : -122.4194,
          );
        }).toList();

        final alerts = _generateAlerts(mines);
        return _buildTabContent(mines, alerts, dataLabel: 'Live Security Overview');
      },
    );
  }

  Widget _buildDemoBody() {
    final sampleMines = [
      MineStatus(id: 'A1', mq4: '12', mq7: '8', water: 'Low', rssi: '-72', active: false, latitude: 37.4217, longitude: -122.0840),
      MineStatus(id: 'B2', mq4: '48', mq7: '24', water: 'High', rssi: '-61', active: true, latitude: 37.4275, longitude: -122.1697),
    ];
    final alerts = _generateAlerts(sampleMines);
    return _buildTabContent(sampleMines, alerts, dataLabel: 'Demo Mode Overview', demoMode: true);
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.info_outline, size: 64, color: Color(0xFFF5B700)),
            SizedBox(height: 16),
            Text(
              'No mine telemetry found yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            Text(
              'Make sure your surface gateway is powered on and connected to Firebase. Once your underground nodes send data, the live status will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(List<MineStatus> mines, List<AlertEvent> alerts, {required String dataLabel, bool demoMode = false}) {
    switch (_selectedIndex) {
      case 0:
        return DashboardTab(mines: mines, alerts: alerts, dataLabel: dataLabel, demoMode: demoMode);
      case 1:
        return MapTab(mines: mines, alerts: alerts);
      case 2:
        return AlertsTab(alerts: alerts, mines: mines, demoMode: demoMode);
      default:
        return const SafetyTab();
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
  const DashboardTab({super.key, required this.mines, required this.alerts, required this.dataLabel, required this.demoMode});

  final List<MineStatus> mines;
  final List<AlertEvent> alerts;
  final String dataLabel;
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    final activeAlerts = alerts.where((item) => item.severity == AlertSeverity.critical || item.severity == AlertSeverity.warning).length;
    final safeMines = mines.where((mine) => !mine.active).length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          decoration: BoxDecoration(color: const Color(0xFF112135), borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dataLabel, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(demoMode ? 'Demo mode: no live Firebase data.' : 'Connected to live monitoring.', style: const TextStyle(fontSize: 14, color: Color(0xFF8FA6C0))),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SummaryCard(label: 'Active alerts', value: activeAlerts.toString(), color: activeAlerts > 0 ? const Color(0xFFFF5C5C) : const Color(0xFF57D27A)),
                  _SummaryCard(label: 'Safe nodes', value: safeMines.toString(), color: const Color(0xFF57D27A)),
                  _SummaryCard(label: 'Total nodes', value: mines.length.toString(), color: const Color(0xFF5C9BFF)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text('Critical Alerts', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        ...alerts.take(3).map((alert) => AlertTile(alert: alert)),
        const SizedBox(height: 22),
        const Text('Mine Telemetry', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        ...mines.map((mine) => MineCard(status: mine)),
      ],
    );
  }
}

class MapTab extends StatelessWidget {
  const MapTab({super.key, required this.mines, required this.alerts});

  final List<MineStatus> mines;
  final List<AlertEvent> alerts;

  @override
  Widget build(BuildContext context) {
    final center = mines.isNotEmpty
        ? LatLng(mines.first.latitude, mines.first.longitude)
        : LatLng(37.4275, -122.1697);

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
              MarkerLayer(
                markers: mines.map((mine) {
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
                          decoration: BoxDecoration(color: const Color(0xFF0F1D2C), borderRadius: BorderRadius.circular(8)),
                          child: Text('Node ${mine.id}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        Container(
          color: const Color(0xFF08121F),
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('Map shows active node locations and hazard markers.', style: TextStyle(color: Colors.white70)),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Alert Center', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        if (demoMode)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF112A41), borderRadius: BorderRadius.circular(14)),
            child: const Text('Demo mode: These notifications represent how SubterraGuard surfaces warnings, hazards, and operational alerts.', style: TextStyle(color: Color(0xFFB0C5E2))),
          ),
        const SizedBox(height: 12),
        ...alerts.map((alert) => AlertTile(alert: alert)),
        const SizedBox(height: 24),
        const Text('Message Feed', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        ..._buildMessageFeed(),
      ],
    );
  }

  List<Widget> _buildMessageFeed() {
    final messages = [
      'Surface command confirmed connection to underground node A1.',
      'Scheduled safety inspection due in 12 minutes at shaft access point.',
      'Alert notification created for elevated methane in section B2.',
      'Emergency ventilation protocols are ready for deployment.',
    ];
    return messages
        .map((message) => Card(
              color: const Color(0xFF111A28),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(message, style: const TextStyle(fontSize: 16, color: Colors.white70)),
              ),
            ))
        .toList();
  }
}

class SafetyTab extends StatelessWidget {
  const SafetyTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Safety Methods', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        const Text('SubterraGuard guides operators through hazard detection, response, and post-incident review with clear procedures.', style: TextStyle(fontSize: 16, color: Color(0xFFB0C5E2))),
        const SizedBox(height: 18),
        _SafetyCard(
          title: 'Alert Detection',
          description: 'Monitor methane, carbon monoxide, water ingress, and signal quality continuously. Auto-generated alerts show the most critical risks first.',
        ),
        _SafetyCard(
          title: 'Response Actions',
          description: 'When an alert appears, stop operations in the affected sector, move personnel to safe zones, and confirm ventilation status before resuming work.',
        ),
        _SafetyCard(
          title: 'Communication',
          description: 'Use the message feed and alert center to notify field teams and surface control immediately when a hazard is detected.',
        ),
        _SafetyCard(
          title: 'Recovery',
          description: 'Document each incident, verify that sensors return to safe ranges, and restore equipment only after a formal clearance check.',
        ),
      ],
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
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: color.withAlpha((color.a * 255.0 * 0.16).round().clamp(0, 255)), borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
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
        ? const Color(0xFF3A121E)
        : alert.severity == AlertSeverity.warning
            ? const Color(0xFF3D2E10)
            : const Color(0xFF112135);
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
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(width: 10),
                Expanded(child: Text(alert.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              ],
            ),
            const SizedBox(height: 8),
            Text('Node: ${alert.mineId}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Text(alert.description, style: const TextStyle(fontSize: 15, color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF111A28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(description, style: const TextStyle(fontSize: 16, color: Colors.white70)),
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
    required this.active,
    this.latitude = 37.4275,
    this.longitude = -122.1697,
  });

  final String id;
  final String mq4;
  final String mq7;
  final String water;
  final String rssi;
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
      color: const Color(0xFF111A28),
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
                Text('Mine ${status.id.toUpperCase()}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Chip(
                  backgroundColor: status.active ? const Color(0xFFFF5C5C) : const Color(0xFF57D27A),
                  label: Text(status.active ? 'ALERT' : 'SAFE'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Methane: ${status.mq4} ppm', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text('Carbon monoxide: ${status.mq7} ppm', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text('Water level: ${status.water}', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text('Signal RSSI: ${status.rssi} dBm', style: const TextStyle(color: Color(0xFF8FA6C0))),
          ],
        ),
      ),
    );
  }
}
