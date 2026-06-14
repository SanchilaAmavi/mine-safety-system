import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mine_pulse/main.dart';

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
    final activeAlerts = alerts
        .where((item) =>
            item.severity == AlertSeverity.critical ||
            item.severity == AlertSeverity.warning)
        .toList();
    // ignore: unused_local_variable
    final onlineDevices = mines.where((mine) => mine.online).length;
    final safeDevices = mines.where((mine) => !mine.active).length;
    final lastUpdated = TimeOfDay.now().format(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        // ── Brand header ──
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset('assets/favicon.jpeg', width: 36, height: 36, fit: BoxFit.cover),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Mine Pulse',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: MPColors.text, letterSpacing: -0.5)),
            ),
            Row(
              children: [
                Container(
                  width: 9, height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: demoMode ? MPColors.warning : MPColors.success,
                  ),
                ),
                const SizedBox(width: 6),
                Text(demoMode ? 'Connecting…' : 'Live',
                    style: const TextStyle(fontSize: 12, color: MPColors.muted)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),

        // ── Metrics row (matches web's metric-card grid) ──
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: 'ACTIVE ALERTS',
                value: activeAlerts.length.toString(),
                sub: 'Nodes in alert state',
                color: MPColors.danger,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MetricCard(
                label: 'SAFE NODES',
                value: safeDevices.toString(),
                sub: 'Operating normally',
                color: MPColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: 'TOTAL NODES',
                value: mines.length.toString(),
                sub: 'Connected to gateway',
                color: MPColors.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MetricCard(
                label: 'LAST UPDATED',
                value: lastUpdated,
                sub: 'Refreshed automatically',
                color: MPColors.accent,
                valueFontSize: 18,
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),

        // ── Live Node Status (section title + node cards) ──
        const _SectionTitle('LIVE NODE STATUS'),
        const SizedBox(height: 10),
        if (mines.isEmpty)
          _EmptyPanel(
            title: 'No devices connected',
            message:
                'Live mine telemetry will appear here once your gateway and underground nodes connect.',
          )
        else
          ...mines.map((mine) => MineCard(status: mine)),

        const SizedBox(height: 24),

        // ── Active Alerts ──
        const _SectionTitle('🚨 ACTIVE ALERTS'),
        const SizedBox(height: 10),
        if (activeAlerts.isEmpty)
          _EmptyPanel(
            title: 'All systems stable',
            message: '✅ No active alerts — all mines operating normally.',
            success: true,
          )
        else
          ...activeAlerts.map((alert) => AlertTile(alert: alert)),

        const SizedBox(height: 24),

        // ── Emergency actions ──
        EmergencyActionsCard(onCall: onEmergencyCall, onSms: onEmergencySms),
      ],
    );
  }
}

class MPColors {
  static const Color surface = Color(0xFFFFFFFF);
  static const Color accent = Color(0xFF0057FF);
  static const Color muted = Color(0xFF6E7A8C);
  static const Color border = Color(0xFFE5ECF6);
  static const Color success = Color(0xFF57D27A);
  static const Color danger = Color(0xFFFF5C5C);
  static const Color warning = Color(0xFFFFC107);
  static const Color text = Color(0xFF142A45);
  static const Color ch4 = Color(0xFFFF7043);
  static const Color co = Color(0xFF42A5F5);
  static const Color water = Color(0xFF66BB6A);
  static const Color dangerSoft = Color(0xFFFFEBEE);
  static const Color successSoft = Color(0xFFE8F8EE);
  static const Color warningSoft = Color(0xFFFFF4E5);
}

/// Metric card matching web dashboard's `.metric-card` style.
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
    this.valueFontSize = 28,
  });

  final String label;
  final String value;
  final String sub;
  final Color color;
  final double valueFontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MPColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MPColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: MPColors.muted)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: valueFontSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: color)),
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(fontSize: 11, color: MPColors.muted)),
        ],
      ),
    );
  }
}

/// Section title matching web dashboard's `.section-title` (uppercase, muted).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: MPColors.muted,
      ),
    );
  }
}

/// Empty state panel matching web's `.empty-state`.
class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.title, required this.message, this.success = false});

  final String title;
  final String message;
  final bool success;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: MPColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MPColors.border),
      ),
      child: Column(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: success ? MPColors.success : MPColors.text)),
          const SizedBox(height: 6),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: MPColors.muted)),
        ],
      ),
    );
  }
}