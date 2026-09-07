import 'dart:math' as math;

/// Haversine distance in metres. Inputs are WGS84 degrees.
double haversineMeters({
  required double lat1,
  required double lon1,
  required double lat2,
  required double lon2,
}) {
  const earthRadiusM = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earthRadiusM * math.asin(math.min(1, math.sqrt(a)));
}

double _rad(double deg) => deg * math.pi / 180.0;

/// Linear interpolate along a great-circle-ish planar shortcut for the demo
/// simulator (short hops between nearby depots).
({double lat, double lon}) lerpLatLon(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
  double t,
) {
  final clamped = t.clamp(0.0, 1.0);
  return (
    lat: lat1 + (lat2 - lat1) * clamped,
    lon: lon1 + (lon2 - lon1) * clamped,
  );
}
