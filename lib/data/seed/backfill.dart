import 'dart:math';

import '../../core/clock.dart';
import '../../core/constants.dart';
import '../../core/geo.dart';
import '../../domain/models.dart';
import '../fleet_repository.dart';
import 'seed_service.dart';

class BackfillProgress {
  const BackfillProgress({
    required this.vehicles,
    required this.targetVehicles,
    required this.readings,
    required this.phase,
  });

  final int vehicles;
  final int targetVehicles;
  final int readings;
  final String phase;
}

/// 500 vehicles, >= 2 million signal rows, written through DuckDB appender.
class ScaleBackfill {
  ScaleBackfill(this.repo, {AppClock clock = const SystemClock(), int? seed})
      : _clock = clock,
        _rng = Random(seed ?? 7);

  final FleetRepository repo;
  final AppClock _clock;
  final Random _rng;

  Future<void> run({
    int vehicles = 500,
    int packetsPerVehicle = 500,
    void Function(BackfillProgress progress)? onProgress,
  }) async {
    final now = _clock.now();
    onProgress?.call(
      BackfillProgress(
        vehicles: 0,
        targetVehicles: vehicles,
        readings: 0,
        phase: 'creating vehicles',
      ),
    );

    for (var i = 1; i <= vehicles; i++) {
      final id = 'veh_${i.toString().padLeft(3, '0')}';
      await repo.upsertVehicle(
        id: id,
        regNumber: 'KA01AB${(1000 + i).toString()}',
        model: seedModels[i % seedModels.length],
      );
      if (i % 50 == 0) {
        onProgress?.call(
          BackfillProgress(
            vehicles: i,
            targetVehicles: vehicles,
            readings: 0,
            phase: 'creating vehicles',
          ),
        );
      }
    }

    var readings = 0;
    const batchVehicles = 10;
    for (var start = 1; start <= vehicles; start += batchVehicles) {
      final end = min(vehicles, start + batchVehicles - 1);
      final batch = <TelemetryPacket>[];
      for (var i = start; i <= end; i++) {
        batch.addAll(
          _packetsForVehicle(
            index: i,
            packets: packetsPerVehicle,
            now: now,
          ),
        );
      }
      readings += await repo.appendPackets(batch);
      onProgress?.call(
        BackfillProgress(
          vehicles: end,
          targetVehicles: vehicles,
          readings: readings,
          phase: 'appending readings',
        ),
      );
    }

    onProgress?.call(
      BackfillProgress(
        vehicles: vehicles,
        targetVehicles: vehicles,
        readings: readings,
        phase: 'rebuilding latest snapshot',
      ),
    );
    await repo.rebuildLatestFromLog();

    onProgress?.call(
      BackfillProgress(
        vehicles: vehicles,
        targetVehicles: vehicles,
        readings: readings,
        phase: 'replaying geofences and trips',
      ),
    );
    await repo.replayAllVehicles();
    await repo.recomputeAllAlerts();

    await repo.db.execute(
      "INSERT INTO meta (key, value) VALUES ('backfilled', '1') ON CONFLICT (key) DO UPDATE SET value = '1'",
    );
    onProgress?.call(
      BackfillProgress(
        vehicles: vehicles,
        targetVehicles: vehicles,
        readings: readings,
        phase: 'done',
      ),
    );
  }

  List<TelemetryPacket> _packetsForVehicle({
    required int index,
    required int packets,
    required DateTime now,
  }) {
    final id = 'veh_${index.toString().padLeft(3, '0')}';
    final from = seedGeofences[index % seedGeofences.length];
    final to = seedGeofences[(index + 1) % seedGeofences.length];
    var soc = 20 + (index % 70).toDouble();
    var odo = 50000.0 + index * 10;
    final out = <TelemetryPacket>[];
    for (var p = 0; p < packets; p++) {
      final frac = p / (packets - 1);
      final pos = lerpLatLon(from.lat, from.lon, to.lat, to.lon, frac);
      final lat = pos.lat + (_rng.nextDouble() - 0.5) * 0.0002;
      final lon = pos.lon + (_rng.nextDouble() - 0.5) * 0.0002;
      final t = now.subtract(Duration(seconds: (packets - p) * 40));
      var eventTime = t;
      if (p % 37 == 0) {
        eventTime = t.subtract(const Duration(seconds: 13));
      }
      final moving = frac > 0.08 && frac < 0.92;
      final signals = <String, double>{
        FleetRules.signalSoc: soc,
        FleetRules.signalRange: soc * 3.1,
        FleetRules.signalSpeed: moving ? 35 + (index % 20) : 0,
        FleetRules.signalBatteryTemp: 30 + (index % 18),
        FleetRules.signalOdometer: odo,
        FleetRules.signalIgnition: moving || p < 10 ? 1 : 0,
        FleetRules.signalLat: lat,
        FleetRules.signalLon: lon,
      };
      if (p % 11 == 0) {
        signals[FleetRules.signalGpsAccuracy] = 9;
      }
      out.add(
        TelemetryPacket(
          id: 'bf_${id}_$p',
          vehicleId: id,
          eventTime: eventTime,
          signals: signals,
        ),
      );
      soc = (soc - 0.02).clamp(6, 100);
      odo += moving ? 0.4 : 0;
    }
    return out;
  }
}
