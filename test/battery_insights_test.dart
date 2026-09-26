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
  bool screenOn = true;
  double? tempC = 30;
  int? thermalStatus = probeReportsThermal ? (probeStartThermal ?? 0) : null;
  double? thermalHeadroom = probeReportsThermal ? 0.3 : null;
  int? cycleCount = 212;
  String? health = 'good';
  String? network = 'wifi';
  int reads = 0;

  @override
  Future<BatteryReading?> read() async {
    reads++;
    return BatteryReading(
      at: clock(),
      levelPct: level,
      plugged: plugged,
      chargeMah: chargeMah,
      currentMa: 300,
      tempC: tempC,
      powerSave: false,
      screenOn: screenOn,
      thermalStatus: thermalStatus,
      thermalHeadroom: thermalHeadroom,
      cycleCount: cycleCount,
      health: health,
      network: network,
      brightnessPct: 40,
    );
  }
}

int? probeStartThermal;
bool probeReportsThermal = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late _FakeProbe probe;
  late BatteryInsights insights;
  late List<Map<String, Object>> events;
  late List<Map<String, Object>> flowEvents;
  late List<Map<String, Object>> sessionEvents;
  late Map<String, List<String>> deviceProps;

  const enabled = BatteryInsightsConfig(enabled: true);

  Future<void> start({
    BatteryInsightsConfig config = enabled,
    Map<String, Object> prefs = const {},
    DateTime? at,
  }) async {
    SharedPreferences.setMockInitialValues(
        {'battery_insights.bucket': 0, ...prefs});
    now = at ?? DateTime(2026, 9, 19, 10);
    probe = _FakeProbe(() => now);
    events = [];
    flowEvents = [];
    sessionEvents = [];
    deviceProps = {};
    insights = BatteryInsights.forTesting(probe: probe, clock: () => now);
    await insights.init(
      sink: (name, params) => switch (name) {
        'battery_flow' => flowEvents.add(params),
        'battery_session' => sessionEvents.add(params),
        _ => events.add(params),
      },
      deviceSink: (name, value) => (deviceProps[name] ??= []).add(value),
      observeLifecycle: false,
    );
    insights.configure(config);
    await insights.settled;
  }

  void advance(Duration d, {double drainMah = 0}) {
    now = now.add(d);
    probe.chargeMah -= drainMah;
  }

  test('reports nothing and never reads while disabled', () async {
    await start(config: const BatteryInsightsConfig());
    insights.setDimension('camera', 'scanner');
    advance(const Duration(minutes: 5));
    insights.recordSample();
    await insights.settled;
    expect(events, isEmpty);
    expect(probe.reads, 0);
  });

  test('a transition closes the segment with its drain and state', () async {
    await start();
    advance(const Duration(minutes: 10), drainMah: 50);
    insights.setDimension('camera', 'scanner');
    await insights.settled;

    expect(events, hasLength(1));
    final e = events.single;
    expect(e['flow'], 'none');
    expect(e['camera'], isNull);
    expect(e['screen_on'], '1');
    expect(e['duration_s'], 600);
    expect(e['drain_mah'], 50);
    expect(e['avg_ma'], 300);
    expect(e['end_reason'], 'camera');
  });

  test('flows nest and hand attribution back to the outer flow', () async {
    await start();
    advance(const Duration(minutes: 1));
    final outer = insights.pushFlow('trip');
    await insights.settled;
    advance(const Duration(minutes: 1));
    final inner = insights.pushFlow('scan');
    await insights.settled;
    advance(const Duration(minutes: 1));
    insights.popFlow(inner);
    await insights.settled;

    expect(events.map((e) => e['flow']), ['none', 'trip', 'scan']);
    expect(insights.currentFlow, 'trip');
    insights.popFlow(outer);
    expect(insights.currentFlow, 'none');
  });

  test('segments shorter than minSegment are dropped', () async {
    await start();
    advance(const Duration(seconds: 2));
    insights.setDimension('camera', 'scanner');
    await insights.settled;
    expect(events, isEmpty);
  });

  test('unchanged values do not split a segment', () async {
    await start();
    advance(const Duration(minutes: 1));
    insights.setDimension('tracking', '1');
    advance(const Duration(minutes: 1));
    insights.setDimension('tracking', '1');
    await insights.settled;
    expect(events, hasLength(1));
  });

  test('samples are throttled and roll long segments', () async {
    await start();
    advance(const Duration(seconds: 30));
    insights.recordSample(); // inside minSampleInterval of the start read
    await insights.settled;
    expect(probe.reads, 1);

    for (var i = 0; i < 15; i++) {
      advance(const Duration(minutes: 1), drainMah: 5);
      insights.recordSample();
      await insights.settled;
    }
    expect(events, hasLength(1));
    expect(events.single['end_reason'], 'roll');
    expect(events.single.containsKey('samples'), isFalse);
    expect(events.single.containsKey('end_lag_s'), isFalse); // logged at once
  });

  test('charging splits the segment and is reported, flagged', () async {
    await start();
    advance(const Duration(minutes: 5), drainMah: 20);
    probe.plugged = true;
    insights.recordSample();
    await insights.settled;

    advance(const Duration(minutes: 5), drainMah: -60); // gains charge
    probe.plugged = false;
    insights.recordSample();
    await insights.settled;

    expect(events.map((e) => e['charging']), ['0', '1']);
    expect(events.map((e) => e['end_reason']), ['charging', 'charging']);
    expect(events.last['drain_mah'], -60); // net charge gained
  });

  test('thermal maxima include the reading the segment started on', () async {
    probeStartThermal = 3;
    await start();
    advance(const Duration(minutes: 1));
    insights.setDimension('camera', 'scanner');
    await insights.settled;
    expect(events.single['thermal_status_max'], 3);
    probeStartThermal = null;
  });

  test('a network change is noticed at the next sample', () async {
    await start();
    advance(const Duration(minutes: 2), drainMah: 10);
    probe.network = 'cell';
    insights.recordSample();
    await insights.settled;
    expect(events.single['end_reason'], 'network');
    expect(events.single['network'], 'wifi');
    expect(events.single['brightness'], 'mid');
  });

  test('screen turning off is noticed at the next sample', () async {
    await start();
    advance(const Duration(minutes: 2), drainMah: 10);
    probe.screenOn = false;
    insights.recordSample();
    await insights.settled;
    expect(events.single['end_reason'], 'screen_on');
    expect(events.single['screen_on'], '1');
  });

  test('app lifecycle maps to fg/bg and ignores inactive', () async {
    await start();
    insights.handleLifecycle(AppLifecycleState.resumed);
    await insights.settled;
    events.clear();
    advance(const Duration(minutes: 1));
    insights.handleLifecycle(AppLifecycleState.inactive);
    insights.handleLifecycle(AppLifecycleState.paused);
    await insights.settled;
    expect(events, hasLength(1));
    expect(events.single['app_state'], 'fg');
    expect(events.single['end_reason'], 'app_state');
  });

  test('a segment left by a dead process is reported on the next init',
      () async {
    await start();
    advance(const Duration(minutes: 3), drainMah: 15);
    insights.recordSample();
    await insights.settled;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('battery_insights.segment')!;

    // Relaunched at 10:06; the segment's last reading was at 10:03.
    await start(at: DateTime(2026, 9, 19, 10, 6), prefs: {
      'battery_insights.segment': saved,
      'battery_insights.config': '{"enabled":true}',
    });
    expect(events.first['end_reason'], 'process_death');
    expect(events.first['drain_mah'], 15);
    // Logged at relaunch, 3 minutes after its last reading.
    expect(events.first['end_lag_s'], 180);
  });

  test('installs outside the sample never read', () async {
    SharedPreferences.setMockInitialValues({'battery_insights.bucket': 60});
    probe = _FakeProbe(() => now);
    insights = BatteryInsights.forTesting(probe: probe, clock: () => now);
    await insights.init(sink: (_, __) {}, observeLifecycle: false);
    insights
        .configure(const BatteryInsightsConfig(enabled: true, samplePct: 50));
    insights.setDimension('camera', 'photo');
    await insights.settled;
    expect(probe.reads, 0);
  });

  test('reports the worst thermal state seen after the start', () async {
    await start();
    probe.thermalStatus = 2;
    probe.thermalHeadroom = 0.9;
    advance(const Duration(minutes: 1));
    insights.recordSample();
    await insights.settled;
    probe.thermalStatus = 1;
    probe.thermalHeadroom = 0.6;
    advance(const Duration(minutes: 1));
    insights.setDimension('camera', 'scanner');
    await insights.settled;

    final e = events.single;
    expect(e['thermal_status_max'], 2);
    expect(e['thermal_headroom_max'], 0.9);
    expect(e.containsKey('started_at_s'), isFalse);
  });

  test('values a device does not report are left out, not zeroed', () async {
    probeReportsThermal = false;
    await start();
    probeReportsThermal = true;
    probe.tempC = null;
    advance(const Duration(minutes: 1));
    insights.recordSample();
    advance(const Duration(minutes: 1));
    insights.setDimension('camera', 'scanner');
    await insights.settled;

    final e = events.single;
    expect(e.containsKey('thermal_status_max'), isFalse);
    expect(e.containsKey('thermal_headroom_max'), isFalse);
    expect(e['temp_start_c'], 30); // the start reading still had one
    expect(e['temp_max_c'], 30);
    expect(e.values.whereType<double>().every((v) => v.isFinite), isTrue);
  });

  group('device properties', () {
    test('capacity is a stable median, re-sent only on a real change',
        () async {
      await start(); // 80 % · 4000 mAh → 5000
      Future<void> readAt(double level, double charge) async {
        probe
          ..level = level
          ..chargeMah = charge;
        advance(const Duration(minutes: 2));
        insights.recordSample();
        await insights.settled;
      }

      expect(deviceProps[BatteryInsights.propCapacityMah], isNull); // 1 of 3
      await readAt(79, 4000); // 5063, jittery
      await readAt(78, 3880); // 4974
      // Median of 5000 / 5063 / 4974.
      expect(deviceProps[BatteryInsights.propCapacityMah], ['5000']);

      await readAt(77, 3900); // 5065 — noise, under 2 %
      await readAt(76, 3780); // 4974
      expect(deviceProps[BatteryInsights.propCapacityMah], ['5000']);

      expect(deviceProps[BatteryInsights.propCycleCount], ['212']);
      expect(deviceProps[BatteryInsights.propHealth], ['good']);
      probe.health = 'overheat';
      await readAt(75, 3750);
      expect(deviceProps[BatteryInsights.propHealth], ['good', 'overheat']);
    });

    test('capacity is not estimated below 50 %, missing facts are skipped',
        () async {
      SharedPreferences.setMockInitialValues({'battery_insights.bucket': 0});
      now = DateTime(2026, 9, 19, 10);
      probe = _FakeProbe(() => now)
        ..level = 30
        ..chargeMah = 1500
        ..cycleCount = null
        ..health = null;
      deviceProps = {};
      insights = BatteryInsights.forTesting(probe: probe, clock: () => now);
      await insights.init(
        sink: (_, __) {},
        deviceSink: (name, value) => (deviceProps[name] ??= []).add(value),
        observeLifecycle: false,
      );
      insights.configure(enabled);
      await insights.settled;
      expect(deviceProps, isEmpty);
    });
  });

  test('a segment persisted by an older build still recovers', () async {
    final at = DateTime(2026, 9, 19, 9).millisecondsSinceEpoch;
    const reading = '"levelPct":80,"plugged":false,"chargeMah":4000';
    final old = '{"dims":{"flow":"scan","app_state":"bg"},'
        '"start":{"at":$at,$reading},'
        '"last":{"at":${at + 600000},"levelPct":79,"plugged":false,"chargeMah":3950},'
        '"currentSumMa":0,"currentCount":0,"samples":2}';
    await start(prefs: {
      'battery_insights.segment': old,
      'battery_insights.config': '{"enabled":true}',
    });
    expect(events.first['end_reason'], 'process_death');
    expect(events.first['drain_mah'], 50);
    expect(events.first['flow'], 'scan');
  });

  group('BatteryReading.fromPlatform', () {
    final at = DateTime(2026);

    test('normalises µAh / µA', () {
      final r = BatteryReading.fromPlatform(
          {'level': 50.0, 'chargeCounter': 2000000, 'currentNow': -450000},
          at)!;
      expect(r.chargeMah, 2000);
      expect(r.currentMa, 450);
      expect(r.estCapacityMah, 4000);
    });

    test('keeps OEMs that already report mAh / mA', () {
      final r = BatteryReading.fromPlatform(
          {'level': 50.0, 'chargeCounter': 2000, 'currentNow': 450}, at)!;
      expect(r.chargeMah, 2000);
      expect(r.currentMa, 450);
    });

    test('no level means no reading', () {
      expect(BatteryReading.fromPlatform({'plugged': true}, at), isNull);
      expect(BatteryReading.fromPlatform({}, at), isNull);
    });

    test('unexpected types are treated as absent, never thrown on', () {
      final r = BatteryReading.fromPlatform({
        'level': 55,
        'plugged': 'yes',
        'chargeCounter': 'lots',
        'currentNow': double.nan,
        'temperature': null,
        'thermalStatus': -1,
        'thermalHeadroom': double.infinity,
        'cycleCount': '12',
        'health': 7,
        'screenOn': 1,
      }, at)!;
      expect(r.levelPct, 55);
      expect(r.plugged, isFalse);
      expect(r.chargeMah, isNull);
      expect(r.currentMa, isNull);
      expect(r.tempC, isNull);
      expect(r.thermalStatus, isNull);
      expect(r.thermalHeadroom, isNull);
      expect(r.cycleCount, isNull);
      expect(r.health, isNull);
      expect(r.screenOn, isNull);
      expect(r.estCapacityMah, isNull);
    });

    test('brightness bands on the backlight value; auto wins', () {
      String? band(Map<Object?, Object?> m) =>
          BatteryReading.fromPlatform({'level': 50.0, ...m}, at)!
              .brightnessBand;
      expect(band({'brightnessPct': 10.0}), 'low');
      expect(band({'brightnessPct': 40.0}), 'mid');
      expect(band({'brightnessPct': 90.0}), 'high');
      expect(band({'brightnessPct': 90.0, 'brightnessAuto': true}), 'auto');
      expect(band({}), isNull);
      expect(band({'brightnessPct': 'bright'}), isNull);
    });

    test('network accepts only known transports', () {
      expect(
          BatteryReading.fromPlatform({'level': 50.0, 'network': 'wifi'}, at)!
              .network,
          'wifi');
      expect(
          BatteryReading.fromPlatform({'level': 50.0, 'network': '5g'}, at)!
              .network,
          isNull);
    });

    test('reads the thermal and health fields', () {
      final r = BatteryReading.fromPlatform({
        'level': 90.0,
        'thermalStatus': 3,
        'thermalHeadroom': 0.95,
        'cycleCount': 480,
        'health': 'overheat',
        'designCapacityMah': 5050.0,
      }, at)!;
      expect(r.designCapacityMah, 5050);
      expect(r.thermalStatus, 3);
      expect(r.thermalHeadroom, 0.95);
      expect(r.cycleCount, 480);
      expect(r.health, 'overheat');
    });
  });
}
