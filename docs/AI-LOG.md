# AI collaboration log

The raw conversation transcript is attached separately and uncurated. This file
is the index to it: what was actually hard, what the assistant got wrong, and
where the corrections came from. The dead ends are the interesting part, so
they are written up rather than tidied away.

Every item below is something that happened, not a retrospective
rationalisation. Where a decision was reversed, both the original and the
reason for reversing it are recorded.

---

## Things checked before building on them

**DuckDB under `flutter test`.** The first thing written was a throwaway probe
test, before any application code: does `dart_duckdb` load on the host Dart VM,
does `PRIMARY KEY` work, does `ON CONFLICT DO NOTHING` work, what do timestamps
come back as. The whole architecture leans on those answers. It would have been
easy to design the schema first and discover a week later that host tests
cannot open a database at all.

It turned out the loader looks for the library at a hardcoded relative path in
test environments, which is why `tool/fetch_duckdb_native.sh` exists.

**Whether queries block the UI isolate.** Read the package source rather than
guessing. `dart_duckdb` dispatches every statement to a background isolate
already, which removed a planned layer of isolate plumbing. That is a case
where reading 40 lines of a dependency saved a day of unnecessary work.

---

## Bugs the assistant wrote and then caught

**Trip tie-break ordering was backwards.** The trip engine sorted exits before
entries at equal timestamps, with a confident comment explaining that this
"keeps the occupancy set from spuriously emptying". It does the opposite. Two
adjacent sites sharing a boundary produce an exit from one and an entry to the
other on the same fix; processing the exit first empties the set for an instant
and invents a zero-length trip.

Caught by writing the test `simultaneous exit and entry is a handover, not a
trip` and reasoning through what it should assert *before* running it. The
comment was as wrong as the code, which is the useful lesson: a confident
comment is not evidence.

**Overlapping fences broke the exit fold.** The first version of
`TripEngine.run` treated any exit as potentially trip-starting. Folding from
scratch, a truck inside both a depot and a ring-road fence would exit the depot
first, see an empty occupancy set (because nothing had told it the truck was in
the ring road), and open a trip while the truck was demonstrably still parked.

Fixed by inferring initial occupancy from the crossing list itself: a fence
whose first crossing is an *exit* must have been occupied at the start. Caught
while writing the overlapping-fence tests, before it ever ran.

**Duplicated SQL into a test.** A pipeline test was written with the
current-geofence query pasted in as a local constant rather than imported from
`Q`. That is exactly the kind of copy that drifts and then asserts the wrong
thing forever. Deleted and replaced with the import in the same session it was
written.

**Two connections to one database file.** The device benchmark opened
`FleetDb` directly for the build phase and then opened `AppServices` on the
same path to run the derivation. It reported **0 crossings and 0 trips** while
the host run reported 14,491 and 7,246.

This one is worth dwelling on because the first instinct was to go looking for
a bug in the crossing engine — the engine was fine, and the harness was lying.
The counts were read through a handle that never saw the other handle's writes.
The comment in the benchmark now records it so the next person does not repeat
it.

---

## Places the tests were wrong, not the code

**Identical event times in the alert lifecycle tests.** Three alert tests
failed: a battery charging from 8% to 55% did not resolve its alert. The
instinct was to suspect the resolve SQL.

Instead a five-line probe was written that printed `latest_readings` after each
step. It showed SOC still at 8.0 — because the test's helper sent every packet
with the *same* event time, and the ingest rule is that a reading only becomes
current if its event time beats what is stored. The code was correct and the
fixture was not. The helper now advances the clock a minute per call, with a
comment explaining that two readings sharing an instant is a duplicate, not a
lifecycle case.

The general lesson: when a test fails, find out what the database actually
contains before editing the thing under test.

**A four-and-a-half minute test that was not slow.** The first widget test run
took 4:32 for one test while the other six took a second each. Two rounds of
instrumentation — timing `AppServices.boot`, then every step of the test body —
showed everything completing in under a second. Re-running the same file took
five seconds total. It was one-time kernel compilation of the Material library,
not a defect. Reported as such rather than "fixed" with a change that would
have done nothing.

---

## Library and tooling dead ends

**Named parameters in `dart_duckdb` are broken for repeated use.** The
reporting queries reference the current time a dozen times each, so they were
written with a named `$now` parameter bound once. Every query with a *second*
parameter then failed with "Can not bind to parameter number 6, statement only
has 2 parameters".

Reading the package source explained it: it enumerates named parameters by
scanning the SQL text and does not deduplicate, so `$now` used five times
consumes five slots while DuckDB allocates one. The fix is to interpolate the
clock as a literal — safe, since it is a timestamp we generate — and keep bound
parameters for real user input. The dead `selectNamed` helpers were deleted
rather than left lying around.

**`at` is a reserved word in DuckDB.** A history query aliased a column `AS at`
and failed with a bare "syntax error at or near ','", which points nowhere
useful. Found by bisecting the query against a live database rather than
staring at it: `AT` is part of `AT TIME ZONE`.

**Interval constructors reject bound parameters.** `time_bucket(INTERVAL (?)
SECOND, …)` does not parse. The bucket width is now interpolated, with a
comment saying why so nobody "fixes" it back.

**`dart_duckdb` 1.4.x cannot build for Android at all.** The Android build
failed with a 404 fetching `libduckdb-android_arm64-v8a.zip`. The package's
gradle script hardcodes a GitHub release URL, and 1.4.4 points at a `v1.4.4`
tag that was never published. Pinning to 1.4.2 — the newest release that *does*
have Android assets — failed too, because 1.4.2's gradle points at `v1.4.1`,
which does not exist either.

Resolved by querying the GitHub releases API for which versions actually ship
Android archives, then checking that 1.2.2's URL points at a real tag *and*
that its Dart API is identical before switching. The host test library was
re-pinned to the matching engine so tests and device run the same DuckDB.

**An `abiFilters` block that did nothing.** The debug APK is 232 MB because
DuckDB's native library is ~50 MB per ABI and debug builds carry three. Adding
`ndk { abiFilters }` to the app's gradle had no effect — Flutter's gradle plugin
adds the ABIs itself — and neither did `--target-platform android-arm64` on an
incremental build. The change was reverted rather than left in place looking
like it worked.

**iOS Simulator does not work, and it took two findings to be sure why.** The
first launch on a simulator failed with a dlopen trace saying
`duckdb.framework/duckdb` was not in the bundle. The obvious read is "the
framework is missing", and it was: the pod's prepare step had left
`duckdb-framework-ios.zip` sitting unextracted in `ios/Libraries/release/`.

Extracting it would have looked like a fix. Checking the binary before
declaring victory is what stopped that: `lipo -info` reports a single `arm64`
slice and `otool -l` reports `LC_VERSION_MIN_IPHONEOS`, meaning it is built for
physical devices and has no simulator slice at all. Checking every published
release back to 1.0.1 confirmed none of them ship one.

So there were two independent problems — an unextracted archive that also
breaks *device* builds, and a framework that fundamentally cannot load on a
simulator. Reporting only the first would have sent someone chasing a fix that
could never work.

**Web is impossible, not merely unsupported.** `flutter run -d chrome` failed
with hundreds of "Only JS interop members may be 'external'" errors from
`duckdb.g.dart`. The tempting read is that our own `dart:io` imports forced the
FFI path and that guarding them would fix it.

Checking the package first showed that is wrong: 1.2.2's `dart_duckdb.dart`
exports `src/ffi/duckdb_ffi.dart` with no `if (dart.library.io)` guard, and
there is no `src/web/` directory to fall back to. The bindings compile on every
platform whatever we do. 1.4.x does have the conditional export and a web
implementation — but 1.4.x cannot build for Android, so there is no version
that does both.

That turned a plausible afternoon of conditional-import surgery into a
two-minute answer plus a deleted `web/` folder.

**The emulator ran out of disk.** The existing Pixel 7 AVD had 537 MB free with
other projects' apps installed. Rather than delete someone else's apps, a
dedicated `Bench_Pixel7_API36` AVD was created with a 12 GB data partition.
Additive, reproducible, and it does not disturb the machine's existing state.

---

## A performance bug found by measuring, not by reading

App launch on the device measured ~5 s to first frame, of which ~3.7 s was our
own boot — while the same database open took 341 ms inside an already-running
process. That gap is the interesting signal.

The cause: `AppServices.boot` seeds geofences, and the seed check asked "is the
geofence list empty?". `GeofenceRepository.list()` computes vehicle counts per
fence, which resolved each vehicle's position by pivoting **every position row
in the log**. On a 2.6 M row database that is a full-history scan, and it ran on
every single app start.

Two fixes: the current-position query now reads the `latest_readings`
projection (proportional to the fleet, not to its history), and the seed check
counts rows instead of asking for the list.

This is the entire argument for the scale exercise. Nobody would have found it
by reading the code — it looks like a cheap existence check.

**And a second one underneath it.** With that fixed, a profile build still
spent ~2 s in boot while the same database open took 341 ms in an
already-running process. The gap was the signal. Listing the app's own files
showed a **7 MB write-ahead log**: Android force-stops a backgrounded process,
and DuckDB replays its WAL on open.

The fix is to checkpoint when the app is backgrounded. The first attempt
swallowed checkpoint failures silently, and the WAL did not shrink — so the
next step was to log the outcome rather than assume the fix worked. It reported
`checkpoint: ok in 603 ms` and the WAL fell from 14 MB to 105 KB. Launch went
from ~3.3 s to ~1.8 s.

Worth noting the near-miss: the version with the silent `catch` would have been
committed as a working fix, with a confident comment, and it was not working.
Logging the outcome is what turned an assumption into a measurement.

---

## Decisions the assistant proposed and were kept, with the reasoning recorded

- **Full per-vehicle replay instead of incremental derivation.** Proposed
  incremental with a stored checkpoint first, then rejected it: "the state we
  left off at" is not well-defined once packets arrive late. Replay makes
  idempotency a property of the construction rather than of an argument. The
  cost is measured (16.5 s for 500 vehicles) and the incremental design is
  written down in the README as the next step rather than half-built.

- **Fall through to STOPPED** for a vehicle that is online but stale on both
  speed and ignition. A fifth chip breaks the specified filter set; OFFLINE is
  a lie. Considered all three options explicitly rather than picking the first.

- **Versioned geofences.** Reached by asking what happens to April's trips when
  someone widens a fence in September, before writing any geofence code.

- **Content-hashed packet ids.** Chosen so retransmissions without a device id
  still dedupe, with the trade-off written down: two genuinely distinct
  identical packets collapse into one.

---

## Where a human should push back

These are the choices most worth arguing about in review, listed because they
are judgement calls rather than facts:

1. **STOPPED as the fall-through status.** Defensible, but an operator might
   reasonably prefer an explicit "no recent motion data" state, and that would
   mean changing the specified chip set.
2. **The 10-minute per-signal staleness window** is reused from the
   vehicle-level rule for simplicity. A real fleet would want it per signal —
   an odometer that only moves when the truck does should not be judged on the
   same clock as speed.
3. **Trips ignore direct handovers between overlapping fences.** Correct for
   nested fences (depot inside a ring road), arguably wrong for two adjacent
   depots that happen to touch.
4. **Full replay on every touched vehicle** is the right call at 500 vehicles
   and the wrong one at 50,000.
5. **The accuracy gate at 100 m** is a guess informed by nothing but
   plausibility. Real fleet data would set it empirically.
