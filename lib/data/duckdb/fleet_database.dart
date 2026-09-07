import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:dart_duckdb/open.dart' as duckdb_open;
import 'package:path/path.dart' as p;

import 'schema.dart';

/// File-backed (or test) DuckDB connection. UI and engines read through this.
class FleetDatabase {
  FleetDatabase._(this.path, this._database, this._connection);

  final String path;
  final Database _database;
  final Connection _connection;
  bool _closed = false;

  Connection get connection => _connection;

  static Future<FleetDatabase> open(String path) async {
    _bindNativeLibrary();
    final database = await duckdb.open(path);
    final connection = await duckdb.connect(database);
    final db = FleetDatabase._(path, database, connection);
    await db._migrate();
    return db;
  }

  Future<void> _migrate() async {
    for (final stmt in fleetSchemaSql
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)) {
      await _connection.execute('$stmt;');
    }
  }

  Future<void> execute(String sql, [List<Object?> params = const []]) async {
    if (params.isEmpty) {
      await _connection.execute(sql);
      return;
    }
    final stmt = await _connection.prepare(sql);
    try {
      stmt.bindParams(params);
      await stmt.execute();
    } finally {
      await stmt.dispose();
    }
  }

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    late final ResultSet rs;
    PreparedStatement? stmt;
    if (params.isEmpty) {
      rs = await _connection.query(sql);
    } else {
      stmt = await _connection.prepare(sql);
      stmt.bindParams(params);
      rs = await stmt.execute();
    }
    try {
      final names = rs.columnNames;
      return [
        for (final row in rs.fetchAll())
          {for (var i = 0; i < names.length; i++) names[i]: row[i]},
      ];
    } finally {
      await rs.dispose();
      await stmt?.dispose();
    }
  }

  Future<Map<String, Object?>?> selectOne(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final rows = await select(sql, params);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<void> transaction(Future<void> Function() body) async {
    await _connection.execute('BEGIN');
    try {
      await body();
      await _connection.execute('COMMIT');
    } catch (e) {
      try {
        await _connection.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  Future<Appender> appender(String table) => _connection.append(table, null);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _connection.dispose();
    await _database.dispose();
  }

  /// Linux tests/desktop need an explicit libduckdb.so; Android/iOS plugins bundle it.
  static void _bindNativeLibrary() {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    const env = 'DUCKDB_LIBRARY_PATH';
    final libName = Platform.isMacOS ? 'libduckdb.dylib' : 'libduckdb.so';
    final os = Platform.isMacOS ? OperatingSystem.macOS : OperatingSystem.linux;
    final candidates = <String>[
      if (Platform.environment[env] != null) Platform.environment[env]!,
      p.join(Directory.current.path, 'native', libName),
      p.join(
        Directory.current.path,
        '..',
        'duckdb',
        Platform.isMacOS ? 'macos' : 'linux',
        'Libraries',
        'release',
        libName,
      ),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        duckdb_open.open.overrideFor(os, path);
        return;
      }
    }
  }
}
