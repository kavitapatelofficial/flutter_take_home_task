import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_take_home_task/data/repo/fleet_repository.dart';
import 'package:flutter_take_home_task/domain/model/vehicle_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_harness.dart';

/// One vehicle's worth of current state, as ages rather than timestamps.
class Case {
  const Case(
    this.name, {
    this.pingAgo,
    this.speed,
    this.speedAgo,
    this.ignition,
    this.ignitionAgo,
    required this.expected,
  });

  final String name;
  final Duration? pingAgo;
  final double? speed;
  final Duration? speedAgo;
  final bool? ignition;
  final Duration? ignitionAgo;
  final VehicleStatus expected;
}

void main() {
  late FleetDb db;
  late FixedClock clock;
  late FleetRepository repo;

  final now = DateTime.utc(2026, 9, 4, 12, 0);

  // The table below is the specification of the status ladder. Both the SQL
  // in Q.statusExpression and the Dart in classifyStatus() are checked
  // against it, which is the only thing keeping the two honest.
  const cases = [
    Case('never reported anything', expected: VehicleStatus.offline),
    Case(
      'silent for eleven minutes',
      pingAgo: Duration(minutes: 11),
      speed: 60,
      speedAgo: Duration(minutes: 11),
      expected: VehicleStatus.offline,
    ),
    Case(
      'just inside the offline window and moving',
      pingAgo: Duration(minutes: 9),
      speed: 42,
      speedAgo: Duration(minutes: 9),
      expected: VehicleStatus.moving,
    ),
    Case(
      'stationary with ignition on',
      pingAgo: Duration(minutes: 1),
      speed: 0,
      speedAgo: Duration(minutes: 1),
      ignition: true,
      ignitionAgo: Duration(minutes: 1),
      expected: VehicleStatus.idle,
    ),
    Case(
      'stationary with ignition off',
      pingAgo: Duration(minutes: 1),
      speed: 0,
      speedAgo: Duration(minutes: 1),
      ignition: false,
      ignitionAgo: Duration(minutes: 1),
      expected: VehicleStatus.stopped,
    ),
    Case(
      'moving beats everything else',
      pingAgo: Duration(minutes: 1),
      speed: 55,
      speedAgo: Duration(minutes: 1),
      ignition: false,
      ignitionAgo: Duration(minutes: 1),
      expected: VehicleStatus.moving,
    ),
    // The interesting ones: online, but the signals the ladder needs have
    // gone quiet on their own.
    Case(
      'online on some other signal, speed long stale',
      pingAgo: Duration(minutes: 1),
      speed: 70,
      speedAgo: Duration(minutes: 30),
      expected: VehicleStatus.stopped,
    ),
    Case(
      'stale speed of zero with a fresh ignition off',
      pingAgo: Duration(minutes: 1),
      speed: 0,
      speedAgo: Duration(minutes: 30),
      ignition: false,
      ignitionAgo: Duration(minutes: 2),
      expected: VehicleStatus.stopped,
    ),
    Case(
      'fresh zero speed but ignition too old to call it idle',
      pingAgo: Duration(minutes: 1),
      speed: 0,
      speedAgo: Duration(minutes: 1),
      ignition: true,
      ignitionAgo: Duration(minutes: 40),
      expected: VehicleStatus.stopped,
    ),
    Case(
      'clock slightly ahead reads as brand new, not negative',
      pingAgo: Duration(minutes: -2),
      speed: 30,
      speedAgo: Duration(minutes: -2),
      expected: VehicleStatus.moving,
    ),
  ];

  setUp(() async {
    db = await openTestDb();
    clock = FixedClock(now);
    repo = FleetRepository(db, clock);

    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      await db.execute(
        'INSERT INTO vehicles VALUES (?, ?, ?)',
        ['v$i', 'REG$i', 'Model'],
      );
      Future<void> put(String signal, double value, Duration ago) =>
          db.execute('INSERT INTO latest_readings VALUES (?, ?, ?, ?)',
              ['v$i', signal, now.subtract(ago), value]);

      if (c.pingAgo != null) {
        // The heartbeat signal: something arrived, not necessarily speed.
        await put('soc', 55, c.pingAgo!);
      }
      if (c.speed != null) await put('speed', c.speed!, c.speedAgo!);
      if (c.ignition != null) {
        await put('ignition', c.ignition! ? 1 : 0, c.ignitionAgo!);
      }
    }
  });
  tearDown(() async => db.close());

  test('the SQL status ladder matches the specification table', () async {
    final vehicles = await repo.list();
    final byId = {for (final v in vehicles) v.vehicleId: v};

    for (var i = 0; i < cases.length; i++) {
      expect(
        byId['v$i']!.status,
        cases[i].expected,
        reason: 'SQL disagrees for: ${cases[i].name}',
      );
    }
  });

  test('the Dart mirror agrees with the SQL for every case', () {
    for (final c in cases) {
      expect(
        classifyStatus(
          sinceLastPing: c.pingAgo == null
              ? null
              : _clamp(_maxOf(c.pingAgo!, c.speedAgo, c.ignitionAgo)),
          speed: c.speed,
          speedAge: c.speedAgo == null ? null : _clamp(c.speedAgo!),
          ignitionOn: c.ignition,
          ignitionAge: c.ignitionAgo == null ? null : _clamp(c.ignitionAgo!),
        ),
        c.expected,
        reason: 'Dart disagrees for: ${c.name}',
      );
    }
  });

  test('filter counts are computed in SQL and cover the whole fleet', () async {
    final counts = await repo.counts();
    expect(counts.total, cases.length);

    for (final status in VehicleStatus.values) {
      final listed = await repo.list(status: status);
      expect(listed, hasLength(counts[status]),
          reason: 'chip count and filtered list disagree for ${status.label}');
    }
  });

  test('a filter with no matches yields an empty list, not an error', () async {
    final none = await repo.list(status: VehicleStatus.idle, query: 'nothing');
    expect(none, isEmpty);
  });

  test('search filters on registration and model', () async {
    expect(await repo.list(query: 'REG3'), hasLength(1));
    expect(await repo.list(query: 'Model'), hasLength(cases.length));
  });

  test('advancing the clock alone takes the fleet offline', () async {
    expect(
      (await repo.counts())[VehicleStatus.offline],
      lessThan(cases.length),
    );
    clock.advance(const Duration(hours: 2));
    expect((await repo.counts())[VehicleStatus.offline], cases.length);
  });
}

/// Last ping is the newest of the signals present, matching how
/// vehicle_last_ping is defined.
Duration _maxOf(Duration a, Duration? b, Duration? c) {
  var smallest = a;
  for (final d in [b, c]) {
    if (d != null && d < smallest) smallest = d;
  }
  return smallest;
}

Duration _clamp(Duration d) => d.isNegative ? Duration.zero : d;
