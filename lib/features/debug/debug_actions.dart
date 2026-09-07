import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/seed/backfill.dart';
import '../../data/seed/seed_service.dart';

/// Debug-only operator actions: seed, flaky ingest, 2M-row backfill, retention.
Future<void> runFleetDebugAction(
  BuildContext context,
  WidgetRef ref,
  String value,
) async {
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
        builder: (context) => const BackfillDialog(),
      );
      bumpRefresh(ref);
  }
}

class BackfillDialog extends ConsumerStatefulWidget {
  const BackfillDialog({super.key});

  @override
  ConsumerState<BackfillDialog> createState() => _BackfillDialogState();
}

class _BackfillDialogState extends ConsumerState<BackfillDialog> {
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
