const fleetSchemaSql = r'''
CREATE TABLE IF NOT EXISTS vehicles (
  id VARCHAR PRIMARY KEY,
  reg_number VARCHAR NOT NULL,
  model VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS packets (
  id VARCHAR PRIMARY KEY,
  vehicle_id VARCHAR NOT NULL,
  event_time TIMESTAMP NOT NULL,
  ingest_time TIMESTAMP NOT NULL,
  UNIQUE (vehicle_id, event_time)
);

CREATE TABLE IF NOT EXISTS readings (
  packet_id VARCHAR NOT NULL,
  vehicle_id VARCHAR NOT NULL,
  signal VARCHAR NOT NULL,
  value DOUBLE NOT NULL,
  event_time TIMESTAMP NOT NULL,
  PRIMARY KEY (packet_id, signal)
);

CREATE INDEX IF NOT EXISTS idx_readings_vehicle_signal_time
  ON readings (vehicle_id, signal, event_time);

CREATE TABLE IF NOT EXISTS vehicle_signal_latest (
  vehicle_id VARCHAR NOT NULL,
  signal VARCHAR NOT NULL,
  value DOUBLE NOT NULL,
  event_time TIMESTAMP NOT NULL,
  packet_id VARCHAR NOT NULL,
  PRIMARY KEY (vehicle_id, signal)
);

CREATE TABLE IF NOT EXISTS geofences (
  id VARCHAR PRIMARY KEY,
  name VARCHAR NOT NULL,
  lat DOUBLE NOT NULL,
  lon DOUBLE NOT NULL,
  radius_m DOUBLE NOT NULL,
  active BOOLEAN NOT NULL,
  version INTEGER NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  deactivated_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS geofence_versions (
  geofence_id VARCHAR NOT NULL,
  version INTEGER NOT NULL,
  name VARCHAR NOT NULL,
  lat DOUBLE NOT NULL,
  lon DOUBLE NOT NULL,
  radius_m DOUBLE NOT NULL,
  valid_from TIMESTAMP NOT NULL,
  valid_to TIMESTAMP,
  PRIMARY KEY (geofence_id, version)
);

CREATE TABLE IF NOT EXISTS geofence_events (
  id VARCHAR PRIMARY KEY,
  vehicle_id VARCHAR NOT NULL,
  geofence_id VARCHAR NOT NULL,
  geofence_version INTEGER NOT NULL,
  kind VARCHAR NOT NULL,
  event_time TIMESTAMP NOT NULL,
  packet_id VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_geofence_events_vehicle_time
  ON geofence_events (vehicle_id, event_time);

CREATE TABLE IF NOT EXISTS vehicle_geofence_current (
  vehicle_id VARCHAR PRIMARY KEY,
  geofence_id VARCHAR
);

CREATE TABLE IF NOT EXISTS trips (
  id VARCHAR PRIMARY KEY,
  vehicle_id VARCHAR NOT NULL,
  origin_geofence_id VARCHAR NOT NULL,
  dest_geofence_id VARCHAR,
  started_at TIMESTAMP NOT NULL,
  ended_at TIMESTAMP,
  status VARCHAR NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_trips_vehicle ON trips (vehicle_id, started_at);

CREATE TABLE IF NOT EXISTS alerts (
  id VARCHAR PRIMARY KEY,
  vehicle_id VARCHAR NOT NULL,
  kind VARCHAR NOT NULL,
  severity VARCHAR NOT NULL,
  opened_at TIMESTAMP NOT NULL,
  resolved_at TIMESTAMP,
  dismissed_at TIMESTAMP,
  dismiss_reason VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_alerts_open
  ON alerts (vehicle_id, kind, resolved_at);

CREATE TABLE IF NOT EXISTS soc_hourly (
  vehicle_id VARCHAR NOT NULL,
  hour TIMESTAMP NOT NULL,
  avg_soc DOUBLE NOT NULL,
  min_soc DOUBLE NOT NULL,
  max_soc DOUBLE NOT NULL,
  PRIMARY KEY (vehicle_id, hour)
);

CREATE TABLE IF NOT EXISTS meta (
  key VARCHAR PRIMARY KEY,
  value VARCHAR NOT NULL
);
''';

/// Status is first-match-wins. `$now` is bound as a TIMESTAMP parameter.
const statusSql = '''
CASE
  WHEN ping.last_ping IS NULL OR (CAST(? AS TIMESTAMP) - ping.last_ping) > INTERVAL 10 MINUTE THEN 'offline'
  WHEN COALESCE(spd.value, 0) > 0 THEN 'moving'
  WHEN COALESCE(spd.value, 0) = 0 AND COALESCE(ign.value, 0) = 1 THEN 'idle'
  ELSE 'stopped'
END
''';

const fleetFromSql = '''
FROM vehicles v
LEFT JOIN (
  SELECT vehicle_id, MAX(event_time) AS last_ping
  FROM vehicle_signal_latest
  GROUP BY vehicle_id
) ping ON ping.vehicle_id = v.id
LEFT JOIN vehicle_signal_latest soc
  ON soc.vehicle_id = v.id AND soc.signal = 'soc'
LEFT JOIN vehicle_signal_latest rng
  ON rng.vehicle_id = v.id AND rng.signal = 'range'
LEFT JOIN vehicle_signal_latest spd
  ON spd.vehicle_id = v.id AND spd.signal = 'speed'
LEFT JOIN vehicle_signal_latest ign
  ON ign.vehicle_id = v.id AND ign.signal = 'ignition'
LEFT JOIN vehicle_geofence_current cur ON cur.vehicle_id = v.id
LEFT JOIN geofences g ON g.id = cur.geofence_id
LEFT JOIN (
  SELECT
    vehicle_id,
    COUNT(*) FILTER (WHERE resolved_at IS NULL AND dismissed_at IS NULL) AS open_alert_count,
    COUNT(*) FILTER (
      WHERE resolved_at IS NULL AND dismissed_at IS NULL AND severity = 'critical'
    ) AS critical_alert_count
  FROM alerts
  GROUP BY vehicle_id
) al ON al.vehicle_id = v.id
''';
