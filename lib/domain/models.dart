enum VehicleStatus { offline, moving, idle, stopped }

enum AlertSeverity { warning, critical }

enum SignalVerdict { normal, alert, stale }

enum TripStatus { inProgress, completed }

enum FleetFilter { all, moving, idle, stopped, offline }

class VehicleRow {
  const VehicleRow({
    required this.id,
    required this.regNumber,
    required this.model,
    required this.status,
    this.soc,
    this.rangeKm,
    this.speed,
    this.ignitionOn,
    this.lastPing,
    this.currentGeofenceId,
    this.currentGeofenceName,
    this.openAlertCount = 0,
    this.hasCriticalAlert = false,
  });

  final String id;
  final String regNumber;
  final String model;
  final VehicleStatus status;
  final double? soc;
  final double? rangeKm;
  final double? speed;
  final bool? ignitionOn;
  final DateTime? lastPing;
  final String? currentGeofenceId;
  final String? currentGeofenceName;
  final int openAlertCount;
  final bool hasCriticalAlert;
}

class SignalReading {
  const SignalReading({
    required this.signal,
    required this.label,
    required this.unit,
    this.value,
    this.eventTime,
    this.verdict,
  });

  final String signal;
  final String label;
  final String unit;
  final double? value;
  final DateTime? eventTime;
  final SignalVerdict? verdict;
}

class VehicleAlert {
  const VehicleAlert({
    required this.id,
    required this.vehicleId,
    required this.kind,
    required this.severity,
    required this.openedAt,
    this.resolvedAt,
    this.dismissedAt,
    this.dismissReason,
  });

  final String id;
  final String vehicleId;
  final String kind;
  final AlertSeverity severity;
  final DateTime openedAt;
  final DateTime? resolvedAt;
  final DateTime? dismissedAt;
  final String? dismissReason;

  bool get isOpen => resolvedAt == null && dismissedAt == null;

  String get title => switch (kind) {
        'battery_soc' => severity == AlertSeverity.critical
            ? 'Battery critically low'
            : 'Low battery',
        'battery_temp' => 'Battery overheating',
        _ => kind,
      };
}

class Geofence {
  const Geofence({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.active,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.deactivatedAt,
    this.vehicleCount = 0,
  });

  final String id;
  final String name;
  final double lat;
  final double lon;
  final double radiusM;
  final bool active;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deactivatedAt;
  final int vehicleCount;
}

class Trip {
  const Trip({
    required this.id,
    required this.vehicleId,
    required this.originGeofenceId,
    required this.startedAt,
    required this.status,
    this.originName,
    this.destGeofenceId,
    this.destName,
    this.endedAt,
  });

  final String id;
  final String vehicleId;
  final String originGeofenceId;
  final String? originName;
  final String? destGeofenceId;
  final String? destName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final TripStatus status;
}

class SocPoint {
  const SocPoint(this.time, this.soc);
  final DateTime time;
  final double soc;
}

class FilterCounts {
  const FilterCounts({
    required this.all,
    required this.moving,
    required this.idle,
    required this.stopped,
    required this.offline,
  });

  final int all;
  final int moving;
  final int idle;
  final int stopped;
  final int offline;

  int forFilter(FleetFilter filter) => switch (filter) {
        FleetFilter.all => all,
        FleetFilter.moving => moving,
        FleetFilter.idle => idle,
        FleetFilter.stopped => stopped,
        FleetFilter.offline => offline,
      };
}

class FleetSnapshot {
  const FleetSnapshot({
    required this.vehicles,
    required this.counts,
    required this.asOf,
    required this.queryMicros,
  });

  final List<VehicleRow> vehicles;
  final FilterCounts counts;
  final DateTime asOf;
  final int queryMicros;
}

class TelemetryPacket {
  const TelemetryPacket({
    required this.id,
    required this.vehicleId,
    required this.eventTime,
    required this.signals,
  });

  final String id;
  final String vehicleId;
  final DateTime eventTime;

  /// Sparse map: a packet may carry only a subset of signals.
  final Map<String, double> signals;
}

class LocationSample {
  const LocationSample({
    required this.packetId,
    required this.eventTime,
    required this.lat,
    required this.lon,
    this.accuracyM,
  });

  final String packetId;
  final DateTime eventTime;
  final double lat;
  final double lon;
  final double? accuracyM;
}

class FenceVersion {
  const FenceVersion({
    required this.geofenceId,
    required this.version,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.validFrom,
    this.validTo,
  });

  final String geofenceId;
  final int version;
  final String name;
  final double lat;
  final double lon;
  final double radiusM;
  final DateTime validFrom;
  final DateTime? validTo;

  bool validAt(DateTime t) {
    if (t.isBefore(validFrom)) return false;
    if (validTo == null) return true;
    return t.isBefore(validTo!);
  }
}

class ConfirmedTransition {
  const ConfirmedTransition({
    required this.id,
    required this.vehicleId,
    required this.geofenceId,
    required this.geofenceVersion,
    required this.kind,
    required this.eventTime,
    this.packetId,
  });

  final String id;
  final String vehicleId;
  final String geofenceId;
  final int geofenceVersion;

  /// `confirmed_enter` or `confirmed_exit`
  final String kind;
  final DateTime eventTime;
  final String? packetId;
}

class ReplayResult {
  const ReplayResult({
    required this.events,
    required this.trips,
    this.currentGeofenceId,
  });

  final List<ConfirmedTransition> events;
  final List<Trip> trips;
  final String? currentGeofenceId;
}

class IngestResult {
  const IngestResult({
    required this.accepted,
    required this.duplicate,
  });

  final bool accepted;
  final bool duplicate;

  static const skippedDuplicate = IngestResult(accepted: false, duplicate: true);
  static const stored = IngestResult(accepted: true, duplicate: false);
}
