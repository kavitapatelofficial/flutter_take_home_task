import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/alerts/alerts_screen.dart';
import '../ui/diagnostics/diagnostics_screen.dart';
import '../ui/fleet/fleet_screen.dart';
import '../ui/geofences/geofences_screen.dart';
import '../ui/widgets/common.dart';
import 'providers.dart';

class FleetConsoleApp extends StatelessWidget {
  const FleetConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // A dark console. Operators read this in a cab or a yard office, and the
    // status colours carry meaning, so the surface stays out of their way.
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4C8DFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF12141A),
    );

    return MaterialApp(
      title: 'Fleet Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
          space: 1,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      home: const _Shell(),
    );
  }
}

class _Shell extends ConsumerStatefulWidget {
  const _Shell();

  @override
  ConsumerState<_Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<_Shell> {
  int _tab = 0;

  static const _titles = ['Fleet', 'Alerts', 'Geofences', 'Diagnostics'];

  @override
  Widget build(BuildContext context) {
    final alertCount = ref.watch(alertCountProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
      body: IndexedStack(
        index: _tab,
        children: const [
          FleetScreen(),
          AlertsScreen(),
          GeofencesScreen(),
          DiagnosticsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        height: 62,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping),
            label: 'Fleet',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: alertCount > 0,
              label: Text('$alertCount'),
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: alertCount > 0,
              label: Text('$alertCount'),
              child: const Icon(Icons.notifications),
            ),
            label: 'Alerts',
          ),
          const NavigationDestination(
            icon: Icon(Icons.fence_outlined),
            selectedIcon: Icon(Icons.fence),
            label: 'Geofences',
          ),
          const NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: 'Diagnostics',
          ),
        ],
      ),
    );
  }
}

/// Shown while the database opens and the schema is applied.
class BootScreen extends StatelessWidget {
  const BootScreen({super.key, this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: error == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not open the database',
                  detail: '$error',
                ),
        ),
      );
}
