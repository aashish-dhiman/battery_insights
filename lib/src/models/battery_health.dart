import 'capacity_estimator.dart';

/// The phone's battery condition, as far as an app can know it.
///
/// [capacityMah] is worked out by the package from this phone's own readings
/// (see [BatteryInsights.batteryHealth]); the rest is what Android reports.
/// Every field is null until known.
class BatteryHealth {
  const BatteryHealth({
    this.capacityMah,
    this.designMah,
    this.cycleCount,
    this.status,
    this.samples = 0,
  });

  /// Full-charge capacity today: the median of up to 25 estimates of
  /// charge ÷ level, taken on battery at 50 % or more, one per level step.
  /// Null until [minSamples] are in, or on a phone with no charge counter.
  final double? capacityMah;

  /// Factory-rated capacity from the OEM power profile. Null on phones that
  /// do not expose it.
  final double? designMah;

  /// Charge cycles, as Android reports them (Android 14+).
  final int? cycleCount;

  /// Android's own verdict: `good`, `overheat`, `dead`, `over_voltage`,
  /// `failure` or `cold`.
  final String? status;

  /// Capacity estimates [capacityMah] rests on so far.
  final int samples;

  /// Estimates needed before [capacityMah] is given.
  static const int minSamples = CapacityEstimator.minSamples;

  /// [capacityMah] as a share of [designMah], in percent — how much of its
  /// original charge the battery still holds. Null unless both are known.
  ///
  /// A few percent over 100 is normal on new batteries and on OEMs that
  /// rescale the displayed battery %. Under ~80 is a worn battery.
  double? get healthPct {
    final c = capacityMah;
    final d = designMah;
    return c == null || d == null || d <= 0 ? null : c / d * 100;
  }

  /// Whether [healthPct] is known and under [threshold].
  bool isWorn({double threshold = 80}) {
    final pct = healthPct;
    return pct != null && pct < threshold;
  }

  @override
  String toString() => 'BatteryHealth(capacity: ${capacityMah?.round()} mAh, '
      'design: ${designMah?.round()} mAh, '
      'health: ${healthPct?.toStringAsFixed(1)} %, cycles: $cycleCount, '
      'status: $status, samples: $samples)';
}
