import 'dart:async';
import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:dart_duckdb/open.dart' as duckdb_lib;

import 'schema.dart';

/// Thin wrapper over a DuckDB connection.
///
/// dart_duckdb already runs every statement on its own isolate, so nothing
/// here needs to worry about blocking the UI thread -- a two-million-row scan
/// costs latency, not frames. What this class adds is the bits the raw API
/// leaves to the caller: rows as maps instead of positional lists, parameter
/// binding without hand-rolling a PreparedStatement each time, schema setup on
/// first open, and a write lock.
///
/// The write lock exists because DuckDB gives us one connection and therefore
/// one transaction context. Two overlapping `transaction()` bodies would
/// interleave their statements inside a single BEGIN and commit each other's
/// half-finished work. Serialising writes is the honest fix; reads stay
/// concurrent.
class FleetDb {
  FleetDb._(this._db, this._con, this.path);

  final Database _db;
  final Connection _con;

  /// The file this database lives in, or ':memory:' for tests.
  final String path;

  Future<void> _writeQueue = Future.value();
  bool _closed = false;

  /// Points the loader at a DuckDB build on disk.
  ///
  /// On a device the library is inside the app bundle and this is never
  /// called. Host-side runs (flutter test, tool/benchmark.dart) have no bundle,
  /// so they call this with the copy fetched by tool/fetch_duckdb_native.sh.
  static void useNativeLibrary(String libraryPath) {
    final os = Platform.isMacOS
        ? OperatingSystem.macOS
        : Platform.isLinux
            ? OperatingSystem.linux
            : Platform.isWindows
                ? OperatingSystem.windows
                : null;
    if (os != null) {
      duckdb_lib.open.overrideFor(os, libraryPath);
    }
  }

  static Future<FleetDb> open({String path = ':memory:'}) async {
    final db = await duckdb.open(path);
    final con = await duckdb.connect(db);
    final fleetDb = FleetDb._(db, con, path);
    await fleetDb._migrate();
    return fleetDb;
  }

  Future<void> _migrate() async {
    for (final statement in schemaStatements) {
      await _con.execute(statement);
    }
    await execute(
      "INSERT INTO meta VALUES ('schema_version', ?) "
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [schemaVersion.toString()],
    );
  }

  /// Runs a query and returns rows as column-name keyed maps.
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final result = await _run(sql, params);
    try {
      final names = result.columnNames;
      return [
        for (final row in result.fetchAll())
          {for (var i = 0; i < names.length; i++) names[i]: row[i]},
      ];
    } finally {
      await result.dispose();
    }
  }

  /// Runs a query expected to produce a single row, or null.
  Future<Map<String, Object?>?> selectOne(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final rows = await select(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  /// Runs a statement for its effect.
  Future<void> execute(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    if (params.isEmpty) {
      await _con.execute(sql);
      return;
    }
    final result = await _run(sql, params);
    await result.dispose();
  }

  Future<ResultSet> _run(String sql, List<Object?> params) async {
    if (params.isEmpty) return _con.query(sql);
    final statement = await _con.prepare(sql);
    try {
      // DuckDB parameter indices are 1-based.
      for (var i = 0; i < params.length; i++) {
        statement.bind(_normalise(params[i]), i + 1);
      }
      return await statement.execute();
    } finally {
      await statement.dispose();
    }
  }

  /// Timestamps are bound as UTC without exception.
  ///
  /// DuckDB's TIMESTAMP has no timezone, so a local DateTime would silently
  /// store wall-clock time in the operator's zone and compare wrong against
  /// event times from a vehicle in another one. Normalising at the boundary
  /// means the rest of the codebase can stop thinking about it.
  Object? _normalise(Object? value) =>
      value is DateTime ? value.toUtc() : value;

  /// Serialises a write transaction against all other writes.
  Future<T> transaction<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _con.execute('BEGIN TRANSACTION');
        try {
          final value = await body();
          await _con.execute('COMMIT');
          completer.complete(value);
        } catch (error, stack) {
          await _con.execute('ROLLBACK');
          completer.completeError(error, stack);
        }
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _con.dispose();
    await _db.dispose();
  }
}
