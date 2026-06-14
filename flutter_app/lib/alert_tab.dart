import 'package:flutter/material.dart';
import 'package:mine_pulse/main.dart';

class MPColors {
  static const Color surface = Color(0xFFFFFFFF);
  static const Color accent = Color(0xFF0057FF);
  static const Color muted = Color(0xFF6E7A8C);
  static const Color border = Color(0xFFE5ECF6);
  static const Color success = Color(0xFF57D27A);
  static const Color danger = Color(0xFFFF5C5C);
  static const Color warning = Color(0xFFFFC107);
  static const Color text = Color(0xFF142A45);
}

class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.alert, this.timeLabel});

  final AlertEvent alert;
  final String? timeLabel;

  Color get _accent {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return MPColors.danger;
      case AlertSeverity.warning:
        return MPColors.warning;
      case AlertSeverity.safe:
        return MPColors.success;
      default:
        return MPColors.accent;
    }
  }

  String get _icon {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return '🚨';
      case AlertSeverity.warning:
        return '⚠️';
      case AlertSeverity.safe:
        return '✅';
      default:
        return 'ℹ️';
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _showDetail(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: MPColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MPColors.border),
          // left accent stripe, like web's border-left
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 40,
              decoration: BoxDecoration(color: _accent, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 12),
            Text(_icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(alert.title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: MPColors.text)),
                  const SizedBox(height: 2),
                  Text('Node ${alert.mineId} · ${alert.description}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: MPColors.muted)),
                ],
              ),
            ),
            if (timeLabel != null) ...[
              const SizedBox(width: 8),
              Text(timeLabel!, style: const TextStyle(fontSize: 11, color: MPColors.muted)),
            ],
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(alert.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Node: ${alert.mineId}'),
            const SizedBox(height: 8),
            Text(alert.description),
            const SizedBox(height: 8),
            Text('Severity: ${alert.severity}'),
            const SizedBox(height: 6),
            const Text(
              'Action: Check the node, confirm the hazard level, and dispatch the response team if needed.',
            ),
          ],
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
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERTS TAB — Active Alerts + Alert History (matches web dashboard split)
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

    // History = everything else (including resolved/info/safe), reversed for newest-first feel
    final history = alerts.where((item) => item.severity != AlertSeverity.safe).toList().reversed.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        const Text('Alert Center',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: MPColors.text)),
        const SizedBox(height: 16),

        // ── Active Alerts ──
        const Text('🚨 ACTIVE ALERTS',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: MPColors.muted)),
        const SizedBox(height: 10),
        if (activeAlerts.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: MPColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: MPColors.border),
            ),
            child: const Column(
              children: [
                Text('All systems stable',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: MPColors.success)),
                SizedBox(height: 6),
                Text('✅ No active alerts — all mines operating normally.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: MPColors.muted)),
              ],
            ),
          )
        else
          ...activeAlerts.map((alert) => AlertTile(alert: alert, timeLabel: 'LIVE')),

        const SizedBox(height: 24),

        // ── Alert History ──
        const Text('ALERT HISTORY',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: MPColors.muted)),
        const SizedBox(height: 10),
        if (history.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: MPColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: MPColors.border),
            ),
            child: const Text('No historical alerts recorded yet.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: MPColors.muted)),
          )
        else
          ...history.take(10).map((alert) => AlertTile(alert: alert)),
      ],
    );
  }
}