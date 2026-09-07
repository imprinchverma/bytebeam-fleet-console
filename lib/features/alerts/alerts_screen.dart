import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/models.dart';
import '../../shared/widgets/fleet_widgets.dart';
import '../vehicle/dismiss_sheet.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(openAlertsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(title: 'Could not load alerts', body: e.toString()),
        data: (alerts) {
          if (alerts.isEmpty) {
            return const EmptyState(
              title: 'Nothing needs attention',
              body: 'Open alerts are computed from fresh DuckDB readings.',
              icon: Icons.check_circle_outline,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: alerts.length,
            itemBuilder: (context, i) {
              final alert = alerts[i];
              final color = alert.severity == AlertSeverity.critical
                  ? FleetTheme.critical
                  : FleetTheme.warning;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  onTap: () => context.push('/vehicles/${alert.vehicleId}'),
                  leading: Icon(Icons.warning_amber_rounded, color: color),
                  title: Text(alert.title),
                  subtitle: Text(
                    '${alert.vehicleId} · ${alert.severity.name.toUpperCase()} · '
                    '${DateFormat('HH:mm').format(alert.openedAt.toLocal())}',
                  ),
                  trailing: TextButton(
                    onPressed: () => _dismiss(context, ref, alert),
                    child: const Text('Dismiss'),
                  ),
                ),
              );
            },
          );
        },
      ),
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
