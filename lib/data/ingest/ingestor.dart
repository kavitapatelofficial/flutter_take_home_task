import '../../core/clock.dart';
import '../../domain/rules.dart';
import '../db/fleet_db.dart';
import 'packet.dart';

/// Writes telemetry into the log.
///
/// The whole batch goes through a temp table and then four set-based
/// statements. The alternative -- a prepared INSERT per signal -- would be
/// several thousand round trips to the database isolate for a single burst
/// from a vehicle coming out of a basement, which is exactly the case that has
/// to be fast.
///
/// Everything here is idempotent. Feeding the same batch twice, or feeding a
/// batch that overlaps one already stored, leaves the database in the state it
/// would have reached from the union of the two.
class Ingestor {
  Ingestor(this._db, this._clock);

  final FleetDb _db;
  final Clock _clock;

  static const _rawColumns =
      'vehicle_id, signal, event_time, ingest_time, value, packet_id';

  Future<IngestResult> ingest(List<TelemetryPacket> packets) async {
    if (packets.isEmpty) return IngestResult.empty;

    final now = _clock.nowUtc();
    final horizon = now.add(Rules.futureSkewTolerance);

    final accepted = <TelemetryPacket>[];
    final rejected = <String, int>{};
    final rejectedRows = <List<Object?>>[];

    for (final packet in packets) {
      // A vehicle clock that has drifted into next week would otherwise pin
      // the truck permanently fresh and poison every age on the screen. We
      // refuse it, and we write down that we refused it.
      if (packet.eventTime.isAfter(horizon)) {
        rejected['clock_skew_future'] = (rejected['clock_skew_future'] ?? 0) + 1;
        rejectedRows.add([
          packet.packetId,
          packet.vehicleId,
          packet.eventTime,
          now,
          'clock_skew_future',
        ]);
        continue;
      }
      if (packet.signals.isEmpty) {
        rejected['empty_packet'] = (rejected['empty_packet'] ?? 0) + 1;
        rejectedRows.add([
          packet.packetId,
          packet.vehicleId,
          packet.eventTime,
          now,
          'empty_packet',
        ]);
        continue;
      }
      accepted.add(packet);
    }

    if (rejectedRows.isNotEmpty) {
      await _insertRows(
        'rejected_packets',
        5,
        rejectedRows.expand((r) => r).toList(),
        rejectedRows.length,
      );
    }

    if (accepted.isEmpty) {
      return IngestResult(
        accepted: 0,
        duplicates: 0,
        rejected: rejected,
        touched: const {},
      );
    }

    return _db.transaction(() async {
      await _stageBatch(accepted, now);

      // Which packets in the batch are genuinely new? Decided before anything
      // is written, so that a packet already on disk contributes no readings
      // no matter how many times it appears in this batch.
      await _db.execute('''
        CREATE OR REPLACE TEMP TABLE ingest_new AS
        SELECT DISTINCT packet_id
        FROM ingest_batch b
        WHERE NOT EXISTS (
          SELECT 1 FROM packets p WHERE p.packet_id = b.packet_id
        )
      ''');

      final newCount = (await _db.selectOne(
        'SELECT count(*) AS n FROM ingest_new',
      ))!['n'] as int;

      if (newCount == 0) {
        return IngestResult(
          accepted: 0,
          duplicates: accepted.length,
          rejected: rejected,
          touched: const {},
        );
      }

      await _db.execute('''
        INSERT INTO signal_readings ($_rawColumns)
        SELECT $_rawColumns
        FROM ingest_batch JOIN ingest_new USING (packet_id)
      ''');

      await _db.execute('''
        INSERT INTO packets
        SELECT packet_id,
               any_value(vehicle_id),
               any_value(event_time),
               any_value(ingest_time),
               count(*)
        FROM ingest_batch JOIN ingest_new USING (packet_id)
        GROUP BY packet_id
      ''');

      // Current state. The row_number keeps one row per (vehicle, signal) so
      // DuckDB is never asked to resolve the same conflict twice in one
      // statement, and the WHERE on the update is the late-packet rule: a
      // reading only becomes current if it was measured after what is already
      // current.
      await _db.execute('''
        INSERT INTO latest_readings (vehicle_id, signal, event_time, value)
        SELECT vehicle_id, signal, event_time, value FROM (
          SELECT vehicle_id, signal, event_time, value,
                 row_number() OVER (
                   PARTITION BY vehicle_id, signal
                   ORDER BY event_time DESC, ingest_time DESC, packet_id DESC
                 ) AS rn
          FROM ingest_batch JOIN ingest_new USING (packet_id)
        ) WHERE rn = 1
        ON CONFLICT (vehicle_id, signal) DO UPDATE
          SET value = excluded.value, event_time = excluded.event_time
          WHERE excluded.event_time > latest_readings.event_time
      ''');

      final touchedRows = await _db.select('''
        SELECT vehicle_id, min(event_time) AS from_time
        FROM ingest_batch JOIN ingest_new USING (packet_id)
        GROUP BY vehicle_id
      ''');

      return IngestResult(
        accepted: newCount,
        duplicates: accepted.length - newCount,
        rejected: rejected,
        touched: {
          for (final row in touchedRows)
            row['vehicle_id'] as String: row['from_time'] as DateTime,
        },
      );
    });
  }

  /// Lands the batch in a temp table, collapsing repeats of the same
  /// (packet, signal) that arrived inside one batch.
  Future<void> _stageBatch(List<TelemetryPacket> packets, DateTime now) async {
    await _db.execute('''
      CREATE OR REPLACE TEMP TABLE ingest_raw (
        vehicle_id  VARCHAR,
        signal      VARCHAR,
        event_time  TIMESTAMP,
        ingest_time TIMESTAMP,
        value       DOUBLE,
        packet_id   VARCHAR
      )
    ''');

    final values = <Object?>[];
    var rows = 0;
    for (final packet in packets) {
      for (final entry in packet.signals.entries) {
        values.addAll([
          packet.vehicleId,
          entry.key,
          packet.eventTime,
          now,
          entry.value,
          packet.packetId,
        ]);
        rows++;
      }
    }
    await _insertRows('ingest_raw', 6, values, rows);

    await _db.execute('''
      CREATE OR REPLACE TEMP TABLE ingest_batch AS
      SELECT $_rawColumns FROM (
        SELECT *, row_number() OVER (
          PARTITION BY packet_id, signal ORDER BY ingest_time
        ) AS rn
        FROM ingest_raw
      ) WHERE rn = 1
    ''');
  }

  /// Multi-row INSERT in chunks, to stay under DuckDB's bound-parameter limit.
  Future<void> _insertRows(
    String table,
    int columns,
    List<Object?> flatValues,
    int rowCount,
  ) async {
    const maxRowsPerStatement = 500;
    final placeholder = '(${List.filled(columns, '?').join(', ')})';

    var offset = 0;
    while (offset < rowCount) {
      final chunk = (rowCount - offset).clamp(0, maxRowsPerStatement);
      final sql = 'INSERT INTO $table VALUES '
          '${List.filled(chunk, placeholder).join(', ')}';
      await _db.execute(
        sql,
        flatValues.sublist(offset * columns, (offset + chunk) * columns),
      );
      offset += chunk;
    }
  }
}
