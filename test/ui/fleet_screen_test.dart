import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_take_home_task/app/providers.dart';
import 'package:flutter_take_home_task/app/services.dart';
import 'package:flutter_take_home_task/core/clock.dart';
import 'package:flutter_take_home_task/data/ingest/packet.dart';
import 'package:flutter_take_home_task/domain/model/models.dart';
import 'package:flutter_take_home_task/ui/alerts/alerts_screen.dart';
import 'package:flutter_take_home_task/ui/fleet/fleet_screen.dart';
import 'package:flutter_take_home_task/ui/vehicle/vehicle_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_harness.dart';

/// Widget tests against a real DuckDB, not a mock repository.
///
/// The failures worth catching in this app are the ones where the SQL and the
/// screen disagree -- a chip count that does not match the list it filters to,
/// a STALE pill where an ALERT belongs. A fake repository would answer
/// whatever the test told it to and prove none of that.
///
/// Everything runs inside [WidgetTester.runAsync]. testWidgets normally
/// executes its body in a fake-async zone where timers never fire on their
/// own, and every read here completes from dart_duckdb's background isolate --
/// real async that the fake clock will not deliver, so the test would simply
/// hang. runAsync gives us the real event loop; the cost is that
/// pumpAndSettle is unavailable, so [_settle] pumps a bounded number of real
/// frames instead.
void main() {
  late AppServices services;
  late FixedClock clock;

  final t0 = DateTime.utc(2026, 9, 4, 12);

  setUp(() async {
    useHostDuckDb();
    clock = FixedClock(t0);
    services = await AppServices.boot(clock: clock, overridePath: ':memory:');
  });
  tearDown(() async => services.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpApp(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          servicesProvider.overrideWithValue(services),
          // No wall-clock refresh timer: the tests move the clock themselves,
          // and a periodic rebuild would make frame counts unpredictable.
          refreshIntervalProvider.overrideWithValue(null),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> send(
    String vehicleId,
    Map<String, double> signals, {
    Duration ago = Duration.zero,
  }) =>
      services.pipeline.ingest([
        TelemetryPacket(
          vehicleId: vehicleId,
          eventTime: clock.nowUtc().subtract(ago),
          signals: signals,
        ),
      ]);

  Future<void> addVehicle(String id, String reg) => services.db.execute(
        'INSERT INTO vehicles VALUES (?, ?, ?)',
        [id, reg, 'eTruck 400'],
      );

  group('fleet list', () {
    testWidgets('renders a vehicle with its status and charge', (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'KA01AB1234');
        await send('v1', {'speed': 42, 'soc': 66, 'range_km': 277});

        await pumpApp(tester, const FleetScreen());

        expect(find.text('KA01AB1234'), findsOneWidget);
        expect(find.text('MOVING'), findsOneWidget);
        expect(find.text('66%'), findsOneWidget);
        expect(find.text('277 km'), findsOneWidget);
      });
    });

    testWidgets('chip counts agree with the list they filter to',
        (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'MOVER0001');
        await addVehicle('v2', 'IDLER0001');
        await addVehicle('v3', 'GONE00001');
        await send('v1', {'speed': 40, 'soc': 80});
        await send('v2', {'speed': 0, 'ignition': 1, 'soc': 70});
        await send('v3', {'soc': 60}, ago: const Duration(hours: 2));

        await pumpApp(tester, const FleetScreen());

        expect(find.text('All  3'), findsOneWidget);
        expect(find.text('Moving  1'), findsOneWidget);
        expect(find.text('Idle  1'), findsOneWidget);
        expect(find.text('Offline  1'), findsOneWidget);

        await tap(tester, find.text('Moving  1'));
        expect(find.text('MOVER0001'), findsOneWidget);
        expect(find.text('IDLER0001'), findsNothing);
      });
    });

    testWidgets('a filter matching nothing shows an empty state',
        (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'KA01AB1234');
        await send('v1', {'speed': 40, 'soc': 80});

        await pumpApp(tester, const FleetScreen());
        await tap(tester, find.text('Offline  0'));

        expect(find.text('No vehicles match'), findsOneWidget);

        await tap(tester, find.text('Clear filters'));
        expect(find.text('KA01AB1234'), findsOneWidget);
      });
    });
  });

  group('readings register', () {
    testWidgets('shows a verdict per signal, including STALE and a dash',
        (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'KA01AB1234');
        // Fresh and fine, fresh and bad, and one that last reported hours ago.
        await send('v1', {'speed': 0, 'soc': 12});
        await send('v1', {'odometer': 98000}, ago: const Duration(hours: 3));

        await pumpApp(tester, const VehicleScreen(vehicleId: 'v1'));

        expect(find.text('NORMAL'), findsWidgets);
        expect(find.text('ALERT'), findsOneWidget, reason: 'SOC is under 20');
        expect(find.text('STALE'), findsOneWidget, reason: 'the odometer');
        // Battery temperature never reported: a dash, and no pill at all.
        expect(find.text('—'), findsWidgets);
      });
    });

    testWidgets('a verdict is withdrawn once its signal goes stale',
        (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'KA01AB1234');
        await send('v1', {'soc': 12, 'speed': 0});

        await pumpApp(tester, const VehicleScreen(vehicleId: 'v1'));
        expect(find.text('ALERT'), findsOneWidget);

        clock.advance(const Duration(minutes: 30));
        await services.pipeline.refreshDerivedState();
        await settle(tester);

        expect(find.text('ALERT'), findsNothing,
            reason: 'a signal we cannot see supports no claim either way');
        expect(find.text('STALE'), findsWidgets);
      });
    });
  });

  group('alerts', () {
    testWidgets('dismissing asks for a reason and offers undo', (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'KA01AB1234');
        await send('v1', {'soc': 8});

        await pumpApp(tester, const AlertsScreen());
        expect(find.text('Battery critically low'), findsOneWidget);

        await tap(tester, find.text('Dismiss'));

        // The three reasons, in the order the spec gives them.
        for (final reason in DismissReason.values) {
          expect(find.text(reason.label), findsOneWidget);
        }

        await tap(tester, find.text('I am on it'));
        expect(find.text('UNDO'), findsOneWidget);
        expect(find.text('Battery critically low'), findsNothing);

        await tap(tester, find.text('UNDO'));
        expect(find.text('Battery critically low'), findsOneWidget,
            reason: 'undo restores the alert, it does not raise a new one');
      });
    });

    testWidgets('an empty alert list explains itself', (tester) async {
      await tester.runAsync(() async {
        await addVehicle('v1', 'KA01AB1234');
        await send('v1', {'soc': 90});

        await pumpApp(tester, const AlertsScreen());
        expect(find.text('Nothing needs attention'), findsOneWidget);
      });
    });
  });
}
