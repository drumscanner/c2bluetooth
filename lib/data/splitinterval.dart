import 'dart:typed_data';

import '../internal/bytes.dart';

/// Sent once when a split or interval finishes.
///
/// Parsed from the Split/Interval Data BLE characteristic (0xCE060037).
class SplitIntervalData {
  Duration elapsedTime;
  double distance;
  Duration splitTime;
  int splitDistance;
  Duration restTime;
  int restDistance;
  int splitType;
  int splitNumber;

  SplitIntervalData.fromBytes(Uint8List data)
      : elapsedTime = centis(u24(data, 0)),
        distance = u24(data, 3) / 10,
        splitTime = tenths(u24(data, 6)),
        splitDistance = u24(data, 9),
        restTime = Duration(seconds: u16(data, 12)),
        restDistance = u16(data, 14),
        splitType = data[16],
        splitNumber = data[17];

  Map<String, Object?> toDataMap() => {
        "split.elapsed_time": elapsedTime,
        "split.distance": distance,
        "split.time": splitTime,
        "split.split_distance": splitDistance,
        "split.rest_time": restTime,
        "split.rest_distance": restDistance,
        "split.type": splitType,
        "split.number": splitNumber,
      };
}

/// Averages for the split or interval that just finished, sent alongside [SplitIntervalData].
///
/// Parsed from the Additional Split/Interval Data BLE characteristic (0xCE060038).
class AdditionalSplitIntervalData {
  Duration elapsedTime;
  int strokeRate;
  int? workHeartRate;
  int? restHeartRate;

  /// Per 500m.
  Duration averagePace;
  int calories;

  /// Calories per hour.
  int averageCalories;

  /// Meters per second.
  double speed;

  /// Watts.
  int power;
  int averageDragFactor;
  int splitNumber;
  int? machineType;

  AdditionalSplitIntervalData.fromBytes(Uint8List data)
      : elapsedTime = centis(u24(data, 0)),
        strokeRate = data[3],
        workHeartRate = readHeartRate(data[4]),
        restHeartRate = readHeartRate(data[5]),
        averagePace = tenths(u16(data, 6)),
        calories = u16(data, 8),
        averageCalories = u16(data, 10),
        speed = u16(data, 12) / 1000,
        power = u16(data, 14),
        averageDragFactor = data[16],
        splitNumber = data[17],
        machineType = data.length > 18 ? data[18] : null;

  Map<String, Object?> toDataMap() => {
        "split.elapsed_time": elapsedTime,
        "split.stroke_rate": strokeRate,
        "split.work_heart_rate": workHeartRate,
        "split.rest_heart_rate": restHeartRate,
        "split.average_pace": averagePace,
        "split.calories": calories,
        "split.average_calories": averageCalories,
        "split.speed": speed,
        "split.power": power,
        "split.average_drag_factor": averageDragFactor,
        "split.number": splitNumber,
        "split.machine_type": machineType,
      };
}
