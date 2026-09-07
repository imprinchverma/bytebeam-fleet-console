import '../../core/constants.dart';
import '../../domain/models.dart';

class AlertEvaluation {
  const AlertEvaluation({
    required this.kind,
    this.severity,
    required this.inBreach,
    required this.fresh,
  });

  final String kind;
  final AlertSeverity? severity;
  final bool inBreach;
  final bool fresh;
}

/// Fresh-only thresholds. SOC is one escalating alert, not two rows.
class AlertRules {
  static List<AlertEvaluation> evaluate({
    required DateTime now,
    required Map<String, ({double value, DateTime eventTime})> latest,
  }) {
    return [
      _soc(now, latest[FleetRules.signalSoc]),
      _temp(now, latest[FleetRules.signalBatteryTemp]),
    ];
  }

  static AlertEvaluation _soc(
    DateTime now,
    ({double value, DateTime eventTime})? reading,
  ) {
    if (reading == null) {
      return const AlertEvaluation(
        kind: FleetRules.alertSoc,
        inBreach: false,
        fresh: false,
      );
    }
    final fresh = now.difference(reading.eventTime) <= FleetRules.staleAfter;
    if (!fresh) {
      return const AlertEvaluation(
        kind: FleetRules.alertSoc,
        inBreach: false,
        fresh: false,
      );
    }
    if (reading.value < FleetRules.criticalBatteryPct) {
      return const AlertEvaluation(
        kind: FleetRules.alertSoc,
        severity: AlertSeverity.critical,
        inBreach: true,
        fresh: true,
      );
    }
    if (reading.value < FleetRules.lowBatteryPct) {
      return const AlertEvaluation(
        kind: FleetRules.alertSoc,
        severity: AlertSeverity.warning,
        inBreach: true,
        fresh: true,
      );
    }
    return const AlertEvaluation(
      kind: FleetRules.alertSoc,
      inBreach: false,
      fresh: true,
    );
  }

  static AlertEvaluation _temp(
    DateTime now,
    ({double value, DateTime eventTime})? reading,
  ) {
    if (reading == null) {
      return const AlertEvaluation(
        kind: FleetRules.alertTemp,
        inBreach: false,
        fresh: false,
      );
    }
    final fresh = now.difference(reading.eventTime) <= FleetRules.staleAfter;
    if (!fresh) {
      return const AlertEvaluation(
        kind: FleetRules.alertTemp,
        inBreach: false,
        fresh: false,
      );
    }
    if (reading.value > FleetRules.overheatC) {
      return const AlertEvaluation(
        kind: FleetRules.alertTemp,
        severity: AlertSeverity.critical,
        inBreach: true,
        fresh: true,
      );
    }
    return const AlertEvaluation(
      kind: FleetRules.alertTemp,
      inBreach: false,
      fresh: true,
    );
  }
}

SignalVerdict? verdictFor({
  required DateTime now,
  required String signal,
  required double value,
  required DateTime eventTime,
}) {
  if (now.difference(eventTime) > FleetRules.staleAfter) {
    return SignalVerdict.stale;
  }
  if (signal == FleetRules.signalSoc && value < FleetRules.lowBatteryPct) {
    return SignalVerdict.alert;
  }
  if (signal == FleetRules.signalBatteryTemp && value > FleetRules.overheatC) {
    return SignalVerdict.alert;
  }
  return SignalVerdict.normal;
}
