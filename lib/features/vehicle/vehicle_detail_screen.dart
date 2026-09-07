import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/models.dart';
import '../../shared/widgets/fleet_widgets.dart';
import 'dismiss_sheet.dart';

class VehicleDetailScreen extends ConsumerWidget {
  const VehicleDetailScreen({super.key, required this.vehicleId});

  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(vehicleDetailProvider(vehicleId));
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(title: 'Missing vehicle', body: e.toString()),
        data: (data) => _Body(data: data),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.data});

  final VehicleDetailData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = data.vehicle;
    final now = DateTime.now().toUtc();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.regNumber, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  Text(v.model, style: const TextStyle(color: FleetTheme.muted)),
                ],
              ),
            ),
            StatusChip(status: v.status),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          v.currentGeofenceName == null
              ? 'Outside every active geofence'
              : 'Now in ${v.currentGeofenceName}',
          style: const TextStyle(color: FleetTheme.accent),
        ),
        const SizedBox(height: 20),
        const Text('Readings register', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        for (final row in data.register) _RegisterRow(row: row, now: now),
        const SizedBox(height: 20),
        const Text('SOC history', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        SizedBox(height: 160, child: _SocChart(points: data.spark)),
        const SizedBox(height: 20),
        const Text('Open alerts', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        if (data.alerts.isEmpty)
          const Text('None', style: TextStyle(color: FleetTheme.muted))
        else
          for (final alert in data.alerts)
            _AlertCard(
              alert: alert,
              onDismiss: () => _dismiss(context, ref, alert),
            ),
        const SizedBox(height: 20),
        const Text('Trips', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        if (data.trips.isEmpty)
          const Text(
            'No confirmed geofence transitions yet.',
            style: TextStyle(color: FleetTheme.muted),
          )
        else
          for (final trip in data.trips) _TripTile(trip: trip),
      ],
    );
  }

  Future<void> _dismiss(
    BuildContext context,
    WidgetRef ref,
    VehicleAlert alert,
  ) async {
    final reason = await showDismissReasonSheet(context);
    if (reason == null) return;
    await ref.read(repositoryProvider).dismissAlert(alertId: alert.id, reason: reason);
    bumpRefresh(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: FleetRules.undoWindow,
        content: Text('Alert dismissed · $reason'),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            await ref.read(repositoryProvider).undoDismiss(alert.id);
            bumpRefresh(ref);
          },
        ),
      ),
    );
  }
}

class _RegisterRow extends StatelessWidget {
  const _RegisterRow({required this.row, required this.now});

  final SignalReading row;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final valueText = _format(row);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: FleetTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: FleetTheme.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.label, style: const TextStyle(color: FleetTheme.muted, fontSize: 12)),
                const SizedBox(height: 2),
                Text(valueText, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          AgeLabel(at: row.eventTime, now: now),
          const SizedBox(width: 8),
          if (row.verdict != null) VerdictPill(verdict: row.verdict!),
        ],
      ),
    );
  }

  String _format(SignalReading row) {
    if (row.value == null) return '—';
    if (row.signal == 'last_ping') {
      return DateFormat('HH:mm:ss').format(row.eventTime!.toLocal());
    }
    final n = row.value!;
    final shown = n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);
    return row.unit.isEmpty ? shown : '$shown ${row.unit}';
  }
}

class _SocChart extends StatelessWidget {
  const _SocChart({required this.points});

  final List<SocPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return const EmptyState(
        title: 'Not enough SOC history',
        body: 'The event log will fill this sparkline as packets arrive.',
        icon: Icons.show_chart,
      );
    }
    final spots = [
      for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].soc),
    ];
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: 100,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: FleetTheme.accent,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: FleetTheme.accent.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onDismiss});

  final VehicleAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = alert.severity == AlertSeverity.critical
        ? FleetTheme.critical
        : FleetTheme.warning;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(alert.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  alert.severity.name.toUpperCase(),
                  style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
        ],
      ),
    );
  }
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final origin = trip.originName ?? trip.originGeofenceId;
    final dest = trip.destName ?? trip.destGeofenceId ?? '—';
    final inProgress = trip.status == TripStatus.inProgress;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        inProgress ? Icons.route : Icons.flag,
        color: inProgress ? FleetTheme.accent : FleetTheme.moving,
      ),
      title: Text('$origin → $dest'),
      subtitle: Text(
        inProgress
            ? 'IN PROGRESS · started ${DateFormat('HH:mm').format(trip.startedAt.toLocal())}'
            : 'COMPLETED · ${DateFormat('HH:mm').format(trip.startedAt.toLocal())}–${DateFormat('HH:mm').format(trip.endedAt!.toLocal())}',
      ),
    );
  }
}
