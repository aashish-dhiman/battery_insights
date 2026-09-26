import 'package:battery_insights/battery_insights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A 5000 mAh-design battery that now holds [fullMah].
class _Probe implements BatteryProbe {
  _Probe(this.clock);
  final DateTime Function() clock;

  double fullMah = 4100;
  double level = 90;
  double? design = 5000;
  int? cycles = 312;
  String? status = 'good';

  @override
  Future<BatteryReading?> read() async => BatteryReading(
        at: clock(),
        levelPct: level,
        plugged: false,
        chargeMah: fullMah * level / 100,
        designCapacityMah: design,
        cycleCount: cycles,
        health: status,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late _Probe probe;
  late BatteryInsights insights;

  Future<void> start({
    BatteryInsightsConfig config = const BatteryInsightsConfig(enabled: true),
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(
        {'battery_insights.bucket': 0, ...prefs});
    now = DateTime(2026, 9, 26, 9);
    probe = _Probe(() => now);
    insights = BatteryInsights.forTesting(probe: probe, clock: () => now);
    await insights.init(config: config, observeLifecycle: false);
    await insights.settled;
  }

  /// One reading per level step, the way the estimator wants them.
  Future<void> drainSteps(int n) async {
    for (var i = 0; i < n; i++) {
      probe.level -= 1;
      now = now.add(const Duration(minutes: 2));
      insights.setDimension('step', '${probe.level}');
      await insights.settled;
    }
  }

  test('empty before any reading', () {
    const h = BatteryHealth();
    expect(h.capacityMah, isNull);
    expect(h.healthPct, isNull);
    expect(h.isWorn(), isFalse);
  });

  test('capacity needs minSamples; then health % is capacity / design',
      () async {
    await start();
    // init's own reading is the first estimate.
    expect(insights.batteryHealth.samples, 1);
    expect(insights.batteryHealth.capacityMah, isNull);
    expect(insights.batteryHealth.designMah, 5000);
    expect(insights.batteryHealth.cycleCount, 312);
    expect(insights.batteryHealth.status, 'good');

    await drainSteps(BatteryHealth.minSamples - 1);
    final h = insights.batteryHealth;
    expect(h.samples, BatteryHealth.minSamples);
    expect(h.capacityMah, closeTo(4100, 0.01));
    expect(h.healthPct, closeTo(82, 0.01));
    expect(h.isWorn(), isFalse);
    expect(h.isWorn(threshold: 85), isTrue);
  });

  test('the estimate survives a restart', () async {
    await start();
    await drainSteps(4);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('battery_insights.capacity')!;
    await start(prefs: {'battery_insights.capacity': raw});
    expect(insights.batteryHealth.capacityMah, closeTo(4100, 0.01));
  });

  test('no design capacity means no health %, but capacity still known',
      () async {
    await start();
    probe.design = null;
    await drainSteps(3);
    final h = insights.batteryHealth;
    expect(h.capacityMah, isNotNull);
    expect(h.designMah, isNull);
    expect(h.healthPct, isNull);
  });

  test('probeNow fills the Android-reported fields while not reporting',
      () async {
    await start(config: const BatteryInsightsConfig());
    expect(insights.batteryHealth.status, isNull);
    await insights.probeNow();
    final h = insights.batteryHealth;
    expect(h.status, 'good');
    expect(h.cycleCount, 312);
    expect(h.designMah, 5000);
    // Estimates are only taken while reporting.
    expect(h.samples, 0);
  });
}
