import 'package:fleet_console/core/constants.dart';
import 'package:fleet_console/data/duckdb/fleet_database.dart';
import 'package:fleet_console/data/fleet_repository.dart';
import 'package:fleet_console/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

TelemetryPacket pkt(
  String vehicle,
  DateTime t,
  Map<String, double> signals, {
  String? id,
}) {
  return TelemetryPacket(
    id: id ?? 'pkt_${vehicle}_${t.microsecondsSinceEpoch}',
    vehicleId: vehicle,
    eventTime: t,
    signals: signals,
  );
}

void main() {
  test('duplicate packets are ignored', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final t = h.clock.now().subtract(const Duration(minutes: 1));
      final packet = pkt('v1', t, {FleetRules.signalSoc: 50, FleetRules.signalSpeed: 10});
      expect((await h.repo.ingestPacket(packet)).accepted, isTrue);
      expect((await h.repo.ingestPacket(packet)).duplicate, isTrue);
      final stats = await h.repo.stats();
      expect(stats.packets, 1);
    });
  });

  test('late packet older than current latest does not clobber SOC', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final now = h.clock.now();
      await h.repo.ingestPacket(
        pkt('v1', now.subtract(const Duration(minutes: 1)), {FleetRules.signalSoc: 80}),
      );
      await h.repo.ingestPacket(
        pkt('v1', now.subtract(const Duration(minutes: 4)), {FleetRules.signalSoc: 10}),
      );
      final register = await h.repo.loadRegister('v1');
      final soc = register.firstWhere((r) => r.signal == FleetRules.signalSoc);
      expect(soc.value, 80);
    });
  });

  test('status first-match-wins including missing speed/ignition', () async {
    await withRepo((h) async {
      Future<VehicleRow> one(String id, Map<String, double> signals, {Duration ago = const Duration(minutes: 1)}) async {
        await h.repo.upsertVehicle(id: id, regNumber: id, model: 'M');
        await h.repo.ingestPacket(pkt(id, h.clock.now().subtract(ago), signals));
        return (await h.repo.loadVehicle(id))!;
      }

      final moving = await one('moving', {FleetRules.signalSpeed: 12, FleetRules.signalIgnition: 0});
      final idle = await one('idle', {FleetRules.signalSpeed: 0, FleetRules.signalIgnition: 1});
      final stopped = await one('stopped', {FleetRules.signalIgnition: 0});
      final missing = await one('missing', {FleetRules.signalSoc: 40});
      final offline = await one(
        'offline',
        {FleetRules.signalSpeed: 30},
        ago: const Duration(minutes: 11),
      );

      expect(moving.status, VehicleStatus.moving);
      expect(idle.status, VehicleStatus.idle);
      expect(stopped.status, VehicleStatus.stopped);
      expect(missing.status, VehicleStatus.stopped);
      expect(offline.status, VehicleStatus.offline);
    });
  });

  test('filter counts come from SQL', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'a', regNumber: 'A', model: 'M');
      await h.repo.upsertVehicle(id: 'b', regNumber: 'B', model: 'M');
      await h.repo.ingestPacket(
        pkt('a', h.clock.now().subtract(const Duration(minutes: 1)), {FleetRules.signalSpeed: 5}),
      );
      await h.repo.ingestPacket(
        pkt('b', h.clock.now().subtract(const Duration(minutes: 12)), {FleetRules.signalSpeed: 5}),
      );
      final snap = await h.repo.loadFleet();
      expect(snap.counts.all, 2);
      expect(snap.counts.moving, 1);
      expect(snap.counts.offline, 1);
      final onlyOffline = await h.repo.loadFleet(filter: FleetFilter.offline);
      expect(onlyOffline.vehicles, hasLength(1));
      expect(onlyOffline.vehicles.single.id, 'b');
    });
  });

  test('SOC escalation is one alert row and dismiss+undo works', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final t = h.clock.now().subtract(const Duration(minutes: 1));
      await h.repo.ingestPacket(pkt('v1', t, {FleetRules.signalSoc: 15}));
      var alerts = await h.repo.loadOpenAlerts(vehicleId: 'v1');
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, AlertSeverity.warning);

      await h.repo.ingestPacket(
        pkt('v1', t.add(const Duration(seconds: 10)), {FleetRules.signalSoc: 8}),
      );
      alerts = await h.repo.loadOpenAlerts(vehicleId: 'v1');
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, AlertSeverity.critical);

      final id = alerts.single.id;
      await h.repo.dismissAlert(alertId: id, reason: 'I am on it');
      expect(await h.repo.loadOpenAlerts(vehicleId: 'v1'), isEmpty);
      await h.repo.undoDismiss(id);
      expect(await h.repo.loadOpenAlerts(vehicleId: 'v1'), hasLength(1));
    });
  });

  test('clearing SOC resolves even a dismissed alert', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      final t = h.clock.now().subtract(const Duration(minutes: 1));
      await h.repo.ingestPacket(pkt('v1', t, {FleetRules.signalSoc: 12}));
      final id = (await h.repo.loadOpenAlerts(vehicleId: 'v1')).single.id;
      await h.repo.dismissAlert(alertId: id, reason: 'Wrong alert');
      await h.repo.ingestPacket(
        pkt('v1', t.add(const Duration(seconds: 20)), {FleetRules.signalSoc: 40}),
      );
      final rows = await h.db.select('SELECT resolved_at FROM alerts WHERE id = ?', [id]);
      expect(rows.single['resolved_at'], isNotNull);
    });
  });

  test('kill-and-relaunch reads the same vehicles from the file', () async {
    final h = await RepoHarness.open();
    final path = h.db.path;
    try {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA99ZZ', model: 'Semi');
      await h.repo.ingestPacket(
        pkt('v1', h.clock.now(), {FleetRules.signalSoc: 66, FleetRules.signalSpeed: 3}),
      );
      await h.db.close();
      final db2 = await FleetDatabase.open(path);
      final repo2 = FleetRepository(db2, clock: h.clock);
      final snap = await repo2.loadFleet();
      expect(snap.vehicles, hasLength(1));
      expect(snap.vehicles.single.regNumber, 'KA99ZZ');
      expect(snap.vehicles.single.soc, 66);
      await db2.close();
    } finally {
      await h.dispose();
    }
  });

  test('never-reported signals show as null with no pill', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      await h.repo.ingestPacket(pkt('v1', h.clock.now(), {FleetRules.signalSoc: 50}));
      final register = await h.repo.loadRegister('v1');
      final range = register.firstWhere((r) => r.signal == FleetRules.signalRange);
      expect(range.value, isNull);
      expect(range.verdict, isNull);
    });
  });

  test('fleet query on a small DuckDB file is measurable', () async {
    await withRepo((h) async {
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01', model: 'Semi');
      await h.repo.ingestPacket(
        pkt('v1', h.clock.now(), {
          FleetRules.signalSoc: 70,
          FleetRules.signalSpeed: 12,
          FleetRules.signalRange: 180,
        }),
      );
      final times = <int>[];
      for (var i = 0; i < 10; i++) {
        times.add((await h.repo.loadFleet()).queryMicros);
      }
      times.sort();
      final p50 = times[5];
      final p95 = times[9];
      // ignore: avoid_print
      print('fleet_query_us p50=$p50 p95=$p95');
      expect(p50, greaterThan(0));
      expect(p95, greaterThanOrEqualTo(p50));
    });
  });
}
