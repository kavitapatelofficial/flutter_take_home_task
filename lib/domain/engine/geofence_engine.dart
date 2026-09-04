import '../../core/geo.dart';
import '../rules.dart';

/// One position report.
class Fix {
  const Fix({
    required this.eventTime,
    required this.ingestTime,
    required this.packetId,
    required this.lat,
    required this.lon,
    this.accuracyM,
  });

  final DateTime eventTime;
  final DateTime ingestTime;
  final String packetId;
  final double lat;
  final double lon;
  final double? accuracyM;
}

/// A geofence as it was defined over some window of event time.
class FenceVersion {
  const FenceVersion({
    required this.geofenceId,
    required this.version,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.active,
    required this.validFrom,
    this.validTo,
  });

  final String geofenceId;
  final int version;
  final double lat;
  final double lon;
  final double radiusM;
  final bool active;
  final DateTime validFrom;
  final DateTime? validTo;

  bool coversEventTime(DateTime t) =>
      !t.isBefore(validFrom) && (validTo == null || t.isBefore(validTo!));
}

enum TransitionKind { entry, exit }

class GeofenceTransition {
  const GeofenceTransition({
    required this.geofenceId,
    required this.kind,
    required this.eventTime,
    required this.windowStart,
    required this.uncertain,
  });

  final String geofenceId;
  final TransitionKind kind;

  /// When we believe the crossing happened: the event time of the first fix
  /// that showed the vehicle on the new side.
  final DateTime eventTime;

  /// The last fix that showed it on the old side. Together with [eventTime]
  /// this brackets the true crossing.
  final DateTime? windowStart;

  /// True when that bracket is too wide to call the crossing time meaningful.
  final bool uncertain;
}

/// Whether a vehicle was inside a fence, and how sure we were.
enum _Side { inside, outside }

/// Per-fence state carried across an incremental run.
class FenceState {
  FenceState({
    this.inside,
    this.lastFixOnCurrentSide,
    this.candidateSide,
    this.candidateSince,
    this.candidateCount = 0,
  });

  /// Confirmed occupancy. Null means we have not yet seen a fix good enough
  /// to establish a baseline.
  bool? inside;

  /// Event time of the most recent fix that agreed with [inside]. This is the
  /// far edge of the bracket when a crossing is later confirmed.
  DateTime? lastFixOnCurrentSide;

  bool? candidateSide;
  DateTime? candidateSince;
  int candidateCount;
}

/// Turns a stream of position fixes into confirmed geofence crossings.
///
/// The problem this solves is that raw fixes lie in five different ways, and
/// each needs a different answer:
///
/// * **Duplicates.** Two packets carrying the same instant. The caller hands
///   us at most one fix per event time (first received wins, matching how
///   current state resolves ties), so the engine never sees them.
///
/// * **Late and out-of-order packets.** The engine is a fold over fixes sorted
///   by *event* time, never arrival time, and it is a pure function of that
///   sequence. Replaying with a late fix inserted in its rightful place gives
///   exactly the result we would have reached had it arrived on time. That is
///   the whole reason transitions are derived rather than accumulated: there
///   is no incremental state to patch, only a computation to redo.
///
/// * **GPS jitter.** A truck parked on a fence boundary with 10 m of noise
///   would emit an entry/exit pair every few seconds and manufacture hundreds
///   of trips. Two defences: a hysteresis band around the edge, inside which
///   we simply hold the previous state and say nothing, and a requirement for
///   [Rules.confirmationFixes] consecutive agreeing fixes before a change is
///   believed.
///
/// * **Inaccurate readings.** Fixes whose own reported accuracy is worse than
///   [Rules.gpsMaxAccuracyMetres] are not allowed to move a vehicle at all --
///   a fix admitting it could be 300 m off has no business crossing a 200 m
///   fence. Below that gate, accuracy still widens the hysteresis band, so a
///   +/- 60 m fix must clear the edge by 60 m rather than the nominal 25.
///
/// * **Missing intervals.** When the bracketing fixes straddle a gap longer
///   than [Rules.maxCertainGap] -- the vehicle was in a basement -- we do not
///   interpolate a crossing time we cannot know. The transition is recorded at
///   the first fix that confirms it, the window of ignorance is kept on the
///   row, and the row is flagged uncertain so the UI can say so.
///
/// Overlapping fences are not a special case here: each fence is folded
/// independently, so a vehicle can be inside three at once. Reconciling that
/// into one answer is the caller's job.
///
/// Geofence edits are handled by evaluating each fix against the fence
/// definition that was in force at *that fix's event time*. Editing a fence
/// therefore changes the future and leaves the past alone.
class GeofenceEngine {
  const GeofenceEngine({
    this.confirmationFixes = Rules.confirmationFixes,
    this.maxAccuracyMetres = Rules.gpsMaxAccuracyMetres,
    this.maxCertainGap = Rules.maxCertainGap,
  });

  final int confirmationFixes;
  final double maxAccuracyMetres;
  final Duration maxCertainGap;

  /// Folds [fixes] (which must already be in event-time order) over the fence
  /// definitions in [versions], mutating [seed] so the caller can persist the
  /// resume point.
  List<GeofenceTransition> run({
    required List<Fix> fixes,
    required List<FenceVersion> versions,
    required Map<String, FenceState> seed,
  }) {
    final byFence = <String, List<FenceVersion>>{};
    for (final version in versions) {
      (byFence[version.geofenceId] ??= []).add(version);
    }

    final transitions = <GeofenceTransition>[];

    for (final fix in fixes) {
      // The accuracy gate is applied once, not per fence: a fix we do not
      // trust is not trusted about anything.
      if (fix.accuracyM != null && fix.accuracyM! > maxAccuracyMetres) continue;

      for (final entry in byFence.entries) {
        final version = _versionAt(entry.value, fix.eventTime);
        // The fence did not exist yet, or was deactivated at this point in
        // event time. A deactivated fence stops producing crossings from its
        // deactivation onward, but the crossings it produced while active
        // stay on the record -- that is what keeps trip history readable
        // after a depot is retired.
        if (version == null || !version.active) continue;

        final state = seed.putIfAbsent(entry.key, FenceState.new);
        final transition = _step(fix, version, state);
        if (transition != null) transitions.add(transition);
      }
    }

    transitions.sort((a, b) {
      final byTime = a.eventTime.compareTo(b.eventTime);
      if (byTime != 0) return byTime;
      final byFenceId = a.geofenceId.compareTo(b.geofenceId);
      if (byFenceId != 0) return byFenceId;
      return a.kind.index.compareTo(b.kind.index);
    });
    return transitions;
  }

  GeofenceTransition? _step(Fix fix, FenceVersion fence, FenceState state) {
    final distance = haversineMetres(fix.lat, fix.lon, fence.lat, fence.lon);
    final margin = Rules.hysteresisFor(fix.accuracyM);

    final _Side? side;
    if (distance <= fence.radiusM - margin) {
      side = _Side.inside;
    } else if (distance >= fence.radiusM + margin) {
      side = _Side.outside;
    } else {
      // Inside the hysteresis band. We have no opinion; the previous state
      // stands and this fix is not evidence for or against a crossing.
      side = null;
    }
    if (side == null) return null;

    final isInside = side == _Side.inside;

    // First trustworthy fix for this fence: establish a baseline without
    // claiming a crossing. We did not observe the vehicle cross anything, so
    // we do not invent an event.
    if (state.inside == null) {
      state
        ..inside = isInside
        ..lastFixOnCurrentSide = fix.eventTime
        ..candidateSide = null
        ..candidateCount = 0;
      return null;
    }

    if (isInside == state.inside) {
      state
        ..lastFixOnCurrentSide = fix.eventTime
        ..candidateSide = null
        ..candidateSince = null
        ..candidateCount = 0;
      return null;
    }

    // Disagrees with the confirmed state: a candidate crossing.
    if (state.candidateSide == isInside) {
      state.candidateCount++;
    } else {
      state
        ..candidateSide = isInside
        ..candidateSince = fix.eventTime
        ..candidateCount = 1;
    }

    if (state.candidateCount < confirmationFixes) return null;

    // Confirmed. We date the crossing at the *first* fix that showed the new
    // side, not the one that confirmed it -- the earlier fix is the better
    // estimate of when it actually happened, and confirmation is only the
    // question of whether we believe it at all.
    final crossedAt = state.candidateSince!;
    final windowStart = state.lastFixOnCurrentSide;
    final uncertain = windowStart != null &&
        crossedAt.difference(windowStart) > maxCertainGap;

    state
      ..inside = isInside
      ..lastFixOnCurrentSide = fix.eventTime
      ..candidateSide = null
      ..candidateSince = null
      ..candidateCount = 0;

    return GeofenceTransition(
      geofenceId: fence.geofenceId,
      kind: isInside ? TransitionKind.entry : TransitionKind.exit,
      eventTime: crossedAt,
      windowStart: windowStart,
      uncertain: uncertain,
    );
  }

  FenceVersion? _versionAt(List<FenceVersion> versions, DateTime at) {
    for (final version in versions) {
      if (version.coversEventTime(at)) return version;
    }
    return null;
  }
}
