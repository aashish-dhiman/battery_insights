import 'package:flutter/material.dart';

import 'battery_debug_format.dart';
import 'battery_debug_snapshot.dart';
import 'battery_metric_info.dart';

// Building blocks of BatteryInsightsDebugView.

enum DebugEmphasis { good, warn, bad }

Color emphasisColor(ThemeData theme, DebugEmphasis? emphasis) =>
    switch (emphasis) {
      DebugEmphasis.good => Colors.green.shade700,
      DebugEmphasis.warn => Colors.orange.shade800,
      DebugEmphasis.bad => theme.colorScheme.error,
      null => theme.colorScheme.onSurface,
    };

/// A titled card of rows, with an optional icon and note beside the title.
class DebugSection extends StatelessWidget {
  const DebugSection({
    super.key,
    required this.title,
    required this.children,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final String? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: muted),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: muted,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(trailing!,
                      style:
                          theme.textTheme.labelSmall?.copyWith(color: muted)),
              ],
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

/// A label and its value. With [info], the label carries an info icon and
/// tapping the label explains the metric.
///
/// A [sub] row belongs to the row above it: indented behind a guide line and
/// set smaller, instead of padding the label with spaces.
class DebugMetricRow extends StatelessWidget {
  const DebugMetricRow({
    super.key,
    required this.label,
    required this.value,
    this.info,
    this.caption,
    this.emphasis,
    this.sub = false,
  });

  /// From [BatteryMetrics]: label and explanation together.
  DebugMetricRow.of(
    BatteryMetricInfo metric,
    String value, {
    Key? key,
    String? caption,
    DebugEmphasis? emphasis,
    bool sub = false,
  }) : this(
          key: key,
          label: metric.label,
          value: value,
          info: metric.description,
          caption: caption,
          emphasis: emphasis,
          sub: sub,
        );

  final String label;
  final String value;
  final String? info;

  /// Small text under the label, e.g. the parameter's raw name.
  final String? caption;
  final DebugEmphasis? emphasis;
  final bool sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final labelStyle =
        (sub ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
            ?.copyWith(color: muted);
    final valueStyle =
        (sub ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
            ?.copyWith(
      color: sub && emphasis == null ? muted : emphasisColor(theme, emphasis),
      fontWeight: emphasis == null ? FontWeight.w500 : FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(this.label, style: labelStyle)),
        if (info != null) ...[
          const SizedBox(width: 4),
          Icon(Icons.info_outline, size: sub ? 13 : 15, color: muted),
        ],
      ],
    );
    if (caption != null) {
      label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          Text(caption!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted.withAlpha(170),
                fontFamily: 'monospace',
              )),
        ],
      );
    }
    if (info != null) {
      label = Tooltip(
        message: info,
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 8),
        preferBelow: false,
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(12),
        textStyle: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onInverseSurface, height: 1.35),
        child: label,
      );
    }

    final row = Padding(
      padding: EdgeInsets.fromLTRB(sub ? 12 : 16, sub ? 2 : 7, 16, sub ? 6 : 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
              flex: 6,
              child: Align(alignment: Alignment.centerLeft, child: label)),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: Text(value, textAlign: TextAlign.end, style: valueStyle),
          ),
        ],
      ),
    );
    if (!sub) return row;
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.outlineVariant, width: 2),
          ),
        ),
        child: row,
      ),
    );
  }
}

/// A short muted line, for empty states.
class DebugHint extends StatelessWidget {
  const DebugHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(text,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Dimension values as chips, each explaining itself when it has an entry in
/// [info].
class DebugChips extends StatelessWidget {
  const DebugChips(this.values, {super.key, this.info = const {}});
  final Map<String, String> values;
  final Map<String, BatteryMetricInfo> info;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in values.entries)
              _maybeTooltip(
                info[e.key]?.description,
                Chip(
                  label: Text('${e.key}: ${e.value}'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _maybeTooltip(String? message, Widget child) => message == null
      ? child
      : Tooltip(
          message: message,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 8),
          child: child,
        );
}

/// The at-a-glance header: level, draw, heat and where the app is.
class DebugSummaryCard extends StatelessWidget {
  const DebugSummaryCard({super.key, required this.snap, required this.now});

  final BatteryDebugSnapshot snap;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = snap.latest;
    final muted = theme.colorScheme.onSurfaceVariant;
    final flow = snap.flows.isEmpty ? 'none' : snap.flows.last;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  r?.plugged == true
                      ? Icons.battery_charging_full
                      : Icons.battery_std,
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  r == null ? '—' : BatteryDebugFormat.number(r.levelPct, '%'),
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _StatusPill(active: snap.isActive),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              r == null
                  ? 'No reading yet.'
                  : '${r.plugged ? 'Charging' : 'On battery'} · '
                      'read ${BatteryDebugFormat.ago(r.at, now)}',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _Stat(
                  label: 'Draw now',
                  value: BatteryDebugFormat.number(r?.currentMa, ' mA'),
                ),
                _Stat(
                  label: 'Battery temp',
                  value: BatteryDebugFormat.number(r?.tempC, ' °C', places: 1),
                ),
                _Stat(
                  label: 'Segment avg',
                  value: BatteryDebugFormat.number(snap.openAvgMa, ' mA'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Flow',
                style: theme.textTheme.labelSmall?.copyWith(color: muted)),
            const SizedBox(height: 2),
            Text(
              flow,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? Colors.green.shade700 : Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        active ? 'Reporting' : 'Not reporting',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// One closed segment: a one-line summary, expanding to every parameter
/// exactly as it was (or would have been) sent, each explained.
class DebugRecordTile extends StatelessWidget {
  const DebugRecordTile({
    super.key,
    required this.record,
    this.dimensionInfo = const {},
  });

  final BatteryDebugRecord record;
  final Map<String, BatteryMetricInfo> dimensionInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = record.params;
    final sent = record.outcome == BatteryRecordOutcome.sent;
    final duration = p['duration_s'];
    final summary = [
      p['flow'],
      // Host dimensions: whatever the package does not define itself.
      for (final e in p.entries)
        if (!BatteryMetrics.params.containsKey(e.key) &&
            e.value is String &&
            BatteryDebugFormat.isSet(e.value as String))
          '${e.key} ${e.value}',
      p['app_state'],
    ].whereType<Object>().join(' · ');
    final numbers = [
      if (duration is int)
        BatteryDebugFormat.duration(Duration(seconds: duration)),
      if (p['drain_mah'] is num)
        BatteryDebugFormat.number(p['drain_mah'] as num, ' mAh', places: 1),
      if (p['avg_ma'] is num)
        BatteryDebugFormat.number(p['avg_ma'] as num, ' mA'),
    ].join(' · ');

    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(summary, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        '${BatteryDebugFormat.clock(record.closedAt)} · ended by ${record.reason}'
        '${numbers.isEmpty ? '' : ' · $numbers'}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: Text(
        record.outcome.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color:
              sent ? Colors.green.shade700 : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      children: [
        for (final e in record.params.entries) _paramRow(e.key, '${e.value}'),
      ],
    );
  }

  Widget _paramRow(String key, String value) {
    final info = BatteryMetrics.params[key] ?? dimensionInfo[key];
    return DebugMetricRow(
      label: info?.label ?? key,
      value: value,
      info: info?.description,
      caption: info == null ? null : key,
    );
  }
}
