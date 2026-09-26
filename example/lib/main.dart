import 'dart:async';

import 'package:battery_insights/battery_insights.dart';
import 'package:flutter/material.dart';

/// Events the sink received, newest first, for the on-screen log.
final ValueNotifier<List<String>> eventLog = ValueNotifier(const []);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await BatteryInsights.instance.init(
    // In a real app, route these to your analytics SDK, e.g.
    // FirebaseAnalytics.instance.logEvent(name: name, parameters: params).
    sink: (name, params) {
      debugPrint('$name $params');
      eventLog.value = ['$name  ${_short(params)}', ...eventLog.value.take(49)];
    },
    deviceSink: (name, value) => debugPrint('device $name = $value'),
    // Usually from remote config; enabled here so the demo reports at once.
    config: const BatteryInsightsConfig(
      enabled: true,
      minSampleInterval: Duration(seconds: 30),
      rollAfter: Duration(minutes: 5),
    ),
  );

  // Keep long segments sampled. A real app calls recordSample() from
  // callbacks it already runs (location, heartbeat, sync) instead.
  Timer.periodic(const Duration(seconds: 30),
      (_) => BatteryInsights.instance.recordSample());

  runApp(const ExampleApp());
}

String _short(Map<String, Object> p) => [
      for (final k in const [
        'flow',
        'app_state',
        'duration_s',
        'drain_mah',
        'avg_ma',
        'end_reason',
      ])
        if (p[k] != null) '$k=${p[k]}',
    ].join(' ');

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'battery_insights',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      // Flow-wise tracking by route: map route names to flow names once.
      navigatorObservers: [
        BatteryFlowRouteObserver(
          flowForRoute: (route) => switch (route.settings.name) {
            '/checkout' => 'checkout',
            _ => null,
          },
        ),
      ],
      // The floating debug HUD, shown while the switch in the debug view is on.
      builder: (context, child) =>
          BatteryInsightsOverlay(child: child ?? const SizedBox()),
      routes: {
        '/': (_) => const HomePage(),
        '/checkout': (_) => const CheckoutPage(),
        '/debug': (_) => Scaffold(
              appBar: AppBar(title: const Text('Battery debug')),
              body: const BatteryInsightsDebugView(),
            ),
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('battery_insights'),
        actions: [
          IconButton(
            tooltip: 'Debug view',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.pushNamed(context, '/debug'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const UsageTodayCard(),
          const SizedBox(height: 16),
          Text('Flow-wise tracking',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.shopping_cart_outlined),
            label: const Text('Checkout (tracked by route)'),
            onPressed: () => Navigator.pushNamed(context, '/checkout'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Camera (BatteryFlowScope + dimension)'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CameraPage()),
            ),
          ),
          const SizedBox(height: 8),
          const HeavyWorkButton(),
          const SizedBox(height: 24),
          Text('Events sent', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder(
            valueListenable: eventLog,
            builder: (context, log, _) => log.isEmpty
                ? const Text('None yet — events are sent when a flow is left, '
                    'the app changes between foreground and background, or '
                    'state changes.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in log)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(line,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Every-user tracking: the app's own battery use today, kept on the device.
class UsageTodayCard extends StatelessWidget {
  const UsageTodayCard({super.key});

  @override
  Widget build(BuildContext context) {
    final insights = BatteryInsights.instance;
    return ListenableBuilder(
      listenable: insights.debugChanges,
      builder: (context, _) {
        final day = insights.usageToday;
        String line(BatteryUsageTotal t) =>
            '${_mins(t.duration)} · ${t.drainMah.toStringAsFixed(1)} mAh';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This app today',
                    style: Theme.of(context).textTheme.titleMedium),
                // A user-facing setting: how much history stays on the phone.
                Row(
                  children: [
                    const Expanded(child: Text('Keep battery history')),
                    DropdownButton<int>(
                      value: insights.config.usageDays,
                      items: [
                        for (final days in {
                          0,
                          7,
                          14,
                          30,
                          insights.config.usageDays
                        })
                          DropdownMenuItem(
                            value: days,
                            child: Text(days == 0 ? 'Off' : '$days days'),
                          ),
                      ],
                      onChanged: (days) => insights
                          .configure(insights.config.copyWith(usageDays: days)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (insights.config.usageDays == 0)
                  const Text('History is off — nothing is kept on the phone.')
                else if (day == null)
                  const Text('Collecting… totals grow as segments close.')
                else ...[
                  Text('Total       ${line(day.total)}'),
                  Text('Foreground  ${line(day.foreground)}'),
                  Text('Background  ${line(day.background)}'),
                  const Divider(),
                  for (final e in day.flows.entries)
                    Text('${e.key.padRight(12)}${line(e.value)}'),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  static String _mins(Duration d) => '${d.inMinutes} min';
}

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Everything on this route is attributed to the "checkout" flow. '
            'Go back to send a battery_flow event with the visit\'s drain.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  @override
  void initState() {
    super.initState();
    // A host dimension: set it where the state really changes (e.g. when the
    // camera controller starts), clear it when it stops.
    BatteryInsights.instance.setDimension('camera', 'preview');
  }

  @override
  void dispose() {
    BatteryInsights.instance.setDimension('camera', 'off');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BatteryFlowScope(
      flow: 'camera',
      child: Scaffold(
        appBar: AppBar(title: const Text('Camera')),
        body: const Center(
          child: Text('Pretend the camera preview is running.'),
        ),
      ),
    );
  }
}

/// Flow-wise tracking in code: measure one piece of work and show its cost.
class HeavyWorkButton extends StatefulWidget {
  const HeavyWorkButton({super.key});

  @override
  State<HeavyWorkButton> createState() => _HeavyWorkButtonState();
}

class _HeavyWorkButtonState extends State<HeavyWorkButton> {
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final run = BatteryInsights.instance.startFlow('heavy_work');
    final end = DateTime.now().add(const Duration(seconds: 20));
    var x = 0.0;
    while (DateTime.now().isBefore(end)) {
      for (var i = 0; i < 2000000; i++) {
        x += i * 0.5;
      }
      await Future<void>.delayed(Duration.zero); // keep the UI alive
    }
    final report = await run.finish();
    if (!mounted) return;
    setState(() => _running = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(report == null
          ? 'No reading (not reporting, or not on Android). ($x)'
          : 'heavy_work: ${report.duration.inSeconds}s, '
              '${report.drainMah?.toStringAsFixed(2) ?? '?'} mAh, '
              '${report.avgMa?.toStringAsFixed(0) ?? '?'} mA avg'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: _running
          ? const SizedBox.square(
              dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.memory),
      label: Text(_running
          ? 'Burning CPU for 20 s…'
          : 'Heavy work (startFlow / finish)'),
      onPressed: _running ? null : _run,
    );
  }
}
