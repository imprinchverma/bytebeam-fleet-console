import 'package:fleet_console/app/providers.dart';
import 'package:fleet_console/domain/models.dart';
import 'package:fleet_console/features/fleet/fleet_home_screen.dart';
import 'package:fleet_console/features/vehicle/dismiss_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  testWidgets('empty fleet shows empty state', (tester) async {
    await tester.runAsync(() async {
      final h = await RepoHarness.open();
      addTearDown(h.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(h.db),
            clockProvider.overrideWithValue(h.clock),
          ],
          child: const MaterialApp(home: FleetHomeScreen()),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump();
        if (find.text('No vehicles match this filter').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(find.text('No vehicles match this filter'), findsOneWidget);
      expect(find.textContaining('All 0'), findsOneWidget);
    });
  });

  testWidgets('filter chips show SQL counts', (tester) async {
    await tester.runAsync(() async {
      final h = await RepoHarness.open();
      addTearDown(h.dispose);
      await h.repo.upsertVehicle(id: 'v1', regNumber: 'KA01AB1001', model: 'Semi');
      await h.repo.ingestPacket(
        TelemetryPacket(
          id: 'p1',
          vehicleId: 'v1',
          eventTime: h.clock.now().subtract(const Duration(minutes: 1)),
          signals: const {'speed': 20, 'soc': 70, 'range': 200},
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(h.db),
            clockProvider.overrideWithValue(h.clock),
          ],
          child: const MaterialApp(home: FleetHomeScreen()),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump();
        if (find.text('KA01AB1001').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(find.text('KA01AB1001'), findsOneWidget);
      expect(find.textContaining('Moving 1'), findsOneWidget);
      expect(find.text('MOVING'), findsOneWidget);
    });
  });

  testWidgets('dismiss sheet lists reasons in assignment order', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDismissReasonSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final labels = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
    final reasons = dismissReasons.map(labels.indexOf).toList();
    expect(reasons[0] < reasons[1], isTrue);
    expect(reasons[1] < reasons[2], isTrue);
    expect(dismissReasons, ['I am on it', 'Wrong alert', 'Something else…']);
  });
}
