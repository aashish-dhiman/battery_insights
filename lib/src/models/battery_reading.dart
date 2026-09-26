/// One read of the battery and thermal state, normalised across OEMs.
///
/// Everything but [at], [levelPct] and [plugged] is optional: devices differ in
/// what they report, and a missing value is null rather than a guess.
///
/// Android documents the charge counter in µAh and current in µA, but some
/// OEMs report mAh / mA instead. Both are normalised here so everything
/// downstream works in mAh / mA regardless of the device.
class BatteryReading {
  const BatteryReading({
    required this.at,
    required this.levelPct,
    required this.plugged,
    this.chargeMah,
    this.currentMa,
    this.tempC,
    this.voltageMv,
    this.powerSave,
    this.screenOn,
    this.thermalStatus,
    this.thermalHeadroom,
    this.cycleCount,
    this.health,
    this.sdkInt,
    this.designCapacityMah,
    this.brightnessPct,
    this.brightnessAuto,
    this.network,
  });

  final DateTime at;
  final double levelPct;
  final bool plugged;

  /// Remaining charge from the fuel gauge. Far finer than [levelPct]; null
  /// where the device does not report it.
  final double? chargeMah;

  /// Instantaneous draw, as a magnitude (the sign convention varies by OEM).
  final double? currentMa;

  /// Battery temperature. Android exposes no CPU or skin temperature to apps;
  /// [thermalStatus] and [thermalHeadroom] are the whole-device signals.
  final double? tempC;
  final int? voltageMv;
  final bool? powerSave;
  final bool? screenOn;

  /// `PowerManager.getCurrentThermalStatus` (Android 10+): 0 none, 1 light,
  /// 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown — how hard the
  /// OS is throttling the phone for heat.
  final int? thermalStatus;

  /// `PowerManager.getThermalHeadroom` (Android 11+): 1.0 is the onset of
  /// severe throttling.
  final double? thermalHeadroom;

  /// Charge cycles (Android 14+).
  final int? cycleCount;

  /// `good`, `overheat`, `dead`, `over_voltage`, `failure` or `cold`.
  final String? health;

  /// Android API level of the device. For debug display only — events carry
  /// the OS version through the analytics SDK already.
  final int? sdkInt;

  /// Factory-rated capacity from the OEM power profile (hidden API; null where
  /// unavailable or a placeholder). Fixed for the device model.
  final double? designCapacityMah;

  /// Backlight level as a percentage of the device's maximum (the power-side
  /// value, not the slider position).
  final double? brightnessPct;
  final bool? brightnessAuto;

  /// `wifi`, `cell`, `ethernet`, `other` or `none`.
  final String? network;

  /// `auto`, or the manual backlight as `low` (< 25 %), `mid` (< 60 %) or
  /// `high`. Bands are on the backlight value, where power scales with it.
  String? get brightnessBand {
    if (brightnessAuto == true) return 'auto';
    final pct = brightnessPct;
    if (pct == null) return null;
    if (pct < 25) return 'low';
    if (pct < 60) return 'mid';
    return 'high';
  }

  /// Full-charge capacity implied by this reading — what the battery holds
  /// today, so it falls as the battery wears. Null when too close to empty for
  /// the division to mean anything.
  double? get estCapacityMah {
    final charge = chargeMah;
    if (charge == null || levelPct < 5) return null;
    return charge / (levelPct / 100);
  }

  /// Builds a reading from the plugin's map, or null when it carries no level.
  /// Values of an unexpected type are treated as absent, never cast.
  static BatteryReading? fromPlatform(Map<Object?, Object?> raw, DateTime at) {
    final level = _double(raw['level']);
    if (level == null || level < 0 || level > 100) return null;

    double? chargeMah;
    final rawCharge = _double(raw['chargeCounter']);
    if (rawCharge != null && rawCharge > 0) {
      chargeMah = rawCharge / 1000;
      // A phone battery is never under ~500 mAh, so a µAh reading that implies
      // one was really reported in mAh.
      if (level >= 5 && chargeMah / (level / 100) < 500) chargeMah = rawCharge;
    }

    double? currentMa;
    final rawCurrent = _double(raw['currentNow'])?.abs();
    if (rawCurrent != null && rawCurrent > 0) {
      // Under 1000 µA (1 mA) is not a plausible draw for an awake phone, so
      // such values were reported in mA.
      currentMa = rawCurrent < 1000 ? rawCurrent : rawCurrent / 1000;
    }

    final rawTemp = _double(raw['temperature']);
    final thermalStatus = _int(raw['thermalStatus']);
    final health = raw['health'];
    return BatteryReading(
      at: at,
      levelPct: level,
      plugged: _bool(raw['plugged']) ?? false,
      chargeMah: chargeMah,
      currentMa: currentMa,
      tempC: rawTemp == null ? null : rawTemp / 10,
      voltageMv: _int(raw['voltage']),
      powerSave: _bool(raw['powerSave']),
      screenOn: _bool(raw['screenOn']),
      thermalStatus:
          thermalStatus != null && thermalStatus >= 0 ? thermalStatus : null,
      thermalHeadroom: _double(raw['thermalHeadroom']),
      cycleCount: _int(raw['cycleCount']),
      health: health is String && health.isNotEmpty ? health : null,
      sdkInt: _int(raw['sdkInt']),
      designCapacityMah: _double(raw['designCapacityMah']),
      brightnessPct: _double(raw['brightnessPct']),
      brightnessAuto: _bool(raw['brightnessAuto']),
      network: _network(raw['network']),
    );
  }

  static const _networks = {'wifi', 'cell', 'ethernet', 'other', 'none'};
  static String? _network(Object? v) =>
      v is String && _networks.contains(v) ? v : null;

  static double? _double(Object? v) =>
      v is num && v.isFinite ? v.toDouble() : null;
  static int? _int(Object? v) => v is num && v.isFinite ? v.toInt() : null;
  static bool? _bool(Object? v) => v is bool ? v : null;

  Map<String, Object?> toJson() => {
        'at': at.millisecondsSinceEpoch,
        'levelPct': levelPct,
        'plugged': plugged,
        'chargeMah': chargeMah,
        'currentMa': currentMa,
        'tempC': tempC,
        'voltageMv': voltageMv,
        'powerSave': powerSave,
        'screenOn': screenOn,
        'thermalStatus': thermalStatus,
        'thermalHeadroom': thermalHeadroom,
        'cycleCount': cycleCount,
        'health': health,
        'sdkInt': sdkInt,
        'designCapacityMah': designCapacityMah,
        'brightnessPct': brightnessPct,
        'brightnessAuto': brightnessAuto,
        'network': network,
      };

  /// Readings persisted by an older build simply lack the newer keys.
  factory BatteryReading.fromJson(Map<String, dynamic> json) => BatteryReading(
        at: DateTime.fromMillisecondsSinceEpoch(_int(json['at']) ?? 0),
        levelPct: _double(json['levelPct']) ?? 0,
        plugged: _bool(json['plugged']) ?? false,
        chargeMah: _double(json['chargeMah']),
        currentMa: _double(json['currentMa']),
        tempC: _double(json['tempC']),
        voltageMv: _int(json['voltageMv']),
        powerSave: _bool(json['powerSave']),
        screenOn: _bool(json['screenOn']),
        thermalStatus: _int(json['thermalStatus']),
        thermalHeadroom: _double(json['thermalHeadroom']),
        cycleCount: _int(json['cycleCount']),
        health: json['health'] is String ? json['health'] as String : null,
        sdkInt: _int(json['sdkInt']),
        designCapacityMah: _double(json['designCapacityMah']),
        brightnessPct: _double(json['brightnessPct']),
        brightnessAuto: _bool(json['brightnessAuto']),
        network: _network(json['network']),
      );
}
