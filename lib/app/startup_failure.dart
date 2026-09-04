import 'dart:io';

/// A boot failure translated into something a human can act on.
///
/// The raw failure when DuckDB's native library is missing is a forty-line
/// dlopen trace listing every path the loader tried. That is the right
/// information for the person who wrote the loader and the wrong information
/// for anyone else: it says where it looked, never why it was not there.
class StartupFailure implements Exception {
  const StartupFailure({
    required this.headline,
    required this.explanation,
    required this.detail,
  });

  /// One line, the actual problem.
  final String headline;

  /// What to do about it.
  final String explanation;

  /// The original error, kept for whoever does want the trace.
  final String detail;

  /// Classifies a boot error.
  ///
  /// Only the native-library case gets special treatment, because it is the
  /// one that is not the app's fault and not the user's either -- it is a
  /// packaging fact about the platform they happen to be on.
  factory StartupFailure.from(Object error) {
    final text = error.toString();
    final isLibraryFailure = text.contains('Failed to load dynamic library') ||
        text.contains('dlopen') ||
        text.contains('duckdb.framework');

    if (!isLibraryFailure) {
      return StartupFailure(
        headline: 'Could not open the database',
        explanation:
            'The database file may be corrupt or in use by another copy of '
            'the app. Deleting it and relaunching will start over.',
        detail: text,
      );
    }

    if (Platform.isIOS) {
      return StartupFailure(
        headline: 'DuckDB is not available on the iOS Simulator',
        explanation:
            'dart_duckdb ships a device-only iOS framework: every published '
            'release is built for arm64-iphoneos, with no simulator slice, so '
            'the linker has nothing to load here.\n\n'
            'Run on a physical iPhone, or on macOS or Android, all of which '
            'are supported. This is a limitation of the package, not of the '
            'app: nothing above the storage layer is platform-specific.',
        detail: text,
      );
    }

    return StartupFailure(
      headline: 'DuckDB could not be loaded',
      explanation:
          'The native DuckDB library is missing from this build. On desktop '
          'and in tests it is fetched by tool/fetch_duckdb_native.sh; on a '
          'device it ships inside the app bundle, so a failure here usually '
          'means the build did not complete. Try a clean rebuild.',
      detail: text,
    );
  }

  @override
  String toString() => '$headline\n\n$explanation\n\n$detail';
}
