import 'dart:math' as math;

const double earthRadiusMetres = 6371008.8;

/// Great-circle distance in metres.
///
/// Geofences here are a few hundred metres across, so a flat-earth
/// approximation would be accurate enough. Haversine costs nothing extra and
/// removes one thing to be wrong about.
double haversineMetres(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = _rad(lat1);
  final phi2 = _rad(lat2);
  final dPhi = _rad(lat2 - lat1);
  final dLambda = _rad(lon2 - lon1);

  final a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(phi1) *
          math.cos(phi2) *
          math.sin(dLambda / 2) *
          math.sin(dLambda / 2);
  return 2 * earthRadiusMetres * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _rad(double degrees) => degrees * math.pi / 180.0;

/// Offsets a coordinate by a north/east displacement in metres.
/// Used by seed data and by tests that need "a point 40 m outside this fence".
({double lat, double lon}) offsetMetres(
  double lat,
  double lon, {
  double north = 0,
  double east = 0,
}) {
  final dLat = north / earthRadiusMetres;
  final dLon = east / (earthRadiusMetres * math.cos(_rad(lat)));
  return (
    lat: lat + dLat * 180 / math.pi,
    lon: lon + dLon * 180 / math.pi,
  );
}
