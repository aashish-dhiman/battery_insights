import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/battery_reading.dart';

/// Source of [BatteryReading]s. Swapped for a fake in tests.
abstract class BatteryProbe {
  Future<BatteryReading?> read();
}

/// Reads the battery through the Android plugin. Returns null off Android or
/// when the read fails — callers treat that as "no reading this time".
class PlatformBatteryProbe implements BatteryProbe {
  const PlatformBatteryProbe();

  static const MethodChannel _channel = MethodChannel('battery_insights');

  @override
  Future<BatteryReading?> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('read');
      if (raw == null) return null;
      return BatteryReading.fromPlatform(raw, DateTime.now());
    } catch (_) {
      return null;
    }
  }
}
