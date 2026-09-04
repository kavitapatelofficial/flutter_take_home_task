import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/data/db/fleet_db.dart';
import 'package:flutter_take_home_task/data/ingest/ingestor.dart';
import 'package:flutter_take_home_task/data/ingest/packet.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_harness.dart';

void main() {
  late FleetDb db;
  late FixedClock clock;
  late Ingestor ingestor;

  final t0 = DateTime.utc(2026, 9, 4, 10, 0);

  setUp(() async {
    db = await openTestDb();
    clock = FixedClock(t0);
    ingestor = Ingestor(db, clock);
    await db.execute(
      "INSERT INTO vehicles VALUES ('v1', 'KA01AB1234', 'Model A')",
    );
  });
  tearDown(() async => db.close());

  TelemetryPacket packet(
    DateTime at,
    Map<String, double> signals, {
    String? id,
    String vehicle = 'v1',
  }) =>
      TelemetryPacket(
        vehicleId: vehicle,
        eventTime: at,
        signals: signals,
        devicePacketId: id,
      );

  Future<int> readingCount() async =>
      (await db.selectOne('SELECT count(*) AS n FROM signal_readings'))!['n']
          as int;

  Future<Map<String, Object?>?> latest(String signal) => db.selectOne(
        'SELECT * FROM latest_readings WHERE signal = ?',
        [signal],
      );

  group('deduplication', () {
    test('the same packet ingested twice stores one copy', () async {
      final p = packet(t0, {'soc': 55, 'speed': 0});
      final first = await ingestor.ingest([p]);
      final second = await ingestor.ingest([p]);

      expect(first.accepted, 1);
      expect(second.accepted, 0);
      expect(second.duplicates, 1);
      expect(await readingCount(), 2);
    });

    test('a retransmission with no device id dedupes on content', () async {
      // Two separately constructed packets, same content, no device id: the
      // modem retrying. They must collapse.
      await ingestor.ingest([packet(t0, {'soc': 55.0})]);
      await ingestor.ingest([packet(t0, {'soc': 55.0})]);
      expect(await readingCount(), 1);
    });

    test('same timestamp but a different value is a different packet',
        () async {
      await ingestor.ingest([packet(t0, {'soc': 55.0})]);
      await ingestor.ingest([packet(t0, {'soc': 56.0})]);
      expect(await readingCount(), 2);
    });

    test('duplicates inside a single batch collapse', () async {
      final p = packet(t0, {'soc': 55});
      final result = await ingestor.ingest([p, p, p]);
      expect(result.accepted, 1);
      expect(await readingCount(), 1);
    });
  });

  group('ordering', () {
    test('a late packet is stored but does not rewrite current state',
        () async {
      await ingestor.ingest([packet(t0, {'soc': 60})]);
      await ingestor.ingest([
        packet(t0.subtract(const Duration(minutes: 30)), {'soc': 90}),
      ]);

      final current = await latest('soc');
      expect(current!['value'], 60.0, reason: 'the older reading must not win');
      expect(current['event_time'], t0);
      expect(await readingCount(), 2, reason: 'but it is still in the log');
    });

    test('an out-of-order batch settles on the newest reading', () async {
      await ingestor.ingest([
        packet(t0.subtract(const Duration(minutes: 2)), {'soc': 70}),
        packet(t0, {'soc': 65}),
        packet(t0.subtract(const Duration(minutes: 1)), {'soc': 68}),
      ]);
      expect((await latest('soc'))!['value'], 65.0);
    });

    test('a backlog dumped after a basement stay lands in full', () async {
      final backlog = [
        for (var i = 60; i > 0; i--)
          packet(t0.subtract(Duration(minutes: i)), {'soc': 40 + i / 10}),
      ];
      final result = await ingestor.ingest(backlog);
      expect(result.accepted, 60);
      expect((await latest('soc'))!['event_time'],
          t0.subtract(const Duration(minutes: 1)));
    });
  });

  group('rejection', () {
    test('a packet from beyond the skew tolerance is refused and recorded',
        () async {
      final result = await ingestor.ingest([
        packet(t0.add(const Duration(hours: 2)), {'soc': 50}),
      ]);
      expect(result.accepted, 0);
      expect(result.rejected['clock_skew_future'], 1);
      expect(await readingCount(), 0);

      final row = await db.selectOne(
        'SELECT reason FROM rejected_packets',
      );
      expect(row!['reason'], 'clock_skew_future');
    });

    test('a small forward clock drift is accepted', () async {
      final result = await ingestor.ingest([
        packet(t0.add(const Duration(minutes: 2)), {'soc': 50}),
      ]);
      expect(result.accepted, 1);
    });

    test('an empty packet is refused', () async {
      final result = await ingestor.ingest([packet(t0, {})]);
      expect(result.rejected['empty_packet'], 1);
    });
  });

  test('touched reports the earliest event time per vehicle', () async {
    await db.execute(
      "INSERT INTO vehicles VALUES ('v2', 'KA01AB9999', 'Model B')",
    );
    final result = await ingestor.ingest([
      packet(t0, {'soc': 50}),
      packet(t0.subtract(const Duration(minutes: 5)), {'soc': 52}),
      packet(t0, {'soc': 80}, vehicle: 'v2'),
    ]);
    expect(result.touched['v1'], t0.subtract(const Duration(minutes: 5)));
    expect(result.touched['v2'], t0);
  });

  test('last ping tracks the newest reading across signals', () async {
    await ingestor.ingest([
      packet(t0.subtract(const Duration(minutes: 9)), {'odometer': 1000}),
      packet(t0, {'soc': 50}),
    ]);
    final row = await db.selectOne('SELECT last_ping FROM vehicle_last_ping');
    expect(row!['last_ping'], t0);
  });
}
