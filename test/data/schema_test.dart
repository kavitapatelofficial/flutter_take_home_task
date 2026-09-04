import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_harness.dart';

void main() {
  late FleetDb db;

  setUp(() async => db = await openTestDb());
  tearDown(() async => db.close());

  test('schema applies and records its version', () async {
    final row = await db.selectOne(
      "SELECT value FROM meta WHERE key = 'schema_version'",
    );
    expect(row!['value'], '1');
  });

  test('timestamps round-trip as UTC', () async {
    final at = DateTime.utc(2026, 3, 14, 9, 30, 15, 250);
    await db.execute(
      'INSERT INTO packets VALUES (?, ?, ?, ?, ?)',
      ['p1', 'v1', at, at, 3],
    );
    final row = await db.selectOne('SELECT event_time FROM packets');
    expect(row!['event_time'], at);
  });

  test('packet primary key makes re-ingest a no-op', () async {
    final at = DateTime.utc(2026, 3, 14, 9, 30);
    for (var i = 0; i < 3; i++) {
      await db.execute(
        'INSERT INTO packets VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING',
        ['p1', 'v1', at, at, 3],
      );
    }
    final row = await db.selectOne('SELECT count(*) AS n FROM packets');
    expect(row!['n'], 1);
  });

  test('guarded upsert lets a newer reading win and ignores a later-arriving '
      'older one', () async {
    Future<void> put(DateTime at, double value) => db.execute(
          'INSERT INTO latest_readings VALUES (?, ?, ?, ?) '
          'ON CONFLICT (vehicle_id, signal) DO UPDATE SET '
          '  value = excluded.value, event_time = excluded.event_time '
          'WHERE excluded.event_time > latest_readings.event_time',
          ['v1', 'soc', at, value],
        );

    await put(DateTime.utc(2026, 3, 14, 9, 0), 80);
    await put(DateTime.utc(2026, 3, 14, 9, 5), 78);
    // Arrives now, but was measured before the value already stored.
    await put(DateTime.utc(2026, 3, 14, 8, 55), 95);

    final row = await db.selectOne(
      'SELECT value, event_time FROM latest_readings',
    );
    expect(row!['value'], 78.0);
    expect(row['event_time'], DateTime.utc(2026, 3, 14, 9, 5));
  });

  test('location_fixes pivots three signals from one packet into one fix',
      () async {
    final at = DateTime.utc(2026, 3, 14, 9, 0);
    for (final (signal, value) in [
      ('lat', 12.9716),
      ('lon', 77.5946),
      ('gps_accuracy_m', 8.0),
    ]) {
      await db.execute(
        'INSERT INTO signal_readings VALUES (?, ?, ?, ?, ?, ?)',
        ['v1', signal, at, at, value, 'p1'],
      );
    }
    // A packet with no accuracy field still yields a usable fix.
    final later = DateTime.utc(2026, 3, 14, 9, 1);
    for (final (signal, value) in [('lat', 12.98), ('lon', 77.60)]) {
      await db.execute(
        'INSERT INTO signal_readings VALUES (?, ?, ?, ?, ?, ?)',
        ['v1', signal, later, later, value, 'p2'],
      );
    }

    final fixes = await db.select(
      'SELECT * FROM location_fixes ORDER BY event_time',
    );
    expect(fixes, hasLength(2));
    expect(fixes[0]['lat'], closeTo(12.9716, 1e-9));
    expect(fixes[0]['accuracy_m'], 8.0);
    expect(fixes[1]['accuracy_m'], isNull);
  });

  test('a latitude with no matching longitude is not a fix', () async {
    final at = DateTime.utc(2026, 3, 14, 9, 0);
    await db.execute(
      'INSERT INTO signal_readings VALUES (?, ?, ?, ?, ?, ?)',
      ['v1', 'lat', at, at, 12.97, 'p1'],
    );
    expect(await db.select('SELECT * FROM location_fixes'), isEmpty);
  });
}
