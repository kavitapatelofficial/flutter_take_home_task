import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/services.dart';

Future<void> main() async {
  // Started before anything else so the cold-start figure on the Diagnostics
  // screen covers the real path: binding initialisation, finding a writable
  // directory, opening the database, applying the schema.
  final startup = Stopwatch()..start();

  WidgetsFlutterBinding.ensureInitialized();

  runApp(_Bootstrap(startup: startup));
}

/// Opens the database, then hands the app its services.
///
/// The app deliberately does not render the fleet screen against an empty
/// store while the database warms up in the background. Local-first means the
/// database *is* the state; a screen that paints before it is open would be
/// showing something it made up.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.startup});

  final Stopwatch startup;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  AppServices? _services;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final services = await AppServices.boot(since: widget.startup);
      // A fresh install has an empty fleet, which makes for a poor first
      // impression of a screen whose whole job is showing 500 trucks. The
      // simulator fills it in over the first few seconds; the Diagnostics tab
      // has the button for the full 500-vehicle backfill.
      services.simulator.start();
      if (mounted) setState(() => _services = services);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _services?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_services == null) return BootScreen(error: _error);
    return ProviderScope(
      overrides: [servicesProvider.overrideWithValue(_services!)],
      child: const FleetConsoleApp(),
    );
  }
}
