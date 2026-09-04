import 'package:flutter_take_home_task/app/startup_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a dynamic-library failure is explained, not just echoed', () {
    final failure = StartupFailure.from(
      ArgumentError(
        "Failed to load dynamic library 'duckdb.framework/duckdb': "
        'dlopen(duckdb.framework/duckdb, 0x0001): tried: '
        '/Runner.app/duckdb.framework/duckdb (no such file)',
      ),
    );

    expect(failure.headline, isNot(contains('dlopen')));
    expect(failure.explanation, isNotEmpty);
    expect(
      failure.detail,
      contains('dlopen'),
      reason: 'the trace is kept, it just does not lead',
    );
  });

  test('an unrelated failure keeps a generic headline', () {
    final failure = StartupFailure.from(StateError('disk full'));
    expect(failure.headline, 'Could not open the database');
    expect(failure.detail, contains('disk full'));
  });
}
