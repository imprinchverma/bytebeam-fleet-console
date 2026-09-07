import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/models.dart';
import '../../shared/widgets/fleet_widgets.dart';

class GeofenceListScreen extends ConsumerWidget {
  const GeofenceListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(geofencesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Geofences')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/geofences/new'),
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(title: 'Could not load geofences', body: e.toString()),
        data: (fences) {
          if (fences.isEmpty) {
            return const EmptyState(
              title: 'No geofences yet',
              body: 'Seed the demo fleet or create a circular fence.',
              icon: Icons.radar_outlined,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
            itemCount: fences.length,
            itemBuilder: (context, i) => _FenceCard(fence: fences[i]),
          );
        },
      ),
    );
  }
}

class _FenceCard extends StatelessWidget {
  const _FenceCard({required this.fence});

  final Geofence fence;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => context.push('/geofences/${fence.id}'),
        title: Text(fence.name),
        subtitle: Text(
          '${fence.radiusM.round()} m · ${fence.vehicleCount} vehicles'
          '${fence.active ? '' : ' · deactivated'}',
        ),
        trailing: Icon(
          fence.active ? Icons.circle : Icons.circle_outlined,
          color: fence.active ? FleetTheme.accent : FleetTheme.offline,
          size: 14,
        ),
      ),
    );
  }
}

class GeofenceEditScreen extends ConsumerStatefulWidget {
  const GeofenceEditScreen({super.key, this.geofenceId});

  final String? geofenceId;

  @override
  ConsumerState<GeofenceEditScreen> createState() => _GeofenceEditScreenState();
}

class _GeofenceEditScreenState extends ConsumerState<GeofenceEditScreen> {
  final _name = TextEditingController();
  LatLng _center = const LatLng(12.9716, 77.5946);
  double _radius = 1200;
  bool _loading = true;
  Geofence? _existing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.geofenceId != null) {
      final fence = await ref.read(repositoryProvider).loadGeofence(widget.geofenceId!);
      if (fence != null) {
        _existing = fence;
        _name.text = fence.name;
        _center = LatLng(fence.lat, fence.lon);
        _radius = fence.radiusM;
      }
    } else {
      _name.text = 'New fence';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Create geofence' : 'Edit geofence'),
        actions: [
          if (_existing != null && _existing!.active)
            TextButton(
              onPressed: _deactivate,
              child: const Text('Deactivate'),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 13,
                onTap: (tap, latlng) => setState(() => _center = latlng),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.bytebeam.fleet_console',
                ),
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _center,
                      radius: _radius,
                      useRadiusInMeter: true,
                      color: FleetTheme.accent.withValues(alpha: 0.18),
                      borderStrokeWidth: 2,
                      borderColor: FleetTheme.accent,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _center,
                      width: 24,
                      height: 24,
                      child: const Icon(Icons.place, color: FleetTheme.accent),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Material(
            color: FleetTheme.card,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Radius ${_radius.round()} m'),
                      ),
                      Expanded(
                        flex: 2,
                        child: Slider(
                          min: 200,
                          max: 5000,
                          value: _radius.clamp(200, 5000),
                          onChanged: (v) => setState(() => _radius = v),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _save,
                      child: Text(_existing == null ? 'Create' : 'Save version'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final repo = ref.read(repositoryProvider);
    if (_existing == null) {
      await repo.createGeofence(
        name: _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim(),
        lat: _center.latitude,
        lon: _center.longitude,
        radiusM: _radius,
      );
    } else {
      await repo.editGeofence(
        id: _existing!.id,
        name: _name.text.trim(),
        lat: _center.latitude,
        lon: _center.longitude,
        radiusM: _radius,
      );
    }
    bumpRefresh(ref);
    if (mounted) context.pop();
  }

  Future<void> _deactivate() async {
    await ref.read(repositoryProvider).deactivateGeofence(_existing!.id);
    bumpRefresh(ref);
    if (mounted) context.pop();
  }
}
