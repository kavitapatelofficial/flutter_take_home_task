# Fleet Console

A local-first fleet operations screen for 500 electric trucks, built on an
embedded DuckDB. Telemetry lands in an append-only event log on the device; the
UI reads from that database and nothing else. Kill the app and relaunch it and
everything it knew comes back off disk.

---

## Running it

```bash
flutter pub get
flutter run                       # macOS, or -d <device> for Android
```

The app boots with an empty database, seeds four geofences, and starts a
simulator that fills the fleet in over the first few seconds. For the full
500-vehicle dataset, open **Diagnostics → Backfill 500 vehicles**.

### Tests

```bash
./tool/fetch_duckdb_native.sh     # once: host-side DuckDB for flutter test
flutter test
```

`flutter test` runs on the host Dart VM, which has no app bundle and therefore
none of the native DuckDB that ships inside the APK. The script drops the
matching build in `.native/` and the test harness points the loader at it.

87 tests. Most of them run against a real DuckDB rather than a mock, including
the widget tests — the failures worth catching in this app are the ones where
the SQL and the screen disagree, and a fake repository would prove nothing
about those.

### Benchmarks

```bash
dart run tool/benchmark.dart --build     # writes bench_out/fleet.duckdb
dart run tool/benchmark.dart --measure   # measures it in a fresh process

# on a device:
flutter test integration_test/device_benchmark_test.dart -d <device>
```

---

## 30-second tour

**Fleet** — every vehicle with registration, model, SOC, range, alert badge and
a status chip. Filter chips carry live counts computed in SQL over the same
definition the list uses, so a chip reading 42 above a list of 41 is impossible
by construction. The search box filters the counts too. Rows with critical
alerts sort to the top; the screen exists to answer "what needs attention now",
and alphabetical order answers a different question.

**Vehicle detail** — the readings register: one row per signal with its value,
its *own* age, and a verdict. NORMAL and ALERT are claims backed by a fresh
reading. STALE is grey and makes no claim in either direction. A signal that
has never reported shows a dash and no pill at all. Below it, SOC over the
retained window with the two alert thresholds drawn on, an expandable table of
the raw rows behind the chart, live alerts, and derived trips.

**Alerts** — unresolved, undismissed, and still backed by a fresh signal.
Dismissing opens the reason sheet ("I am on it", "Wrong alert", "Something
else…") and gives you five seconds to undo.

**Geofences** — create, edit and deactivate, with live counts of the vehicles
inside each. Editing supersedes a version rather than mutating one; the fleet
is re-derived afterwards.

**Diagnostics** — the scale exercise, runnable on the device being measured,
plus the simulator toggle and retention compaction.

---

## Architecture

```
telemetry ─▶ packets ─▶ signal_readings ────────────────┐  append-only log
                            │                            │
                            ├──▶ latest_readings         │  current state
                            ├──▶ geofence_events         │  derived
                            └──▶ trips ──────────────────┘
                                        ▲
                        UI ─────────────┘  reads projections, never the log
```

`signal_readings` is the only source of truth. Everything else is derived and
can be rebuilt from it, which is what makes late and out-of-order packets
tractable: there is no running total to patch, only a computation to redo.

Reading the log directly for every refresh would be the wrong work — a fleet
list that scans 2.6M rows to find 500 current values. So the log has
projections beside it, maintained on write. Query cost tracks the size of the
fleet, not the size of its history.

Everything a screen shows comes from a query. No widget keeps its own copy of
state that the database also holds; screens re-query on a tick rather than
patching themselves from a delta. `dart_duckdb` runs every statement on a
background isolate, so a slow query costs latency, never frames.

**Where the decisions live.** `lib/domain/rules.dart` holds every judgement
call — freshness windows, GPS gates, hysteresis, confirmation counts,
retention — with the reasoning attached. `lib/data/repo/queries.dart` holds the
SQL fragments that more than one screen depends on, so the status ladder exists
exactly once.

---

## The ambiguous cases, and how they were resolved

### Two different clocks for "stale"

The spec gives a vehicle-level staleness rule (OFFLINE after 10 minutes) and
separately asks the readings register for each signal's *own* age. These are
genuinely different clocks. A truck can heartbeat SOC every minute while its
odometer has not been mentioned in an hour. Both windows are 10 minutes — one
number to explain, and a signal unmentioned for ten minutes is exactly as
untrustworthy as a vehicle unheard-from for ten.

### A vehicle that is online but quiet on speed and ignition

The status ladder is decided on *fresh* speed and ignition only: 60 km/h
reported nine minutes ago and never since does not mean the truck is moving
now. That leaves a gap the spec's four buckets do not cover — online, but
neither signal fresh.

Three options: invent a fifth UNKNOWN chip, call it OFFLINE, or pick a resting
default. A fifth chip breaks the specified filter set. OFFLINE is a lie — the
vehicle is demonstrably talking to us. So it falls through to **STOPPED**: the
conservative claim, never asserting motion we cannot see. The readings register
still shows the real per-signal staleness, so nothing is hidden, only
summarised.

The ladder is implemented twice — in SQL for the list, in Dart for testing —
and a table-driven test runs the same cases through both.

### Duplicates

Packets dedupe on a primary key. When the device supplies an id we trust it;
when it does not, the id is a hash of the content — vehicle, event time, and
every signal/value pair sorted. A modem retransmitting the same reading
produces the same bytes and therefore the same key, so the retry does nothing.

The deliberate consequence: two genuinely distinct packets identical in every
field collapse into one. That is the right trade — a vehicle reporting the same
SOC twice in the same millisecond carries no information the first one did not,
and the alternative makes a duplicate indistinguishable from real data.

### Late packets

A late reading is still written to the log, still appears in history, still
moves geofences and trips. It just does not get to rewrite the present: the
`latest_readings` upsert only applies when the incoming event time beats what
is stored. One `WHERE` clause, and the rule holds everywhere.

Alerts are evaluated against current state rather than the incoming batch, so a
packet from an hour ago cannot raise an alert about a battery level the truck
has long since left behind.

### Clock skew

Packets timestamped more than 5 minutes into the future are **refused** and the
refusal recorded in `rejected_packets`. A vehicle clock that has drifted into
next week would otherwise pin the truck permanently fresh and poison every age
on screen. Ages are clamped at zero, so a slightly-fast clock reads as brand
new rather than negative. Nothing is dropped silently — silent drops are how
you lose an afternoon to a missing vehicle.

### GPS jitter, and inaccurate fixes

Two defences, because they solve different problems.

A **hysteresis band** around the fence edge: entry needs the fix inside by a
margin, exit needs it outside by a margin, and in between the previous state
stands and the fix is evidence of nothing. Without it a truck parked on a
boundary with 10 m of noise emits an entry/exit pair every few seconds and
manufactures hundreds of trips. There is a test that parks a vehicle on the
line for 40 fixes and asserts zero crossings.

**Two consecutive agreeing fixes** before a change is believed. One fix is a
rumour. This is the cheapest defence against a single wild outlier, and it
costs only one sampling interval of latency.

Fixes whose *own* reported accuracy is worse than 100 m cannot move a vehicle
at all — a fix admitting it could be 300 m off has no business crossing a 200 m
fence. Below that gate accuracy still widens the hysteresis band, so a ±60 m
fix must clear the edge by 60 m rather than the nominal 25.

### Missing intervals — the basement case

No interpolation. When a truck's last fix is inside the depot at 09:00 and its
next is on a motorway at 11:30, it certainly left, but we have no idea when.

The crossing is recorded at the first fix that confirms it, the window of
ignorance `[09:00, 11:30]` is kept on the row, and the row is flagged
`uncertain` so the UI can say "approximate" instead of quietly inventing a
two-and-a-half-hour trip.

Crossings are dated at the *first* fix that showed the new side, not the one
that confirmed it — the earlier fix is the better estimate of when it actually
happened; confirmation only decides whether we believe it at all.

### Geofence edits

Geofences are **versioned, never mutated**. Each fix is judged against the
version in force at that fix's own event time. Widening the depot fence this
afternoon does not retroactively un-leave a truck that departed in April.
Deactivation is the same mechanism — a new version with `active = false` — so a
retired depot stops producing crossings while every trip it ever named stays
readable.

### Overlapping fences

A vehicle can be inside several at once, and each fence is folded
independently, so occupancy is a set rather than a single answer.

Two different questions get two different answers. *"Which geofence is this
vehicle in?"* takes the smallest containing fence — the most specific answer is
the useful one. *"How many vehicles are in this fence?"* counts containment, so
a truck inside both the depot and the ring road counts for both.

For trips, a trip is about being **away**, not about being outside one
particular circle. It starts on the exit that empties the occupancy set and
ends on the entry that refills it. A truck rolling out of the depot gate while
still inside the ring-road fence has not started a journey; it starts when it
leaves the outermost fence. Entries sort before exits at equal timestamps, so
two adjacent sites sharing a boundary hand over without the set momentarily
emptying and inventing a zero-length trip.

The one-active-trip rule falls out of the machine rather than being enforced on
top of it: a trip can only start from a non-empty occupancy set, and starting
one empties it.

### Idempotency

Both engines are pure functions of an event-time-ordered input, and a touched
vehicle has its crossings and trips recomputed and replaced wholesale. The same
packets in any arrival order converge on the same rows; a duplicate batch is a
no-op because it recomputes the same answer. A late packet that revises a
crossing revises the trip that crossing produced rather than adding a second
one beside it.

This replays a vehicle rather than appending to it, deliberately. "The state we
left off at" is not well-defined once packets arrive late — a fix from twenty
minutes ago can break up a run of readings that had already confirmed a
crossing — and unpicking that from an accumulated counter means storing and
correctly restoring the engine's pending-candidate state, then getting it right
again every time a fence is edited. Replay makes idempotency a property of the
construction rather than of an argument. The cost is measured below.

### Alerts

The two SOC thresholds are **one escalating alert**. Severity is a column on
the open instance, recomputed on every fresh reading: 21 → 18 → 9 raises one
alert that escalates, and charging back to 15 de-escalates the same row rather
than closing it and opening another. It ends only when SOC clears 20.

**Resolution and dismissal are independent.** Dismissal annotates an instance;
it never closes one. A condition clearing closes the instance whether or not
anyone dismissed it. The consequence that matters: a condition that clears and
returns opens a *new* instance, undismissed and visible — dismissing today's
low battery must not suppress tomorrow's. There is a test named after exactly
that.

**Staleness suspends rather than resolves.** If the driving signal stops
reporting we make no claim in either direction, exactly as the register makes
no claim. The alert is hidden and the row left open, so when the truck comes
back on air we reuse the instance instead of raising a duplicate beside it.

---

## Scale exercise

### Method

`tool/benchmark.dart` builds the dataset and measures it **in two separate
processes** — building 2.6M rows leaves a process holding the memory it took to
build them, which is not what "memory at rest" means.
`integration_test/device_benchmark_test.dart` runs the same measurements inside
the real app, against the bundled DuckDB, writing to the real
application-support directory.

Both take five unmeasured warm-up passes before sampling. The first execution
of a query pays for planning, and quoting that as the steady-state figure would
be wrong in the flattering direction. 50 samples per figure.

The generator produces 2,625,000 signal rows: 500 vehicles × (700 samples × 6
signals + 350 position fixes × 3). Values are deterministic functions of
(vehicle, sample) rather than `random()`, so a regression is a regression and
not a different dice roll.

### Device: Pixel 7, API 36 (arm64 emulator), 4 cores, debug build

| Measurement | Result |
|---|---|
| Backfill, 2,625,000 rows | 25.4 s |
| Derivation — crossings + trips, all 500 vehicles | 16.5 s |
| Alert sweep, whole fleet | 54 ms |
| Cold open + first fleet query (500 rows) | **341 ms** |
| Fleet list, warm | **p50 8.1 ms · p95 17.4 ms** |
| Filter chip counts, warm | p50 5.3 ms · p95 8.8 ms |
| Filtered list (search), warm | p50 8.1 ms · p95 32.4 ms |
| RSS delta across opening the db + 500 rows | **3.2 MB** (408.6 MB total) |
| Database file | 43.8 MB |
| Derived | 14,491 crossings, 7,246 trips, 108 alerts |

### Host: M-series macOS, DuckDB 1.2.1

| Measurement | Result |
|---|---|
| Backfill, 2,625,000 rows | 0.70 s |
| Derivation, all 500 vehicles | 2.4 s |
| Cold open + first fleet query, fresh process | 74 ms |
| Fleet list, warm | p50 3.0 ms · p95 4.5 ms |
| Filter chip counts, warm | p50 1.9 ms · p95 2.0 ms |
| RSS at rest | 295.5 MB (260.8 MB before opening the db) |

The device and the host derive **identical** crossing and trip counts, which is
the determinism claim holding across two platforms and two CPU architectures.

### Reading these numbers

**The fleet list is fast, and that is the projection working, not DuckDB being
magic.** 8 ms at p50 over 2.6M stored rows is what you get for reading a
500-row projection instead of the log. The p95 of 17 ms is emulator noise —
other tenants on a shared machine — not a different code path.

**Cold start is 341 ms for the database, but app launch is not.** A debug build
measures ~4.8–5.5 s to first frame (`am start -W`), of which ~3.7 s is our own
boot. That is JIT warm-up, not the database: the same open takes 341 ms in an
already-running process. Debug numbers overstate startup badly and are reported
here as debug numbers.

Measuring this found a real bug. Startup was calling the geofence list, whose
vehicle counts pivoted *every position row the app had ever stored* — a
three-second full-history scan on every launch. The current-position query now
reads the projection instead of the log, and the seed check counts rows instead
of asking for the list. That is the kind of thing a benchmark is for.

**Derivation is the slow part, and I would fix it next.** 16.5 s to replay 500
vehicles is fine as a one-off backfill and fine for live ingest — a packet from
one truck replays one truck, a few milliseconds — but it is the number that
would hurt first at 5,000 vehicles or after a geofence edit, which re-derives
the fleet.

The fix is the incremental checkpoint described above: store the engine's
per-fence resume state (confirmed side, last agreeing fix, pending candidate
count) so an in-order batch folds only new fixes, and fall back to full replay
only when a packet lands before the watermark or a fence version changes. I
did not build it because replay makes idempotency provable rather than
argued, and correctness on the ambiguous cases is what this exercise is
actually about. I would rather ship a measured 16 s with a known fix than an
unmeasured optimisation that silently mis-handles a late packet.

**Memory is unremarkable.** 3.2 MB to open the database and materialise 500
rows. DuckDB is columnar and memory-maps its file, so history costs address
space rather than RSS. The 408 MB total is the Flutter debug engine plus this
benchmark's own heap, and means little on its own — the delta is the number
worth quoting.

---

## Retention

An append-only log grows forever. Three tiers, with what each one costs:

| Tier | Window | Kept | Lost |
|---|---|---|---|
| Raw | 7 days | Every reading as reported | — |
| Rollup | +90 days | 5-min buckets: min, max, last, count per (vehicle, signal) | Individual readings, packet ids, the ability to re-derive crossings |
| Beyond | — | Trips, crossings, alerts only | All telemetry |

The raw window is also the window in which a late packet can still correct
history, and in which a fence edit can still be applied retroactively — past
that line the positions that would have to be re-judged are gone.

Positions are **dropped rather than rolled up**: an averaged latitude is worse
than no latitude. The crossings derived from them survive as the summary, which
is the answer an operator actually wanted.

Trips, crossings and resolved alerts are a few rows per vehicle per day and are
kept indefinitely. Open alerts are never dropped however old they are. The SOC
chart reads raw rows and rollup buckets in one query, so it keeps working
across the boundary.

Compaction is a button on Diagnostics rather than a background job — on a
device, deciding *when* to spend that I/O is a product question, and wiring it
to app lifecycle or a WorkManager job is the obvious next step.

---

## What I cut, and why

**Trip distance.** The column exists and stays null. Computing it properly
means integrating over the position fixes per trip, and the honest cheap
version (straight line between fence centres) would be a misleading number on a
screen full of carefully-caveated ones. Not asked for; not worth a wrong
answer.

**A map.** Geofences are edited as latitude, longitude and radius in a form.
A map would be the obvious way to place a fence, and it is a rendering problem,
not a data-model problem — which is what this exercise is about.

**Incremental derivation.** Described above, measured, deliberately deferred.

**Schema migrations.** There is a `schema_version` in `meta` and a versioned
statement list, but only version 1 exists, so there is no migration path to
prove. Writing one with nothing to migrate would be speculative.

**Release-mode measurements.** All device figures are debug builds. Startup in
particular would improve substantially; the query numbers would move much less,
since they are dominated by native DuckDB rather than by Dart.

**A single `AppServices` locator** rather than finer-grained injection. It is
one class assembled at startup and overridden wholesale in tests, which is
enough seam for the tests that exist. At more screens I would split it.

---

## Notes on the dependency

`dart_duckdb` is pinned to exactly `1.2.2`, not `^1.2.0`. The package fetches
its Android `.so` at build time from a GitHub release URL hardcoded in its
gradle script, and on the 1.4 line those URLs point at releases that were never
published — 1.4.4 asks for a `v1.4.4` tag that does not exist, 1.4.2 asks for
`v1.4.1`, which does not either. Both fail the Android build with a 404 before
compiling a line of Dart. 1.2.2 points at `v1.2.0`, whose archives are actually
there, and its Dart API is identical.

Two other things cost time and are worth knowing:

- The package enumerates **named parameters** by scanning the SQL text without
  deduplicating, so a parameter used six times gets six slots while DuckDB
  allocates one, and every binding after the first lands on the wrong index.
  The reporting queries interpolate the clock as a literal instead; real user
  input still goes through bound parameters.
- `at` is a reserved word in DuckDB (`AT TIME ZONE`), and an interval
  constructor will not accept a bound parameter.
