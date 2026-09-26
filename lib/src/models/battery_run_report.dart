import 'battery_reading.dart';

/// What a [BatteryRunReport] measured.
enum BatteryRunKind {
  /// One visit to a flow, from entering it to leaving it — including time
  /// spent in nested flows, in the background, or with any dimension changing.
  flow,

  /// One uninterrupted stretch in the foreground or in the background. Sessions
  /// alternate, so together they cover the whole life of the app process.
  session,
}

/// Battery cost of one flow visit or one app session, measured from a reading
/// at its start to a reading at its end.
///
/// Unlike segments, a run is not split when a dimension changes: it answers
/// "what did this checkout cost?" or "what did the user's last foreground
/// session cost?" as one number.
class BatteryRunReport {
  const BatteryRunReport({
    required this.kind,
    required this.name,
    required this.start,
    required this.end,
    this.maxTempC,
    this.thermalStatusMax,
    this.currentMaAvg,
    this.charging = false,
    this.samples = 2,
  });

  final BatteryRunKind kind;

  /// The flow's name, or `fg` / `bg` for a session.
  final String name;
  final BatteryReading start;
  final BatteryReading end;

  /// Hottest battery temperature seen during the run, °C.
  final double? maxTempC;

  /// Worst OS thermal status seen during the run (Android 10+).
  final int? thermalStatusMax;

  /// Mean instantaneous current over the readings after [start].
  final double? currentMaAvg;

  /// Whether the device was plugged in at any reading of the run. Drain of a
  /// charging run is net of what the charger put in, so filter these out of
  /// drain analysis.
  final bool charging;

  /// Readings the run is built from, including [start] and [end].
  final int samples;

  Duration get duration => end.at.difference(start.at);

  /// Charge used, from the charge counter; null where the device has none.
  /// Negative while charging: net charge gained.
  double? get drainMah {
    final a = start.chargeMah;
    final b = end.chargeMah;
    return a == null || b == null ? null : a - b;
  }

  /// [drainMah] per hour — the rate to compare runs of different lengths.
  double? get avgMa {
    final drain = drainMah;
    final seconds = duration.inSeconds;
    return drain == null || seconds <= 0 ? null : drain / (seconds / 3600);
  }

  /// Battery percentage points used. Coarse, but every device reports it.
  double get levelDrop => start.levelPct - end.levelPct;

  /// The event name this run is reported under.
  String get eventName => switch (kind) {
        BatteryRunKind.flow => 'battery_flow',
        BatteryRunKind.session => 'battery_session',
      };

  /// Event parameters, in the same conventions as `battery_segment`: every
  /// value is a string or a finite number, and a value the device did not
  /// report is left out rather than sent as 0.
  Map<String, Object> toParams() {
    final params = <String, Object>{
      kind == BatteryRunKind.flow ? 'flow' : 'app_state': name,
      'charging': charging ? '1' : '0',
      'duration_s': duration.inSeconds,
      'level_start': start.levelPct.round(),
      'level_end': end.levelPct.round(),
      'samples': samples,
    };
    void put(String key, num? value, [int places = 1]) {
      if (value == null || !value.isFinite) return;
      params[key] = places == 0
          ? value.round()
          : double.parse(value.toStringAsFixed(places));
    }

    put('drain_mah', drainMah, 2);
    put('avg_ma', avgMa);
    put('current_ma_avg', currentMaAvg);
    put('temp_start_c', start.tempC);
    put('temp_max_c', maxTempC);
    put('thermal_status_max', thermalStatusMax, 0);
    return params;
  }

  @override
  String toString() => 'BatteryRunReport(${kind.name} $name, '
      '${duration.inSeconds}s, drain ${drainMah?.toStringAsFixed(1)} mAh)';
}

/// Accumulates the readings of one run. Internal to the engine.
class BatteryRunAccumulator {
  BatteryRunAccumulator(this.kind, this.name);

  final BatteryRunKind kind;
  final String name;

  BatteryReading? start;
  BatteryReading? last;
  double? maxTempC;
  int? thermalStatusMax;
  bool charging = false;
  double _currentSum = 0;
  int _currentCount = 0;
  int samples = 0;

  bool get started => start != null;

  void begin(BatteryReading r) {
    start = r;
    samples = 0;
    _currentSum = 0;
    _currentCount = 0;
    maxTempC = null;
    thermalStatusMax = null;
    charging = false;
    _take(r);
  }

  void add(BatteryReading r) {
    if (start == null) return;
    _take(r);
    final c = r.currentMa;
    if (c != null) {
      _currentSum += c;
      _currentCount++;
    }
  }

  void _take(BatteryReading r) {
    last = r;
    samples++;
    if (r.plugged) charging = true;
    final t = r.tempC;
    if (t != null && (maxTempC == null || t > maxTempC!)) maxTempC = t;
    final s = r.thermalStatus;
    if (s != null && (thermalStatusMax == null || s > thermalStatusMax!)) {
      thermalStatusMax = s;
    }
  }

  /// Forgets the start, e.g. when reporting is switched off mid-run.
  void reset() {
    start = null;
    last = null;
  }

  BatteryRunReport? report() {
    final s = start;
    final e = last;
    if (s == null || e == null) return null;
    return BatteryRunReport(
      kind: kind,
      name: name,
      start: s,
      end: e,
      maxTempC: maxTempC,
      thermalStatusMax: thermalStatusMax,
      currentMaAvg: _currentCount > 0 ? _currentSum / _currentCount : null,
      charging: charging,
      samples: samples,
    );
  }
}
