# Fleet Console

Local-first Flutter take-home for Bytebeam (Flutter Engineer, SDE-3). One operator screen for an electric truck fleet: where the vehicles are, whether they are okay, and what needs attention now.

Telemetry is stored in an **on-disk DuckDB** file. The UI queries that file. Kill the app and relaunch it: everything comes back off disk.

## Run the app

```bash
flutter pub get
flutter run
```

Android is the primary target (`dart_duckdb` ships native binaries). The first launch seeds 12 demo vehicles and three circular geofences around Bengaluru.

Useful debug menu (top-right on Fleet home):

- **Reseed demo fleet** — scripted trips, idle/stopped/offline, low-battery and overheat alerts
- **Ingest one live packet** — one sparse, possibly late/duplicate packet
- **Toggle live simulator** — ongoing flaky ingest
- **Backfill 500 vehicles / 2M rows** — scale exercise (slow, progress dialog)
- **Run retention compact** — drop raw readings older than 7 days (keeps in-progress trip packets and hourly SOC)

## Run the tests

```bash
# Linux desktop/tests need the DuckDB shared library once:
bash tool/fetch_duckdb.sh
flutter test
```

## 30-second feature tour

1. **Fleet home** — reg, model, SOC, range, alert badge, status chip. Status is first-match-wins: Offline (>10 min) → Moving (speed > 0) → Idle (speed 0, ignition on) → Stopped. Filter chips All / Moving / Idle / Stopped / Offline show live **SQL counts**. Empty filters get an empty state.
2. **Vehicle detail** — readings register (value, age, NORMAL / ALERT / STALE pill, or "—" if never reported), SOC sparkline from the event log, current geofence, trips.
3. **Alerts** — Low battery (SOC < 20% warning) and critically low (SOC < 10%) are **one escalating alert**. Overheat (> 45 °C) is separate. Dismiss opens a reason sheet in this order: "I am on it", "Wrong alert", "Something else…". UNDO is offered for 5 seconds. A condition that clears resolves even a dismissed alert.
4. **Geofences** — create / edit / deactivate circular fences. Deactivated fences stay for trip history. Live vehicle counts are SQL. Entry/exit uses event-time history with hysteresis, dwell, accuracy drop, and gap handling (`docs/DECISIONS.md`).
5. **Trips** — a confirmed exit starts a trip; the next confirmed entry completes it; otherwise it stays IN PROGRESS. Replay is idempotent.

## Scale / performance

See `docs/PERF.md`. The in-app debug action backfills 500 vehicles and at least 2 million signal rows.

## Docs

- `docs/DECISIONS.md` — ambiguous cases and why
- `docs/PERF.md` — measured numbers, method, retention
- `docs/ai-conversation-logs/` — uncurated AI logs
