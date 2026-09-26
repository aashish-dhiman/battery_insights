import 'dart:async';

import 'package:flutter/material.dart';

import '../core/battery_insights.dart';
import '../models/battery_reading.dart';
import '../models/battery_run_report.dart';
import '../models/battery_usage.dart';
import 'battery_debug_format.dart';
import 'battery_debug_snapshot.dart';
import 'battery_debug_widgets.dart';
import 'battery_metric_info.dart';

/// Debug console for battery analytics: whether this device is reporting,
/// the live battery and thermal state, the segment in progress and the last
/// segments closed — sent or dropped, and why.
///
/// Headless like the other package debug panes: the host supplies the
/// scaffold and app bar. Refreshing reads the battery for display only (see
/// [BatteryInsights.probeNow]); it never touches what is reported.
class BatteryInsightsDebugView extends StatefulWidget {
  const BatteryInsightsDebugView({
    super.key,
    this.refreshInterval = const Duration(seconds: 5),
    this.dimensionInfo = const {},
  });

  final Duration refreshInterval;

  /// Labels and explanations for the host's own dimensions (`camera`,
  /// `tracking`, …), which the package cannot know. Shown in their tooltips
  /// alongside the package's own [BatteryMetrics].
  final Map<String, BatteryMetricInfo> dimensionInfo;

  @override
  State<BatteryInsightsDebugView> createState() =>
      _BatteryInsightsDebugViewState();
}

class _BatteryInsightsDebugViewState extends State<BatteryInsightsDebugView> {
  final BatteryInsights _insights = BatteryInsights.instance;
  Timer? _timer;

  static const _m = BatteryMetrics.live;

  @override
  void initState() {
    super.initState();
    _insights.probeNow();
    _timer =
        Timer.periodic(widget.refreshInterval, (_) => _insights.probeNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable:
          Listenable.merge([_insights.debugChanges, _insights.overlayEnabled]),
      builder: (context, _) {
        final snap = _insights.debugSnapshot;
        final now = DateTime.now();
        final r = snap.latest;
        return RefreshIndicator(
          onRefresh: _insights.probeNow,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              DebugSummaryCard(snap: snap, now: now),
              _hudSwitch(),
              _tapHint(context),
              DebugSection(
                title: 'Reporting',
                icon: Icons.cloud_upload_outlined,
                children: _reporting(snap),
              ),
              DebugSection(
                title: 'What the app is doing',
                icon: Icons.account_tree_outlined,
                children: _appState(snap),
              ),
              DebugSection(
                title: 'Usage today',
                icon: Icons.today_outlined,
                children: _usage(snap.usageToday),
              ),
              DebugSection(
                title: 'Flow runs & sessions',
                icon: Icons.route_outlined,
                trailing: '${snap.recentRuns.length} kept',
                children: snap.recentRuns.isEmpty
                    ? [
                        const DebugHint(
                            'None finished yet. A flow run ends when its flow '
                            'is left; a session when the app changes between '
                            'foreground and background.'),
                      ]
                    : [for (final run in snap.recentRuns) _run(run, now)],
              ),
              DebugSection(
                title: 'Segment in progress',
                icon: Icons.timelapse,
                children: _openSegment(snap, now),
              ),
              if (r != null) ...[
                DebugSection(
                  title: 'Power',
                  icon: Icons.bolt_outlined,
                  children: _power(r),
                ),
                DebugSection(
                  title: 'Heat',
                  icon: Icons.thermostat_outlined,
                  children: _heat(r, headroomSeen: snap.thermalHeadroomSeen),
                ),
                DebugSection(
                  title: 'Screen & system',
                  icon: Icons.smartphone_outlined,
                  children: _system(r),
                ),
                DebugSection(
                  title: 'Battery health',
                  icon: Icons.health_and_safety_outlined,
                  children: _health(snap, r),
                ),
              ],
              DebugSection(
                title: 'Recent segments',
                icon: Icons.history,
                trailing: '${snap.recent.length} kept',
                children: snap.recent.isEmpty
                    ? [const DebugHint('None closed yet this session.')]
                    : [
                        for (final rec in snap.recent)
                          DebugRecordTile(
                            record: rec,
                            dimensionInfo: widget.dimensionInfo,
                          ),
                      ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _hudSwitch() {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: SwitchListTile(
        title: const Text('Show battery HUD'),
        subtitle: const Text(
            'Floating live readout over every screen. Drag to move, tap to open this page.'),
        value: _insights.overlayEnabled.value,
        onChanged: _insights.setOverlayEnabled,
      ),
    );
  }

  Widget _tapHint(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Tap any label with this icon to see what it means.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _reporting(BatteryDebugSnapshot snap) {
    final c = snap.config;
    final inSample = snap.bucket < c.samplePct;
    return [
      DebugMetricRow.of(
        _m['status']!,
        snap.isActive ? 'Reporting' : 'Not reporting',
        emphasis: snap.isActive ? DebugEmphasis.good : DebugEmphasis.bad,
      ),
      DebugMetricRow.of(_m['enabled']!, c.enabled ? 'Yes' : 'No',
          emphasis: c.enabled ? null : DebugEmphasis.bad),
      DebugMetricRow.of(_m['sample']!, '${c.samplePct}% of installs'),
      DebugMetricRow.of(
        _m['sample_bucket']!,
        'bucket ${snap.bucket} · ${inSample ? 'included' : 'left out'}',
        emphasis: inSample ? null : DebugEmphasis.warn,
        sub: true,
      ),
      DebugMetricRow.of(
          _m['roll_after']!, BatteryDebugFormat.duration(c.rollAfter)),
      DebugMetricRow.of(_m['min_segment']!, '${c.minSegment.inSeconds} s'),
      DebugMetricRow.of(
          _m['min_sample_gap']!, '${c.minSampleInterval.inSeconds} s'),
      DebugMetricRow.of(_m['session_counts']!,
          '${snap.sentCount} sent · ${snap.droppedCount} dropped'),
      for (final e in snap.deviceProperties.entries) _param(e.key, e.value),
    ];
  }

  List<Widget> _appState(BatteryDebugSnapshot snap) {
    return [
      DebugMetricRow.of(
          _m['flow']!, snap.flows.isEmpty ? 'none' : snap.flows.join(' › ')),
      DebugMetricRow.of(_m['app_state']!, snap.appState),
      for (final e in snap.dimensions.entries) _param(e.key, e.value),
    ];
  }

  List<Widget> _openSegment(BatteryDebugSnapshot snap, DateTime now) {
    final seg = snap.openSegment;
    if (seg == null) {
      return [
        DebugHint(snap.isActive
            ? 'Opens at the next reading.'
            : 'None — this device is not reporting.'),
      ];
    }
    return [
      DebugMetricRow.of(_m['running_for']!,
          BatteryDebugFormat.duration(now.difference(seg.start.at))),
      DebugMetricRow.of(_m['drain_so_far']!,
          BatteryDebugFormat.number(snap.openDrainMah, ' mAh', places: 2)),
      DebugMetricRow.of(
          _m['avg_so_far']!, BatteryDebugFormat.number(snap.openAvgMa, ' mA')),
      DebugMetricRow.of(_m['samples']!, '${seg.samples}'),
      DebugMetricRow.of(_m['max_temp']!,
          BatteryDebugFormat.number(seg.maxTempC, ' °C', places: 1)),
      DebugMetricRow.of(
          _m['max_thermal']!, BatteryDebugFormat.thermal(seg.thermalStatusMax)),
      DebugChips(seg.dims,
          info: {...BatteryMetrics.params, ...widget.dimensionInfo}),
    ];
  }

  List<Widget> _power(BatteryReading r) {
    return [
      DebugMetricRow.of(
          _m['level']!, BatteryDebugFormat.number(r.levelPct, '%')),
      DebugMetricRow.of(_m['charging']!, r.plugged ? 'Yes' : 'No',
          emphasis: r.plugged ? DebugEmphasis.warn : null),
      DebugMetricRow.of(
          _m['charge']!, BatteryDebugFormat.number(r.chargeMah, ' mAh')),
      DebugMetricRow.of(
          _m['current']!, BatteryDebugFormat.number(r.currentMa, ' mA')),
      DebugMetricRow.of(
          _m['voltage']!, BatteryDebugFormat.number(r.voltageMv, ' mV')),
    ];
  }

  List<Widget> _heat(BatteryReading r, {required bool headroomSeen}) {
    return [
      DebugMetricRow.of(
          _m['temp']!, BatteryDebugFormat.number(r.tempC, ' °C', places: 1),
          emphasis: (r.tempC ?? 0) >= 42 ? DebugEmphasis.warn : null),
      DebugMetricRow.of(_m['thermal_status']!,
          BatteryDebugFormat.thermalOf(r, headroomSeen: headroomSeen),
          emphasis: (r.thermalStatus ?? 0) >= 2 ? DebugEmphasis.bad : null),
      DebugMetricRow.of(
        _m['thermal_headroom']!,
        r.thermalHeadroom != null
            ? BatteryDebugFormat.number(r.thermalHeadroom, '', places: 2)
            : headroomSeen
                // Reported earlier in this process: this read was simply too
                // soon after the last one.
                ? '— (skipped this read)'
                : BatteryDebugFormat.unavailable(r, since: 30),
      ),
    ];
  }

  List<Widget> _system(BatteryReading r) {
    return [
      DebugMetricRow.of(_m['screen_on']!, BatteryDebugFormat.flag(r.screenOn)),
      DebugMetricRow.of(
        _m['brightness']!,
        r.brightnessBand == null
            ? '—'
            : r.brightnessAuto == true
                ? 'auto'
                : '${r.brightnessBand} · ${BatteryDebugFormat.number(r.brightnessPct, '%')}',
      ),
      DebugMetricRow.of(_m['network']!, r.network ?? '—'),
      DebugMetricRow.of(
          _m['power_save']!, BatteryDebugFormat.flag(r.powerSave)),
      DebugMetricRow.of(_m['android_api']!, r.sdkInt?.toString() ?? '—'),
    ];
  }

  /// The stable capacity is what gets reported; the single-reading one sits
  /// under it as a sub-row, so the jitter the median smooths out is visible.
  List<Widget> _health(BatteryDebugSnapshot snap, BatteryReading r) {
    final stable = snap.capacityMah;
    final design = r.designCapacityMah;
    final healthPct = stable != null && design != null && design > 0
        ? stable / design * 100
        : null;
    return [
      DebugMetricRow.of(
        _m['capacity_stable']!,
        stable != null
            ? '${stable.round()} mAh'
            : 'collecting ${snap.capacitySamples}/3',
      ),
      DebugMetricRow.of(
        _m['capacity_basis']!,
        stable != null
            ? '${snap.capacitySamples} estimates'
            : 'on battery, ≥ 50 %',
        sub: true,
      ),
      DebugMetricRow.of(
        _m['capacity_now']!,
        BatteryDebugFormat.number(r.estCapacityMah, ' mAh'),
        sub: true,
      ),
      DebugMetricRow.of(
          _m['capacity_design']!, BatteryDebugFormat.number(design, ' mAh')),
      DebugMetricRow.of(
        _m['capacity_health']!,
        BatteryDebugFormat.number(healthPct, '%'),
        emphasis:
            healthPct != null && healthPct < 80 ? DebugEmphasis.bad : null,
      ),
      DebugMetricRow.of(_m['health']!, r.health ?? '—',
          emphasis: r.health != null && r.health != 'good'
              ? DebugEmphasis.bad
              : null),
      DebugMetricRow.of(
        _m['cycles']!,
        r.cycleCount?.toString() ??
            BatteryDebugFormat.unavailable(r, since: 34),
      ),
    ];
  }

  List<Widget> _usage(BatteryDayUsage? day) {
    if (day == null) {
      return [
        const DebugHint('Nothing yet today — totals grow as segments close.')
      ];
    }
    String line(BatteryUsageTotal t) => [
          BatteryDebugFormat.duration(t.duration),
          if (t.measuredSeconds > 0)
            BatteryDebugFormat.number(t.drainMah, ' mAh', places: 1),
          if (t.avgMa != null) BatteryDebugFormat.number(t.avgMa, ' mA avg'),
        ].join(' · ');
    final flows = day.flows.entries.toList()
      ..sort((a, b) => b.value.drainMah.compareTo(a.value.drainMah));
    return [
      DebugMetricRow(label: 'Total', value: line(day.total)),
      DebugMetricRow(
          label: 'Foreground', value: line(day.foreground), sub: true),
      DebugMetricRow(
          label: 'Background', value: line(day.background), sub: true),
      if (day.chargingSeconds > 0)
        DebugMetricRow(
          label: 'Charging',
          value: BatteryDebugFormat.duration(
              Duration(seconds: day.chargingSeconds)),
          sub: true,
        ),
      for (final e in flows)
        DebugMetricRow(
            label: e.key, value: line(e.value), caption: 'flow', sub: true),
    ];
  }

  Widget _run(BatteryRunReport run, DateTime now) {
    final kind = run.kind == BatteryRunKind.flow ? 'flow' : 'session';
    return DebugMetricRow(
      label: '${run.name} · $kind',
      caption: '${BatteryDebugFormat.duration(now.difference(run.end.at))} ago',
      value: [
        BatteryDebugFormat.duration(run.duration),
        if (run.drainMah != null)
          BatteryDebugFormat.number(run.drainMah, ' mAh', places: 1),
        if (run.avgMa != null) BatteryDebugFormat.number(run.avgMa, ' mA'),
        if (run.charging) 'charging',
      ].join(' · '),
    );
  }

  /// A sent parameter, device property or host dimension, by its raw name.
  Widget _param(String key, String value) {
    final info = BatteryMetrics.params[key] ?? widget.dimensionInfo[key];
    return DebugMetricRow(
      label: info?.label ?? key,
      value: value,
      info: info?.description,
      caption: info == null ? null : key,
    );
  }
}
