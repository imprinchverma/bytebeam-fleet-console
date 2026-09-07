import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/seed/backfill.dart';
import '../../data/seed/seed_service.dart';
import '../../domain/models.dart';
import '../../shared/widgets/fleet_widgets.dart';

class FleetHomeScreen extends ConsumerWidget {
  const FleetHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(fleetSnapshotProvider);
    final filter = ref.watch(fleetFilterProvider);
    final sim = ref.watch(simulatorProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Console'),
        actions: [
          IconButton(
            tooltip: 'Geofences',
            onPressed: () => context.push('/geofences'),
            icon: const Icon(Icons.radar_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) => _onMenu(context, ref, value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'seed', child: Text('Reseed demo fleet')),
              PopupMenuItem(value: 'tick', child: Text('Ingest one live packet')),
              PopupMenuItem(value: 'sim', child: Text('Toggle live simulator')),
              PopupMenuItem(value: 'backfill', child: Text('Backfill 500 vehicles / 2M rows')),
              PopupMenuItem(value: 'compact', child: Text('Run retention compact')),
            ],
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          title: 'Could not read DuckDB',
          body: e.toString(),
          icon: Icons.error_outline,
        ),
        data: (snap) {
          return RefreshIndicator(
            onRefresh: () async => bumpRefresh(ref),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sim.running
                              ? 'Live ingest on  ·  last ${sim.lastPacketId ?? 'packet'}'
                              : 'Local-first  ·  ${snap.vehicles.length} shown  ·  query ${(snap.queryMicros / 1000).toStringAsFixed(1)} ms',
                          style: const TextStyle(color: FleetTheme.muted, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final f in FleetFilter.values)
                              FilterChip(
                                selected: filter == f,
                                label: Text(
                                  '${_label(f)} ${snap.counts.forFilter(f)}',
                                ),
                                onSelected: (_) {
                                  ref.read(fleetFilterProvider.notifier).state = f;
                                },
                                selectedColor: FleetTheme.accent.withValues(alpha: 0.2),
                                checkmarkColor: FleetTheme.accent,
                                labelStyle: TextStyle(
                                  color: filter == f ? FleetTheme.accent : FleetTheme.text,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: const BorderSide(color: FleetTheme.line),
                                backgroundColor: FleetTheme.card,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (snap.vehicles.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      title: 'No vehicles match this filter',
                      body: 'Counts come from SQL. Switch chips or reseed the demo fleet from the menu.',
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: snap.vehicles.length,
                    itemBuilder: (context, i) {
                      final v = snap.vehicles[i];
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: _VehicleTile(vehicle: v, asOf: snap.asOf),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _label(FleetFilter f) => switch (f) {
        FleetFilter.all => 'All',
        FleetFilter.moving => 'Moving',
        FleetFilter.idle => 'Idle',
        FleetFilter.stopped => 'Stopped',
        FleetFilter.offline => 'Offline',
      };

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String value) async {
    final repo = ref.read(repositoryProvider);
    switch (value) {
      case 'seed':
        await SeedService(repo).seedDemoFleet();
        bumpRefresh(ref);
      case 'tick':
        await ref.read(simulatorProvider.notifier).tickOnce();
      case 'sim':
        await ref.read(simulatorProvider.notifier).toggle();
      case 'compact':
        final result = await repo.compactRetention();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Dropped ${result['dropped_readings']} raw readings')),
          );
        }
        bumpRefresh(ref);
      case 'backfill':
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => const _BackfillDialog(),
        );
        bumpRefresh(ref);
    }
  }
}

class _VehicleTile extends StatelessWidget {
  const _VehicleTile({required this.vehicle, required this.asOf});

  final VehicleRow vehicle;
  final DateTime asOf;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FleetTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: FleetTheme.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/vehicles/${vehicle.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          vehicle.regNumber,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (vehicle.openAlertCount > 0) ...[
                          const SizedBox(width: 8),
                          _AlertBadge(
                            count: vehicle.openAlertCount,
                            critical: vehicle.hasCriticalAlert,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(vehicle.model, style: const TextStyle(color: FleetTheme.muted, fontSize: 12)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      children: [
                        Text(
                          vehicle.soc == null ? 'SOC —' : 'SOC ${vehicle.soc!.round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          vehicle.rangeKm == null ? 'Range —' : '${vehicle.rangeKm!.round()} km',
                          style: const TextStyle(color: FleetTheme.muted),
                        ),
                        if (vehicle.currentGeofenceName != null)
                          Text(
                            vehicle.currentGeofenceName!,
                            style: const TextStyle(color: FleetTheme.accent, fontSize: 12),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StatusChip(status: vehicle.status),
                  const SizedBox(height: 8),
                  AgeLabel(at: vehicle.lastPing, now: asOf),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertBadge extends StatelessWidget {
  const _AlertBadge({required this.count, required this.critical});

  final int count;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    final color = critical ? FleetTheme.critical : FleetTheme.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        NumberFormat.compact().format(count),
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _BackfillDialog extends ConsumerStatefulWidget {
  const _BackfillDialog();

  @override
  ConsumerState<_BackfillDialog> createState() => _BackfillDialogState();
}

class _BackfillDialogState extends ConsumerState<_BackfillDialog> {
  String _phase = 'starting';
  int _readings = 0;
  int _vehicles = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await ScaleBackfill(ref.read(repositoryProvider)).run(
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _phase = p.phase;
            _readings = p.readings;
            _vehicles = p.vehicles;
          });
        },
      );
    } catch (e) {
      _error = e;
    }
    if (mounted && _error == null) {
      Navigator.of(context).pop();
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Scale backfill'),
      content: SizedBox(
        width: 360,
        child: _error != null
            ? Text('Failed: $_error')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_phase),
                  Text('Vehicles $_vehicles / 500'),
                  Text('Signal rows $_readings'),
                  const SizedBox(height: 8),
                  const Text(
                    'This writes through DuckDB, then rebuilds latest snapshots, geofence trips, and alerts.',
                    style: TextStyle(color: FleetTheme.muted, fontSize: 12),
                  ),
                ],
              ),
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
