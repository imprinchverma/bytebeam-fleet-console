import 'package:fleet_console/data/seed/backfill.dart';
import 'package:fleet_console/data/seed/seed_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  test('bench modest backfill', () async {
    await withRepo((h) async {
      for (final fence in seedGeofences) {
        await h.repo.createGeofence(
          id: fence.id,
          name: fence.name,
          lat: fence.lat,
          lon: fence.lon,
          radiusM: fence.radiusM,
        );
      }
      const vehicles = 40;
      const packets = 30;
      final started = DateTime.now();
      await ScaleBackfill(h.repo, clock: h.clock).run(
        vehicles: vehicles,
        packetsPerVehicle: packets,
      );
      final backfillMs = DateTime.now().difference(started).inMilliseconds;
      final times = <int>[];
      for (var i = 0; i < 10; i++) {
        times.add((await h.repo.loadFleet()).queryMicros);
      }
      times.sort();
      final stats = await h.repo.stats();
      // ignore: avoid_print
      print(
        'backfill_ms=$backfillMs readings=${stats.readings} vehicles=${stats.vehicles} '
        'p50_us=${times[5]} p95_us=${times[9]} first_us=${times.first}',
      );
      expect(stats.readings, greaterThan(1000));
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
