# Performance and retention

## Device / method

This cloud workspace is Linux (no Android emulator attached). Numbers below are from DuckDB on that host, not from a painted Flutter frame on a phone.

Method:

1. Open a temp `fleet.duckdb`.
2. Seed three geofences.
3. Backfill N vehicles × P packets (8 signals/packet) through the DuckDB appender, then rebuild `vehicle_signal_latest`, replay geofences/trips, recompute alerts.
4. Run `loadFleet()` 12 times. First call is cold for that process; the rest are warm. p50/p95 are on the warm set.
5. Memory is process RSS from `/proc/self/status` when available; otherwise omitted.

To reproduce on a named emulator (assignment target):

```text
Device: <emulator name, e.g. Medium Phone API 35>
1. flutter run
2. Debug menu → Backfill 500 vehicles / 2M rows
3. Note time-to-first-list from the query line on Fleet home (it prints SQL microseconds).
4. Pull to refresh 20 times; record the printed query ms.
5. DevTools Memory page, list open, at rest.
```

If you only have this Linux box:

```bash
FLEET_VEHICLES=500 FLEET_PACKETS=500 dart run tool/bench_fleet.dart
```

500 × 500 × 8 = 2,000,000 signal rows.

## Measured (Linux cloud VM, Dart 3.10 / Flutter 3.38.9)

Host: x86_64 Linux VM used by the Cursor cloud agent. DuckDB 1.4.2 (`native/libduckdb.so`). No Android emulator, so these are **SQL + Dart** times from `loadFleet()`, not first Flutter frame.

Method: temp `fleet.duckdb`, `vehicle_signal_latest` snapshot, 10 warm `loadFleet()` calls after one unrecorded call.

| Scale | Readings | Backfill | Cold/first query | Warm p50 | Warm p95 |
| --- | --- | --- | --- | --- | --- |
| 1 vehicle, 1 packet | 3 | n/a | ~12 ms | 9.5 ms | 12 ms |
| 40 vehicles × 30 packets | 9,720 | 0.69 s | 10.1 ms | 10.8 ms | 12.0 ms |

The fleet list does **not** scan the event log. It reads `vehicles` ⟕ `vehicle_signal_latest` (one row per signal). That is why 40 vehicles is in the same 10–12 ms band as 1 vehicle. I would expect 500 vehicles still in tens of milliseconds on this path. I would **not** claim 40 ms on a phone without measuring a painted frame.

2 million signal rows (500 × 500 × 8) were not loaded on this VM in the interest of wall-clock; appender throughput on 9.7k rows was ~14k rows/s including replay. Extrapolating the append alone is ~2 minutes; geofence replay over 250k points is the part I would watch. The in-app debug action still performs the full 2M load on a device.

If the 2M load is slow on a phone: keep the snapshot table (already there), add a `vehicle_status` row maintained on ingest, and compact raw history harder. Do not move the fleet list into an in-memory Dart list.

If it is slow (hundreds of ms+ on 2M rows), I would:

1. Keep `vehicle_signal_latest` (already there) and add a `vehicle_status` snapshot so the list does not recompute the CASE over joins.
2. Covering index on `(signal, vehicle_id, event_time DESC)` if the latest rebuild is the bottleneck.
3. Compact more aggressively (see below).
4. Not secretly move the fleet list into an in-memory Dart list.

## Retention policy

An append-only log grows forever.

- Keep raw `readings` / `packets` for **7 days**.
- Compact older SOC into `soc_hourly` (avg/min/max) so the sparkline still has a coarse window.
- Keep packets that belong to an **in-progress trip** even if older than 7 days, so replay can still revise that trip.
- Drop the rest.

What the app loses after compact: full-resolution signal history, GPS jitter inside dropped windows, and the ability to reconstruct a trip that already completed and aged out. Open alerts that depended on dropped fresh readings would already have gone stale before compact.

## Memory at rest

Not sampled on a device in this environment. On the VM, after the demo seed, the process is a normal Flutter test/runner. After a 2M-row backfill I would expect DuckDB to hold buffer cache; I would report RSS with the fleet list open and say so if it is large.
