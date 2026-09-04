import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/services.dart';
import 'app/startup_failure.dart';

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

class _BootstrapState extends State<_Bootstrap> with WidgetsBindingObserver {
  AppServices? _services;
  StartupFailure? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  /// Settle the database whenever the app leaves the foreground.
  ///
  /// Android will kill a backgrounded process without warning, and DuckDB
  /// replays its write-ahead log on the next open. Checkpointing here is the
  /// difference between relaunching into a settled file and relaunching into
  /// a couple of seconds of WAL replay -- measured, on a device, at 7 MB of
  /// WAL after a force-stop mid-simulation.
  ///
  /// The simulator is paused too: there is nothing to watch it, and a
  /// background process writing telemetry nobody asked for is just battery.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final services = _services;
    if (services == null) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        services.simulator.stop();
        unawaited(services.checkpoint());
      case AppLifecycleState.resumed:
        services.simulator.start();
      case AppLifecycleState.inactive:
        break;
    }
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
      if (mounted) setState(() => _error = StartupFailure.from(error));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
