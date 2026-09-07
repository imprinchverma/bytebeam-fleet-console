import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/clock.dart';
import '../data/duckdb/fleet_database.dart';
import '../data/fleet_repository.dart';
import '../data/seed/simulator.dart';
import '../domain/models.dart';

final clockProvider = Provider<AppClock>((ref) => const SystemClock());

final databaseProvider = Provider<FleetDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden in main()');
});

final repositoryProvider = Provider<FleetRepository>((ref) {
  return FleetRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  );
});

final fleetFilterProvider = StateProvider<FleetFilter>((ref) => FleetFilter.all);

final refreshTickProvider = StateProvider<int>((ref) => 0);

void bumpRefresh(WidgetRef ref) {
  ref.read(refreshTickProvider.notifier).state++;
}

final fleetSnapshotProvider = FutureProvider<FleetSnapshot>((ref) async {
  ref.watch(refreshTickProvider);
  final filter = ref.watch(fleetFilterProvider);
  return ref.watch(repositoryProvider).loadFleet(filter: filter);
});

final geofencesProvider = FutureProvider<List<Geofence>>((ref) async {
  ref.watch(refreshTickProvider);
  return ref.watch(repositoryProvider).loadGeofences();
});

final vehicleDetailProvider =
    FutureProvider.family<VehicleDetailData, String>((ref, id) async {
  ref.watch(refreshTickProvider);
  final repo = ref.watch(repositoryProvider);
  final vehicle = await repo.loadVehicle(id);
  if (vehicle == null) {
    throw StateError('Vehicle $id not found');
  }
  final register = await repo.loadRegister(id);
  final spark = await repo.loadSocHistory(id);
  final alerts = await repo.loadOpenAlerts(vehicleId: id);
  final trips = await repo.loadTrips(id);
  return VehicleDetailData(
    vehicle: vehicle,
    register: register,
    spark: spark,
    alerts: alerts,
    trips: trips,
  );
});

class VehicleDetailData {
  const VehicleDetailData({
    required this.vehicle,
    required this.register,
    required this.spark,
    required this.alerts,
    required this.trips,
  });

  final VehicleRow vehicle;
  final List<SignalReading> register;
  final List<SocPoint> spark;
  final List<VehicleAlert> alerts;
  final List<Trip> trips;
}

class SimulatorState {
  const SimulatorState({this.running = false, this.lastPacketId});
  final bool running;
  final String? lastPacketId;

  SimulatorState copyWith({bool? running, String? lastPacketId}) {
    return SimulatorState(
      running: running ?? this.running,
      lastPacketId: lastPacketId ?? this.lastPacketId,
    );
  }
}

class SimulatorController extends StateNotifier<SimulatorState> {
  SimulatorController(this._ref) : super(const SimulatorState());

  final Ref _ref;
  TelemetrySimulator? _sim;

  Future<void> tickOnce() async {
    _sim ??= TelemetrySimulator(_ref.read(repositoryProvider));
    final packet = await _sim!.tick();
    state = state.copyWith(lastPacketId: packet.id);
    _ref.read(refreshTickProvider.notifier).state++;
  }

  Future<void> toggle() async {
    if (state.running) {
      state = state.copyWith(running: false);
      return;
    }
    state = state.copyWith(running: true);
    _sim ??= TelemetrySimulator(_ref.read(repositoryProvider));
    Future<void>(() async {
      while (state.running) {
        try {
          await tickOnce();
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    });
  }
}

final simulatorProvider =
    StateNotifierProvider<SimulatorController, SimulatorState>(
  SimulatorController.new,
);
