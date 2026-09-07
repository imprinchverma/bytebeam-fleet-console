import '../../core/constants.dart';
import '../../core/geo.dart';
import '../../domain/models.dart';

/// Confirmed geofence enter/exit from event-time location history.
///
/// Strategy (see docs/DECISIONS.md):
/// duplicates are gone before we get here; we walk event_time order;
/// drop inaccurate GPS; hysteresis + dwell; gaps break membership;
/// innermost fence wins overlaps; trips are derived from confirmed transitions.
class GeofenceReplay {
  ReplayResult replay({
    required String vehicleId,
    required List<LocationSample> points,
    required List<FenceVersion> fences,
  }) {
    final ordered = [...points]..sort((a, b) => a.eventTime.compareTo(b.eventTime));
    final usable = <LocationSample>[];
    LocationSample? prevKept;
    for (final p in ordered) {
      if (p.accuracyM != null && p.accuracyM! > FleetRules.gpsAccuracyMaxM) {
        continue;
      }
      if (prevKept != null && p.eventTime.isAtSameMomentAs(prevKept.eventTime)) {
        continue;
      }
      usable.add(p);
      prevKept = p;
    }

    String? candidateId;
    int dwellCount = 0;
    DateTime? dwellStart;
    String? confirmedId;
    final events = <ConfirmedTransition>[];
    LocationSample? prev;

    void resetDwell(String? next, DateTime at) {
      candidateId = next;
      dwellCount = next == null && confirmedId == null ? 0 : 1;
      dwellStart = at;
    }

    for (final point in usable) {
      if (prev != null &&
          point.eventTime.difference(prev.eventTime) > FleetRules.locationGapBreak) {
        candidateId = null;
        dwellCount = 0;
        dwellStart = null;
        confirmedId = null;
      }

      final next = _candidateFence(point, fences, confirmedId);
      if (next == candidateId) {
        dwellCount += 1;
        dwellStart ??= point.eventTime;
      } else {
        resetDwell(next, point.eventTime);
      }

      final dwellTime = dwellStart == null
          ? Duration.zero
          : point.eventTime.difference(dwellStart!);
      final confirmed = dwellCount >= FleetRules.dwellSamples ||
          dwellTime >= FleetRules.dwellDuration;

      if (confirmed && next != confirmedId) {
        if (confirmedId != null) {
          final fence = _fenceAt(confirmedId, point.eventTime, fences);
          events.add(
            ConfirmedTransition(
              id: _eventId(vehicleId, 'confirmed_exit', confirmedId, point.eventTime),
              vehicleId: vehicleId,
              geofenceId: confirmedId,
              geofenceVersion: fence?.version ?? 0,
              kind: 'confirmed_exit',
              eventTime: point.eventTime,
              packetId: point.packetId,
            ),
          );
        }
        if (next != null) {
          final fence = _fenceAt(next, point.eventTime, fences)!;
          events.add(
            ConfirmedTransition(
              id: _eventId(vehicleId, 'confirmed_enter', next, point.eventTime),
              vehicleId: vehicleId,
              geofenceId: next,
              geofenceVersion: fence.version,
              kind: 'confirmed_enter',
              eventTime: point.eventTime,
              packetId: point.packetId,
            ),
          );
        }
        confirmedId = next;
        dwellCount = 0;
        dwellStart = point.eventTime;
      }

      prev = point;
    }

    final trips = deriveTrips(vehicleId: vehicleId, events: events);
    return ReplayResult(
      events: events,
      trips: trips,
      currentGeofenceId: confirmedId,
    );
  }

  List<Trip> deriveTrips({
    required String vehicleId,
    required List<ConfirmedTransition> events,
  }) {
    final ordered = [...events]..sort((a, b) => a.eventTime.compareTo(b.eventTime));
    final trips = <Trip>[];
    Trip? active;

    for (final event in ordered) {
      if (event.kind == 'confirmed_exit') {
        active ??= Trip(
          id: _tripId(vehicleId, event.geofenceId, event.eventTime),
          vehicleId: vehicleId,
          originGeofenceId: event.geofenceId,
          startedAt: event.eventTime,
          status: TripStatus.inProgress,
        );
      } else if (event.kind == 'confirmed_enter' && active != null) {
        trips.add(
          Trip(
            id: active.id,
            vehicleId: vehicleId,
            originGeofenceId: active.originGeofenceId,
            destGeofenceId: event.geofenceId,
            startedAt: active.startedAt,
            endedAt: event.eventTime,
            status: TripStatus.completed,
          ),
        );
        active = null;
      }
    }
    if (active != null) trips.add(active);
    return trips;
  }

  String? _candidateFence(
    LocationSample point,
    List<FenceVersion> fences,
    String? confirmedId,
  ) {
    final valid = fences.where((f) => f.validAt(point.eventTime)).toList();
    final inside = <FenceVersion>[];
    for (final fence in valid) {
      final dist = haversineMeters(
        lat1: point.lat,
        lon1: point.lon,
        lat2: fence.lat,
        lon2: fence.lon,
      );
      if (dist <= fence.radiusM - FleetRules.geofenceHysteresisM) {
        inside.add(fence);
      }
    }
    if (inside.isNotEmpty) {
      inside.sort((a, b) {
        final r = a.radiusM.compareTo(b.radiusM);
        if (r != 0) return r;
        return a.geofenceId.compareTo(b.geofenceId);
      });
      return inside.first.geofenceId;
    }

    if (confirmedId != null) {
      final current = valid.where((f) => f.geofenceId == confirmedId);
      if (current.isNotEmpty) {
        final fence = current.first;
        final dist = haversineMeters(
          lat1: point.lat,
          lon1: point.lon,
          lat2: fence.lat,
          lon2: fence.lon,
        );
        if (dist < fence.radiusM + FleetRules.geofenceHysteresisM) {
          return confirmedId;
        }
      }
    }
    return null;
  }

  FenceVersion? _fenceAt(
    String id,
    DateTime at,
    List<FenceVersion> fences,
  ) {
    final matches = fences.where((f) => f.geofenceId == id && f.validAt(at));
    if (matches.isEmpty) return null;
    return matches.first;
  }

  String _eventId(String vehicleId, String kind, String fenceId, DateTime t) =>
      'evt_${vehicleId}_${kind}_${fenceId}_${t.microsecondsSinceEpoch}';

  String _tripId(String vehicleId, String originId, DateTime startedAt) =>
      'trip_${vehicleId}_${originId}_${startedAt.microsecondsSinceEpoch}';
}
