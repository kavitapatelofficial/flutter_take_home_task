/// Every judgement call this app makes, in one file.
///
/// The spec's data model has cases it deliberately does not decide for us:
/// what "stale" means per signal versus per vehicle, what a status chip should
/// say when the signals it depends on have gone quiet, when a GPS fix is good
/// enough to move a vehicle across a fence, what happens to an alert whose
/// driving signal stops reporting. Those decisions live here rather than being
/// scattered through SQL strings and widgets, so that they can be read,
/// argued with, and changed in one place.
///
/// Anything in this file that a query also needs is exported as SQL through
/// [RuleSql] so the two can never drift apart.
library;

/// Signals we store. Booleans ride as 0/1 doubles; the log is numeric-only so
/// that one table can hold every signal without a type column.
class Signals {
  static const soc = 'soc';
  static const rangeKm = 'range_km';
  static const speed = 'speed';
  static const batteryTemp = 'battery_temp';
  static const odometer = 'odometer';
  static const ignition = 'ignition';
  static const lat = 'lat';
  static const lon = 'lon';
  static const gpsAccuracy = 'gps_accuracy_m';

  /// The signals the readings register shows, in display order.
  static const registerOrder = <String>[
    soc,
    rangeKm,
    speed,
    batteryTemp,
    odometer,
  ];

  static const locationSignals = <String>[lat, lon, gpsAccuracy];

  static const labels = <String, String>{
    soc: 'State of charge',
    rangeKm: 'Range',
    speed: 'Speed',
    batteryTemp: 'Battery temperature',
    odometer: 'Odometer',
    ignition: 'Ignition',
    lat: 'Latitude',
    lon: 'Longitude',
    gpsAccuracy: 'GPS accuracy',
  };

  static const units = <String, String>{
    soc: '%',
    rangeKm: 'km',
    speed: 'km/h',
    batteryTemp: '°C',
    odometer: 'km',
    gpsAccuracy: 'm',
  };
}

class Rules {
  const Rules._();

  // ---------------------------------------------------------------------
  // Freshness
  // ---------------------------------------------------------------------

  /// A vehicle is OFFLINE when its newest packet is older than this.
  /// Given by the spec.
  static const vehicleOfflineAfter = Duration(minutes: 10);

  /// A *single signal* is STALE when its own newest reading is older than
  /// this.
  ///
  /// The spec gives us a vehicle-level staleness rule and separately asks the
  /// readings register for "its own age" and a STALE verdict per signal, so
  /// the two are genuinely different clocks. A truck can heartbeat SOC every
  /// minute while its odometer has not moved -- and so not been sent -- for an
  /// hour. We hold the per-signal window at the same 10 minutes as the vehicle
  /// window: one number to explain, and a signal that has not been mentioned
  /// in ten minutes is exactly as untrustworthy as a vehicle that has not been
  /// heard from in ten.
  static const signalStaleAfter = Duration(minutes: 10);

  /// Packets timestamped further into the future than this are rejected at
  /// ingest.
  ///
  /// Vehicle clocks drift and occasionally reset to epoch or to a wrong year.
  /// A packet from the future would otherwise pin the vehicle "fresh" forever
  /// and poison every age calculation. Inside the tolerance we accept the
  /// packet and clamp its age at zero; beyond it we refuse the packet and
  /// count it, because silently dropping data is how you end up debugging a
  /// missing vehicle at 2am.
  static const futureSkewTolerance = Duration(minutes: 5);

  // ---------------------------------------------------------------------
  // Alert thresholds (spec-given)
  // ---------------------------------------------------------------------

  static const socWarningBelow = 20.0;
  static const socCriticalBelow = 10.0;
  static const batteryTempCriticalAbove = 45.0;

  // ---------------------------------------------------------------------
  // Readings register verdict bands
  // ---------------------------------------------------------------------

  /// Bands used for the NORMAL/ALERT pill on signals that are not themselves
  /// alert conditions. Speed and odometer have no meaningful "bad" value for a
  /// fleet list, so they are always NORMAL when fresh.
  static const batteryTempWarnAbove = 45.0;

  // ---------------------------------------------------------------------
  // Geofence transition detection
  // ---------------------------------------------------------------------

  /// Fixes reported with an accuracy circle larger than this are ignored when
  /// deciding transitions.
  ///
  /// They are still stored and still drawn in history -- we do not destroy
  /// data -- but a fix that admits it could be 300 m off cannot be allowed to
  /// move a vehicle across a 200 m fence. Vehicles in urban canyons and multi
  /// storey car parks emit these constantly.
  static const gpsMaxAccuracyMetres = 100.0;

  /// Minimum hysteresis band around the fence edge, in metres.
  ///
  /// A vehicle parked exactly on a fence boundary with 10 m of GPS noise would
  /// otherwise emit an entry/exit pair every few seconds and manufacture
  /// hundreds of trips. Entry requires the fix to be inside by at least this
  /// margin, exit requires it to be outside by at least this margin, and
  /// between the two the previous state simply persists.
  static const geofenceHysteresisMetres = 25.0;

  /// The effective margin also grows with the fix's own reported accuracy: a
  /// fix that says it is +/- 60 m must clear the edge by 60 m, not 25 m.
  static double hysteresisFor(double? accuracyMetres) {
    final accuracy = accuracyMetres ?? 0;
    return accuracy > geofenceHysteresisMetres
        ? accuracy
        : geofenceHysteresisMetres;
  }

  /// Number of consecutive qualifying fixes needed before a state change is
  /// confirmed.
  ///
  /// One fix is a rumour, two is a decision. This is the cheapest defence
  /// against a single wild outlier that passed the accuracy gate, and it costs
  /// us only the interval between two fixes in transition latency. A vehicle
  /// that emits one fix inside a fence and then goes silent forever stays
  /// outside, which is the conservative answer.
  static const confirmationFixes = 2;

  /// A transition whose two bracketing fixes are further apart in event time
  /// than this is recorded, but flagged uncertain.
  ///
  /// This is the basement case. A truck's last fix is inside the depot at
  /// 09:00 and its next is on a motorway at 11:30; it certainly left, but we
  /// have no idea when. We do not interpolate a fake crossing time. We record
  /// the exit at the first fix that confirms it (11:30), keep the window
  /// [09:00, 11:30] on the row, and mark the boundary uncertain so the UI can
  /// say so rather than quietly lying about a two and a half hour trip.
  static const maxCertainGap = Duration(minutes: 30);

  // ---------------------------------------------------------------------
  // Retention
  // ---------------------------------------------------------------------

  /// Raw per-reading resolution kept for this long.
  static const rawRetention = Duration(days: 7);

  /// Rolled-up buckets kept for this long past the raw window.
  static const rollupRetention = Duration(days: 90);

  /// Width of a rollup bucket.
  static const rollupBucket = Duration(minutes: 5);
}

/// Rule constants rendered as SQL literals.
///
/// The fleet list counts and the status chips are computed in SQL (the spec
/// asks for the counts in SQL, and pulling 500 rows into Dart to classify them
/// would defeat the point of having a database). That means the thresholds
/// exist twice unless something like this exists. Every query interpolates
/// from here.
class RuleSql {
  const RuleSql._();

  static String get offlineIntervalSeconds =>
      '${Rules.vehicleOfflineAfter.inSeconds}';

  static String get staleIntervalSeconds =>
      '${Rules.signalStaleAfter.inSeconds}';

  static const socWarningBelow = '${Rules.socWarningBelow}';
  static const socCriticalBelow = '${Rules.socCriticalBelow}';
  static const batteryTempCriticalAbove = '${Rules.batteryTempCriticalAbove}';

  /// Age in seconds of a timestamp column against a bound `now` parameter,
  /// clamped at zero so that a slightly-future clock reads as brand new
  /// rather than negative.
  static String ageSeconds(String column, String nowExpr) =>
      'greatest(0, date_diff(\'second\', $column, $nowExpr))';
}
