import 'package:flutter/widgets.dart';

import '../core/battery_insights.dart';

/// Attributes battery drain to [flow] while this widget is mounted. Wrap a
/// flow's entry screen; nested scopes hand attribution back to the outer flow
/// when they unmount.
class BatteryFlowScope extends StatefulWidget {
  const BatteryFlowScope({super.key, required this.flow, required this.child});

  final String flow;
  final Widget child;

  @override
  State<BatteryFlowScope> createState() => _BatteryFlowScopeState();
}

class _BatteryFlowScopeState extends State<BatteryFlowScope> {
  late Object _token;

  @override
  void initState() {
    super.initState();
    _token = BatteryInsights.instance.pushFlow(widget.flow);
  }

  @override
  void didUpdateWidget(BatteryFlowScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow != widget.flow) {
      BatteryInsights.instance.popFlow(_token);
      _token = BatteryInsights.instance.pushFlow(widget.flow);
    }
  }

  @override
  void dispose() {
    BatteryInsights.instance.popFlow(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
