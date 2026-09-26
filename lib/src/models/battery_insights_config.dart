/// Settings, typically driven by remote config. Off by default: nothing is
/// read or sent until the host turns it on.
class BatteryInsightsConfig {
  const BatteryInsightsConfig({
    this.enabled = false,
    this.samplePct = 100,
    this.rollAfter = const Duration(minutes: 15),
    this.minSegment = const Duration(seconds: 5),
    this.minSampleInterval = const Duration(seconds: 60),
    this.segmentEvents = true,
    this.flowEvents = true,
    this.sessionEvents = true,
    this.maxDimensions = 4,
  });

  final bool enabled;

  /// Share of installs (0–100) that report. Each install draws a fixed bucket
  /// once, so the same devices stay in the cohort across sessions.
  final int samplePct;

  /// A segment older than this is closed at the next sample, so a long idle
  /// stretch or session becomes several rows instead of one.
  final Duration rollAfter;

  /// Segments, flow runs and sessions shorter than this are not reported
  /// (e.g. a flow opened and left straight away) — they carry no measurable
  /// drain.
  final Duration minSegment;

  /// Minimum gap between reads triggered by [BatteryInsights.recordSample].
  /// State transitions always read.
  final Duration minSampleInterval;

  /// Send a `battery_segment` event for every closed segment — drain split by
  /// every dimension at once.
  final bool segmentEvents;

  /// Send a `battery_flow` event each time a flow is left — the whole visit's
  /// cost as one row.
  final bool flowEvents;

  /// Send a `battery_session` event for every foreground and background
  /// stretch — the app's battery use for every user, flows or not.
  final bool sessionEvents;

  /// Host dimensions allowed at once (see [BatteryInsights.setDimension]).
  /// The default keeps a `battery_segment` within Firebase Analytics' 25
  /// parameters; raise it if your analytics backend allows more.
  final int maxDimensions;

  Map<String, Object> toJson() => {
        'enabled': enabled,
        'samplePct': samplePct,
        'rollAfterS': rollAfter.inSeconds,
        'minSegmentS': minSegment.inSeconds,
        'minSampleIntervalS': minSampleInterval.inSeconds,
        'segmentEvents': segmentEvents,
        'flowEvents': flowEvents,
        'sessionEvents': sessionEvents,
        'maxDimensions': maxDimensions,
      };

  /// Parses a config written by [toJson] — or one from remote config, where
  /// any missing or mistyped key falls back to its default.
  factory BatteryInsightsConfig.fromJson(Map<String, dynamic> json) {
    const d = BatteryInsightsConfig();
    Duration secs(Object? v, Duration fallback) =>
        v is num ? Duration(seconds: v.toInt()) : fallback;
    bool flag(Object? v, bool fallback) => v is bool ? v : fallback;
    int count(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    return BatteryInsightsConfig(
      enabled: flag(json['enabled'], d.enabled),
      samplePct: count(json['samplePct'], d.samplePct),
      rollAfter: secs(json['rollAfterS'], d.rollAfter),
      minSegment: secs(json['minSegmentS'], d.minSegment),
      minSampleInterval: secs(json['minSampleIntervalS'], d.minSampleInterval),
      segmentEvents: flag(json['segmentEvents'], d.segmentEvents),
      flowEvents: flag(json['flowEvents'], d.flowEvents),
      sessionEvents: flag(json['sessionEvents'], d.sessionEvents),
      maxDimensions: count(json['maxDimensions'], d.maxDimensions),
    );
  }

  BatteryInsightsConfig copyWith({
    bool? enabled,
    int? samplePct,
    Duration? rollAfter,
    Duration? minSegment,
    Duration? minSampleInterval,
    bool? segmentEvents,
    bool? flowEvents,
    bool? sessionEvents,
    int? maxDimensions,
  }) =>
      BatteryInsightsConfig(
        enabled: enabled ?? this.enabled,
        samplePct: samplePct ?? this.samplePct,
        rollAfter: rollAfter ?? this.rollAfter,
        minSegment: minSegment ?? this.minSegment,
        minSampleInterval: minSampleInterval ?? this.minSampleInterval,
        segmentEvents: segmentEvents ?? this.segmentEvents,
        flowEvents: flowEvents ?? this.flowEvents,
        sessionEvents: sessionEvents ?? this.sessionEvents,
        maxDimensions: maxDimensions ?? this.maxDimensions,
      );
}
