/// Injectable clock so tests can freeze "now" for stale/offline rules.
abstract class AppClock {
  DateTime now();
}

class SystemClock implements AppClock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

class FakeClock implements AppClock {
  FakeClock(DateTime now) : _now = now.toUtc();

  DateTime _now;

  @override
  DateTime now() => _now;

  void setNow(DateTime value) => _now = value.toUtc();

  void advance(Duration d) => _now = _now.add(d);
}
