import 'package:battery_insights/battery_insights.dart';
import 'package:battery_insights/src/debug/battery_debug_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Returns [headrooms] in turn, then null forever — the rate-limited OS call.
class _Probe implements BatteryProbe {
  _Probe(this.headrooms);
  final List<double?> headrooms;
  int _i = 0;

  @override
  Future<BatteryReading?> read() async {
    final h = _i < headrooms.length ? headrooms[_i] : null;
    _i++;
    return BatteryReading(
      at: DateTime(2026, 9, 20),
      levelPct: 80,
      plugged: false,
      thermalStatus: 0,
      thermalHeadroom: h,
      sdkInt: 33,
    );
  }
}

BatteryReading _reading({double? headroom}) => BatteryReading(
      at: DateTime(2026, 9, 20),
      levelPct: 80,
      plugged: false,
      thermalStatus: 0,
      thermalHeadroom: headroom,
      sdkInt: 33,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BatteryDebugFormat.thermalOf', () {
    test('no headroom ever seen reads as an unverified status', () {
      expect(BatteryDebugFormat.thermalOf(_reading()),
          contains('unverified: no thermal HAL'));
    });

    test('a reading without headroom after one with it is not HAL-less', () {
      expect(BatteryDebugFormat.thermalOf(_reading(), headroomSeen: true),
          isNot(contains('no thermal HAL')));
    });

    test('a reading with headroom is never HAL-less', () {
      expect(BatteryDebugFormat.thermalOf(_reading(headroom: 0.4)),
          isNot(contains('no thermal HAL')));
    });
  });

  test('the snapshot remembers headroom across readings that lack it',
      () async {
    SharedPreferences.setMockInitialValues({'battery_insights.bucket': 0});
    final insights = BatteryInsights.forTesting(
      probe: _Probe([0.35, null, null]),
      clock: () => DateTime(2026, 9, 20),
    );
    await insights.init(sink: (_, __) {}, observeLifecycle: false);
    expect(insights.debugSnapshot.thermalHeadroomSeen, isFalse);

    await insights.probeNow(); // 0.35
    expect(insights.debugSnapshot.thermalHeadroomSeen, isTrue);

    await insights.probeNow(); // null: rate-limited
    final snap = insights.debugSnapshot;
    expect(snap.latest?.thermalHeadroom, isNull);
    expect(snap.thermalHeadroomSeen, isTrue);
  });
}
