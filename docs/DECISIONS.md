# Decisions

The assignment is not a feature checklist. Packets arrive late, duplicated, out of order, or not at all. These are the rules the app actually implements, written so they can be defended in a live session.

## Source of truth

DuckDB on disk is the source of truth. `vehicle_signal_latest` is a DuckDB table updated in the same ingest transaction (or rebuilt after bulk load). It is not an in-memory cache the UI reads instead of SQL. Kill + relaunch opens the same file.

Packets are sparse. Fleet SOC/range come from that signal’s latest row, not from “whatever was in the last packet.”

## Status chip (first match wins)

Order:

1. **OFFLINE** — vehicle-level last ping (max event_time across any signal) older than 10 minutes, or never pinged.
2. **MOVING** — speed > 0.
3. **IDLE** — speed = 0 and ignition on.
4. **STOPPED** — otherwise (ignition off, or speed/ignition never reported).

Missing speed is treated as 0. Missing ignition is treated as off. Once the vehicle is not OFFLINE, we do not require speed/ignition to be fresh; staleness of those signals is shown on the detail register instead. A moving vehicle with ignition off is still MOVING because speed is checked first.

## Alerts

Thresholds apply to **fresh** readings only (same 10-minute window).

- SOC < 20% → warning; SOC < 10% → critical. These are **one** `battery_soc` row. Crossing 10% updates severity on the open row.
- Battery temp > 45 °C is a separate `battery_temp` critical alert.

Dismiss stores `dismissed_at` + reason and hides the alert. UNDO (5s, UI) clears those columns. If the operator dismisses while the condition is still true, we leave it dismissed until the condition clears. Clearing (SOC ≥ 20%, temp ≤ 45) **or** the signal going stale sets `resolved_at`, even if dismissed. A later breach opens a new row.

A signal that has never reported is shown as "—" with **no** pill. STALE means too old to judge: no NORMAL/ALERT claim.

## Duplicates and late packets

`packets` is unique on `(vehicle_id, event_time)`. First ingest wins; a duplicate is a no-op (no second readings, no second trip).

`vehicle_signal_latest` only moves forward in event_time. A late packet still lands in the append-only `readings` log (so history and geofence replay can see it) but does not overwrite a newer SOC.

## Geofences

Circular, versioned. Create/edit/deactivate persist. Edits close the current `geofence_versions` row (`valid_to`) and insert a new version. Deactivate keeps the row for trip history.

Deterministic confirmation, walked in **event_time** order:

- Drop points with `gps_accuracy > 50 m`.
- Duplicate timestamps: keep the first.
- **Inside** a fence: distance ≤ radius − 25 m. **Outside**: distance ≥ radius + 25 m. In the band, keep the previous candidate.
- Overlap: innermost (smallest radius), then geofence id.
- Confirm after 3 consecutive samples **or** 60 s of event-time dwell.
- A gap > 10 minutes in event-time: membership becomes unknown. We do **not** emit an exit and we do **not** interpolate a path. The next dwell must confirm again.
- Replay for a vehicle deletes that vehicle’s `geofence_events` + `trips` and writes them again from the log. Same history → same ids. A late point can move a boundary without inserting a second trip.

Seed fences in Bengaluru do not overlap, so innermost-vs-nested is only hit in tests.

## Trips

- Confirmed exit, no active trip → start (`id` = vehicle + origin fence + exit event_time).
- Next confirmed enter → complete, including return-to-origin.
- No enter → `in_progress`.
- One active trip per vehicle by construction of the walk.
- An enter while there is no active trip only updates current fence (vehicle started already inside).

## Retention

Raw `readings` are kept 7 days. Older SOC is compacted into `soc_hourly`. Packets that still belong to an `in_progress` trip are kept. Compaction loses full-resolution history and any jitter inside dropped windows; open trips remain replayable from their start.

## What I would still change

If the fleet-list query is slow after 2M rows, the next cut is a `vehicle_status` snapshot table maintained on ingest, plus covering indexes, not an in-memory list.
