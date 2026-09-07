import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import 'router.dart';

class FleetApp extends StatelessWidget {
  const FleetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Fleet Console',
      debugShowCheckedModeBanner: false,
      theme: FleetTheme.dark(),
      routerConfig: appRouter,
    );
  }
}

class FleetRoot extends StatelessWidget {
  const FleetRoot({super.key, required this.databaseOverride});

  final Override databaseOverride;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [databaseOverride],
      child: const FleetApp(),
    );
  }
}
