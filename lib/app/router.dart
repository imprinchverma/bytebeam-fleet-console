import 'package:go_router/go_router.dart';

import '../features/fleet/fleet_home_screen.dart';
import '../features/geofences/geofence_edit_screen.dart';
import '../features/geofences/geofence_list_screen.dart';
import '../features/vehicle/vehicle_detail_screen.dart';

final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const FleetHomeScreen()),
    GoRoute(
      path: '/vehicles/:id',
      builder: (context, state) =>
          VehicleDetailScreen(vehicleId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/geofences',
      builder: (context, state) => const GeofenceListScreen(),
    ),
    GoRoute(
      path: '/geofences/new',
      builder: (context, state) => const GeofenceEditScreen(),
    ),
    GoRoute(
      path: '/geofences/:id',
      builder: (context, state) =>
          GeofenceEditScreen(geofenceId: state.pathParameters['id']),
    ),
  ],
);
