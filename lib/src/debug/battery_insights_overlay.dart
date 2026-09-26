import 'dart:async';

import 'package:flutter/material.dart';

import '../core/battery_insights.dart';
import 'battery_debug_format.dart';
import 'battery_debug_snapshot.dart';

/// Lays a small, draggable battery readout over [child] while
/// [BatteryInsights.overlayEnabled] is on. Wrap the app in
/// `MaterialApp.builder`, and only on builds where debug tooling is allowed.
///
/// [child] stays at the same position in the tree whether or not the HUD is
/// showing, so toggling it never rebuilds the app beneath.
class BatteryInsightsOverlay extends StatelessWidget {
  const BatteryInsightsOverlay({super.key, required this.child, this.onTap});

  final Widget child;

  /// Tapping the HUD — typically opens the host's debug screen.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: BatteryInsights.instance.overlayEnabled,
      builder: (context, enabled, _) => Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          if (enabled) _Hud(onTap: onTap),
        ],
      ),
    );
  }
}

class _Hud extends StatefulWidget {
  const _Hud({this.onTap});
  final VoidCallback? onTap;

  @override
  State<_Hud> createState() => _HudState();
}

class _HudState extends State<_Hud> {
  static const _refresh = Duration(seconds: 5);
  final BatteryInsights _insights = BatteryInsights.instance;
  Offset? _offset;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _insights.probeNow();
    // Display-only reads while the HUD is up and the app is in front; the
    // ticks stop with the app in the background.
    _timer = Timer.periodic(_refresh, (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _insights.probeNow();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final offset = _offset ?? Offset(12, media.padding.top + 72);

    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanUpdate: (d) => setState(() {
          final next = (_offset ?? offset) + d.delta;
          _offset = Offset(
            next.dx.clamp(0, media.size.width - 80),
            next.dy.clamp(media.padding.top, media.size.height - 60),
          );
        }),
        child: ListenableBuilder(
          listenable: _insights.debugChanges,
          builder: (context, _) => _HudCard(
            snap: _insights.debugSnapshot,
            onClose: () => _insights.setOverlayEnabled(false),
          ),
        ),
      ),
    );
  }
}

class _HudCard extends StatelessWidget {
  const _HudCard({required this.snap, required this.onClose});

  final BatteryDebugSnapshot snap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final r = snap.latest;
    final seg = snap.openSegment;
    final now = DateTime.now();

    final lines = <(String, Color?)>[
      if (r == null)
        ('no reading yet', null)
      else
        (
          '${r.plugged ? '⚡ ' : ''}${BatteryDebugFormat.number(r.levelPct, '%')}'
              ' · ${BatteryDebugFormat.number(r.currentMa, ' mA')}'
              ' · ${BatteryDebugFormat.number(r.tempC, '°C', places: 1)}',
          null
        ),
      (
        [
          snap.flows.isEmpty ? 'none' : snap.flows.last,
          for (final e in snap.dimensions.entries)
            if (BatteryDebugFormat.isSet(e.value)) '${e.key} ${e.value}',
          snap.appState,
        ].join(' · '),
        null
      ),
      if (seg != null)
        (
          'seg ${BatteryDebugFormat.duration(now.difference(seg.start.at))}'
              ' · ${BatteryDebugFormat.number(snap.openDrainMah, ' mAh', places: 1)}'
              ' · ${BatteryDebugFormat.number(snap.openAvgMa, ' mA')}',
          null
        ),
      if (r?.thermalStatus != null)
        (
          'thermal ${BatteryDebugFormat.thermalOf(r!, headroomSeen: snap.thermalHeadroomSeen)}'
              '${r.thermalHeadroom == null ? '' : ' · ${r.thermalHeadroom!.toStringAsFixed(2)}'}',
          (r.thermalStatus ?? 0) >= 2 ? Colors.orangeAccent : null
        ),
      if (!snap.isActive) ('NOT REPORTING', Colors.redAccent),
    ];

    return Material(
      color: Colors.black.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (text, color) in lines)
                    Text(
                      text,
                      style: TextStyle(
                        color: color ?? Colors.white,
                        fontSize: 11,
                        height: 1.35,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
            InkWell(
              onTap: onClose,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 14, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
