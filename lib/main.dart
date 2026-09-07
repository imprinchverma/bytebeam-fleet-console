import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'data/duckdb/fleet_database.dart';
import 'data/fleet_repository.dart';
import 'data/seed/seed_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, 'fleet.duckdb');
  final db = await FleetDatabase.open(dbPath);
  final repo = FleetRepository(db);
  await SeedService(repo).ensureDemoSeed();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
      child: const FleetApp(),
    ),
  );
}
