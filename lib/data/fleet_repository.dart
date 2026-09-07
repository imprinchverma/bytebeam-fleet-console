import '../core/clock.dart';
import '../core/constants.dart';
import '../domain/models.dart';
import 'duckdb/coerce.dart';
import 'duckdb/fleet_database.dart';
import 'duckdb/schema.dart';
import 'engines/alert_engine.dart';
import 'engines/geofence_engine.dart';

/// All operator reads go through SQL on [FleetDatabase]. This class is the
/// write path (ingest, dismiss, geofence CRUD) plus query helpers.
class FleetRepository {
  FleetRepository(this.db, {AppClock clock = const SystemClock()})
      : _clock = clock,
        _replay = GeofenceReplay();

  final FleetDatabase db;
  final AppClock _clock;
  final GeofenceReplay _replay;
  int _seq = 0;

  DateTime get now => _clock.now();

  Future<void> upsertVehicle({
    required String id,
    required String regNumber,
    required String model,
  }) {
    return db.execute(
      '''
      INSERT INTO vehicles (id, reg_number, model) VALUES (?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        reg_number = excluded.reg_number,
        model = excluded.model
      ''',
      [id, regNumber, model],
    );
  }

  Future<IngestResult> ingestPacket(
    TelemetryPacket packet, {
    bool replayLocation = true,
    bool recomputeAlerts = true,
  }) async {
    final eventTime = packet.eventTime.toUtc();
    final ingestTime = now;

    final existing = await db.selectOne(
      'SELECT id FROM packets WHERE vehicle_id = ? AND event_time = ?',
      [packet.vehicleId, eventTime],
    );
    if (existing != null) return IngestResult.skippedDuplicate;

    await db.transaction(() async {
      await db.execute(
        '''
        INSERT INTO packets (id, vehicle_id, event_time, ingest_time)
        VALUES (?, ?, ?, ?)
        ON CONFLICT (vehicle_id, event_time) DO NOTHING
        ''',
        [packet.id, packet.vehicleId, eventTime, ingestTime],
      );
      final stored = await db.selectOne(
        'SELECT id FROM packets WHERE vehicle_id = ? AND event_time = ?',
        [packet.vehicleId, eventTime],
      );
      if (asString(stored?['id']) != packet.id) {
        return;
      }
      for (final entry in packet.signals.entries) {
        await db.execute(
          '''
          INSERT INTO readings (packet_id, vehicle_id, signal, value, event_time)
          VALUES (?, ?, ?, ?, ?)
          ''',
          [packet.id, packet.vehicleId, entry.key, entry.value, eventTime],
        );
        await db.execute(
          '''
          INSERT INTO vehicle_signal_latest (vehicle_id, signal, value, event_time, packet_id)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (vehicle_id, signal) DO UPDATE SET
            value = excluded.value,
            event_time = excluded.event_time,
            packet_id = excluded.packet_id
          WHERE excluded.event_time >= vehicle_signal_latest.event_time
          ''',
          [packet.vehicleId, entry.key, entry.value, eventTime, packet.id],
        );
      }
    });

    if (replayLocation &&
        packet.signals.containsKey(FleetRules.signalLat) &&
        packet.signals.containsKey(FleetRules.signalLon)) {
      await replayVehicle(packet.vehicleId);
    }
    if (recomputeAlerts) {
      await recomputeAlertsFor(packet.vehicleId);
    }
    return IngestResult.stored;
  }

  /// Bulk append used by the 2M-row backfill. Caller rebuilds latest + replay.
  Future<int> appendPackets(List<TelemetryPacket> batch) async {
    if (batch.isEmpty) return 0;
    var stored = 0;
    final packetApp = await db.appender('packets');
    final readingApp = await db.appender('readings');
    try {
      final ingestTime = now;
      for (final packet in batch) {
        final eventTime = packet.eventTime.toUtc();
        packetApp.append(packet.id);
        packetApp.append(packet.vehicleId);
        packetApp.append(eventTime);
        packetApp.append(ingestTime);
        packetApp.endRow();
        for (final entry in packet.signals.entries) {
          readingApp.append(packet.id);
          readingApp.append(packet.vehicleId);
          readingApp.append(entry.key);
          readingApp.append(entry.value);
          readingApp.append(eventTime);
          readingApp.endRow();
        }
        stored += packet.signals.length;
      }
      packetApp.flush();
      readingApp.flush();
    } finally {
      packetApp.dispose();
      readingApp.dispose();
    }
    return stored;
  }

  Future<void> rebuildLatestFromLog() async {
    await db.execute('DELETE FROM vehicle_signal_latest');
    await db.execute('''
      INSERT INTO vehicle_signal_latest (vehicle_id, signal, value, event_time, packet_id)
      SELECT vehicle_id, signal, value, event_time, packet_id
      FROM (
        SELECT *, ROW_NUMBER() OVER (
          PARTITION BY vehicle_id, signal ORDER BY event_time DESC
        ) AS rn
        FROM readings
      )
      WHERE rn = 1
    ''');
  }

  Future<void> replayVehicle(String vehicleId) async {
    final pointRows = await db.select(
      '''
      SELECT p.id AS packet_id, p.event_time,
             lat.value AS lat, lon.value AS lon, acc.value AS gps_accuracy
      FROM packets p
      JOIN readings lat ON lat.packet_id = p.id AND lat.signal = 'lat'
      JOIN readings lon ON lon.packet_id = p.id AND lon.signal = 'lon'
      LEFT JOIN readings acc ON acc.packet_id = p.id AND acc.signal = 'gps_accuracy'
      WHERE p.vehicle_id = ?
      ORDER BY p.event_time
      ''',
      [vehicleId],
    );
    final points = [
      for (final row in pointRows)
        if (asDouble(row['lat']) != null && asDouble(row['lon']) != null)
          LocationSample(
            packetId: asString(row['packet_id'])!,
            eventTime: requireDateTime(row['event_time']),
            lat: asDouble(row['lat'])!,
            lon: asDouble(row['lon'])!,
            accuracyM: asDouble(row['gps_accuracy']),
          ),
    ];
    final fences = await loadFenceVersions();
    final result = _replay.replay(
      vehicleId: vehicleId,
      points: points,
      fences: fences,
    );

    await db.transaction(() async {
      await db.execute('DELETE FROM geofence_events WHERE vehicle_id = ?', [vehicleId]);
      await db.execute('DELETE FROM trips WHERE vehicle_id = ?', [vehicleId]);
      await db.execute(
        'DELETE FROM vehicle_geofence_current WHERE vehicle_id = ?',
        [vehicleId],
      );
      for (final event in result.events) {
        await db.execute(
          '''
          INSERT INTO geofence_events
            (id, vehicle_id, geofence_id, geofence_version, kind, event_time, packet_id)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            event.id,
            event.vehicleId,
            event.geofenceId,
            event.geofenceVersion,
            event.kind,
            event.eventTime,
            event.packetId,
          ],
        );
      }
      for (final trip in result.trips) {
        await db.execute(
          '''
          INSERT INTO trips
            (id, vehicle_id, origin_geofence_id, dest_geofence_id, started_at, ended_at, status)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            trip.id,
            trip.vehicleId,
            trip.originGeofenceId,
            trip.destGeofenceId,
            trip.startedAt,
            trip.endedAt,
            trip.status == TripStatus.completed ? 'completed' : 'in_progress',
          ],
        );
      }
      await db.execute(
        'INSERT INTO vehicle_geofence_current (vehicle_id, geofence_id) VALUES (?, ?)',
        [vehicleId, result.currentGeofenceId],
      );
    });
  }

  Future<void> replayAllVehicles() async {
    final rows = await db.select('SELECT id FROM vehicles');
    for (final row in rows) {
      await replayVehicle(asString(row['id'])!);
    }
  }

  Future<void> recomputeAlertsFor(String vehicleId) async {
    final latestRows = await db.select(
      'SELECT signal, value, event_time FROM vehicle_signal_latest WHERE vehicle_id = ?',
      [vehicleId],
    );
    final latest = <String, ({double value, DateTime eventTime})>{};
    for (final row in latestRows) {
      latest[asString(row['signal'])!] = (
        value: asDouble(row['value'])!,
        eventTime: requireDateTime(row['event_time']),
      );
    }
    final evaluations = AlertRules.evaluate(now: now, latest: latest);
    for (final evaluation in evaluations) {
      await _applyAlert(vehicleId, evaluation);
    }
  }

  Future<void> recomputeAllAlerts() async {
    final rows = await db.select('SELECT id FROM vehicles');
    for (final row in rows) {
      await recomputeAlertsFor(asString(row['id'])!);
    }
  }

  Future<void> _applyAlert(String vehicleId, AlertEvaluation evaluation) async {
    final open = await db.selectOne(
      '''
      SELECT id, severity, dismissed_at FROM alerts
      WHERE vehicle_id = ? AND kind = ? AND resolved_at IS NULL
      ORDER BY opened_at DESC
      LIMIT 1
      ''',
      [vehicleId, evaluation.kind],
    );

    if (evaluation.inBreach && evaluation.fresh) {
      final severity = evaluation.severity!.name;
      if (open == null) {
        final id =
            'alert_${vehicleId}_${evaluation.kind}_${now.microsecondsSinceEpoch}_${_seq++}';
        await db.execute(
          '''
          INSERT INTO alerts (id, vehicle_id, kind, severity, opened_at)
          VALUES (?, ?, ?, ?, ?)
          ''',
          [id, vehicleId, evaluation.kind, severity, now],
        );
        await _logAlertEvent(
          alertId: id,
          vehicleId: vehicleId,
          kind: evaluation.kind,
          action: 'opened',
          severity: severity,
        );
      } else if (open['dismissed_at'] == null) {
        if (asString(open['severity']) != severity) {
          await db.execute(
            'UPDATE alerts SET severity = ? WHERE id = ?',
            [severity, asString(open['id'])],
          );
          await _logAlertEvent(
            alertId: asString(open['id'])!,
            vehicleId: vehicleId,
            kind: evaluation.kind,
            action: 'escalated',
            severity: severity,
          );
        }
      }
      return;
    }

    if (open != null) {
      final shouldResolve = !evaluation.inBreach || !evaluation.fresh;
      if (shouldResolve) {
        await db.execute(
          'UPDATE alerts SET resolved_at = ? WHERE id = ?',
          [now, asString(open['id'])],
        );
        await _logAlertEvent(
          alertId: asString(open['id'])!,
          vehicleId: vehicleId,
          kind: evaluation.kind,
          action: evaluation.inBreach ? 'stale_resolved' : 'cleared',
          severity: asString(open['severity']),
        );
      }
    }
  }

  Future<void> _logAlertEvent({
    required String alertId,
    required String vehicleId,
    required String kind,
    required String action,
    String? severity,
    String? reason,
  }) {
    return db.execute(
      '''
      INSERT INTO alert_events (id, alert_id, vehicle_id, kind, action, severity, reason, occurred_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        'aevt_${alertId}_${action}_${now.microsecondsSinceEpoch}_${_seq++}',
        alertId,
        vehicleId,
        kind,
        action,
        severity,
        reason,
        now,
      ],
    );
  }

  Future<void> dismissAlert({
    required String alertId,
    required String reason,
  }) async {
    final row = await db.selectOne(
      'SELECT vehicle_id, kind, severity FROM alerts WHERE id = ?',
      [alertId],
    );
    await db.execute(
      'UPDATE alerts SET dismissed_at = ?, dismiss_reason = ? WHERE id = ? AND resolved_at IS NULL',
      [now, reason, alertId],
    );
    if (row != null) {
      await _logAlertEvent(
        alertId: alertId,
        vehicleId: asString(row['vehicle_id'])!,
        kind: asString(row['kind'])!,
        action: 'dismissed',
        severity: asString(row['severity']),
        reason: reason,
      );
    }
  }

  Future<void> undoDismiss(String alertId) async {
    final row = await db.selectOne(
      'SELECT vehicle_id, kind, severity FROM alerts WHERE id = ?',
      [alertId],
    );
    await db.execute(
      'UPDATE alerts SET dismissed_at = NULL, dismiss_reason = NULL WHERE id = ? AND resolved_at IS NULL',
      [alertId],
    );
    if (row != null) {
      await _logAlertEvent(
        alertId: alertId,
        vehicleId: asString(row['vehicle_id'])!,
        kind: asString(row['kind'])!,
        action: 'undo_dismiss',
        severity: asString(row['severity']),
      );
    }
  }

  Future<List<FenceVersion>> loadFenceVersions() async {
    final rows = await db.select('''
      SELECT geofence_id, version, name, lat, lon, radius_m, valid_from, valid_to
      FROM geofence_versions
    ''');
    return [
      for (final row in rows)
        FenceVersion(
          geofenceId: asString(row['geofence_id'])!,
          version: asInt(row['version']),
          name: asString(row['name'])!,
          lat: asDouble(row['lat'])!,
          lon: asDouble(row['lon'])!,
          radiusM: asDouble(row['radius_m'])!,
          validFrom: requireDateTime(row['valid_from']),
          validTo: asDateTime(row['valid_to']),
        ),
    ];
  }

  Future<String> createGeofence({
    required String name,
    required double lat,
    required double lon,
    required double radiusM,
    String? id,
  }) async {
    final fenceId = id ?? 'gf_${now.microsecondsSinceEpoch}';
    final ts = now;
    await db.transaction(() async {
      await db.execute(
        '''
        INSERT INTO geofences
          (id, name, lat, lon, radius_m, active, version, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, TRUE, 1, ?, ?)
        ''',
        [fenceId, name, lat, lon, radiusM, ts, ts],
      );
      await db.execute(
        '''
        INSERT INTO geofence_versions
          (geofence_id, version, name, lat, lon, radius_m, valid_from, valid_to)
        VALUES (?, 1, ?, ?, ?, ?, ?, NULL)
        ''',
        [fenceId, name, lat, lon, radiusM, ts],
      );
    });
    return fenceId;
  }

  Future<void> editGeofence({
    required String id,
    required String name,
    required double lat,
    required double lon,
    required double radiusM,
  }) async {
    final current = await db.selectOne(
      'SELECT version FROM geofences WHERE id = ?',
      [id],
    );
    if (current == null) return;
    final nextVersion = asInt(current['version']) + 1;
    final ts = now;
    await db.transaction(() async {
      await db.execute(
        '''
        UPDATE geofence_versions SET valid_to = ?
        WHERE geofence_id = ? AND valid_to IS NULL
        ''',
        [ts, id],
      );
      await db.execute(
        '''
        INSERT INTO geofence_versions
          (geofence_id, version, name, lat, lon, radius_m, valid_from, valid_to)
        VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
        ''',
        [id, nextVersion, name, lat, lon, radiusM, ts],
      );
      await db.execute(
        '''
        UPDATE geofences
        SET name = ?, lat = ?, lon = ?, radius_m = ?, version = ?, updated_at = ?
        WHERE id = ?
        ''',
        [name, lat, lon, radiusM, nextVersion, ts, id],
      );
    });
    await replayAllVehicles();
  }

  Future<void> deactivateGeofence(String id) async {
    final ts = now;
    await db.transaction(() async {
      await db.execute(
        '''
        UPDATE geofence_versions SET valid_to = ?
        WHERE geofence_id = ? AND valid_to IS NULL
        ''',
        [ts, id],
      );
      await db.execute(
        '''
        UPDATE geofences
        SET active = FALSE, deactivated_at = ?, updated_at = ?
        WHERE id = ?
        ''',
        [ts, ts, id],
      );
    });
    await replayAllVehicles();
  }

  Future<FleetSnapshot> loadFleet({FleetFilter filter = FleetFilter.all}) async {
    final asOf = now;
    final sw = Stopwatch()..start();
    final statusExpr = statusSql.trim();
    final where = switch (filter) {
      FleetFilter.all => '',
      FleetFilter.moving => "WHERE status = 'moving'",
      FleetFilter.idle => "WHERE status = 'idle'",
      FleetFilter.stopped => "WHERE status = 'stopped'",
      FleetFilter.offline => "WHERE status = 'offline'",
    };

    final countRows = await db.select(
      '''
      SELECT
        COUNT(*) AS all_count,
        COUNT(*) FILTER (WHERE status = 'moving') AS moving,
        COUNT(*) FILTER (WHERE status = 'idle') AS idle,
        COUNT(*) FILTER (WHERE status = 'stopped') AS stopped,
        COUNT(*) FILTER (WHERE status = 'offline') AS offline
      FROM (
        SELECT $statusExpr AS status
        $fleetFromSql
      )
      ''',
      [asOf],
    );
    final countsRow = countRows.first;
    final counts = FilterCounts(
      all: asInt(countsRow['all_count']),
      moving: asInt(countsRow['moving']),
      idle: asInt(countsRow['idle']),
      stopped: asInt(countsRow['stopped']),
      offline: asInt(countsRow['offline']),
    );

    final rows = await db.select(
      '''
      SELECT * FROM (
        SELECT
          v.id,
          v.reg_number,
          v.model,
          soc.value AS soc,
          rng.value AS range_km,
          spd.value AS speed,
          ign.value AS ignition,
          ping.last_ping,
          cur.geofence_id AS current_geofence_id,
          g.name AS current_geofence_name,
          COALESCE(al.open_alert_count, 0) AS open_alert_count,
          COALESCE(al.critical_alert_count, 0) AS critical_alert_count,
          $statusExpr AS status
        $fleetFromSql
      )
      $where
      ORDER BY
        CASE status
          WHEN 'offline' THEN 0
          WHEN 'stopped' THEN 1
          WHEN 'idle' THEN 2
          ELSE 3
        END,
        open_alert_count DESC,
        reg_number
      ''',
      [asOf],
    );
    sw.stop();

    final vehicles = [
      for (final row in rows)
        VehicleRow(
          id: asString(row['id'])!,
          regNumber: asString(row['reg_number'])!,
          model: asString(row['model'])!,
          status: VehicleStatus.values.byName(asString(row['status'])!),
          soc: asDouble(row['soc']),
          rangeKm: asDouble(row['range_km']),
          speed: asDouble(row['speed']),
          ignitionOn: row['ignition'] == null ? null : asDouble(row['ignition']) == 1,
          lastPing: asDateTime(row['last_ping']),
          currentGeofenceId: asString(row['current_geofence_id']),
          currentGeofenceName: asString(row['current_geofence_name']),
          openAlertCount: asInt(row['open_alert_count']),
          hasCriticalAlert: asInt(row['critical_alert_count']) > 0,
        ),
    ];

    return FleetSnapshot(
      vehicles: vehicles,
      counts: counts,
      asOf: asOf,
      queryMicros: sw.elapsedMicroseconds,
    );
  }

  Future<VehicleRow?> loadVehicle(String id) async {
    final snap = await loadFleet();
    for (final v in snap.vehicles) {
      if (v.id == id) return v;
    }
    return null;
  }

  Future<List<SignalReading>> loadRegister(String vehicleId) async {
    final asOf = now;
    final labels = {
      FleetRules.signalSoc: ('SOC', '%'),
      FleetRules.signalRange: ('Range', 'km'),
      FleetRules.signalSpeed: ('Speed', 'km/h'),
      FleetRules.signalBatteryTemp: ('Battery temp', '°C'),
      FleetRules.signalOdometer: ('Odometer', 'km'),
    };
    final readings = <SignalReading>[];
    for (final signal in FleetRules.registerSignals) {
      final row = await db.selectOne(
        '''
        SELECT value, event_time FROM vehicle_signal_latest
        WHERE vehicle_id = ? AND signal = ?
        ''',
        [vehicleId, signal],
      );
      final meta = labels[signal]!;
      if (row == null) {
        readings.add(SignalReading(signal: signal, label: meta.$1, unit: meta.$2));
        continue;
      }
      final value = asDouble(row['value'])!;
      final time = requireDateTime(row['event_time']);
      readings.add(
        SignalReading(
          signal: signal,
          label: meta.$1,
          unit: meta.$2,
          value: value,
          eventTime: time,
          verdict: verdictFor(now: asOf, signal: signal, value: value, eventTime: time),
        ),
      );
    }

    final ping = await db.selectOne(
      'SELECT MAX(event_time) AS last_ping FROM vehicle_signal_latest WHERE vehicle_id = ?',
      [vehicleId],
    );
    final lastPing = asDateTime(ping?['last_ping']);
    readings.add(
      SignalReading(
        signal: 'last_ping',
        label: 'Last ping',
        unit: '',
        value: lastPing?.millisecondsSinceEpoch.toDouble(),
        eventTime: lastPing,
        verdict: lastPing == null
            ? null
            : (asOf.difference(lastPing) > FleetRules.staleAfter
                ? SignalVerdict.stale
                : SignalVerdict.normal),
      ),
    );
    return readings;
  }

  Future<List<SocPoint>> loadSocHistory(String vehicleId, {Duration? window}) async {
    final from = now.subtract(window ?? FleetRules.retentionRaw);
    final rows = await db.select(
      '''
      SELECT date_trunc('minute', event_time) AS t, AVG(value) AS soc
      FROM readings
      WHERE vehicle_id = ? AND signal = 'soc' AND event_time >= ?
      GROUP BY 1
      ORDER BY 1
      ''',
      [vehicleId, from],
    );
    if (rows.isNotEmpty) {
      return [
        for (final row in rows)
          SocPoint(requireDateTime(row['t']), asDouble(row['soc'])!),
      ];
    }
    final hourly = await db.select(
      '''
      SELECT hour AS t, avg_soc AS soc
      FROM soc_hourly
      WHERE vehicle_id = ? AND hour >= ?
      ORDER BY hour
      ''',
      [vehicleId, from],
    );
    return [
      for (final row in hourly)
        SocPoint(requireDateTime(row['t']), asDouble(row['soc'])!),
    ];
  }

  Future<List<VehicleAlert>> loadOpenAlerts({String? vehicleId}) async {
    final sql = vehicleId == null
        ? '''
          SELECT * FROM alerts
          WHERE resolved_at IS NULL AND dismissed_at IS NULL
          ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, opened_at
          '''
        : '''
          SELECT * FROM alerts
          WHERE vehicle_id = ? AND resolved_at IS NULL AND dismissed_at IS NULL
          ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, opened_at
          ''';
    final rows = await db.select(sql, vehicleId == null ? const [] : [vehicleId]);
    return [for (final row in rows) _alertFrom(row)];
  }

  Future<List<Trip>> loadTrips(String vehicleId) async {
    final rows = await db.select(
      '''
      SELECT t.*, og.name AS origin_name, dg.name AS dest_name
      FROM trips t
      LEFT JOIN geofences og ON og.id = t.origin_geofence_id
      LEFT JOIN geofences dg ON dg.id = t.dest_geofence_id
      WHERE t.vehicle_id = ?
      ORDER BY t.started_at DESC
      ''',
      [vehicleId],
    );
    return [
      for (final row in rows)
        Trip(
          id: asString(row['id'])!,
          vehicleId: asString(row['vehicle_id'])!,
          originGeofenceId: asString(row['origin_geofence_id'])!,
          originName: asString(row['origin_name']),
          destGeofenceId: asString(row['dest_geofence_id']),
          destName: asString(row['dest_name']),
          startedAt: requireDateTime(row['started_at']),
          endedAt: asDateTime(row['ended_at']),
          status: asString(row['status']) == 'completed'
              ? TripStatus.completed
              : TripStatus.inProgress,
        ),
    ];
  }

  Future<List<Geofence>> loadGeofences({bool includeInactive = true}) async {
    final asOf = now;
    final rows = await db.select(
      '''
      SELECT g.*,
        (
          SELECT COUNT(*) FROM (
            SELECT v.id, $statusSql AS status
            $fleetFromSql
          ) fleet
          JOIN vehicle_geofence_current c ON c.vehicle_id = fleet.id
          WHERE c.geofence_id = g.id
            AND fleet.status != 'offline'
        ) AS vehicle_count
      FROM geofences g
      ${includeInactive ? '' : 'WHERE g.active'}
      ORDER BY g.active DESC, g.name
      ''',
      [asOf],
    );
    return [for (final row in rows) _geofenceFrom(row)];
  }

  Future<Geofence?> loadGeofence(String id) async {
    final all = await loadGeofences();
    for (final g in all) {
      if (g.id == id) return g;
    }
    return null;
  }

  Future<({int vehicles, int readings, int packets})> stats() async {
    final v = await db.selectOne('SELECT COUNT(*) AS c FROM vehicles');
    final r = await db.selectOne('SELECT COUNT(*) AS c FROM readings');
    final p = await db.selectOne('SELECT COUNT(*) AS c FROM packets');
    return (
      vehicles: asInt(v?['c']),
      readings: asInt(r?['c']),
      packets: asInt(p?['c']),
    );
  }

  Future<Map<String, int>> compactRetention() async {
    final cutoff = now.subtract(FleetRules.retentionRaw);
    await db.execute('''
      INSERT INTO soc_hourly (vehicle_id, hour, avg_soc, min_soc, max_soc)
      SELECT vehicle_id, date_trunc('hour', event_time), AVG(value), MIN(value), MAX(value)
      FROM readings
      WHERE signal = 'soc' AND event_time < ?
      GROUP BY 1, 2
      ON CONFLICT (vehicle_id, hour) DO UPDATE SET
        avg_soc = excluded.avg_soc,
        min_soc = excluded.min_soc,
        max_soc = excluded.max_soc
    ''', [cutoff]);

    final protected = await db.select('''
      SELECT DISTINCT p.id
      FROM packets p
      JOIN trips t ON t.vehicle_id = p.vehicle_id
      WHERE t.status = 'in_progress' AND p.event_time >= t.started_at
    ''');
    final keepIds = protected.map((r) => "'${asString(r['id'])}'").join(',');
    final keepClause = keepIds.isEmpty ? 'FALSE' : 'packet_id IN ($keepIds)';

    final droppedReadings = await db.selectOne(
      'SELECT COUNT(*) AS c FROM readings WHERE event_time < ? AND NOT ($keepClause)',
      [cutoff],
    );
    await db.execute(
      'DELETE FROM readings WHERE event_time < ? AND NOT ($keepClause)',
      [cutoff],
    );
    await db.execute(
      '''
      DELETE FROM packets p
      WHERE p.event_time < ?
        AND NOT EXISTS (SELECT 1 FROM readings r WHERE r.packet_id = p.id)
        AND p.id NOT IN (SELECT id FROM packets WHERE ${keepIds.isEmpty ? 'FALSE' : 'id IN ($keepIds)'})
      ''',
      [cutoff],
    );
    return {'dropped_readings': asInt(droppedReadings?['c'])};
  }

  VehicleAlert _alertFrom(Map<String, Object?> row) {
    return VehicleAlert(
      id: asString(row['id'])!,
      vehicleId: asString(row['vehicle_id'])!,
      kind: asString(row['kind'])!,
      severity: asString(row['severity']) == 'critical'
          ? AlertSeverity.critical
          : AlertSeverity.warning,
      openedAt: requireDateTime(row['opened_at']),
      resolvedAt: asDateTime(row['resolved_at']),
      dismissedAt: asDateTime(row['dismissed_at']),
      dismissReason: asString(row['dismiss_reason']),
    );
  }

  Geofence _geofenceFrom(Map<String, Object?> row) {
    return Geofence(
      id: asString(row['id'])!,
      name: asString(row['name'])!,
      lat: asDouble(row['lat'])!,
      lon: asDouble(row['lon'])!,
      radiusM: asDouble(row['radius_m'])!,
      active: asBool(row['active']),
      version: asInt(row['version']),
      createdAt: requireDateTime(row['created_at']),
      updatedAt: requireDateTime(row['updated_at']),
      deactivatedAt: asDateTime(row['deactivated_at']),
      vehicleCount: asInt(row['vehicle_count']),
    );
  }
}
