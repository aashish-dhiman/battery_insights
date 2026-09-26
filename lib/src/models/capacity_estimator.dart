import 'battery_reading.dart';

/// A stable full-charge capacity for this device, from many noisy readings.
///
/// Apps cannot read the fuel gauge's full-charge value, so it is estimated as
/// charge ÷ level. A single estimate jitters by several percent: both inputs
/// move in ~1 % steps at different moments, and the level is the OEM's display
/// percentage rather than the gauge's own. The median of estimates taken
/// under the least noisy conditions is steady — it moves as the battery wears,
/// not from one reading to the next.
class CapacityEstimator {
  CapacityEstimator([List<double>? samples, this._lastLevel])
      : _samples = [...?samples];

  /// Estimates kept, newest last. Enough for a steady median, few enough that
  /// wear shows within weeks.
  static const int maxSamples = 25;

  /// Fewer than this and there is no estimate yet.
  static const int minSamples = 3;

  /// Below this charge a 1 % level step moves the estimate by more than 2 %.
  static const double minLevelPct = 50;

  final List<double> _samples;
  int? _lastLevel;

  int get sampleCount => _samples.length;

  /// Median of the kept estimates, or null until [minSamples] are in.
  double? get capacityMah {
    if (_samples.length < minSamples) return null;
    final sorted = [..._samples]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Takes [r] if it is a clean sample. Returns whether it was kept.
  ///
  /// Kept only on battery (while charging, level and counter drift apart the
  /// most), at [minLevelPct] or above, and once per level step — a user
  /// sitting at 72 % for an hour would otherwise fill the window with one
  /// level's bias.
  bool add(BatteryReading r) {
    final estimate = r.estCapacityMah;
    if (r.plugged || r.levelPct < minLevelPct || estimate == null) return false;
    if (estimate < 500 || estimate > 20000) return false;
    final level = r.levelPct.round();
    if (level == _lastLevel) return false;
    _lastLevel = level;
    _samples.add(estimate);
    if (_samples.length > maxSamples) _samples.removeAt(0);
    return true;
  }

  Map<String, Object?> toJson() =>
      {'samples': _samples, 'lastLevel': _lastLevel};

  factory CapacityEstimator.fromJson(Map<String, dynamic> json) {
    final raw = json['samples'];
    return CapacityEstimator(
      raw is List
          ? [
              for (final v in raw)
                if (v is num && v.isFinite) v.toDouble()
            ]
          : null,
      json['lastLevel'] is int ? json['lastLevel'] as int : null,
    );
  }
}
