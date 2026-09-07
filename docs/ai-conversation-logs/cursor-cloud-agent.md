# AI conversation logs (uncurated)

Bytebeam Fleet Console take-home. Cursor Cloud agent, 7 Sep 2026.

This is the working log, including wrong turns. It is not a cleaned write-up.

---

User asked to analyse `Bytebeam Flutter Engineer - SDE 3 Assignment.pdf` and implement the Flutter assignment, upload to git, cover every point, and make a plan if anything was unclear.

The PDF is a local-first **Fleet Console**. 500 electric trucks. Telemetry is late, duplicated, out of order, or dumped after hours in a basement. The hard part is the data model, not feature volume.

First pass I treated this as a plan: current workspace was `lbm-health-hub`, a different app. Asked where to put the new project. User chose a sibling folder + new private GitHub repo.

Then the agent moved to a cloud workspace still attached to `imprinchverma/lbm-health-hub`. No Flutter SDK on the VM. `gh` is authenticated as the Cursor GitHub App (read-only for PRs/issues). Creating a second GitHub repo from here may not be allowed; the code ships on a feature branch of this repo and can be copied into a private Bytebeam repo.

## Wrong turns

1. **Import paths.** `lib/data/engines/geofence_engine.dart` used `../core` (resolves to `lib/data/core`). Should have been `../../core`. Same class of bug in `seed_service.dart`. Compiler dump was huge before I looked at the first line.

2. **Missing semicolon** on `statusSql` after a search-replace. Dart reported "Expected ';' after this" on the opening `'''`, which looked like an interpolation problem. It was just the terminator.

3. **Status SQL used aliases that did not exist** in the FROM clause (`last_ping`, `speed`, `ignition`). The joins expose `ping.last_ping`, `spd.value`, `ign.value`. First-match-wins would have been wrong in SQL. Fixed before tests ran against DuckDB.

4. **`libduckdb.so`.** `dart_duckdb` 1.4.4 does not magically find a Linux library in `flutter test`. First run: `Failed to load dynamic library 'libduckdb.so'`. Widget tests then hung on `pumpAndSettle` because a `CircularProgressIndicator` never settles. Downloaded DuckDB 1.4.2 linux-amd64, bind with `open.overrideFor` *before* the `duckdb` singleton is created. `FleetDatabase.open` was shadowing the package `open` helper — had to import `package:dart_duckdb/open.dart` as a prefix.

5. **Widget tests vs isolates.** DuckDB queries run on a background isolate. Default widget-test fake async never delivers those completions. `tester.runAsync` plus a short poll loop fixed empty-state and filter-chip tests.

6. **Geofence gap handling.** First draft reset dwell on a 10-minute gap but kept `confirmedId`, so a later warehouse dwell emitted `exit(depot)` and invented a trip across the hole. Assignment says do not interpolate missing intervals. Now a gap clears membership without emitting an exit.

7. **Backfill duplicates via appender.** Unique `(vehicle_id, event_time)` plus DuckDB appender does not no-op; it fails the batch. Duplicates stay on the live ingest path (`ON CONFLICT` / pre-check). Backfill does not insert duplicate event_times.

8. **Simulator `toggle()`** originally `await`ed an infinite loop from the AppBar menu. Fire-and-forget the loop instead.

## Decisions that stuck

- File-backed DuckDB, UI reads SQL, `vehicle_signal_latest` is a DuckDB snapshot not a Dart list.
- SOC warning/critical is one alert row. Overheat is separate. Stale cannot alert. Clear resolves even dismissed.
- Geofence: accuracy drop, ±25 m hysteresis, 3 samples or 60 s dwell, innermost overlap, versioned edits, gap = unknown.
- Trips from confirmed transitions only; replay rebuilds per vehicle so late packets revise without duplicates.
- 7-day raw retention, hourly SOC compact, keep in-progress trip packets.

## What was not measured on a phone

No Android emulator in this cloud VM. Cold-start-to-first-paint and RSS-at-rest are described as a method in `docs/PERF.md`. Fleet-list SQL microseconds are measured in tests against DuckDB on Linux. The in-app debug action still backfills 500 × 500 × 8 = 2,000,000 signal rows for a real device run.
