import 'package:fleet_console/core/constants.dart';
import 'package:fleet_console/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

TelemetryPacket pkt(String vehicle, DateTime t, Map<String, double> signals) {
  return TelemetryPacket(
    id: 'pkt_${vehicle}_${t.microsecondsSinceEpoch}',
    vehicleId: vehicle,
    eventTime: t,
    signals: signals,
  );
}

void main() {
  test('duplicate (vehicle_id, event_time) inserts no readings', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final t = h.clock.now().subtract(const Duration(minutes: 1));
      await h.repo.ingestPacket(pkt('v1', t, {FleetRules.signalSoc: 50}));
      final again = TelemetryPacket(
        id: 'other-id',
        vehicleId: 'v1',
        eventTime: t,
        signals: {FleetRules.signalSoc: 1},
      );
      expect((await h.repo.ingestPacket(again)).duplicate, isTrue);
      final stats = await h.repo.stats();
      expect(stats.packets, 1);
      expect(stats.readings, 1);
      final soc = (await h.repo.loadRegister('v1'))
          .firstWhere((r) => r.signal == FleetRules.signalSoc);
      expect(soc.value, 50);
    });
  });

  test('dismissed SOC stays dismissed until it clears, then can reopen', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final t = h.clock.now().subtract(const Duration(minutes: 2));
      await h.repo.ingestPacket(pkt('v1', t, {FleetRules.signalSoc: 15}));
      final first = (await h.repo.loadOpenAlerts(vehicleId: 'v1')).single;
      await h.repo.dismissAlert(alertId: first.id, reason: 'I am on it');
      await h.repo.ingestPacket(
        pkt('v1', t.add(const Duration(seconds: 5)), {FleetRules.signalSoc: 12}),
      );
      expect(await h.repo.loadOpenAlerts(vehicleId: 'v1'), isEmpty);

      await h.repo.ingestPacket(
        pkt('v1', t.add(const Duration(seconds: 10)), {FleetRules.signalSoc: 40}),
      );
      await h.repo.ingestPacket(
        pkt('v1', t.add(const Duration(seconds: 20)), {FleetRules.signalSoc: 9}),
      );
      final next = await h.repo.loadOpenAlerts(vehicleId: 'v1');
      expect(next, hasLength(1));
      expect(next.single.id, isNot(first.id));
      expect(next.single.severity, AlertSeverity.critical);
    });
  });

  test('overheat is independent of SOC alerts', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final t = h.clock.now().subtract(const Duration(minutes: 1));
      await h.repo.ingestPacket(
        pkt('v1', t, {
          FleetRules.signalSoc: 15,
          FleetRules.signalBatteryTemp: 48,
        }),
      );
      final alerts = await h.repo.loadOpenAlerts(vehicleId: 'v1');
      expect(alerts.map((a) => a.kind).toSet(), {
        FleetRules.alertSoc,
        FleetRules.alertTemp,
      });
    });
  });

  test('retention keeps in-progress trip packets and drops old raw SOC', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final now = h.clock.now();
      await h.repo.ingestPacket(
        pkt('v1', now.subtract(const Duration(days: 8)), {FleetRules.signalSoc: 70}),
      );
      await h.repo.ingestPacket(
        pkt('v1', now.subtract(const Duration(hours: 1)), {FleetRules.signalSoc: 60}),
      );
      final before = await h.repo.stats();
      expect(before.readings, 2);
      final dropped = await h.repo.compactRetention();
      expect(dropped['dropped_readings'], 1);
      final after = await h.repo.stats();
      expect(after.readings, 1);
      final hourly = await h.db.select('SELECT COUNT(*) AS c FROM soc_hourly');
      expect(hourly.single['c'], isNot(0));
    });
  });

  test('alert_events records open, dismiss, and undo', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      await h.repo.ingestPacket(
        pkt('v1', h.clock.now().subtract(const Duration(minutes: 1)), {
          FleetRules.signalSoc: 11,
        }),
      );
      final id = (await h.repo.loadOpenAlerts(vehicleId: 'v1')).single.id;
      await h.repo.dismissAlert(alertId: id, reason: 'Wrong alert');
      await h.repo.undoDismiss(id);
      final events = await h.db.select(
        'SELECT action FROM alert_events WHERE alert_id = ? ORDER BY occurred_at',
        [id],
      );
      expect(events.map((e) => e['action']), ['opened', 'dismissed', 'undo_dismiss']);
    });
  });
}
