/// Wall-clock time, injectable.
///
/// Every freshness decision in this app is "now minus an event time", so a
/// hard-coded DateTime.now() would make those decisions untestable.
/// Production uses [SystemClock]; tests pin a [FixedClock] and move it by hand.
abstract class Clock {
  DateTime nowUtc();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

class FixedClock implements Clock {
  FixedClock(DateTime now) : _now = now.toUtc();

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  set now(DateTime value) => _now = value.toUtc();

  void advance(Duration by) => _now = _now.add(by);
}
