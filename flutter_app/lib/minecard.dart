import 'package:flutter/material.dart';
import 'package:mine_pulse/main.dart';

class MineCard extends StatelessWidget {
  const MineCard({super.key, required this.status});
  final MineStatus status;

  @override
  Widget build(BuildContext context) {
    final inAlert = status.active;
    final badgeColor = inAlert
        ? const Color(0xFFFF5C5C)
        : status.online
            ? const Color(0xFF57D27A)
            : const Color(0xFFFFC107);
    final badgeBg = inAlert
        ? const Color(0xFFFFEBEE)
        : status.online
            ? const Color(0xFFE8F8EE)
            : const Color(0xFFFFF4E5);
    final badgeLabel = inAlert ? 'ALERT' : (status.online ? 'ONLINE' : 'OFFLINE');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: inAlert ? const Color(0xFFFF5C5C) : const Color(0xFFE5ECF6),
          width: inAlert ? 1.4 : 1,
        ),
        boxShadow: inAlert
            ? [const BoxShadow(color: Color(0x1AFF5C5C), blurRadius: 18, offset: Offset(0, 6))]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status.id.toUpperCase(),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF142A45))),
                    const SizedBox(height: 3),
                    Text(
                      'Live telemetry · ${status.online ? 'Gateway connected' : 'Standby / offline'}',
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF6E7A8C)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(badgeLabel,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: badgeColor)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Sensor rows
          _SensorRow(dotColor: const Color(0xFFFF7043), label: 'Methane (MQ-4)', value: '${status.mq4} ppm'),
          _SensorRow(dotColor: const Color(0xFF42A5F5), label: 'CO (MQ-7)', value: '${status.mq7} ppm'),
          _SensorRow(dotColor: const Color(0xFF66BB6A), label: 'Water level', value: status.water),
          _SensorRow(dotColor: const Color(0xFF0057FF), label: 'RSSI', value: '${status.rssi} dBm'),
          _SensorRow(dotColor: const Color(0xFF57D27A), label: 'Battery', value: status.battery),

          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE5ECF6))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Updated', style: TextStyle(fontSize: 11, color: Color(0xFF6E7A8C))),
                Text(
                  '${status.latitude.toStringAsFixed(4)}, ${status.longitude.toStringAsFixed(4)}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6E7A8C), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sensor row matching web's `.sensor-row` (colored dot + label + value).
class _SensorRow extends StatelessWidget {
  const _SensorRow({required this.dotColor, required this.label, required this.value});

  final Color dotColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF6E7A8C))),
            ],
          ),
          Text(value,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF142A45))),
        ],
      ),
    );
  }
}