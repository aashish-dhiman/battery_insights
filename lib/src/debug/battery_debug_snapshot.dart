import '../models/battery_insights_config.dart';
import '../models/battery_reading.dart';
import '../models/battery_run_report.dart';
import '../models/battery_usage.dart';

/// What became of a closed segment.
enum BatteryRecordOutcome {
  sent('sent'),
  tooShort('dropped · too short'),
  inactive('dropped · not reporting');

  const BatteryRecordOutcome(this.label);
  final String label;
}

/// One closed segment, kept in memory for the debug view whether or not it
/// was sent.
class BatteryDebugRecord {
  const BatteryDebugRecord({
    required this.closedAt,
    required this.reason,
    required this.params,
    required this.outcome,
  });

  final DateTime closedAt;
  final String reason;

  /// Exactly what was (or would have been) sent.
  final Map<String, Object> params;
  final BatteryRecordOutcome outcome;
}

/// The segment still accumulating.
class BatteryOpenSegment {
  const BatteryOpenSegment({
    required this.dims,
    required this.start,
    required this.last,
    required this.samples,
    this.maxTempC,
    this.thermalStatusMax,
    this.thermalHeadroomMax,
  });

  final Map<String, String> dims;
  final BatteryReading start;
  final BatteryReading last;
  final int samples;
  final double? maxTempC;
  final int? thermalStatusMax;
  final double? thermalHeadroomMax;
}

/// Everything the engine knows right now, for debug tooling. Built on demand
/// — nothing here is maintained unless someone reads it.
class BatteryDebugSnapshot {
  const BatteryDebugSnapshot({
    required this.config,
    required this.bucket,
    required this.isActive,
    required this.appState,
    required this.flows,
    required this.dimensions,
    required this.latest,
    this.thermalHeadroomSeen = false,
    this.capacityMah,
    this.capacitySamples = 0,
    required this.openSegment,
    required this.recent,
    required this.sentCount,
    required this.droppedCount,
    required this.deviceProperties,
    this.recentRuns = const [],
    this.usageToday,
  });

  final BatteryInsightsConfig config;

  /// This install's fixed sampling bucket, 0–99. Reports when below
  /// [BatteryInsightsConfig.samplePct].
  final int bucket;
  final bool isActive;
  final String appState;

  /// Open flows, outermost first.
  final List<String> flows;
  final Map<String, String> dimensions;

  /// Most recent reading of any kind, including debug refreshes.
  final BatteryReading? latest;

  /// Whether any reading this process carried a thermal headroom — proof the
  /// device has a thermal HAL even when [latest] happens to lack one.
  final bool thermalHeadroomSeen;

  /// Stable full-charge capacity (median), and how many estimates it rests on.
  final double? capacityMah;
  final int capacitySamples;
  final BatteryOpenSegment? openSegment;

  /// Closed segments, newest first.
  final List<BatteryDebugRecord> recent;
  final int sentCount;
  final int droppedCount;

  /// Device properties handed to the device sink this process.
  final Map<String, String> deviceProperties;

  /// Finished flow runs and sessions, newest first.
  final List<BatteryRunReport> recentRuns;

  /// Today's on-device usage totals.
  final BatteryDayUsage? usageToday;

  /// Charge used by the open segment up to [latest], or null without a
  /// charge counter.
  double? get openDrainMah {
    final seg = openSegment;
    final now = latest;
    if (seg == null || now == null) return null;
    final a = seg.start.chargeMah;
    final b = now.chargeMah;
    if (a == null || b == null || now.at.isBefore(seg.start.at)) return null;
    return a - b;
  }

  /// Average draw of the open segment so far, once it is long enough for the
  /// charge counter to have moved meaningfully.
  double? get openAvgMa {
    final drain = openDrainMah;
    final seg = openSegment;
    final now = latest;
    if (drain == null || seg == null || now == null) return null;
    final seconds = now.at.difference(seg.start.at).inSeconds;
    if (seconds < 10) return null;
    return drain / (seconds / 3600);
  }
}
