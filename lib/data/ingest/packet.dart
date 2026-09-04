import '../../core/ids.dart';

/// One timestamped emission from one vehicle, carrying a subset of signals.
class TelemetryPacket {
  TelemetryPacket({
    required this.vehicleId,
    required DateTime eventTime,
    required this.signals,
    this.devicePacketId,
  }) : eventTime = eventTime.toUtc();

  final String vehicleId;
  final DateTime eventTime;
  final Map<String, double> signals;

  /// The id the device stamped on the packet, when it stamps one.
  final String? devicePacketId;

  /// The key this packet dedupes on.
  ///
  /// When the device gives us an id we trust it. When it does not, we hash the
  /// content: vehicle, event time, and every signal/value pair in sorted
  /// order. A flaky link retransmitting the same reading produces the same
  /// bytes and therefore the same id, so the retry lands on an existing
  /// primary key and does nothing.
  ///
  /// The deliberate consequence: two genuinely distinct packets that are
  /// identical in every field are treated as one. That is the right trade --
  /// a vehicle reporting the same SOC twice in the same millisecond carries no
  /// information the first one did not, and the alternative (accepting both)
  /// means a duplicated packet is indistinguishable from real data.
  late final String packetId = devicePacketId ??
      stableId([
        vehicleId,
        eventTime.microsecondsSinceEpoch,
        ...(signals.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)))
            .map((e) => '${e.key}=${e.value}'),
      ]);
}

/// What an ingest run did, so callers can drive the derived layers.
class IngestResult {
  const IngestResult({
    required this.accepted,
    required this.duplicates,
    required this.rejected,
    required this.touched,
  });

  /// Packets stored for the first time.
  final int accepted;

  /// Packets we had already seen and ignored.
  final int duplicates;

  /// Packets refused at the door, by reason.
  final Map<String, int> rejected;

  /// For each vehicle touched, the earliest event time in the batch.
  ///
  /// This is the trigger for re-derivation. A packet whose event time is older
  /// than work we have already done means the geofence and trip layers were
  /// computed from an incomplete picture and have to be recomputed from that
  /// point.
  final Map<String, DateTime> touched;

  static const empty = IngestResult(
    accepted: 0,
    duplicates: 0,
    rejected: {},
    touched: {},
  );
}
