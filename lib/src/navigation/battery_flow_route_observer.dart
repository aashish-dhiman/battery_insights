import 'package:flutter/widgets.dart';

import '../core/battery_insights.dart';

/// Attributes drain to flows by route, so a host maps its route names to flow
/// names in one place instead of wrapping each screen in a
/// `BatteryFlowScope`. Routes [flowForRoute] maps to null are not flows and
/// leave attribution with whatever is beneath them.
class BatteryFlowRouteObserver extends NavigatorObserver {
  BatteryFlowRouteObserver({required this.flowForRoute});

  final String? Function(Route<dynamic> route) flowForRoute;

  final Map<Route<dynamic>, Object> _tokens = {};

  void _enter(Route<dynamic>? route) {
    if (route == null || _tokens.containsKey(route)) return;
    final flow = flowForRoute(route);
    if (flow == null) return;
    _tokens[route] = BatteryInsights.instance.pushFlow(flow);
  }

  void _leave(Route<dynamic>? route) {
    final token = _tokens.remove(route);
    if (token != null) BatteryInsights.instance.popFlow(token);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _enter(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _leave(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _leave(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _leave(oldRoute);
    _enter(newRoute);
  }
}
