## 0.1.1

- **Battery health.** New `BatteryInsights.instance.batteryHealth` getter returning a `BatteryHealth`: full-charge capacity worked out from the phone's own readings, design capacity, `healthPct`, `isWorn()`, cycle count and Android's health status.
- Example app: battery health card.

## 0.1.0

First public release.

- **Flow-wise tracking.** `startFlow()` / `BatteryFlowRun.finish()` return the battery cost of each flow visit; `BatteryFlowScope` and `BatteryFlowRouteObserver` attribute flows by widget or by route. One `battery_flow` event per visit.
- **Every-user tracking.** Foreground and background sessions (`battery_session`), and segments of constant state (`battery_segment`) that split drain by flow, app state, charging, screen, power saver, brightness, network and up to `maxDimensions` of your own.
- **On-device usage.** `BatteryInsights.instance.usage` keeps daily totals by app state and flow — no backend needed. `usageDays` sets how many days (default 14, up to 366; `0` turns it off and deletes stored totals), so apps can let users choose.
- **Device facts.** Full-charge capacity (stable median estimate), design capacity, cycle count and health, sent once through `deviceSink`.
- **No drain of its own.** No timers, wake locks, alarms or battery receivers; reads only when the app is already awake.
- **Debug tools.** `BatteryInsightsDebugView` and a floating `BatteryInsightsOverlay` HUD.
- Android only (API 21+). Other platforms are safe no-ops.
