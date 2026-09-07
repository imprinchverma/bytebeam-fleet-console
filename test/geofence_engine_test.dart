import 'package:fleet_console/core/geo.dart';
import 'package:fleet_console/data/engines/geofence_engine.dart';
import 'package:fleet_console/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

FenceVersion fence({
  required String id,
  required double lat,
  required double lon,
  double radius = 1000,
  DateTime? from,
  DateTime? to,
  int version = 1,
}) {
  return FenceVersion(
    geofenceId: id,
    version: version,
    name: id,
    lat: lat,
    lon: lon,
    radiusM: radius,
    validFrom: from ?? DateTime.utc(2020),
    validTo: to,
  );
}

LocationSample point(
  String id,
  DateTime t,
  double lat,
  double lon, {
  double accuracy = 5,
}) {
  return LocationSample(
    packetId: id,
    eventTime: t,
    lat: lat,
    lon: lon,
    accuracyM: accuracy,
  );
}

void main() {
  final engine = GeofenceReplay();
  final origin = DateTime.utc(2026, 1, 1, 8);
  const depotLat = 13.02;
  const depotLon = 77.59;
  const warehouseLat = 12.97;
  const warehouseLon = 77.68;

  final depot = fence(id: 'depot', lat: depotLat, lon: depotLon);
  final warehouse = fence(id: 'wh', lat: warehouseLat, lon: warehouseLon);

  test('inaccurate GPS is ignored', () {
    final points = [
      for (var i = 0; i < 5; i++)
        point('p$i', origin.add(Duration(seconds: 20 * i)), depotLat, depotLon, accuracy: 80),
    ];
    final result = engine.replay(vehicleId: 'v', points: points, fences: [depot]);
    expect(result.events, isEmpty);
    expect(result.currentGeofenceId, isNull);
  });

  test('jitter inside the hysteresis band does not emit a false exit', () {
    final points = <LocationSample>[
      for (var i = 0; i < 4; i++)
        point('in$i', origin.add(Duration(seconds: 20 * i)), depotLat, depotLon),
      for (var i = 0; i < 3; i++)
        point(
          'jit$i',
          origin.add(Duration(seconds: 80 + 20 * i)),
          depotLat + 0.009,
          depotLon,
        ),
    ];
    final result = engine.replay(vehicleId: 'v', points: points, fences: [depot]);
    expect(result.currentGeofenceId, 'depot');
    expect(result.events.where((e) => e.kind == 'confirmed_exit'), isEmpty);
  });

  test('dwell then a real move starts a trip and a later enter completes it', () {
    final points = <LocationSample>[
      for (var i = 0; i < 4; i++)
        point('d$i', origin.add(Duration(seconds: 30 * i)), depotLat, depotLon),
      for (var i = 1; i <= 6; i++)
        point(
          'c$i',
          origin.add(Duration(seconds: 120 + 30 * i)),
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lat,
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lon,
        ),
      for (var i = 0; i < 4; i++)
        point(
          'w$i',
          origin.add(Duration(seconds: 360 + 30 * i)),
          warehouseLat,
          warehouseLon,
        ),
    ];
    final result = engine.replay(
      vehicleId: 'v',
      points: points,
      fences: [depot, warehouse],
    );
    expect(result.events.where((e) => e.kind == 'confirmed_exit').length, 1);
    expect(result.events.where((e) => e.kind == 'confirmed_enter').length, 2);
    expect(result.trips, hasLength(1));
    expect(result.trips.single.status, TripStatus.completed);
    expect(result.trips.single.originGeofenceId, 'depot');
    expect(result.trips.single.destGeofenceId, 'wh');
    expect(result.currentGeofenceId, 'wh');
  });

  test('exit without a later enter leaves the trip in progress', () {
    final points = <LocationSample>[
      for (var i = 0; i < 4; i++)
        point('d$i', origin.add(Duration(seconds: 30 * i)), depotLat, depotLon),
      for (var i = 1; i <= 6; i++)
        point(
          'c$i',
          origin.add(Duration(seconds: 120 + 30 * i)),
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lat,
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lon,
        ),
    ];
    final result = engine.replay(
      vehicleId: 'v',
      points: points,
      fences: [depot, warehouse],
    );
    expect(result.trips, hasLength(1));
    expect(result.trips.single.status, TripStatus.inProgress);
  });

  test('replay is idempotent: the same history does not duplicate trips', () {
    final points = <LocationSample>[
      for (var i = 0; i < 4; i++)
        point('d$i', origin.add(Duration(seconds: 30 * i)), depotLat, depotLon),
      for (var i = 1; i <= 6; i++)
        point(
          'c$i',
          origin.add(Duration(seconds: 120 + 30 * i)),
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lat,
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lon,
        ),
    ];
    final a = engine.replay(vehicleId: 'v', points: points, fences: [depot, warehouse]);
    final b = engine.replay(vehicleId: 'v', points: points, fences: [depot, warehouse]);
    expect(a.trips.map((t) => t.id), b.trips.map((t) => t.id));
    expect(a.events.map((e) => e.id), b.events.map((e) => e.id));
  });

  test('late extra point can move a trip start without creating a second trip', () {
    final early = <LocationSample>[
      for (var i = 0; i < 4; i++)
        point('d$i', origin.add(Duration(seconds: 30 * i)), depotLat, depotLon),
      for (var i = 1; i <= 6; i++)
        point(
          'c$i',
          origin.add(Duration(seconds: 150 + 30 * i)),
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lat,
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, i / 7).lon,
        ),
    ];
    final withLate = [
      ...early,
      point(
        'late',
        origin.add(const Duration(seconds: 130)),
        lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, 0.4).lat,
        lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, 0.4).lon,
      ),
    ];
    final first = engine.replay(vehicleId: 'v', points: early, fences: [depot, warehouse]);
    final second = engine.replay(vehicleId: 'v', points: withLate, fences: [depot, warehouse]);
    expect(second.trips, hasLength(1));
    expect(first.trips, hasLength(1));
  });

  test('gap longer than 10 minutes does not invent a path', () {
    final points = [
      for (var i = 0; i < 4; i++)
        point('d$i', origin.add(Duration(seconds: 20 * i)), depotLat, depotLon),
      for (var i = 0; i < 4; i++)
        point(
          'w$i',
          origin.add(Duration(minutes: 20 + i)),
          warehouseLat,
          warehouseLon,
        ),
    ];
    final result = engine.replay(
      vehicleId: 'v',
      points: points,
      fences: [depot, warehouse],
    );
    expect(result.currentGeofenceId, 'wh');
    expect(result.trips.where((t) => t.status == TripStatus.completed), isEmpty);
  });

  test('innermost overlapping fence wins', () {
    final outer = fence(id: 'outer', lat: depotLat, lon: depotLon, radius: 3000);
    final inner = fence(id: 'inner', lat: depotLat, lon: depotLon, radius: 800);
    final points = [
      for (var i = 0; i < 4; i++)
        point('p$i', origin.add(Duration(seconds: 20 * i)), depotLat, depotLon),
    ];
    final result = engine.replay(
      vehicleId: 'v',
      points: points,
      fences: [outer, inner],
    );
    expect(result.currentGeofenceId, 'inner');
  });

  test('geofence version valid_to hides the fence for later points', () {
    final cut = origin.add(const Duration(minutes: 5));
    final versioned = fence(
      id: 'depot',
      lat: depotLat,
      lon: depotLon,
      to: cut,
    );
    final points = [
      for (var i = 0; i < 4; i++)
        point('early$i', origin.add(Duration(seconds: 20 * i)), depotLat, depotLon),
      for (var i = 0; i < 4; i++)
        point('late$i', cut.add(Duration(seconds: 20 * i)), depotLat, depotLon),
    ];
    final result = engine.replay(vehicleId: 'v', points: points, fences: [versioned]);
    expect(result.currentGeofenceId, isNull);
  });

  test('returning to the origin geofence is a valid completed trip', () {
    final points = <LocationSample>[
      for (var i = 0; i < 4; i++)
        point('a$i', origin.add(Duration(seconds: 20 * i)), depotLat, depotLon),
      for (var i = 1; i <= 5; i++)
        point(
          'mid$i',
          origin.add(Duration(seconds: 80 + 20 * i)),
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, 0.5).lat,
          lerpLatLon(depotLat, depotLon, warehouseLat, warehouseLon, 0.5).lon,
        ),
      for (var i = 0; i < 4; i++)
        point(
          'b$i',
          origin.add(Duration(seconds: 220 + 20 * i)),
          depotLat,
          depotLon,
        ),
    ];
    final result = engine.replay(vehicleId: 'v', points: points, fences: [depot]);
    expect(result.trips, hasLength(1));
    expect(result.trips.single.originGeofenceId, 'depot');
    expect(result.trips.single.destGeofenceId, 'depot');
    expect(result.trips.single.status, TripStatus.completed);
  });
}
