import 'package:battery_insights/src/models/battery_reading.dart';
import 'package:battery_insights/src/models/capacity_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

BatteryReading _r(double level, double? charge, {bool plugged = false}) =>
    BatteryReading(
      at: DateTime(2026),
      levelPct: level,
      plugged: plugged,
      chargeMah: charge,
    );

void main() {
  test('needs three clean samples before it answers', () {
    final e = CapacityEstimator();
    expect(e.add(_r(90, 4500)), isTrue);
    expect(e.add(_r(89, 4450)), isTrue);
    expect(e.capacityMah, isNull);
    expect(e.add(_r(88, 4400)), isTrue);
    expect(e.capacityMah, 5000);
  });

  test('the median ignores a jittery outlier', () {
    final e = CapacityEstimator();
    for (final (level, charge) in [
      (90.0, 4500.0),
      (89.0, 4450.0),
      (88.0, 4750.0), // one reading 8 % high
      (87.0, 4350.0),
      (86.0, 4300.0),
    ]) {
      e.add(_r(level, charge));
    }
    expect(e.capacityMah, 5000);
  });

  test('skips charging, low charge, repeats of a level and nonsense', () {
    final e = CapacityEstimator();
    expect(e.add(_r(90, 4500, plugged: true)), isFalse);
    expect(e.add(_r(30, 1600)), isFalse);
    expect(e.add(_r(90, null)), isFalse);
    expect(e.add(_r(90, 100)), isFalse); // implies 111 mAh
    expect(e.add(_r(90, 4500)), isTrue);
    expect(e.add(_r(90, 4510)), isFalse); // same level again
    expect(e.sampleCount, 1);
  });

  test('keeps a bounded window and survives persistence', () {
    final e = CapacityEstimator();
    for (var i = 0; i < 40; i++) {
      e.add(_r(99.0 - (i % 45), (99.0 - (i % 45)) * 50));
    }
    expect(e.sampleCount, CapacityEstimator.maxSamples);
    final back = CapacityEstimator.fromJson(e.toJson());
    expect(back.capacityMah, e.capacityMah);
    expect(CapacityEstimator.fromJson({'samples': 'junk'}).sampleCount, 0);
  });
}
