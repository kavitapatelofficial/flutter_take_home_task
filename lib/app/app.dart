import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/alerts/alerts_screen.dart';
import '../ui/diagnostics/diagnostics_screen.dart';
import '../ui/fleet/fleet_screen.dart';
import '../ui/geofences/geofences_screen.dart';
import 'providers.dart';
import 'startup_failure.dart';

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

  final StartupFailure? error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: error == null
              ? const Center(child: CircularProgressIndicator())
              : _StartupError(error!),
        ),
      );
}

/// The failure screen.
///
/// Leads with what is wrong and what to do, and puts the linker trace behind a
/// disclosure. The trace is the least useful thing on the screen for almost
/// everyone who will ever see it, and it was previously the only thing.
class _StartupError extends StatelessWidget {
  const _StartupError(this.failure);

  final StartupFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                size: 36,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(failure.headline, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                failure.explanation,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 20),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Technical detail',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: [
                    SelectableText(
                      failure.detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
