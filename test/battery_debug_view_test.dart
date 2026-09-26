import 'package:battery_insights/battery_insights.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FullProbe implements BatteryProbe {
  @override
  Future<BatteryReading?> read() async => BatteryReading(
        at: DateTime.now(),
        levelPct: 64,
        plugged: false,
        chargeMah: 3100,
        currentMa: 420,
        tempC: 33.5,
        voltageMv: 3900,
        powerSave: false,
        screenOn: true,
        thermalStatus: 1,
        thermalHeadroom: 0.42,
        cycleCount: 210,
        health: 'good',
        sdkInt: 34,
        designCapacityMah: 5000,
        brightnessPct: 40,
        brightnessAuto: false,
        network: 'wifi',
      );
}

void main() {
  testWidgets(
      'every section renders with a full reading, and labels explain '
      'themselves on tap', (tester) async {
    SharedPreferences.setMockInitialValues({'battery_insights.bucket': 0});
    final insights = BatteryInsights.instance;
    await insights.init(
        sink: (_, __) {}, probe: _FullProbe(), observeLifecycle: false);
    insights.configure(const BatteryInsightsConfig(enabled: true));
    await tester.runAsync(() => insights.settled);
    insights.setDimension('camera', 'scanner');
    await tester.runAsync(() => insights.probeNow());

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: BatteryInsightsDebugView(
          dimensionInfo: {
            'camera': BatteryMetricInfo('Camera', 'Which camera is running.'),
          },
        ),
      ),
    ));
    await tester.pump();

    for (final title in [
      'REPORTING',
      'WHAT THE APP IS DOING',
      'SEGMENT IN PROGRESS',
      'POWER',
      'HEAT',
      'SCREEN & SYSTEM',
      'BATTERY HEALTH',
      'RECENT SEGMENTS',
    ]) {
      await tester.scrollUntilVisible(find.text(title), 200);
      expect(find.text(title), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    // Health is worked out, not read: 3100 mAh at 64 % of a 5000 mAh battery
    // needs the median first, so only the rated capacity shows yet.
    expect(find.text('5000 mAh'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Battery temperature'), -200);
    await tester.tap(find.text('Battery temperature'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('The one heat signal every device reports'),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  test('the live map has an entry for every id the view reads', () {
    const ids = [
      'status',
      'enabled',
      'sample',
      'sample_bucket',
      'roll_after',
      'min_segment',
      'min_sample_gap',
      'session_counts',
      'level',
      'charging',
      'charge',
      'current',
      'voltage',
      'temp',
      'thermal_status',
      'thermal_headroom',
      'screen_on',
      'brightness',
      'network',
      'power_save',
      'android_api',
      'capacity_stable',
      'capacity_basis',
      'capacity_now',
      'capacity_design',
      'capacity_health',
      'health',
      'cycles',
      'flow',
      'app_state',
      'running_for',
      'drain_so_far',
      'avg_so_far',
      'samples',
      'max_temp',
      'max_thermal',
    ];
    for (final id in ids) {
      expect(BatteryMetrics.live[id], isNotNull, reason: id);
    }
  });

  test('every sent parameter is explained', () {
    const sent = [
      'flow',
      'app_state',
      'charging',
      'screen_on',
      'power_save',
      'brightness',
      'network',
      'duration_s',
      'level_start',
      'level_end',
      'drain_mah',
      'avg_ma',
      'current_ma_avg',
      'temp_start_c',
      'temp_max_c',
      'thermal_status_max',
      'thermal_headroom_max',
      'est_capacity_mah',
      'end_lag_s',
      'end_reason',
    ];
    for (final key in sent) {
      expect(BatteryMetrics.params[key], isNotNull, reason: key);
    }
  });
}
