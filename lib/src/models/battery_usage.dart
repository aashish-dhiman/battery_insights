import 'battery_segment.dart';

/// Time and charge spent in one state, summed over segments.
class BatteryUsageTotal {
  BatteryUsageTotal(
      {this.seconds = 0, this.drainMah = 0, this.measuredSeconds = 0});

  /// All time in this state, measured or not.
  int seconds;

  /// Charge used on battery, from the charge counter. Charging time is left
  /// out: it would net off against the drain.
  double drainMah;

  /// The part of [seconds] that [drainMah] covers — on battery, on a device
  /// with a charge counter.
  int measuredSeconds;

  Duration get duration => Duration(seconds: seconds);

  /// Average draw over the measured time, or null with nothing measured.
  double? get avgMa =>
      measuredSeconds <= 0 ? null : drainMah / (measuredSeconds / 3600);

  void _add(int s, double? drain) {
    seconds += s;
    if (drain != null) {
      drainMah += drain;
      measuredSeconds += s;
    }
  }

  Map<String, Object> toJson() =>
      {'s': seconds, 'mah': drainMah, 'ms': measuredSeconds};

  factory BatteryUsageTotal.fromJson(Object? json) {
    if (json is! Map) return BatteryUsageTotal();
    num n(Object? v) => v is num && v.isFinite ? v : 0;
    return BatteryUsageTotal(
      seconds: n(json['s']).toInt(),
      drainMah: n(json['mah']).toDouble(),
      measuredSeconds: n(json['ms']).toInt(),
    );
  }
}

/// One day of the app's battery use on this device — every segment, sent or
/// not, attributed to the local day it started on.
class BatteryDayUsage {
  BatteryDayUsage(this.day,
      {BatteryUsageTotal? foreground,
      BatteryUsageTotal? background,
      this.chargingSeconds = 0,
      Map<String, BatteryUsageTotal>? flows})
      : foreground = foreground ?? BatteryUsageTotal(),
        background = background ?? BatteryUsageTotal(),
        flows = flows ?? {};

  /// Local midnight of the day.
  final DateTime day;
  final BatteryUsageTotal foreground;
  final BatteryUsageTotal background;

  /// Time spent plugged in (any app state). Not part of the drain totals.
  int chargingSeconds;

  /// Per flow, including `none` — time in the app outside every flow.
  final Map<String, BatteryUsageTotal> flows;

  /// Foreground and background together.
  BatteryUsageTotal get total => BatteryUsageTotal(
        seconds: foreground.seconds + background.seconds,
        drainMah: foreground.drainMah + background.drainMah,
        measuredSeconds:
            foreground.measuredSeconds + background.measuredSeconds,
      );

  static String keyOf(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  Map<String, Object> toJson() => {
        'fg': foreground.toJson(),
        'bg': background.toJson(),
        'chg': chargingSeconds,
        'flows': {for (final e in flows.entries) e.key: e.value.toJson()},
      };

  factory BatteryDayUsage.fromJson(DateTime day, Object? json) {
    if (json is! Map) return BatteryDayUsage(day);
    final rawFlows = json['flows'];
    return BatteryDayUsage(
      day,
      foreground: BatteryUsageTotal.fromJson(json['fg']),
      background: BatteryUsageTotal.fromJson(json['bg']),
      chargingSeconds: json['chg'] is num ? (json['chg'] as num).toInt() : 0,
      flows: rawFlows is Map
          ? {
              for (final e in rawFlows.entries)
                if (e.key is String)
                  e.key as String: BatteryUsageTotal.fromJson(e.value)
            }
          : null,
    );
  }
}

/// Rolling on-device totals of the app's battery use, by day, app state and
/// flow — what lets an app show "used 142 mAh today" without a backend.
class BatteryUsageLedger {
  BatteryUsageLedger(
      [Map<String, BatteryDayUsage>? days, int maxDays = defaultDays])
      : _days = {...?days},
        _maxDays = maxDays {
    _trim();
  }

  /// Days kept unless configured otherwise
  /// ([BatteryInsightsConfig.usageDays]).
  static const int defaultDays = 14;

  /// The most [usageDays] can be set to.
  static const int maxAllowedDays = 366;

  int _maxDays;

  /// Days kept. Older ones are dropped as new ones start; lowering it drops
  /// the oldest days at once. 0 keeps nothing.
  int get maxDays => _maxDays;
  set maxDays(int value) {
    _maxDays = value.clamp(0, maxAllowedDays);
    _trim();
  }

  final Map<String, BatteryDayUsage> _days;

  /// Newest first.
  List<BatteryDayUsage> get days {
    final keys = _days.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) _days[k]!];
  }

  BatteryDayUsage? dayOf(DateTime t) => _days[BatteryDayUsage.keyOf(t)];

  /// Adds a closed segment. Charging segments, and the segment in which the
  /// plug state changed, count as time but not drain: their charge counter
  /// mixes use with what the charger put in.
  void add(BatterySegment seg, String endReason) {
    if (_maxDays <= 0) return;
    final start = seg.start.at;
    final key = BatteryDayUsage.keyOf(start);
    final day = _days[key] ??=
        BatteryDayUsage(DateTime(start.year, start.month, start.day));
    final seconds = seg.age.inSeconds;
    if (seconds <= 0) return;

    final charging = seg.dims['charging'] == '1';
    final a = seg.start.chargeMah;
    final b = seg.last.chargeMah;
    final drain = charging || endReason == 'charging' || a == null || b == null
        ? null
        : a - b;

    if (charging) day.chargingSeconds += seconds;
    final state = seg.dims['app_state'];
    if (state == 'fg') day.foreground._add(seconds, drain);
    if (state == 'bg') day.background._add(seconds, drain);
    final flow = seg.dims['flow'] ?? 'none';
    (day.flows[flow] ??= BatteryUsageTotal())._add(seconds, drain);

    _trim();
  }

  void _trim() {
    if (_days.length <= _maxDays) return;
    final keys = _days.keys.toList()..sort();
    for (final k in keys.take(_days.length - _maxDays)) {
      _days.remove(k);
    }
  }

  void clear() => _days.clear();

  Map<String, Object> toJson() =>
      {for (final e in _days.entries) e.key: e.value.toJson()};

  factory BatteryUsageLedger.fromJson(Map<String, dynamic> json,
      {int maxDays = defaultDays}) {
    final days = <String, BatteryDayUsage>{};
    for (final e in json.entries) {
      final day = DateTime.tryParse(e.key);
      if (day == null) continue;
      days[e.key] = BatteryDayUsage.fromJson(day, e.value);
    }
    return BatteryUsageLedger(days, maxDays);
  }
}
