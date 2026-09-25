import 'dart:typed_data';

import 'package:c2bluetooth/c2bluetooth.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

// elapsed time 123.45s, in hundredths, little-endian
const elapsed = [0x39, 0x30, 0x00];

void main() {
  test("AdditionalStatus1 parses speed, stroke rate, heart rate and pace", () {
    var status = AdditionalStatus1.fromBytes(bytes([
      ...elapsed,
      0x9A, 0x10, // speed 4.250 m/s
      24, // stroke rate
      150, // heart rate
      0xE6, 0x2D, // current pace 117.50s
      0xE0, 0x2E, // average pace 120.00s
      0x2C, 0x01, // rest distance 300m
      0x70, 0x17, 0x00, // rest time 60.00s
    ]));

    expect(status.elapsedTime, Duration(milliseconds: 123450));
    expect(status.speed, 4.25);
    expect(status.strokeRate, 24);
    expect(status.heartRate, 150);
    expect(status.currentPace, Duration(milliseconds: 117500));
    expect(status.averagePace, Duration(seconds: 120));
    expect(status.restDistance, 300);
    expect(status.restTime, Duration(seconds: 60));
    expect(status.toDataMap()["status1.stroke_rate"], 24);
  });

  test("AdditionalStatus1 treats a heart rate of 255 as no reading", () {
    var status = AdditionalStatus1.fromBytes(
        bytes([...elapsed, 0, 0, 20, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    expect(status.heartRate, isNull);
  });

  test("AdditionalStatus2 parses averages and the last split", () {
    var status = AdditionalStatus2.fromBytes(bytes([
      ...elapsed,
      2, // interval count
      0xD2, 0x00, // average power 210W
      0x39, 0x00, // total calories 57
      0x18, 0x2E, // split average pace 118.00s
      0xCD, 0x00, // split average power 205W
      0x84, 0x03, // split average calories 900/hr
      0xA1, 0x04, 0x00, // last split time 118.5s
      0xF4, 0x01, 0x00, // last split distance 500m
    ]));

    expect(status.intervalCount, 2);
    expect(status.averagePower, 210);
    expect(status.totalCalories, 57);
    expect(status.splitAveragePace, Duration(seconds: 118));
    expect(status.splitAveragePower, 205);
    expect(status.splitAverageCalories, 900);
    expect(status.lastSplitTime, Duration(milliseconds: 118500));
    expect(status.lastSplitDistance, 500);
  });

  test("AdditionalStatus3 parses screen and battery", () {
    var status = AdditionalStatus3.fromBytes(
        bytes([1, 0, 0x05, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 87]));
    expect(status.operationalState, 1);
    expect(status.screenNumber, 5);
    expect(status.batteryLevel, 87);
  });

  test("SplitIntervalData parses a finished split", () {
    var split = SplitIntervalData.fromBytes(bytes([
      ...elapsed,
      0x88, 0x13, 0x00, // distance 500.0m
      0xA1, 0x04, 0x00, // split time 118.5s
      0xF4, 0x01, 0x00, // split distance 500m
      0x3C, 0x00, // rest time 60s
      0x00, 0x00, // rest distance 0m
      1, // type
      1, // number
    ]));

    expect(split.distance, 500.0);
    expect(split.splitTime, Duration(milliseconds: 118500));
    expect(split.splitDistance, 500);
    expect(split.restTime, Duration(seconds: 60));
    expect(split.splitType, 1);
    expect(split.splitNumber, 1);
  });

  test("AdditionalSplitIntervalData parses split averages", () {
    var split = AdditionalSplitIntervalData.fromBytes(bytes([
      ...elapsed,
      26, // stroke rate
      255, // work heart rate: no reading
      120, // rest heart rate
      0xA1, 0x04, // average pace 118.5s
      0x1E, 0x00, // calories 30
      0x20, 0x03, // average calories 800/hr
      0x7B, 0x10, // speed 4.219 m/s
      0xD6, 0x00, // power 214W
      120, // drag factor
      1, // split number
    ]));

    expect(split.strokeRate, 26);
    expect(split.workHeartRate, isNull);
    expect(split.restHeartRate, 120);
    expect(split.averagePace, Duration(milliseconds: 118500));
    expect(split.averageCalories, 800);
    expect(split.speed, 4.219);
    expect(split.power, 214);
    expect(split.averageDragFactor, 120);
    expect(split.machineType, isNull);
  });

  test("HeartRateBeltInfo parses a 32-bit belt id", () {
    var belt = HeartRateBeltInfo.fromBytes(
        bytes([1, 2, 0x78, 0x56, 0x34, 0x12]));
    expect(belt.manufacturerId, 1);
    expect(belt.deviceType, 2);
    expect(belt.beltId, 0x12345678);
  });

  group("ForceCurveAssembler", () {
    // three packets: 2 points, 2 points, 1 point
    final first = bytes([0x32, 0, 10, 0, 20, 0]);
    final second = bytes([0x32, 1, 30, 0, 40, 0]);
    final last = bytes([0x31, 2, 50, 0]);

    test("returns the curve once its last packet arrives", () {
      var assembler = ForceCurveAssembler();
      expect(assembler.add(first), isNull);
      expect(assembler.add(second), isNull);
      expect(assembler.add(last), [10, 20, 30, 40, 50]);
    });

    test("ignores packets from a curve joined partway through", () {
      var assembler = ForceCurveAssembler();
      expect(assembler.add(second), isNull);
      expect(assembler.add(last), isNull);
      expect(assembler.add(first), isNull);
      expect(assembler.add(second), isNull);
      expect(assembler.add(last), [10, 20, 30, 40, 50]);
    });

    test("a packet with sequence 0 restarts the curve", () {
      var assembler = ForceCurveAssembler();
      assembler.add(first);
      assembler.add(second);
      expect(assembler.add(first), isNull);
      expect(assembler.add(second), isNull);
      expect(assembler.add(last), [10, 20, 30, 40, 50]);
    });
  });

  test("WorkoutSummary.toDataMap works without a recovery heart rate", () {
    var summary = WorkoutSummary.fromBytes(bytes(
        [0, 0, 0, 0, 128, 0, 0, 255, 0, 0, 32, 190, 170, 68, 190, 120, 0, 1, 100, 0]));
    var data = summary.toDataMap();
    expect(data["summary.recovery_heart_rate"], isNull);
    expect(data["summary.average_drag_factor"], 120);
  });
}
