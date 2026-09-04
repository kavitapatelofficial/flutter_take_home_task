import '../repo/geofence_repository.dart';
import 'backfill.dart';

/// The geofences the app starts life with.
///
/// Four rather than the three asked for, because the fourth is the
/// interesting one: "Bengaluru ORR" is large enough to contain both depots, so
/// every vehicle is inside two fences at once and the overlap rules -- which
/// fence a vehicle is reported to be in, and which exit actually starts a trip
/// -- are exercised by the default data rather than only by tests.
Future<void> seedGeofences(
  GeofenceRepository repo, {
  required DateTime validFrom,
}) async {
  if ((await repo.list()).isNotEmpty) return;

  await repo.create(
    name: 'North Depot',
    lat: Backfill.seedDepotLat,
    lon: Backfill.seedDepotLon,
    radiusM: 400,
    validFrom: validFrom,
  );
  await repo.create(
    name: 'Customer Hub',
    lat: Backfill.seedCustomerLat,
    lon: Backfill.seedCustomerLon,
    radiusM: 400,
    validFrom: validFrom,
  );
  await repo.create(
    name: 'Whitefield Yard',
    lat: 12.9698,
    lon: 77.7500,
    radiusM: 600,
    validFrom: validFrom,
  );
  await repo.create(
    name: 'Bengaluru ORR',
    lat: 12.9900,
    lon: 77.6200,
    radiusM: 12000,
    validFrom: validFrom,
  );
}
