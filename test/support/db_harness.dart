import 'dart:io';

import 'package:flutter_take_home_task/data/db/fleet_db.dart';

/// Points dart_duckdb at the host-side library once per test process.
///
/// `flutter test` runs on the host Dart VM, which has no app bundle and so no
/// vendored DuckDB. tool/fetch_duckdb_native.sh puts a matching build in
/// .native/ and this hands the loader its path.
bool _bootstrapped = false;

void useHostDuckDb() {
  if (_bootstrapped) return;
  _bootstrapped = true;

  final root = _projectRoot();
  final candidates = [
    '$root/.native/libduckdb.dylib',
    '$root/.native/libduckdb.so',
  ];
  final found = candidates.firstWhere(
    (p) => File(p).existsSync(),
    orElse: () => '',
  );
  if (found.isEmpty) {
    throw StateError(
      'DuckDB native library not found. Run tool/fetch_duckdb_native.sh first.',
    );
  }
  FleetDb.useNativeLibrary(found);
}

String _projectRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return dir.path;
}

/// An empty in-memory database with the schema applied.
Future<FleetDb> openTestDb() async {
  useHostDuckDb();
  return FleetDb.open();
}
