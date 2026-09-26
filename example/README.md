# battery_insights example

A small Android app showing both ways of tracking:

- **Flow-wise** — the *Checkout* route (tracked by `BatteryFlowRouteObserver`), the *Camera* screen (`BatteryFlowScope` + a host dimension), and *Heavy work* (`startFlow()` / `finish()` returning a report).
- **Every user** — today's usage card (foreground, background, per flow) and the event log with `battery_session` / `battery_segment` events.

Run it on a real Android device (emulators report a fake battery):

```bash
cd example
flutter run
```

Open **Debug view** to see the live reading, the segment in progress and every event, sent or dropped.
