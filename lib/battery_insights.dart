/// Real-device battery drain for Flutter apps: per flow, and for every user
/// across the app's whole life.
library battery_insights;

export 'src/core/battery_insights.dart';
export 'src/debug/battery_debug_snapshot.dart';
export 'src/debug/battery_insights_debug_view.dart';
export 'src/debug/battery_insights_overlay.dart';
export 'src/debug/battery_metric_info.dart';
export 'src/models/battery_health.dart';
export 'src/models/battery_insights_config.dart';
export 'src/models/battery_reading.dart';
export 'src/models/battery_run_report.dart'
    show BatteryRunKind, BatteryRunReport;
export 'src/models/battery_usage.dart';
export 'src/navigation/battery_flow_route_observer.dart';
export 'src/platform/battery_probe.dart';
export 'src/widgets/battery_flow_scope.dart';
