# battery_insights

[![pub package](https://img.shields.io/pub/v/battery_insights.svg)](https://pub.dev/packages/battery_insights)
[![CI](https://github.com/aashish-dhiman/battery_insights/actions/workflows/ci.yml/badge.svg)](https://github.com/aashish-dhiman/battery_insights/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Find out what your Flutter app really costs in battery, on your users' real phones.**

`battery_insights` measures battery drain in mAh from the phone's fuel gauge and attributes it to what the app was doing. It covers two jobs:

| | What you get | How |
|---|---|---|
| **1. Flow-wise tracking** | "Checkout costs 4.2 mAh per visit; the video call 310 mA" | `startFlow()` / `finish()`, `BatteryFlowScope`, or `BatteryFlowRouteObserver` → one `battery_flow` event per visit |
| **2. Every-user tracking** | "Our app drains 3 %/h in the foreground and 0.4 %/h in the background, per model, per release" | Automatic: `battery_session` events for every foreground/background stretch, `battery_segment` events split by flow, charging, screen, network…, and on-device daily totals |

It adds **no drain of its own**: no timers, no wake locks, no battery listeners. It reads only when your app is already awake.

📖 **Full integration guide: https://aashish-dhiman.github.io/battery_insights/**

---

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [1. Flow-wise tracking](#1-flow-wise-tracking)
- [2. Every-user tracking](#2-every-user-tracking)
- [Sending events to analytics](#sending-events-to-analytics)
- [Configuration & remote rollout](#configuration--remote-rollout)
- [Event reference](#event-reference)
- [Debug tools](#debug-tools)
- [How it stays at zero drain](#how-it-stays-at-zero-drain)
- [Accuracy & limitations](#accuracy--limitations)
- [Platform support](#platform-support)

## Install

```bash
flutter pub add battery_insights
```

No permissions to request. The plugin declares only `ACCESS_NETWORK_STATE` (a normal, install-time permission) to tag segments with `wifi`/`cell`.

## Quick start

```dart
import 'package:battery_insights/battery_insights.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await BatteryInsights.instance.init(
    sink: (name, params) => analytics.logEvent(name: name, parameters: params),
    config: const BatteryInsightsConfig(enabled: true),
  );

  runApp(const MyApp());
}
```

That alone gives you **every-user tracking**: foreground/background sessions and segments, reported for every user. Add flows next.

## 1. Flow-wise tracking

A *flow* is anything whose battery cost you want to know: a screen, a feature, a background job. Pick whichever of the three styles fits — they can be mixed.

### a) In code — get the cost back

```dart
final run = BatteryInsights.instance.startFlow('video_call');
await callController.runUntilHangUp();
final report = await run.finish();

print('${report?.drainMah} mAh over ${report?.duration}, '
      '${report?.avgMa} mA average, max ${report?.maxTempC} °C');
```

`finish()` returns a `BatteryRunReport` (or `null` while reporting is off, or when the device gave no reading), and a `battery_flow` event goes to your sink.

### b) By route — one mapping for the whole app

```dart
MaterialApp(
  navigatorObservers: [
    BatteryFlowRouteObserver(
      flowForRoute: (route) => switch (route.settings.name) {
        '/checkout' => 'checkout',
        '/scan' => 'scan',
        _ => null, // not a flow: attribution stays with what is underneath
      },
    ),
  ],
);
```

### c) By widget — for tabs, sheets, drawers, anything that is not a route

```dart
BatteryFlowScope(
  flow: 'map_tab',
  child: MapTab(),
);
```

**Flows nest.** Opening `payment` inside `checkout` attributes segments to `payment` until it closes, then back to `checkout`. The `checkout` run still covers the whole visit, `payment` included.

**Add your own dimensions** for state that changes inside a flow — camera on/off, a download running, GPS tracking:

```dart
BatteryInsights.instance.setDimension('camera', 'preview'); // where it starts
BatteryInsights.instance.setDimension('camera', 'off');     // where it stops
```

Every change closes the current segment, so drain is split by camera state *within* each flow — the difference between "the scan flow is expensive" and "the camera is". Up to `maxDimensions` (default 4) at once.

## 2. Every-user tracking

Once enabled, the whole life of the app is measured with no further code:

- **Sessions** — every foreground stretch and every background stretch becomes a `battery_session` event: how long, how many mAh, the average mA, how hot. This is your "how much battery does our app use" number, for every user.
- **Segments** — time is split wherever any state changes (flow, foreground/background, charging, screen on/off, power saver, brightness band, network, your dimensions) and each piece becomes a `battery_segment` event. Aggregate them to answer "what does the screen cost?", "does background location hurt?", "did release 4.2 regress?".
- **On-device totals** — the last 14 days, by app state and by flow, readable in the app:

```dart
final today = BatteryInsights.instance.usageToday;
if (today != null) {
  print('Today: ${today.total.drainMah.toStringAsFixed(0)} mAh '
        '(foreground ${today.foreground.drainMah.toStringAsFixed(0)}, '
        'background ${today.background.drainMah.toStringAsFixed(0)})');
  for (final e in today.flows.entries) {
    print('  ${e.key}: ${e.value.drainMah.toStringAsFixed(1)} mAh');
  }
}
```

Useful for an in-app "battery usage" screen, a support page, or your own backend — no analytics needed. Listen to `BatteryInsights.instance.debugChanges` to rebuild when totals change, or to `BatteryInsights.instance.reports` for each finished flow run and session.

**Keep long stretches sampled.** Transitions always read the battery. To also catch plugging in, screen toggles and long idle stretches, call `recordSample()` from callbacks your app already runs — location updates, a heartbeat, a sync. It is throttled to one read per `minSampleInterval` (60 s), so calling it often is fine:

```dart
locationStream.listen((pos) {
  BatteryInsights.instance.recordSample();
  // ...
});
```

## Sending events to analytics

The sink receives `(eventName, params)`. Params are flat `String`/`num` maps built to fit Firebase Analytics' limits (≤ 25 params, ≤ 40-char names), so they drop into any SDK.

**Firebase Analytics**

```dart
await BatteryInsights.instance.init(
  sink: (name, params) =>
      FirebaseAnalytics.instance.logEvent(name: name, parameters: params),
  // Rarely-changing device facts (capacity, cycles, health) as user properties:
  deviceSink: (name, value) =>
      FirebaseAnalytics.instance.setUserProperty(name: name, value: value),
);
```

With the BigQuery export on, see the **[BigQuery analysis guide](doc/bigquery.md)** for a curated table, correct time-weighted metrics and ready-made dashboard queries.

**Anything else** (Mixpanel, Amplitude, PostHog, your own API):

```dart
sink: (name, params) => mixpanel.track(name, properties: params),
```

No sink at all? Leave it out and use `usage`, `reports` and `finish()` locally.

## Configuration & remote rollout

Reporting is **off by default**. Pass a config to `init`, or call `configure` whenever your remote config arrives — it is persisted, so a cold start follows the last known switch.

```dart
BatteryInsights.instance.configure(BatteryInsightsConfig.fromJson(
  jsonDecode(remoteConfig.getString('battery_insights')),
));
```

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Master switch |
| `samplePct` | `100` | Share of installs that report (0–100). Each install draws a fixed bucket once, so the cohort is stable |
| `rollAfter` | 15 min | A segment older than this is closed at the next sample |
| `minSegment` | 5 s | Shorter segments, runs and sessions are not sent |
| `minSampleInterval` | 60 s | Throttle for `recordSample()` |
| `segmentEvents` | `true` | Send `battery_segment` |
| `flowEvents` | `true` | Send `battery_flow` |
| `sessionEvents` | `true` | Send `battery_session` |
| `maxDimensions` | `4` | Host dimensions allowed at once (4 keeps segments within Firebase's 25 params) |

JSON keys: `enabled`, `samplePct`, `rollAfterS`, `minSegmentS`, `minSampleIntervalS`, `segmentEvents`, `flowEvents`, `sessionEvents`, `maxDimensions`. Missing or mistyped keys fall back to defaults.

Every method is safe to call before `init`, while disabled, and repeatedly. None throws.

## Event reference

A value the device does not report is **left out**, never sent as 0 — a missing param means "unknown".

### `battery_flow` — one per flow visit

| Param | Type | Meaning |
|---|---|---|
| `flow` | string | Flow name |
| `duration_s` | int | Visit length |
| `drain_mah` | double | Charge used (negative if net charged) |
| `avg_ma` | double | `drain_mah` per hour — compare visits of different lengths |
| `current_ma_avg` | double | Mean instantaneous current |
| `level_start`, `level_end` | int | Battery % |
| `temp_start_c`, `temp_max_c` | double | Battery temperature, °C |
| `thermal_status_max` | int | Worst OS thermal status (Android 10+): 0 none … 6 shutdown |
| `charging` | `'1'`/`'0'` | Plugged in at any reading of the visit — exclude from drain analysis |
| `samples` | int | Readings the visit is built from |

### `battery_session` — one per foreground or background stretch

Same params as `battery_flow`, with `app_state` (`fg`/`bg`) in place of `flow`.

### `battery_segment` — one per stretch of constant state

| Param | Type | Meaning |
|---|---|---|
| `flow` | string | Innermost open flow; `none` outside every flow |
| `app_state` | string | `fg` / `bg` / `unknown` |
| `charging` | `'1'`/`'0'` | Plugged in |
| `screen_on`, `power_save` | `'1'`/`'0'` | Screen interactive, battery saver on |
| `brightness` | string | `auto`, or manual backlight `low` / `mid` / `high` |
| `network` | string | `wifi` / `cell` / `ethernet` / `other` / `none` |
| *your dimensions* | string | From `setDimension` |
| `duration_s` | int | Segment length |
| `level_start`, `level_end` | int | Battery % |
| `drain_mah`, `avg_ma` | double | Charge used, and per hour |
| `current_ma_avg` | double | Mean instantaneous current |
| `temp_start_c`, `temp_max_c` | double | Battery temperature, °C |
| `thermal_status_max` | int | Worst OS thermal status (Android 10+) |
| `thermal_headroom_max` | double | Highest thermal headroom (Android 11+); 1.0 = severe throttling |
| `est_capacity_mah` | int | Full-charge capacity estimate |
| `end_reason` | string | What closed it: the dimension that changed, or `roll`, `start`, `process_death` |
| `end_lag_s` | int | Seconds between the segment's end and its logging (only after a process death) |

### Device properties (`deviceSink`)

Sent once per process, and again only when they change.

| Property | Meaning | Availability |
|---|---|---|
| `battery_capacity_mah` | Full-charge capacity today (stable median estimate, rounded to 50 mAh) | Devices with a charge counter |
| `battery_design_mah` | Factory-rated capacity | Most devices |
| `battery_cycle_count` | Charge cycles | Android 14+ |
| `battery_health` | `good`, `overheat`, `dead`, `over_voltage`, `failure`, `cold` | All |

Battery wear = `battery_capacity_mah / battery_design_mah`.

## Debug tools

For development builds — you decide where they are reachable.

```dart
// A full debug screen: status, live reading, heat, usage today, recent flow
// runs and sessions, the segment in progress, every event sent or dropped.
Scaffold(
  appBar: AppBar(title: const Text('Battery')),
  body: const BatteryInsightsDebugView(),
);

// A draggable floating HUD over the whole app (level · mA · °C · flow),
// toggled from the debug view or with setOverlayEnabled(true).
MaterialApp(
  builder: (context, child) => BatteryInsightsOverlay(child: child!),
);
```

Both refresh every 5 s while visible, with a display-only read that never touches what is reported.

## How it stays at zero drain

- **No timers, wake locks, alarms or battery receivers.** The Android side reads the sticky `ACTION_BATTERY_CHANGED` intent the OS already caches, plus a few `BatteryManager` / `PowerManager` properties — one binder call each.
- **Reads only when the app is awake anyway:** at a state transition, or from `recordSample()`, which you call from work that already runs.
- **Off by default, sampled by install.** Installs outside `samplePct` never read at all.

## Accuracy & limitations

- **Charge counter, not percent.** Drain comes from the fuel gauge's charge counter (µAh), far finer than battery %. Some gauges only step it in ~1 % increments; there a short visit can read 0 while totals across many are still right.
- **Devices without a charge counter** report `level_*` only; filter on `drain_mah` being present.
- **Emulators report a fake battery.** Test on a real device.
- **Readings only while awake.** A change while the app sleeps is noticed at the next read.
- **External activities.** When a flow hands off to the system camera or a picker, your app goes to the background: that time is `app_state = bg` within the flow.
- **Process death.** An open segment is persisted and reported at the next launch (`end_reason = process_death`). Open flow runs and sessions are not.
- **Thermal.** Android exposes no CPU/skin temperature to apps; thermal status/headroom need a thermal HAL, which some devices lack. Battery temperature is always available.
- **Capacity** is estimated (charge ÷ level, median of 25 clean readings), since apps cannot read the gauge's full-charge value.

## Platform support

| Android | iOS | Web / desktop |
|---|---|---|
| ✅ API 21+ | ➖ no-op | ➖ no-op |

On unsupported platforms every call is a safe no-op: `finish()` returns `null`, no events are sent, nothing throws — so you can call it from shared code. iOS exposes only battery % at 1–5 % steps and no charge counter, too coarse for per-flow numbers; contributions welcome.

## Example

[`example/`](example) is a runnable app showing route, widget and in-code flows, today's usage and the event log.

## Contributing

Issues and pull requests are welcome at [github.com/aashish-dhiman/battery_insights](https://github.com/aashish-dhiman/battery_insights). Please run `flutter analyze` and `flutter test` before opening a PR.

## License

[MIT](LICENSE) © Aashish Dhiman
