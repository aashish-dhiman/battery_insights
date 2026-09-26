/// A metric's display name and what it tells you, for the debug tools.
class BatteryMetricInfo {
  const BatteryMetricInfo(this.label, this.description);

  final String label;
  final String description;
}

/// Every metric the debug view shows, with the plain-language explanation
/// behind its info tooltip. One place, so a label or explanation is changed
/// once and reads the same everywhere it appears.
abstract final class BatteryMetrics {
  /// Metrics on the live screen, keyed by a stable id.
  static const Map<String, BatteryMetricInfo> live = {
    // Reporting
    'status': BatteryMetricInfo(
      'Status',
      'Whether this device is sending battery_segment events right now. '
          'Needs the feature enabled by config and this device inside the '
          'sample.',
    ),
    'enabled': BatteryMetricInfo(
      'Enabled by config',
      'The remote switch from the backend config. Off means nothing is read '
          'or sent, whatever else is set.',
    ),
    'sample': BatteryMetricInfo(
      'Sampling',
      'Share of installs that report. Each install draws a fixed bucket '
          '(0–99) once; it reports when its bucket is below the percentage, '
          'so the same devices stay in the cohort.',
    ),
    'sample_bucket': BatteryMetricInfo(
      'This device',
      "This install's fixed bucket. It reports when the bucket is below the "
          'sampling percentage.',
    ),
    'roll_after': BatteryMetricInfo(
      'Split long segments after',
      'A segment that stays unchanged this long is closed and a new one '
          'opened, so a long idle stretch or session becomes several rows.',
    ),
    'min_segment': BatteryMetricInfo(
      'Shortest segment sent',
      'Segments shorter than this are dropped: they carry no measurable '
          'drain.',
    ),
    'min_sample_gap': BatteryMetricInfo(
      'Min gap between samples',
      'Location and heartbeat callbacks read the battery at most this often. '
          'State changes always read.',
    ),
    'session_counts': BatteryMetricInfo(
      'This session',
      'Segments closed since the app started: sent to analytics, or dropped '
          '(too short, or not reporting).',
    ),

    // Power
    'level': BatteryMetricInfo(
      'Battery level',
      'Charge as the phone shows it, in %. Moves in whole steps, so it is too '
          'coarse to measure short stretches.',
    ),
    'charging': BatteryMetricInfo(
      'Charging',
      'Plugged into a charger. Charging segments are reported but excluded '
          'from drain analysis.',
    ),
    'charge': BatteryMetricInfo(
      'Charge left',
      'Charge left in the battery from the fuel gauge, in mAh. Far finer than '
          '%, and what drain is measured from.',
    ),
    'current': BatteryMetricInfo(
      'Current draw',
      'How much current the phone is pulling at this instant, in mA. Jumps '
          'around; the segment average is the number to compare.',
    ),
    'voltage': BatteryMetricInfo(
      'Voltage',
      'Battery voltage in mV. Falls as the battery empties and under heavy '
          'load.',
    ),

    // Heat
    'temp': BatteryMetricInfo(
      'Battery temperature',
      'Temperature of the battery itself, in °C. The one heat signal every '
          'device reports. Above ~42 °C the phone is hot.',
    ),
    'thermal_status': BatteryMetricInfo(
      'Thermal status',
      'The OS view of how hot the whole phone is: none, light, moderate, '
          'severe, critical. From moderate up the phone starts slowing itself '
          'down.',
    ),
    'thermal_headroom': BatteryMetricInfo(
      'Thermal headroom',
      'How close the phone is to throttling: 1.0 is where severe throttling '
          'starts, lower is cooler. Android skips it when read twice within a '
          'second.',
    ),

    // Screen & system
    'screen_on': BatteryMetricInfo(
      'Screen on',
      'Whether the display is on. The screen is often the biggest single '
          'drain.',
    ),
    'brightness': BatteryMetricInfo(
      'Brightness',
      'Auto, or the manual backlight band (low < 25 %, mid < 60 %, high). '
          'Compare flows at the same brightness.',
    ),
    'network': BatteryMetricInfo(
      'Network',
      'Active connection: wifi, cell, ethernet or none. Mobile data costs '
          'more than wifi.',
    ),
    'power_save': BatteryMetricInfo(
      'Power saver',
      'The OS battery saver. It throttles the phone, so drain with it on is '
          'not comparable with drain off.',
    ),
    'android_api': BatteryMetricInfo(
      'Android API level',
      'Android version as an API level. Some readings need a minimum level: '
          'thermal status 29, headroom 30, cycle count 34.',
    ),

    // Battery health
    'capacity_stable': BatteryMetricInfo(
      'Holds when full',
      'What a full charge holds today, in mAh: the median of many single '
          'estimates, so it only moves with real wear. This is what is '
          'reported.',
    ),
    'capacity_basis': BatteryMetricInfo(
      'Based on',
      'How many single estimates the median rests on. Estimates are only '
          'taken on battery at 50 % charge or more; 3 are needed first.',
    ),
    'capacity_now': BatteryMetricInfo(
      'From this reading alone',
      'Charge left ÷ battery level for just this reading. Jitters by a few '
          'percent; shown so you can see what the median smooths out.',
    ),
    'capacity_design': BatteryMetricInfo(
      'Rated when new',
      "The manufacturer's rated capacity, in mAh.",
    ),
    'capacity_health': BatteryMetricInfo(
      'Health vs rated',
      'What a full charge holds today as a share of what it held new. Under '
          '~80 % is a worn battery; a little over 100 % is normal on some '
          'phones.',
    ),
    'health': BatteryMetricInfo(
      'Health status',
      "The OS's own verdict: good, overheat, dead, over-voltage, failure or "
          'cold.',
    ),
    'cycles': BatteryMetricInfo(
      'Charge cycles',
      'Full charge cycles the battery has been through. Android 14+ only.',
    ),

    // What the app is doing
    'flow': BatteryMetricInfo(
      'Flow',
      'What the user is doing in the app, innermost last. Drain is '
          'attributed to the innermost flow; "none" is idle or a screen '
          'outside every flow.',
    ),
    'app_state': BatteryMetricInfo(
      'App',
      'fg while the app is on screen, bg while it is in the background.',
    ),

    // Segment in progress
    'running_for': BatteryMetricInfo(
      'Running for',
      'How long every dimension has held its current value. Any change closes '
          'this segment and starts a new one.',
    ),
    'drain_so_far': BatteryMetricInfo(
      'Used so far',
      'Charge used since this segment opened, in mAh.',
    ),
    'avg_so_far': BatteryMetricInfo(
      'Average draw',
      'Used so far ÷ time, in mA: the drain rate to compare between states. '
          'Shown after 10 s.',
    ),
    'samples': BatteryMetricInfo(
      'Readings',
      'Battery readings taken in this segment.',
    ),
    'max_temp': BatteryMetricInfo(
      'Hottest battery',
      'Highest battery temperature seen in this segment.',
    ),
    'max_thermal': BatteryMetricInfo(
      'Worst thermal status',
      'Worst OS thermal status seen in this segment.',
    ),
  };

  /// Parameters of a sent `battery_segment` event and device properties,
  /// keyed by the name they are sent under.
  static const Map<String, BatteryMetricInfo> params = {
    'flow': BatteryMetricInfo(
      'Flow',
      'Innermost flow open during the segment; none when no flow was open.',
    ),
    'app_state': BatteryMetricInfo(
      'App',
      'fg (on screen), bg (in the background) or unknown.',
    ),
    'charging': BatteryMetricInfo(
      'Charging',
      '1 if plugged in when the segment started. Excluded from drain '
          'analysis.',
    ),
    'screen_on': BatteryMetricInfo('Screen on', '1 if the display was on.'),
    'power_save':
        BatteryMetricInfo('Power saver', '1 if battery saver was on.'),
    'brightness': BatteryMetricInfo(
      'Brightness',
      'auto, or the manual backlight band: low, mid or high.',
    ),
    'network': BatteryMetricInfo(
      'Network',
      'Active connection: wifi, cell, ethernet, other or none.',
    ),
    'duration_s': BatteryMetricInfo('Length', 'Segment length in seconds.'),
    'level_start': BatteryMetricInfo('Level at start', 'Battery % at start.'),
    'level_end': BatteryMetricInfo('Level at end', 'Battery % at end.'),
    'drain_mah': BatteryMetricInfo(
      'Charge used',
      'Charge used during the segment, in mAh, from the fuel gauge. Negative '
          'while charging.',
    ),
    'avg_ma': BatteryMetricInfo(
      'Average draw',
      'Charge used ÷ hours, in mA: the drain rate to compare between flows '
          'and states.',
    ),
    'current_ma_avg': BatteryMetricInfo(
      'Mean instant draw',
      'Average of the instantaneous current readings, in mA. A cross-check '
          'on the average draw.',
    ),
    'temp_start_c': BatteryMetricInfo(
      'Battery temp at start',
      'Battery temperature when the segment opened, in °C.',
    ),
    'temp_max_c': BatteryMetricInfo(
      'Hottest battery',
      'Highest battery temperature during the segment, in °C.',
    ),
    'thermal_status_max': BatteryMetricInfo(
      'Worst thermal status',
      '0 none, 1 light, 2 moderate, 3 severe, 4 critical. Always 0 on phones '
          'without a thermal HAL.',
    ),
    'thermal_headroom_max': BatteryMetricInfo(
      'Max thermal headroom',
      'Closest the phone came to throttling; 1.0 is where severe throttling '
          'starts.',
    ),
    'est_capacity_mah': BatteryMetricInfo(
      'Holds when full',
      'Estimated full-charge capacity, in mAh, used to turn mAh into % of '
          'battery.',
    ),
    'end_lag_s': BatteryMetricInfo(
      'Reported late by',
      'Seconds between the segment ending and the event being sent. Only '
          'after the app was killed mid-segment.',
    ),
    'end_reason': BatteryMetricInfo(
      'Ended by',
      'What closed the segment: the dimension that changed (flow, camera, '
          'app_state, …), roll, charging, start or process_death.',
    ),
    'battery_capacity_mah': BatteryMetricInfo(
      'Holds when full',
      'User property: stable full-charge capacity, in mAh.',
    ),
    'battery_design_mah': BatteryMetricInfo(
      'Rated when new',
      "User property: the manufacturer's rated capacity, in mAh.",
    ),
    'battery_cycle_count': BatteryMetricInfo(
      'Charge cycles',
      'User property: charge cycles (Android 14+).',
    ),
    'battery_health': BatteryMetricInfo(
      'Health status',
      "User property: the OS's battery health verdict.",
    ),
  };
}
