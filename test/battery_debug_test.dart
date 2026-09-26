import 'package:battery_insights/battery_insights.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Probe implements BatteryProbe {
  _Probe(this.clock);
  final DateTime Function() clock;
  double chargeMah = 4000;
  bool plugged = false;
  int reads = 0;

  @override
  Future<BatteryReading?> read() async {
    reads++;
    return BatteryReading(
      at: clock(),
      levelPct: 80,
      plugged: plugged,
      chargeMah: chargeMah,
      currentMa: 250,
      tempC: 31,
      thermalStatus: 1,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late _Probe probe;
  late BatteryInsights insights;
  late List<Map<String, Object>> sent;

  Future<void> start() async {
    SharedPreferences.setMockInitialValues({'battery_insights.bucket': 0});
    now = DateTime(2026, 9, 19, 10);
    probe = _Probe(() => now);
    sent = [];
    insights = BatteryInsights.forTesting(probe: probe, clock: () => now);
    await insights.init(
        sink: (name, p) {
          if (name == BatteryInsights.eventName) sent.add(p);
        },
        observeLifecycle: false);
    insights.configure(const BatteryInsightsConfig(enabled: true));
    await insights.settled;
  }

  test('every closed segment is recorded, sent or dropped', () async {
    await start();
    now = now.add(const Duration(seconds: 2));
    insights.setDimension('camera', 'scanner'); // too short
    await insights.settled;
    now = now.add(const Duration(minutes: 3));
    probe.chargeMah -= 20;
    insights.setDimension('camera', 'off'); // sent
    await insights.settled;

    final snap = insights.debugSnapshot;
    expect(snap.recent.map((r) => r.outcome), [
      BatteryRecordOutcome.sent,
      BatteryRecordOutcome.tooShort,
    ]);
    expect(snap.sentCount, 1);
    expect(snap.droppedCount, 1);
    expect(sent, hasLength(1));
    expect(snap.recent.first.params, sent.single);
  });

  test('probeNow updates the display and nothing else', () async {
    await start();
    final readsBefore = probe.reads;
    now = now.add(const Duration(minutes: 1));
    probe.chargeMah -= 5;
    await insights.probeNow();

    final snap = insights.debugSnapshot;
    expect(probe.reads, readsBefore + 1);
    expect(snap.latest!.at, now);
    expect(snap.openDrainMah, 5);
    expect(snap.openAvgMa, 300);
    expect(snap.openSegment!.samples, 1); // not added to the segment
    expect(sent, isEmpty);
  });

  test('the HUD switch persists', () async {
    await start();
    insights.setOverlayEnabled(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('battery_insights.debug_overlay'), isTrue);
  });

  testWidgets('debug view and HUD render without a platform', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: BatteryInsightsDebugView()),
    ));
    await tester.pump();
    expect(find.text('Show battery HUD'), findsOneWidget);
    expect(find.text('No reading yet.'), findsOneWidget);

    BatteryInsights.instance.setOverlayEnabled(true);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) =>
          BatteryInsightsOverlay(child: child ?? const SizedBox()),
      home: const Scaffold(body: Text('app')),
    ));
    await tester.pump();
    expect(find.text('app'), findsOneWidget);
    expect(find.text('no reading yet'), findsOneWidget);

    BatteryInsights.instance.setOverlayEnabled(false);
    await tester.pumpWidget(const SizedBox());
  });
}
