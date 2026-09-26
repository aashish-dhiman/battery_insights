import 'package:battery_insights/battery_insights.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProbe implements BatteryProbe {
  _FakeProbe(this.clock);
  final DateTime Function() clock;

  double chargeMah = 4000;
  double level = 80;
  bool plugged = false;
  double tempC = 30;
  bool fail = false;

  @override
  Future<BatteryReading?> read() async {
    if (fail) return null;
    return BatteryReading(
      at: clock(),
      levelPct: level,
      plugged: plugged,
      chargeMah: chargeMah,
      currentMa: 300,
      tempC: tempC,
      screenOn: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late _FakeProbe probe;
  late BatteryInsights insights;
  late Map<String, List<Map<String, Object>>> sent;

  const enabled = BatteryInsightsConfig(enabled: true);

  Future<void> start({
    BatteryInsightsConfig? config = enabled,
    Map<String, Object> prefs = const {},
    DateTime? at,
  }) async {
    SharedPreferences.setMockInitialValues(
        {'battery_insights.bucket': 0, ...prefs});
    now = at ?? DateTime(2026, 9, 19, 10);
    probe = _FakeProbe(() => now);
    sent = {};
    insights = BatteryInsights.forTesting(probe: probe, clock: () => now);
    await insights.init(
      sink: (name, params) => (sent[name] ??= []).add(params),
      config: config,
      observeLifecycle: false,
    );
    await insights.settled;
  }

  List<Map<String, Object>> of(String name) => sent[name] ?? const [];

  Future<void> advance(Duration d, {double drainMah = 0}) async {
    await insights.settled;
    now = now.add(d);
    probe.chargeMah -= drainMah;
  }

  group('flow runs', () {
    test('finish() returns the whole visit, across nested flows and dims',
        () async {
      await start();
      await advance(const Duration(minutes: 1), drainMah: 5);
      final checkout = insights.startFlow('checkout');
      await advance(const Duration(minutes: 2), drainMah: 10);
      probe.tempC = 38;
      insights.setDimension('camera', 'on');
      final pay = insights.startFlow('payment');
      await advance(const Duration(minutes: 1), drainMah: 8);
      final payReport = await pay.finish();
      await advance(const Duration(minutes: 1), drainMah: 2);
      final report = await checkout.finish();

      expect(report, isNotNull);
      expect(report!.kind, BatteryRunKind.flow);
      expect(report.name, 'checkout');
      expect(report.duration, const Duration(minutes: 4));
      expect(report.drainMah, 20);
      expect(report.avgMa, 300);
      expect(report.maxTempC, 38);
      expect(report.charging, isFalse);

      expect(payReport!.drainMah, 8);
      expect(payReport.duration, const Duration(minutes: 1));

      final flows = of('battery_flow');
      expect(flows.map((e) => e['flow']), ['payment', 'checkout']);
      expect(flows.last['drain_mah'], 20);
      expect(flows.last['duration_s'], 240);
      expect(flows.last['charging'], '0');
      // The segments still split the same time by every dimension.
      expect(of('battery_segment').map((e) => e['flow']),
          containsAllInOrder(['none', 'checkout', 'payment', 'checkout']));
    });

    test('a same-named nested flow still measures its own visit', () async {
      await start();
      final a = insights.startFlow('scan');
      await advance(const Duration(minutes: 1), drainMah: 3);
      final b = insights.startFlow('scan');
      await advance(const Duration(minutes: 1), drainMah: 4);
      expect((await b.finish())!.drainMah, 4);
      await advance(const Duration(minutes: 1), drainMah: 1);
      expect((await a.finish())!.drainMah, 8);
    });

    test('finish() twice is harmless and returns the same report', () async {
      await start();
      final run = insights.startFlow('x');
      await advance(const Duration(minutes: 1), drainMah: 1);
      final first = await run.finish();
      final second = await run.finish();
      expect(identical(first, second), isTrue);
      expect(run.isFinished, isTrue);
    });

    test('completes with null while reporting is off', () async {
      await start(config: const BatteryInsightsConfig());
      final run = insights.startFlow('x');
      await advance(const Duration(minutes: 1));
      expect(await run.finish(), isNull);
      expect(sent, isEmpty);
    });

    test('completes with null when the device gives no reading', () async {
      await start();
      probe.fail = true;
      final run = insights.startFlow('x');
      await advance(const Duration(minutes: 1));
      expect(await run.finish(), isNull);
    });

    test('a flow opened before reporting started is measured from the start',
        () async {
      await start(config: const BatteryInsightsConfig());
      final run = insights.startFlow('onboarding');
      await advance(const Duration(minutes: 1), drainMah: 9);
      insights.configure(enabled);
      await advance(const Duration(minutes: 2), drainMah: 6);
      final report = await run.finish();
      expect(report!.duration, const Duration(minutes: 2));
      expect(report.drainMah, 6);
    });

    test('short visits are returned but not sent', () async {
      await start();
      final run = insights.startFlow('peek');
      await advance(const Duration(seconds: 2));
      expect(await run.finish(), isNotNull);
      expect(of('battery_flow'), isEmpty);
    });

    test('flowEvents: false keeps runs local', () async {
      await start(config: enabled.copyWith(flowEvents: false));
      final run = insights.startFlow('x');
      await advance(const Duration(minutes: 1), drainMah: 1);
      expect(await run.finish(), isNotNull);
      expect(of('battery_flow'), isEmpty);
    });

    test('reports stream carries every run', () async {
      await start();
      final got = <BatteryRunReport>[];
      final sub = insights.reports.listen(got.add);
      final run = insights.startFlow('x');
      await advance(const Duration(minutes: 1), drainMah: 1);
      await run.finish();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(got.map((r) => r.name), ['x']);
    });
  });

  group('sessions', () {
    test('foreground and background alternate, each reported once', () async {
      await start();
      insights.handleLifecycle(AppLifecycleState.resumed);
      await advance(const Duration(minutes: 10), drainMah: 40);
      insights.handleLifecycle(AppLifecycleState.paused);
      await advance(const Duration(minutes: 30), drainMah: 5);
      insights.recordSample();
      await advance(const Duration(minutes: 30), drainMah: 5);
      insights.handleLifecycle(AppLifecycleState.resumed);
      await insights.settled;

      final sessions = of('battery_session');
      expect(sessions.map((e) => e['app_state']), ['fg', 'bg']);
      expect(sessions[0]['duration_s'], 600);
      expect(sessions[0]['drain_mah'], 40);
      expect(sessions[0]['avg_ma'], 240);
      expect(sessions[1]['duration_s'], 3600);
      expect(sessions[1]['drain_mah'], 10);
      expect(sessions[1]['samples'], 3);
    });

    test('sessionEvents: false keeps them off the sink', () async {
      await start(config: enabled.copyWith(sessionEvents: false));
      insights.handleLifecycle(AppLifecycleState.resumed);
      await advance(const Duration(minutes: 10));
      insights.handleLifecycle(AppLifecycleState.paused);
      await insights.settled;
      expect(of('battery_session'), isEmpty);
      expect(insights.debugSnapshot.recentRuns, hasLength(1));
    });

    test('segmentEvents: false still keeps the ledger', () async {
      await start(config: enabled.copyWith(segmentEvents: false));
      insights.handleLifecycle(AppLifecycleState.resumed);
      await advance(const Duration(minutes: 10), drainMah: 30);
      insights.handleLifecycle(AppLifecycleState.paused);
      await insights.settled;
      expect(of('battery_segment'), isEmpty);
      expect(insights.usageToday!.foreground.drainMah, 30);
    });
  });

  group('usage ledger', () {
    test('totals by app state and flow, charging kept out of drain', () async {
      await start();
      insights.handleLifecycle(AppLifecycleState.resumed);
      await insights.settled;
      await advance(const Duration(minutes: 10), drainMah: 30);
      final run = insights.startFlow('camera');
      await advance(const Duration(minutes: 5), drainMah: 25);
      await run.finish();
      await advance(const Duration(minutes: 2), drainMah: 2);
      insights.handleLifecycle(AppLifecycleState.paused);
      await advance(const Duration(minutes: 60), drainMah: 6);
      probe.plugged = true;
      insights.recordSample(); // closes bg segment: charging changed
      await advance(const Duration(minutes: 30));
      probe.chargeMah += 500;
      insights.handleLifecycle(AppLifecycleState.resumed);
      await insights.settled;

      final day = insights.usageToday!;
      expect(day.day, DateTime(2026, 9, 19));
      expect(day.foreground.seconds, 17 * 60);
      expect(day.foreground.drainMah, 57);
      expect(day.foreground.avgMa, closeTo(57 / (17 / 60), 0.01));
      expect(day.flows['camera']!.drainMah, 25);
      expect(day.flows['none']!.drainMah, 32);
      // The bg segment in which the plug went in counts as time, not drain.
      expect(day.background.seconds, 90 * 60);
      expect(day.background.drainMah, 0);
      expect(day.chargingSeconds, 30 * 60);
      expect(day.total.seconds, 107 * 60);
    });

    test('persists across restarts and keeps at most 14 days', () async {
      await start();
      for (var i = 0; i < 16; i++) {
        await advance(const Duration(days: 1), drainMah: 1);
        insights.setDimension('d', '$i');
        await insights.settled;
      }
      expect(insights.usage, hasLength(BatteryUsageLedger.defaultDays));
      expect(insights.usage.first.day.isAfter(insights.usage.last.day), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('battery_insights.usage')!;
      await start(prefs: {'battery_insights.usage': raw}, at: now);
      expect(insights.usage, hasLength(BatteryUsageLedger.defaultDays));

      insights.clearUsage();
      expect(insights.usage, isEmpty);
    });

    var closed = 0;
    // Each call closes one segment per day: the dimension always changes.
    Future<void> closeDays(int n) async {
      for (var i = 0; i < n; i++) {
        await advance(const Duration(days: 1), drainMah: 1);
        insights.setDimension('d', '${closed++}');
        await insights.settled;
      }
    }

    test('usageDays sets how many days are kept', () async {
      await start(config: enabled.copyWith(usageDays: 3));
      await closeDays(6);
      expect(insights.usage, hasLength(3));

      // Raising it keeps what is there and lets the ledger grow.
      insights.configure(enabled.copyWith(usageDays: 30));
      await closeDays(5);
      expect(insights.usage, hasLength(8));
    });

    test('lowering usageDays drops the oldest days at once, and persists',
        () async {
      await start();
      await closeDays(10);
      final newest = insights.usage.first.day;
      insights.configure(enabled.copyWith(usageDays: 2));
      expect(insights.usage, hasLength(2));
      expect(insights.usage.first.day, newest);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('battery_insights.usage')!;
      final config = prefs.getString('battery_insights.config')!;
      // A restart with no config passed follows the persisted one.
      await start(
        config: null,
        prefs: {
          'battery_insights.usage': raw,
          'battery_insights.config': config,
        },
        at: now,
      );
      expect(insights.config.usageDays, 2);
      expect(insights.usage, hasLength(2));
    });

    test('usageDays: 0 turns the ledger off and deletes stored totals',
        () async {
      await start();
      await closeDays(3);
      expect(insights.usage, isNotEmpty);

      insights.configure(enabled.copyWith(usageDays: 0));
      expect(insights.usage, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('battery_insights.usage'), isNull);

      // Nothing is recorded while off, but events still flow.
      sent.clear();
      await closeDays(2);
      expect(insights.usage, isEmpty);
      expect(insights.usageToday, isNull);
      expect(of('battery_segment'), isNotEmpty);
    });

    test('usageDays is clamped to 0..366', () async {
      await start(config: enabled.copyWith(usageDays: -5));
      await closeDays(1);
      expect(insights.usage, isEmpty);
      insights.configure(enabled.copyWith(usageDays: 5000));
      await closeDays(1);
      expect(insights.usage, hasLength(1));
    });
  });

  test('config round-trips, and a remote map with junk falls back', () {
    const c = BatteryInsightsConfig(
      enabled: true,
      samplePct: 20,
      flowEvents: false,
      maxDimensions: 8,
      usageDays: 30,
    );
    final back = BatteryInsightsConfig.fromJson(c.toJson());
    expect(back.toJson(), c.toJson());
    final junk = BatteryInsightsConfig.fromJson({
      'enabled': 'yes',
      'maxDimensions': 'x',
      'sessionEvents': false,
      'usageDays': '7'
    });
    expect(junk.enabled, isFalse);
    expect(junk.maxDimensions, 4);
    expect(junk.sessionEvents, isFalse);
    expect(junk.usageDays, 14);
  });

  test('maxDimensions comes from config', () async {
    await start(config: enabled.copyWith(maxDimensions: 1));
    insights.setDimension('a', '1');
    insights.setDimension('b', '1');
    expect(insights.debugSnapshot.dimensions.keys, ['a']);
  });
}
