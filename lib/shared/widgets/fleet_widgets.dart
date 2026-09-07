import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/models.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final VehicleStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      VehicleStatus.offline => ('OFFLINE', FleetTheme.offline),
      VehicleStatus.moving => ('MOVING', FleetTheme.moving),
      VehicleStatus.idle => ('IDLE', FleetTheme.idle),
      VehicleStatus.stopped => ('STOPPED', FleetTheme.stopped),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class VerdictPill extends StatelessWidget {
  const VerdictPill({super.key, required this.verdict});

  final SignalVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (verdict) {
      SignalVerdict.normal => ('NORMAL', FleetTheme.moving),
      SignalVerdict.alert => ('ALERT', FleetTheme.critical),
      SignalVerdict.stale => ('STALE', FleetTheme.offline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AgeLabel extends StatelessWidget {
  const AgeLabel({super.key, required this.at, required this.now});

  final DateTime? at;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    if (at == null) {
      return const Text('—', style: TextStyle(color: FleetTheme.muted, fontSize: 12));
    }
    final d = now.difference(at!.toUtc());
    final text = d.inMinutes < 1
        ? '${d.inSeconds}s ago'
        : d.inHours < 1
            ? '${d.inMinutes}m ago'
            : d.inDays < 1
                ? '${d.inHours}h ago'
                : DateFormat('dd MMM HH:mm').format(at!.toLocal());
    return Text(text, style: const TextStyle(color: FleetTheme.muted, fontSize: 12));
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.icon = Icons.local_shipping_outlined,
  });

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: FleetTheme.muted),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: FleetTheme.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: const TextStyle(color: FleetTheme.muted, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
