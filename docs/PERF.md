# Performance and retention

## Device / method

`flutter devices` on 2026-09-07 showed macOS desktop and Chrome. An Android AVD exists (`Pixel_3a_API_34_extension_level_7_arm64-v8a`) but first-painted-frame numbers were not captured in this session.

Numbers below are DuckDB + Dart on the **Mac host** (darwin-arm64, macOS 26.6.2), **not** a painted Flutter frame on a phone. I am not inventing 40 ms cold-start claims.

Method:

1. Open a temp `fleet.duckdb`.
2. Seed three geofences.
3. Backfill N vehicles × P packets (8 signals/packet) through the DuckDB appender, then rebuild `vehicle_signal_latest`, replay geofences/trips, recompute alerts.
4. Run `loadFleet()` 10 times. p50/p95 are the 50th/95th of that sorted set. `first_us` is the first call in the same process.
5. Memory at rest with the list open: **not sampled** (needs DevTools on a running app).

To reproduce on a named emulator:

```text
Device: Pixel_3a_API_34_extension_level_7_arm64-v8a
1. flutter emulators --launch Pixel_3a_API_34_extension_level_7_arm64-v8a
2. flutter run
3. Note time-to-first-list (open → first fleet tiles). The subtitle prints SQL microseconds; that is query time, not frame time.
4. Pull to refresh 20 times; record the printed query ms.
5. DevTools Memory page, list open, at rest.
6. Debug menu → Backfill 500 vehicles / 2M rows, then repeat 3–5.
```

Host-only 2M-row bench:

```bash
bash tool/fetch_duckdb.sh
FLEET_VEHICLES=500 FLEET_PACKETS=500 dart run tool/bench_fleet.dart
```

500 × 500 × 8 = 2,000,000 signal rows.

## Measured (macOS host, `flutter test`, 2026-09-07)

DuckDB 1.4.2 (`native/libduckdb.dylib` from `tool/fetch_duckdb.sh`). SQL + Dart only.

| Scale | Readings | Backfill | First `loadFleet` | p50 | p95 |
| --- | --- | --- | --- | --- | --- |
| 1 vehicle, 1 packet | 3 | n/a | — | 6.8 ms | 11.5 ms |
| 40 vehicles × 30 packets | 9,720 | 0.56 s | 7.7 ms | 9.3 ms | 10.4 ms |

The fleet list does **not** scan the event log. It reads `vehicles` ⟕ `vehicle_signal_latest` (one row per signal). That is why 40 vehicles sits in the same ~10 ms band as 1 vehicle. I would expect 500 vehicles still in tens of milliseconds on this path. I would **not** claim that as phone frame time.

2 million signal rows (500 × 500 × 8) were not loaded here (wall-clock). Appender throughput on 9.7k rows including replay is ~17k rows/s. Extrapolating append alone is on the order of two minutes; geofence replay over 250k points is the part I would watch. The in-app debug action still performs the full 2M load on a device.

If the 2M load is slow on a phone: keep the snapshot table (already there), add a `vehicle_status` row maintained on ingest, and compact raw history harder. Do not move the fleet list into an in-memory Dart list.

## Retention policy

An append-only log grows forever.

- Keep raw `readings` / `packets` for **7 days**.
- Compact older SOC into `soc_hourly` (avg/min/max) so the sparkline still has a coarse window.
- Keep packets that belong to an **in-progress trip** even if older than 7 days, so replay can still revise that trip.
- Drop the rest.

What the app loses after compact: full-resolution signal history, GPS jitter inside dropped windows, and the ability to reconstruct a trip that already completed and aged out. Open alerts that depended on dropped fresh readings would already have gone stale before compact.

## Memory at rest

Not sampled on a device in this environment. After a 2M-row backfill I would expect DuckDB to hold buffer cache; I would report RSS with the fleet list open and say so if it is large.
