import 'dart:io';

import 'package:fleet_console/core/clock.dart';
import 'package:fleet_console/data/duckdb/fleet_database.dart';
import 'package:fleet_console/data/fleet_repository.dart';
import 'package:fleet_console/data/seed/backfill.dart';
import 'package:fleet_console/data/seed/seed_service.dart';
import 'package:path/path.dart' as p;

/// Measures the fleet-list SQL. Usage:
/// `flutter test tool/bench_fleet.dart --plain-name bench`
/// or `dart run` is not used because dart_duckdb loads via Flutter.
Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('fleet_bench_');
  final path = p.join(dir.path, 'fleet.duckdb');
  stdout.writeln('db=$path');
  final db = await FleetDatabase.open(path);
  final clock = FakeClock(DateTime.utc(2026, 9, 7, 12));
  final repo = FleetRepository(db, clock: clock);

  final vehicles = int.tryParse(Platform.environment['FLEET_VEHICLES'] ?? '') ?? 50;
  final packets = int.tryParse(Platform.environment['FLEET_PACKETS'] ?? '') ?? 40;
  stdout.writeln('seeding geofences');
  await SeedService(repo, clock: clock).ensureDemoSeed();
  stdout.writeln('backfill vehicles=$vehicles packets=$packets');
  final started = DateTime.now();
  await ScaleBackfill(repo, clock: clock).run(vehicles: vehicles, packetsPerVehicle: packets);
  stdout.writeln('backfill_s=${DateTime.now().difference(started).inMilliseconds / 1000}');

  final times = <int>[];
  for (var i = 0; i < 12; i++) {
    final snap = await repo.loadFleet();
    times.add(snap.queryMicros);
    if (i == 0) {
      stdout.writeln('first_paint_vehicles=${snap.vehicles.length} query_us=${snap.queryMicros}');
    }
  }
  times.sort();
  int pct(double p) => times[((times.length - 1) * p).round()];
  stdout.writeln('warm_n=${times.length} p50_us=${pct(0.5)} p95_us=${pct(0.95)} max_us=${times.last}');
  final stats = await repo.stats();
  stdout.writeln('stats vehicles=${stats.vehicles} readings=${stats.readings} packets=${stats.packets}');
  await db.close();
}
