import '../../core/clock.dart';
import '../../core/constants.dart';
import '../../core/geo.dart';
import '../../domain/models.dart';
import '../fleet_repository.dart';

const seedGeofences = <({String id, String name, double lat, double lon, double radiusM})>[
  (id: 'gf_depot_north', name: 'Depot North', lat: 13.0200, lon: 77.5946, radiusM: 1200),
  (id: 'gf_warehouse_east', name: 'Warehouse East', lat: 12.9716, lon: 77.6800, radiusM: 1200),
  (id: 'gf_service_west', name: 'Service Hub West', lat: 12.9716, lon: 77.5100, radiusM: 1200),
];

const seedModels = [
  'Volvo FH Electric',
  'Tesla Semi',
  'BYD 8TT',
  'Mercedes eActros',
  'Scania 40R',
];

class SeedService {
  SeedService(this.repo, {AppClock clock = const SystemClock()}) : _clock = clock;

  final FleetRepository repo;
  final AppClock _clock;

  Future<bool> ensureDemoSeed() async {
    final existing = await repo.db.selectOne(
      "SELECT value FROM meta WHERE key = 'seeded'",
    );
    if (existing != null) return false;
    await seedDemoFleet();
    await repo.db.execute(
      "INSERT INTO meta (key, value) VALUES ('seeded', '1') ON CONFLICT (key) DO UPDATE SET value = '1'",
    );
    return true;
  }

  Future<void> seedDemoFleet() async {
    final now = _clock.now();
    for (final fence in seedGeofences) {
      final row = await repo.db.selectOne(
        'SELECT id FROM geofences WHERE id = ?',
        [fence.id],
      );
      if (row == null) {
        await repo.createGeofence(
          id: fence.id,
          name: fence.name,
          lat: fence.lat,
          lon: fence.lon,
          radiusM: fence.radiusM,
        );
      }
    }

    final vehicles = List.generate(12, (i) {
      final n = i + 1;
      return (
        id: 'veh_${n.toString().padLeft(3, '0')}',
        reg: 'KA01AB${(1000 + n).toString()}',
        model: seedModels[i % seedModels.length],
      );
    });
    for (final v in vehicles) {
      await repo.upsertVehicle(id: v.id, regNumber: v.reg, model: v.model);
    }

    Future<void> put(
      String vehicleId,
      DateTime t,
      Map<String, double> signals,
    ) {
      return repo.ingestPacket(
        TelemetryPacket(
          id: 'pkt_${vehicleId}_${t.microsecondsSinceEpoch}',
          vehicleId: vehicleId,
          eventTime: t,
          signals: signals,
        ),
        replayLocation: false,
        recomputeAlerts: false,
      );
    }

    final depot = seedGeofences[0];
    final warehouse = seedGeofences[1];
    final service = seedGeofences[2];

    // v001: completed depot -> warehouse trip, currently moving.
    await _scriptTrip(
      put: put,
      vehicleId: 'veh_001',
      start: now.subtract(const Duration(hours: 2)),
      from: depot,
      to: warehouse,
      soc: 78,
      movingNow: true,
    );

    // v002: idle at depot, low battery warning.
    await _parked(
      put: put,
      vehicleId: 'veh_002',
      at: depot,
      start: now.subtract(const Duration(minutes: 8)),
      soc: 18,
      ignition: 1,
      speed: 0,
    );

    // v003: stopped, critical SOC.
    await _parked(
      put: put,
      vehicleId: 'veh_003',
      at: warehouse,
      start: now.subtract(const Duration(minutes: 6)),
      soc: 8,
      ignition: 0,
      speed: 0,
    );

    // v004: offline (last ping 40 min ago).
    await _parked(
      put: put,
      vehicleId: 'veh_004',
      at: service,
      start: now.subtract(const Duration(minutes: 40)),
      end: now.subtract(const Duration(minutes: 38)),
      soc: 55,
      ignition: 0,
      speed: 0,
    );

    // v005: overheating, moving.
    await _scriptTrip(
      put: put,
      vehicleId: 'veh_005',
      start: now.subtract(const Duration(minutes: 25)),
      from: warehouse,
      to: service,
      soc: 62,
      temp: 48,
      movingNow: true,
      complete: false,
    );

    // Remaining vehicles: mix of idle/moving/stopped around the three fences.
    for (var i = 6; i <= 12; i++) {
      final fence = seedGeofences[i % 3];
      final id = 'veh_${i.toString().padLeft(3, '0')}';
      final moving = i.isEven;
      if (moving) {
        await _scriptTrip(
          put: put,
          vehicleId: id,
          start: now.subtract(Duration(minutes: 20 + i)),
          from: fence,
          to: seedGeofences[(i + 1) % 3],
          soc: 40 + i.toDouble(),
          movingNow: true,
          complete: false,
        );
      } else {
        await _parked(
          put: put,
          vehicleId: id,
          at: fence,
          start: now.subtract(const Duration(minutes: 4)),
          soc: 30 + i.toDouble(),
          ignition: i % 3 == 0 ? 0 : 1,
          speed: 0,
        );
      }
    }

    await repo.replayAllVehicles();
    await repo.recomputeAllAlerts();
  }

  Future<void> _parked({
    required Future<void> Function(String, DateTime, Map<String, double>) put,
    required String vehicleId,
    required ({String id, String name, double lat, double lon, double radiusM}) at,
    required DateTime start,
    DateTime? end,
    required double soc,
    required double ignition,
    required double speed,
    double temp = 32,
  }) async {
    final last = end ?? _clock.now();
    for (var i = 0; i < 4; i++) {
      final t = start.add(Duration(seconds: 40 * i));
      if (t.isAfter(last)) break;
      await put(vehicleId, t, {
        FleetRules.signalSoc: soc,
        FleetRules.signalRange: soc * 3.2,
        FleetRules.signalSpeed: speed,
        FleetRules.signalBatteryTemp: temp,
        FleetRules.signalOdometer: 120000 + i.toDouble(),
        FleetRules.signalIgnition: ignition,
        FleetRules.signalLat: at.lat + 0.0002,
        FleetRules.signalLon: at.lon + 0.0002,
        FleetRules.signalGpsAccuracy: 8,
      });
    }
  }

  Future<void> _scriptTrip({
    required Future<void> Function(String, DateTime, Map<String, double>) put,
    required String vehicleId,
    required DateTime start,
    required ({String id, String name, double lat, double lon, double radiusM}) from,
    required ({String id, String name, double lat, double lon, double radiusM}) to,
    required double soc,
    double temp = 34,
    bool movingNow = false,
    bool complete = true,
  }) async {
    const dwell = 4;
    const cruise = 8;
    var odo = 88000.0;
    var t = start;
    var battery = soc;

    Future<void> sample({
      required double lat,
      required double lon,
      required double speed,
      required double ignition,
    }) async {
      await put(vehicleId, t, {
        FleetRules.signalSoc: battery,
        FleetRules.signalRange: battery * 3.2,
        FleetRules.signalSpeed: speed,
        FleetRules.signalBatteryTemp: temp,
        FleetRules.signalOdometer: odo,
        FleetRules.signalIgnition: ignition,
        FleetRules.signalLat: lat,
        FleetRules.signalLon: lon,
        FleetRules.signalGpsAccuracy: 6,
      });
      t = t.add(const Duration(seconds: 45));
      odo += speed / 80;
      battery = (battery - 0.05).clamp(5, 100);
    }

    for (var i = 0; i < dwell; i++) {
      await sample(lat: from.lat, lon: from.lon, speed: 0, ignition: 1);
    }
    for (var i = 1; i <= cruise; i++) {
      final p = lerpLatLon(from.lat, from.lon, to.lat, to.lon, i / (cruise + 1));
      await sample(lat: p.lat, lon: p.lon, speed: 42, ignition: 1);
    }
    if (complete) {
      for (var i = 0; i < dwell; i++) {
        await sample(lat: to.lat, lon: to.lon, speed: 0, ignition: 1);
      }
    }
    if (movingNow && !t.isAfter(_clock.now())) {
      final p = lerpLatLon(from.lat, from.lon, to.lat, to.lon, complete ? 0.85 : 0.6);
      await sample(lat: p.lat, lon: p.lon, speed: 38, ignition: 1);
    }
  }
}
