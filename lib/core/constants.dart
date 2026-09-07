/// Operator-facing thresholds from the assignment, in one place.
abstract final class FleetRules {
  static const staleAfter = Duration(minutes: 10);
  static const lowBatteryPct = 20.0;
  static const criticalBatteryPct = 10.0;
  static const overheatC = 45.0;
  static const undoWindow = Duration(seconds: 5);

  static const gpsAccuracyMaxM = 50.0;
  static const geofenceHysteresisM = 25.0;
  static const dwellSamples = 3;
  static const dwellDuration = Duration(seconds: 60);
  static const locationGapBreak = Duration(minutes: 10);

  static const retentionRaw = Duration(days: 7);

  static const signalSoc = 'soc';
  static const signalRange = 'range';
  static const signalSpeed = 'speed';
  static const signalBatteryTemp = 'battery_temp';
  static const signalOdometer = 'odometer';
  static const signalIgnition = 'ignition';
  static const signalLat = 'lat';
  static const signalLon = 'lon';
  static const signalGpsAccuracy = 'gps_accuracy';

  static const alertSoc = 'battery_soc';
  static const alertTemp = 'battery_temp';

  static const registerSignals = <String>[
    signalSoc,
    signalRange,
    signalSpeed,
    signalBatteryTemp,
    signalOdometer,
  ];
}
