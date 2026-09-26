import '../models/battery_reading.dart';

/// Display helpers shared by the debug view and the HUD.
abstract final class BatteryDebugFormat {
  /// Whether a host dimension's value is worth showing in a one-line summary:
  /// idle values such as `off`, `none` or `0` are left out.
  static bool isSet(String value) =>
      !const {'off', 'none', '0', 'false', ''}.contains(value);

  static const _thermalNames = [
    'none',
    'light',
    'moderate',
    'severe',
    'critical',
    'emergency',
    'shutdown',
  ];

  /// Why a value is missing: an Android too old to offer it, or a device
  /// that does not implement it.
  static String unavailable(BatteryReading r, {required int since}) {
    final sdk = r.sdkInt;
    if (sdk != null && sdk < since) return '— (needs API $since+)';
    return '— (not reported by device)';
  }

  /// On API 30+ a device with no thermal HAL reports no headroom and leaves
  /// the status at `none` forever, so `none` there is not a reading.
  ///
  /// [headroomSeen] is whether any reading this process had a headroom: one
  /// reading without it proves nothing (the OS rate-limits the call), so a
  /// device that has ever reported one is never called HAL-less.
  static String thermalOf(BatteryReading r, {bool headroomSeen = false}) {
    if (r.thermalStatus == null) return unavailable(r, since: 29);
    final name = thermal(r.thermalStatus);
    final sdk = r.sdkInt;
    if (r.thermalStatus == 0 &&
        r.thermalHeadroom == null &&
        !headroomSeen &&
        sdk != null &&
        sdk >= 30) {
      return '$name (unverified: no thermal HAL)';
    }
    return name;
  }

  static String thermal(int? status) {
    if (status == null) return '—';
    if (status < 0 || status >= _thermalNames.length) return '$status';
    return _thermalNames[status];
  }

  /// `1:05:09`, `4:32` or `12s`.
  static String duration(Duration d) {
    if (d.isNegative) return '0s';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${_two(m)}:${_two(s)}';
    if (m > 0) return '$m:${_two(s)}';
    return '${s}s';
  }

  static String ago(DateTime at, DateTime now) =>
      '${duration(now.difference(at))} ago';

  /// A number with [places] decimals and a unit, or `—` when absent.
  static String number(num? value, String unit, {int places = 0}) {
    if (value == null || !value.isFinite) return '—';
    return '${value.toStringAsFixed(places)}$unit';
  }

  static String flag(bool? value) =>
      value == null ? '—' : (value ? 'yes' : 'no');

  static String clock(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
