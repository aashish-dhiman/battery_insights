import 'battery_reading.dart';

/// A stretch of time during which every dimension held one value. Closed into
/// a single `battery_segment` event, so drain is attributed to exactly one
/// state without any windowing in the warehouse.
class BatterySegment {
  BatterySegment({
    required this.dims,
    required this.start,
    BatteryReading? last,
    double? maxTempC,
    int? thermalStatusMax,
    double? thermalHeadroomMax,
    this.currentSumMa = 0,
    this.currentCount = 0,
    this.samples = 1,
  })  : last = last ?? start,
        maxTempC = maxTempC ?? start.tempC,
        thermalStatusMax = thermalStatusMax ?? start.thermalStatus,
        thermalHeadroomMax = thermalHeadroomMax ?? start.thermalHeadroom;

  final Map<String, String> dims;
  final BatteryReading start;
  BatteryReading last;
  double? maxTempC;

  /// Worst thermal state seen, including [start]: heat builds and fades over
  /// minutes, so the state at the transition belongs to this segment as much
  /// as the one before — the same rule as [maxTempC].
  int? thermalStatusMax;
  double? thermalHeadroomMax;

  /// Instantaneous current is averaged over readings *after* [start]: the
  /// start reading is taken at the transition and still reflects the state
  /// being left.
  double currentSumMa;
  int currentCount;
  int samples;

  Duration get age => last.at.difference(start.at);

  void add(BatteryReading r) {
    last = r;
    samples++;
    final t = r.tempC;
    if (t != null && (maxTempC == null || t > maxTempC!)) maxTempC = t;
    final c = r.currentMa;
    if (c != null) {
      currentSumMa += c;
      currentCount++;
    }
    final status = r.thermalStatus;
    if (status != null &&
        (thermalStatusMax == null || status > thermalStatusMax!)) {
      thermalStatusMax = status;
    }
    final headroom = r.thermalHeadroom;
    if (headroom != null &&
        (thermalHeadroomMax == null || headroom > thermalHeadroomMax!)) {
      thermalHeadroomMax = headroom;
    }
  }

  /// Event parameters for this segment ending at [last]. Dimensions go first
  /// and every value is a string or finite number, as Firebase requires; a
  /// value the device did not report is left out, never sent as 0.
  ///
  /// Firebase stamps the event with the time it is logged, which is when the
  /// segment ended — except for one recovered after a process death, logged at
  /// the next launch. `end_lag_s` carries that gap ([loggedAt] − last reading)
  /// whenever it is a second or more, so the segment ends at
  /// `event_timestamp − end_lag_s` and starts `duration_s` before that.
  ///
  /// [capacityMah] is the device's stable capacity estimate. Without one, a
  /// reading at 50 %+ stands in; below that a single estimate is too noisy to
  /// send.
  Map<String, Object> report(
    String endReason, {
    double? capacityMah,
    DateTime? loggedAt,
  }) {
    final end = last;
    final durationS = end.at.difference(start.at).inSeconds;
    final startCharge = start.chargeMah;
    final endCharge = end.chargeMah;
    final drainMah = startCharge != null && endCharge != null
        ? startCharge - endCharge
        : null;
    final capacity = capacityMah ??
        (end.levelPct >= 50
            ? end.estCapacityMah
            : start.levelPct >= 50
                ? start.estCapacityMah
                : null);

    final params = <String, Object>{
      ...dims,
      'duration_s': durationS,
      'level_start': start.levelPct.round(),
      'level_end': end.levelPct.round(),
      'end_reason': endReason,
    };
    final lag = loggedAt?.difference(end.at).inSeconds;
    if (lag != null && lag >= 1) params['end_lag_s'] = lag;
    void put(String key, num? value, [int places = 1]) {
      if (value == null || !value.isFinite) return;
      params[key] = places == 0
          ? value.round()
          : double.parse(value.toStringAsFixed(places));
    }

    put('drain_mah', drainMah, 2);
    if (drainMah != null && durationS > 0) {
      put('avg_ma', drainMah / (durationS / 3600));
    }
    if (currentCount > 0) put('current_ma_avg', currentSumMa / currentCount);
    put('temp_start_c', start.tempC);
    put('temp_max_c', maxTempC);
    put('est_capacity_mah', capacity, 0);
    put('thermal_status_max', thermalStatusMax, 0);
    put('thermal_headroom_max', thermalHeadroomMax, 2);
    return params;
  }

  Map<String, Object?> toJson() => {
        'dims': dims,
        'start': start.toJson(),
        'last': last.toJson(),
        'maxTempC': maxTempC,
        'thermalStatusMax': thermalStatusMax,
        'thermalHeadroomMax': thermalHeadroomMax,
        'currentSumMa': currentSumMa,
        'currentCount': currentCount,
        'samples': samples,
      };

  factory BatterySegment.fromJson(Map<String, dynamic> json) => BatterySegment(
        dims: Map<String, String>.from(json['dims'] as Map),
        start: BatteryReading.fromJson(
            Map<String, dynamic>.from(json['start'] as Map)),
        last: BatteryReading.fromJson(
            Map<String, dynamic>.from(json['last'] as Map)),
        maxTempC: (json['maxTempC'] as num?)?.toDouble(),
        thermalStatusMax: (json['thermalStatusMax'] as num?)?.toInt(),
        thermalHeadroomMax: (json['thermalHeadroomMax'] as num?)?.toDouble(),
        currentSumMa: (json['currentSumMa'] as num?)?.toDouble() ?? 0,
        currentCount: (json['currentCount'] as num?)?.toInt() ?? 0,
        samples: (json['samples'] as num?)?.toInt() ?? 1,
      );
}
