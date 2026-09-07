import 'dart:math';

import '../../core/clock.dart';
import '../../core/constants.dart';
import '../../core/geo.dart';
import '../../domain/models.dart';
import '../fleet_repository.dart';
import 'seed_service.dart';

/// Live ingest that deliberately emits late, duplicated, and out-of-order packets.
class TelemetrySimulator {
  TelemetrySimulator(this.repo, {AppClock clock = const SystemClock(), int? seed})
      : _clock = clock,
        _rng = Random(seed);

  final FleetRepository repo;
  final AppClock _clock;
  final Random _rng;
  int _seq = 0;

  Future<TelemetryPacket> tick() async {
    final stats = await repo.stats();
    if (stats.vehicles == 0) {
      throw StateError('No vehicles to simulate');
    }
    final rows = await repo.db.select('SELECT id FROM vehicles ORDER BY id');
    final vehicleId = rows[_rng.nextInt(rows.length)]['id'] as String;
    final now = _clock.now();

    var eventTime = now;
    final roll = _rng.nextDouble();
    if (roll < 0.10) {
      eventTime = now.subtract(Duration(seconds: 30 + _rng.nextInt(120)));
    } else if (roll < 0.15) {
      eventTime = now.subtract(const Duration(seconds: 5));
    }

    final origin = seedGeofences[_rng.nextInt(seedGeofences.length)];
    final dest = seedGeofences[_rng.nextInt(seedGeofences.length)];
    final t = _rng.nextDouble();
    final pos = lerpLatLon(origin.lat, origin.lon, dest.lat, dest.lon, t);

    final signals = <String, double>{
      FleetRules.signalSoc: 10 + _rng.nextDouble() * 80,
      FleetRules.signalRange: 40 + _rng.nextDouble() * 200,
      FleetRules.signalSpeed: _rng.nextBool() ? _rng.nextDouble() * 60 : 0,
      FleetRules.signalBatteryTemp: 28 + _rng.nextDouble() * 20,
      FleetRules.signalIgnition: _rng.nextBool() ? 1 : 0,
      FleetRules.signalLat: pos.lat,
      FleetRules.signalLon: pos.lon,
      FleetRules.signalGpsAccuracy: _rng.nextDouble() < 0.05 ? 80 : 7,
    };
    if (_rng.nextDouble() < 0.7) {
      signals[FleetRules.signalOdometer] = 100000 + _rng.nextDouble() * 5000;
    }

    _seq += 1;
    final packet = TelemetryPacket(
      id: 'live_${vehicleId}_${_seq}_${eventTime.microsecondsSinceEpoch}',
      vehicleId: vehicleId,
      eventTime: eventTime,
      signals: signals,
    );

    var result = await repo.ingestPacket(packet);
    if (_rng.nextDouble() < 0.08) {
      result = await repo.ingestPacket(packet);
    }
    if (!result.accepted && result.duplicate) {
      return packet;
    }
    return packet;
  }
}
