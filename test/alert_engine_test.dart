import 'package:fleet_console/core/constants.dart';
import 'package:fleet_console/data/engines/alert_engine.dart';
import 'package:fleet_console/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 7, 12);

  test('SOC below 20% is warning and below 10% is critical on one kind', () {
    final warn = AlertRules.evaluate(now: now, latest: {
      FleetRules.signalSoc: (value: 15, eventTime: now),
    });
    final crit = AlertRules.evaluate(now: now, latest: {
      FleetRules.signalSoc: (value: 8, eventTime: now),
    });
    expect(warn.where((e) => e.kind == FleetRules.alertSoc && e.inBreach), hasLength(1));
    expect(warn.firstWhere((e) => e.kind == FleetRules.alertSoc).severity, AlertSeverity.warning);
    expect(crit.firstWhere((e) => e.kind == FleetRules.alertSoc).severity, AlertSeverity.critical);
  });

  test('stale SOC cannot open an alert', () {
    final eval = AlertRules.evaluate(now: now, latest: {
      FleetRules.signalSoc: (
        value: 5,
        eventTime: now.subtract(const Duration(minutes: 11)),
      ),
    });
    final soc = eval.firstWhere((e) => e.kind == FleetRules.alertSoc);
    expect(soc.inBreach, isFalse);
    expect(soc.fresh, isFalse);
  });

  test('overheat is a separate critical alert', () {
    final eval = AlertRules.evaluate(now: now, latest: {
      FleetRules.signalSoc: (value: 80, eventTime: now),
      FleetRules.signalBatteryTemp: (value: 46, eventTime: now),
    });
    expect(eval.firstWhere((e) => e.kind == FleetRules.alertSoc).inBreach, isFalse);
    expect(eval.firstWhere((e) => e.kind == FleetRules.alertTemp).inBreach, isTrue);
    expect(eval.firstWhere((e) => e.kind == FleetRules.alertTemp).severity, AlertSeverity.critical);
  });

  test('register verdict is STALE when older than 10 minutes', () {
    expect(
      verdictFor(
        now: now,
        signal: FleetRules.signalSoc,
        value: 50,
        eventTime: now.subtract(const Duration(minutes: 11)),
      ),
      SignalVerdict.stale,
    );
  });

  test('never-reported signals have no verdict', () {
    expect(
      verdictFor(
        now: now,
        signal: FleetRules.signalRange,
        value: 12,
        eventTime: now,
      ),
      SignalVerdict.normal,
    );
  });
}
