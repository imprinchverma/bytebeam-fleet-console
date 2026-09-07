import 'dart:io';

import 'package:fleet_console/core/clock.dart';
import 'package:fleet_console/data/duckdb/fleet_database.dart';
import 'package:fleet_console/data/fleet_repository.dart';
import 'package:path/path.dart' as p;

class RepoHarness {
  RepoHarness._(this.db, this.repo, this.clock, this.dir);

  final FleetDatabase db;
  final FleetRepository repo;
  final FakeClock clock;
  final Directory dir;

  static Future<RepoHarness> open({DateTime? now}) async {
    final dir = await Directory.systemTemp.createTemp('fleet_test_');
    final path = p.join(dir.path, 'fleet.duckdb');
    final db = await FleetDatabase.open(path);
    final clock = FakeClock(now ?? DateTime.utc(2026, 9, 7, 12));
    final repo = FleetRepository(db, clock: clock);
    return RepoHarness._(db, repo, clock, dir);
  }

  Future<void> dispose() async {
    await db.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}

Future<void> withRepo(
  Future<void> Function(RepoHarness h) body, {
  DateTime? now,
}) async {
  final h = await RepoHarness.open(now: now);
  try {
    await body(h);
  } finally {
    await h.dispose();
  }
}
