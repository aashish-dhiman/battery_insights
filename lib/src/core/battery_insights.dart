import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../debug/battery_debug_snapshot.dart';
import '../models/battery_insights_config.dart';
import '../models/battery_reading.dart';
import '../models/battery_run_report.dart';
import '../models/battery_segment.dart';
import '../models/capacity_estimator.dart';
import '../models/battery_usage.dart';
import '../platform/battery_probe.dart';

/// Receives each event — `battery_segment`, `battery_flow` or
/// `battery_session` — with its parameters. The host routes it to its
/// analytics SDK.
typedef BatteryEventSink = void Function(
    String name, Map<String, Object> params);

/// Receives per-device battery facts that change rarely (capacity, cycles,
/// health). Route to user properties so every event from the device carries
/// them without spending event parameters.
typedef BatteryDeviceSink = void Function(String name, String value);

/// Measures the battery drain of a Flutter app on real devices, two ways:
///
/// * **Flow-wise** — every visit to a flow (checkout, camera, video call…)
///   gets its own drain, reported as a `battery_flow` event and returned from
///   [BatteryFlowRun.finish].
/// * **For every user, all the time** — the app's whole life is split into
///   foreground and background sessions (`battery_session`), and into segments
///   of constant state (`battery_segment`) that attribute drain to flow, app
///   state, charging, screen, network and the host's own dimensions. On-device
///   daily totals are kept in [usage].
///
/// Measuring must not add drain: there are no timers, wake locks or listeners
/// on the battery. The battery is read only when the app is awake anyway — a
/// state transition, or a [recordSample] from a callback the host already
/// runs (location, heartbeat).
///
/// Every public method is safe to call before [init], when disabled, and
/// repeatedly with an unchanged value. None of them throws.
class BatteryInsights {
  BatteryInsights._();

  static final BatteryInsights instance = BatteryInsights._();

  @visibleForTesting
  BatteryInsights.forTesting({
    required BatteryProbe probe,
    required DateTime Function() clock,
  })  : _probe = probe,
        _clock = clock;

  static const String eventName = 'battery_segment';
  static const String flowEventName = 'battery_flow';
  static const String sessionEventName = 'battery_session';

  /// Device property names, as sent to [BatteryDeviceSink]. Kept within
  /// Firebase's 24-character limit for user property names.
  static const String propCapacityMah = 'battery_capacity_mah';
  static const String propCycleCount = 'battery_cycle_count';
  static const String propHealth = 'battery_health';
  static const String propDesignMah = 'battery_design_mah';

  static const String _prefConfig = 'battery_insights.config';
  static const String _prefBucket = 'battery_insights.bucket';
  static const String _prefSegment = 'battery_insights.segment';
  static const String _prefOverlay = 'battery_insights.debug_overlay';
  static const String _prefCapacity = 'battery_insights.capacity';
  static const String _prefUsage = 'battery_insights.usage';

  /// Closed segments kept in memory for [debugSnapshot].
  static const int _debugRecordLimit = 30;

  /// Flow runs and sessions kept in memory for [debugSnapshot].
  static const int _debugRunLimit = 20;

  BatteryProbe _probe = const PlatformBatteryProbe();
  DateTime Function() _clock = DateTime.now;
  BatteryEventSink? _sink;
  BatteryDeviceSink? _deviceSink;
  final Map<String, String> _deviceSent = {};
  CapacityEstimator _capacity = CapacityEstimator();
  double? _capacitySent;
  SharedPreferences? _prefs;
  BatteryInsightsConfig _config = const BatteryInsightsConfig();
  int _bucket = 0;
  AppLifecycleListener? _lifecycle;

  String _appState = 'unknown';
  final List<BatteryFlowRun> _flows = [];
  final Map<String, String> _custom = {};

  /// Flow runs and the current session: every reading is added to each.
  final List<BatteryRunAccumulator> _openRuns = [];
  BatteryRunAccumulator? _session;
  final List<BatteryRunReport> _recentRuns = [];
  final StreamController<BatteryRunReport> _reports =
      StreamController<BatteryRunReport>.broadcast();
  BatteryUsageLedger _usage = BatteryUsageLedger();

  BatterySegment? _segment;
  DateTime? _lastReadAt;

  final _DebugNotifier _debugChanges = _DebugNotifier();
  final List<BatteryDebugRecord> _records = [];
  int _sentCount = 0;
  int _droppedCount = 0;
  BatteryReading? _latest;

  /// Whether any reading this process carried a thermal headroom. A single
  /// reading without one proves nothing — the OS rate-limits the call — so
  /// "no thermal HAL" is only claimed while this is still false.
  bool _thermalHeadroomSeen = false;

  /// Whether the host should draw the floating debug HUD. Persisted; the host
  /// decides where (if anywhere) the switch is offered.
  final ValueNotifier<bool> overlayEnabled = ValueNotifier(false);

  /// Reads are async; every operation runs through this chain so a transition
  /// never interleaves with another and segments stay contiguous.
  Future<void> _queue = Future.value();

  bool get isActive => _config.enabled && _bucket < _config.samplePct;

  /// The innermost open flow, or `none` when the user is in no flow — which
  /// is what makes idle drain a row of its own.
  String get currentFlow => _flows.isEmpty ? 'none' : _flows.last.name;

  /// The config in effect.
  BatteryInsightsConfig get config => _config;

  /// Every finished flow run and session, as it finishes — whether or not it
  /// was long enough to be sent to the sink. Only while [isActive].
  Stream<BatteryRunReport> get reports => _reports.stream;

  /// On-device totals of the app's battery use, newest day first, for the
  /// last [BatteryInsightsConfig.usageDays] days (empty when that is 0).
  /// Built from closed segments, so
  /// the segment in progress (at most [BatteryInsightsConfig.rollAfter] old
  /// when sampled) is not in it yet.
  List<BatteryDayUsage> get usage => _usage.days;

  /// Today's entry of [usage], or null before any segment closed today.
  BatteryDayUsage? get usageToday => _usage.dayOf(_clock());

  /// Resizes the ledger to [BatteryInsightsConfig.usageDays], deleting the
  /// stored totals when it is 0 and rewriting them when days were dropped.
  void _applyUsageDays() {
    final before = _usage.days.length;
    _usage.maxDays = _config.usageDays;
    if (_usage.maxDays == 0) {
      _prefs?.remove(_prefUsage);
    } else if (_usage.days.length != before) {
      _prefs?.setString(_prefUsage, jsonEncode(_usage.toJson()));
    }
  }

  /// Forgets [usage].
  void clearUsage() {
    _usage.clear();
    _prefs?.remove(_prefUsage);
    _debugChanges.notify();
  }

  @visibleForTesting
  Future<void> get settled => _queue;

  /// Fires whenever anything in [debugSnapshot] may have changed.
  Listenable get debugChanges => _debugChanges;

  /// The engine's state right now, for debug tooling.
  BatteryDebugSnapshot get debugSnapshot {
    final seg = _segment;
    return BatteryDebugSnapshot(
      config: _config,
      bucket: _bucket,
      isActive: isActive,
      appState: _appState,
      flows: [for (final f in _flows) f.name],
      recentRuns: List.unmodifiable(_recentRuns.reversed),
      usageToday: usageToday,
      dimensions: Map.unmodifiable(_custom),
      latest: _latest,
      thermalHeadroomSeen: _thermalHeadroomSeen,
      capacityMah: _capacity.capacityMah,
      capacitySamples: _capacity.sampleCount,
      openSegment: seg == null
          ? null
          : BatteryOpenSegment(
              dims: Map.unmodifiable(seg.dims),
              start: seg.start,
              last: seg.last,
              samples: seg.samples,
              maxTempC: seg.maxTempC,
              thermalStatusMax: seg.thermalStatusMax,
              thermalHeadroomMax: seg.thermalHeadroomMax,
            ),
      recent: List.unmodifiable(_records.reversed),
      sentCount: _sentCount,
      droppedCount: _droppedCount,
      deviceProperties: Map.unmodifiable(_deviceSent),
    );
  }

  /// Reads the battery for display only: segments, throttling and reporting
  /// are untouched, so a debug screen refreshing it cannot skew the data.
  Future<void> probeNow() async {
    try {
      final r = await _probe.read();
      if (r == null) return;
      _remember(r);
      _debugChanges.notify();
    } catch (e) {
      debugPrint('BatteryInsights: probeNow failed: $e');
    }
  }

  void setOverlayEnabled(bool value) {
    overlayEnabled.value = value;
    _prefs?.setBool(_prefOverlay, value);
  }

  /// Loads the persisted config and reports a segment left open by a process
  /// that died. Call once at startup, after `WidgetsFlutterBinding` exists.
  ///
  /// [sink] receives every event for your analytics backend; leave it out to
  /// use only [reports] and [usage]. [config], when given, is applied as if
  /// passed to [configure] — otherwise the last persisted config holds, and
  /// a fresh install stays off until [configure] turns it on.
  Future<void> init({
    BatteryEventSink? sink,
    BatteryDeviceSink? deviceSink,
    BatteryInsightsConfig? config,
    BatteryProbe? probe,
    bool observeLifecycle = true,
  }) async {
    try {
      _sink = sink;
      _deviceSink = deviceSink;
      if (probe != null) _probe = probe;
      final prefs = _prefs = await SharedPreferences.getInstance();

      final rawConfig = prefs.getString(_prefConfig);
      if (rawConfig != null) {
        _config = BatteryInsightsConfig.fromJson(
            Map<String, dynamic>.from(jsonDecode(rawConfig) as Map));
      }
      var bucket = prefs.getInt(_prefBucket);
      if (bucket == null) {
        bucket = Random().nextInt(100);
        await prefs.setInt(_prefBucket, bucket);
      }
      _bucket = bucket;
      overlayEnabled.value = prefs.getBool(_prefOverlay) ?? false;
      if (config != null) {
        _config = config;
        await prefs.setString(_prefConfig, jsonEncode(config.toJson()));
      }
      final rawUsage = prefs.getString(_prefUsage);
      if (rawUsage != null) {
        try {
          _usage = BatteryUsageLedger.fromJson(
              Map<String, dynamic>.from(jsonDecode(rawUsage) as Map));
        } catch (_) {}
      }
      _applyUsageDays();
      final rawCapacity = prefs.getString(_prefCapacity);
      if (rawCapacity != null) {
        try {
          _capacity = CapacityEstimator.fromJson(
              Map<String, dynamic>.from(jsonDecode(rawCapacity) as Map));
        } catch (_) {}
      }

      _appState =
          _appStateOf(WidgetsBinding.instance.lifecycleState) ?? 'unknown';
      if (observeLifecycle) {
        _lifecycle ??= AppLifecycleListener(onStateChange: handleLifecycle);
      }

      _recoverAfterProcessDeath();
      _start();
    } catch (e) {
      debugPrint('BatteryInsights: init failed: $e');
    }
  }

  /// Applies remote config. Persisted, so a cold start follows the last known
  /// switch before the config is fetched again.
  void configure(BatteryInsightsConfig config) {
    try {
      final wasActive = isActive;
      _config = config;
      _prefs?.setString(_prefConfig, jsonEncode(config.toJson()));
      _applyUsageDays();
      if (wasActive && !isActive) {
        _enqueue(() async {
          _segment = null;
          for (final run in _openRuns) {
            run.reset();
          }
          _openRuns.clear();
          _session = null;
          await _prefs?.remove(_prefSegment);
        });
      } else if (!wasActive && isActive) {
        _start();
      }
      _debugChanges.notify();
    } catch (e) {
      debugPrint('BatteryInsights: configure failed: $e');
    }
  }

  /// Sets a host dimension such as `camera` or `tracking`; null clears it.
  /// A change closes the current segment. Keys beyond
  /// [BatteryInsightsConfig.maxDimensions] are ignored.
  void setDimension(String key, String? value) {
    try {
      if (_custom[key] == value) return;
      if (value == null) {
        _custom.remove(key);
      } else {
        if (!_custom.containsKey(key) &&
            _custom.length >= _config.maxDimensions) {
          debugPrint('BatteryInsights: dimension "$key" over the limit');
          return;
        }
        _custom[key] = value;
      }
      _transition(key);
      _debugChanges.notify();
    } catch (e) {
      debugPrint('BatteryInsights: setDimension failed: $e');
    }
  }

  /// Enters a flow and starts measuring it. Call [BatteryFlowRun.finish] (or
  /// [popFlow]) when the user leaves it.
  ///
  /// Flows nest: while an inner flow is open, segments are attributed to it,
  /// and leaving it returns attribution to the one around it. Each flow's run
  /// covers its whole visit, nested flows included.
  BatteryFlowRun startFlow(String name) => pushFlow(name);

  /// Same as [startFlow]; the returned run is the token for [popFlow].
  BatteryFlowRun pushFlow(String name) {
    final run = BatteryFlowRun._(this, name);
    try {
      final before = currentFlow;
      _flows.add(run);
      void begin(BatteryReading? r) {
        if (r != null) _beginRun(run._acc, r);
      }

      if (currentFlow != before) {
        _transition('flow', then: begin);
      } else {
        _atReading(begin);
      }
      _debugChanges.notify();
    } catch (e) {
      debugPrint('BatteryInsights: pushFlow failed: $e');
    }
    return run;
  }

  /// Leaves the flow [token] was returned for. Calling it again is a no-op.
  void popFlow(Object token) {
    try {
      final before = currentFlow;
      if (token is! BatteryFlowRun || !_flows.remove(token)) return;
      void end(BatteryReading? r) => token._complete(_endRun(token._acc));
      if (currentFlow != before) {
        _transition('flow', then: end);
      } else {
        _atReading(end);
      }
      _debugChanges.notify();
    } catch (e) {
      debugPrint('BatteryInsights: popFlow failed: $e');
    }
  }

  /// A moment the app is already awake — call from location and heartbeat
  /// callbacks. Throttled to [BatteryInsightsConfig.minSampleInterval]. Keeps
  /// long segments sampled, notices charging and screen changes, and rolls
  /// segments older than [BatteryInsightsConfig.rollAfter].
  void recordSample() {
    try {
      if (!isActive) return;
      final now = _clock();
      final last = _lastReadAt;
      if (last != null && now.difference(last) < _config.minSampleInterval) {
        return;
      }
      _lastReadAt = now;
      _enqueue(_sample);
    } catch (e) {
      debugPrint('BatteryInsights: recordSample failed: $e');
    }
  }

  /// `inactive` is ignored: it flickers for permission dialogs and the
  /// notification shade, and would only produce slivers of segments.
  @visibleForTesting
  void handleLifecycle(AppLifecycleState state) {
    final next = _appStateOf(state);
    if (next == null || next == _appState) return;
    _appState = next;
    _transition('app_state', then: (r) => _rollSession(r, next));
    _debugChanges.notify();
  }

  static String? _appStateOf(AppLifecycleState? state) => switch (state) {
        AppLifecycleState.resumed => 'fg',
        AppLifecycleState.paused ||
        AppLifecycleState.hidden ||
        AppLifecycleState.detached =>
          'bg',
        AppLifecycleState.inactive || null => null,
      };

  Map<String, String> _baseDims() => {
        'flow': currentFlow,
        'app_state': _appState,
        ..._custom,
      };

  /// Dimensions only a reading can tell. `charging` is among them: a charging
  /// segment is reported like any other, flagged, so drain analysis filters it
  /// out and charging analysis (heat on a cradle, whether a vehicle charger
  /// keeps up) keeps it.
  static Map<String, String> _readingDims(BatteryReading r) => {
        'charging': r.plugged ? '1' : '0',
        if (r.screenOn != null) 'screen_on': r.screenOn! ? '1' : '0',
        if (r.powerSave != null) 'power_save': r.powerSave! ? '1' : '0',
        if (r.brightnessBand != null) 'brightness': r.brightnessBand!,
        if (r.network != null) 'network': r.network!,
      };

  /// Reporting just became active: a new segment, a new session, and every
  /// flow already open starts its run here.
  void _start() {
    final state = _appState;
    _transition('start', then: (r) {
      _rollSession(r, state);
      if (r == null) return;
      for (final f in _flows) {
        if (!f._acc.started) _beginRun(f._acc, r);
      }
    });
  }

  /// Closes the open segment and opens the next with the dimensions as they
  /// are now. They are captured here, not when the queued read completes, so
  /// a burst of changes yields one segment per state.
  ///
  /// [then] runs in the queue with the transition's reading — null when not
  /// active or the read failed — after the old segment closed and before the
  /// new one opens.
  void _transition(String reason, {void Function(BatteryReading? r)? then}) {
    if (!isActive) {
      if (then != null) _enqueue(() async => then(null));
      return;
    }
    final base = _baseDims();
    _enqueue(() async {
      final r = await _safeRead();
      if (r != null) {
        final seg = _segment;
        if (seg != null) {
          seg.add(r);
          _emit(seg, reason);
        }
      }
      then?.call(r);
      if (r != null) _open(r, base);
    });
  }

  /// A reading for a run that starts or ends without changing any dimension
  /// (e.g. a flow of the same name as the one it is nested in).
  void _atReading(void Function(BatteryReading? r) then) {
    if (!isActive) {
      _enqueue(() async => then(null));
      return;
    }
    _enqueue(() async => then(await _safeRead()));
  }

  Future<BatteryReading?> _safeRead() async {
    try {
      return await _read();
    } catch (e) {
      debugPrint('BatteryInsights: read failed: $e');
      return null;
    }
  }

  void _beginRun(BatteryRunAccumulator run, BatteryReading r) {
    run.begin(r);
    if (!_openRuns.contains(run)) _openRuns.add(run);
  }

  /// Ends [run] at its last reading, publishes it, and returns its report —
  /// null for a run that never started (reporting off, or no reading).
  BatteryRunReport? _endRun(BatteryRunAccumulator run) {
    _openRuns.remove(run);
    final report = run.report();
    run.reset();
    if (report != null) _publishRun(report);
    return report;
  }

  /// Ends the current session at [r] and starts one for [state].
  void _rollSession(BatteryReading? r, String state) {
    final old = _session;
    _session = null;
    if (old != null) _endRun(old);
    if (r == null || (state != 'fg' && state != 'bg')) return;
    final next =
        _session = BatteryRunAccumulator(BatteryRunKind.session, state);
    _beginRun(next, r);
  }

  void _publishRun(BatteryRunReport report) {
    _recentRuns.add(report);
    if (_recentRuns.length > _debugRunLimit) _recentRuns.removeAt(0);
    _reports.add(report);
    final send = report.kind == BatteryRunKind.flow
        ? _config.flowEvents
        : _config.sessionEvents;
    if (!isActive || !send || report.duration < _config.minSegment) return;
    try {
      _sink?.call(report.eventName, report.toParams());
    } catch (e) {
      debugPrint('BatteryInsights: sink failed: $e');
    }
  }

  Future<void> _sample() async {
    final r = await _read();
    if (r == null) return;
    final seg = _segment;
    if (seg == null) {
      _open(r, _baseDims());
      return;
    }
    seg.add(r);
    final reason =
        _splitReason(seg, r) ?? (seg.age >= _config.rollAfter ? 'roll' : null);
    if (reason == null) {
      _persist();
      return;
    }
    _emit(seg, reason);
    _open(r, _baseDims());
  }

  /// A change only a reading can reveal: plugging in, or the screen or power
  /// saver toggling while the app was not otherwise told.
  static String? _splitReason(BatterySegment seg, BatteryReading r) {
    final dims = _readingDims(r);
    for (final key in dims.keys) {
      if (seg.dims[key] != dims[key]) return key;
    }
    return null;
  }

  Future<BatteryReading?> _read() async {
    _lastReadAt = _clock();
    final r = await _probe.read();
    if (r != null) {
      _remember(r);
      for (final run in _openRuns) {
        run.add(r);
      }
      if (_capacity.add(r)) {
        _prefs?.setString(_prefCapacity, jsonEncode(_capacity.toJson()));
      }
      _reportDevice(r);
    }
    return r;
  }

  void _remember(BatteryReading r) {
    _latest = r;
    if (r.thermalHeadroom != null) _thermalHeadroomSeen = true;
  }

  /// Sends each device fact once per process and again only when it changes.
  /// Capacity is the [CapacityEstimator] median, never a single reading.
  void _reportDevice(BatteryReading r) {
    final sink = _deviceSink;
    if (sink == null) return;
    void send(String name, String? value) {
      if (value == null || _deviceSent[name] == value) return;
      _deviceSent[name] = value;
      try {
        sink(name, value);
      } catch (e) {
        debugPrint('BatteryInsights: device sink failed: $e');
      }
    }

    // The stable median, re-sent only when it moves 2 % — that is wear or a
    // battery swap, not noise.
    final capacity = _capacity.capacityMah;
    final lastSent = _capacitySent;
    if (capacity != null &&
        (lastSent == null || (capacity - lastSent).abs() / lastSent >= 0.02)) {
      _capacitySent = capacity;
      send(propCapacityMah, ((capacity / 50).round() * 50).toString());
    }
    final design = r.designCapacityMah;
    send(propDesignMah, design?.round().toString());
    send(propCycleCount, r.cycleCount?.toString());
    send(propHealth, r.health);
  }

  void _open(BatteryReading r, Map<String, String> base) {
    _segment = BatterySegment(dims: {...base, ..._readingDims(r)}, start: r);
    _persist();
  }

  void _persist() {
    final seg = _segment;
    if (seg == null) return;
    _prefs?.setString(_prefSegment, jsonEncode(seg.toJson()));
  }

  /// The segment a killed process left open, closed at its last reading. That
  /// understates its length slightly but never invents drain.
  void _recoverAfterProcessDeath() {
    final prefs = _prefs;
    final raw = prefs?.getString(_prefSegment);
    if (prefs == null || raw == null) return;
    prefs.remove(_prefSegment);
    try {
      final seg = BatterySegment.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
      _emit(seg, 'process_death');
    } catch (_) {}
  }

  /// Slivers are not reported: they carry no measurable drain. Every closed
  /// segment is kept for the debug view either way.
  void _emit(BatterySegment seg, String reason) {
    final outcome = !isActive
        ? BatteryRecordOutcome.inactive
        : seg.age < _config.minSegment
            ? BatteryRecordOutcome.tooShort
            : BatteryRecordOutcome.sent;
    final params = seg.report(
      reason,
      capacityMah: _capacity.capacityMah,
      loggedAt: _clock(),
    );
    _records.add(BatteryDebugRecord(
      closedAt: _clock(),
      reason: reason,
      params: params,
      outcome: outcome,
    ));
    if (_records.length > _debugRecordLimit) _records.removeAt(0);
    if (isActive && _usage.maxDays > 0) {
      _usage.add(seg, reason);
      _prefs?.setString(_prefUsage, jsonEncode(_usage.toJson()));
    }

    if (outcome != BatteryRecordOutcome.sent) {
      _droppedCount++;
      return;
    }
    _sentCount++;
    if (!_config.segmentEvents) return;
    try {
      _sink?.call(eventName, params);
    } catch (e) {
      debugPrint('BatteryInsights: sink failed: $e');
    }
  }

  void _enqueue(Future<void> Function() op) {
    _queue = _queue.then((_) async {
      try {
        await op();
      } catch (e) {
        debugPrint('BatteryInsights: $e');
      }
      _debugChanges.notify();
    });
  }
}

/// [ChangeNotifier] with its notify exposed to the engine. Costs nothing while
/// no debug view is listening.
///
/// Hosts set dimensions and flows from `initState`/`dispose`, i.e. mid-build
/// or mid-unmount, where rebuilding a listening debug view throws. Those
/// notifications are deferred to after the frame and coalesced.
class _DebugNotifier extends ChangeNotifier {
  bool _scheduled = false;

  void notify() {
    if (!hasListeners) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    binding.addPostFrameCallback((_) {
      _scheduled = false;
      notifyListeners();
    });
  }
}

/// One visit to a flow, from [BatteryInsights.startFlow] to [finish].
///
/// Also the identity token for [BatteryInsights.popFlow]: two open flows with
/// the same name are still left independently.
class BatteryFlowRun {
  BatteryFlowRun._(this._engine, this.name)
      : _acc = BatteryRunAccumulator(BatteryRunKind.flow, name);

  final BatteryInsights _engine;
  final String name;
  final BatteryRunAccumulator _acc;
  final Completer<BatteryRunReport?> _done = Completer();

  /// Completes with the run's report once the flow is left — null when
  /// reporting was off or the device gave no reading.
  Future<BatteryRunReport?> get report => _done.future;

  bool get isFinished => _done.isCompleted;

  /// Leaves the flow and returns its report (see [report]).
  Future<BatteryRunReport?> finish() {
    _engine.popFlow(this);
    return report;
  }

  void _complete(BatteryRunReport? report) {
    if (!_done.isCompleted) _done.complete(report);
  }

  @override
  String toString() => 'BatteryFlowRun($name)';
}
