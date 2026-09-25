import 'dart:typed_data';

import '../internal/bytes.dart';

/// Speed, stroke rate, heart rate and pace, updated continuously while rowing.
///
/// Parsed from the Additional Status 1 BLE characteristic (0xCE060032).
class AdditionalStatus1 {
  Duration elapsedTime;

  /// Meters per second.
  double speed;
  int strokeRate;
  int? heartRate;

  /// Current and average pace, per 500m.
  Duration currentPace;
  Duration averagePace;
  int restDistance;
  Duration restTime;

  AdditionalStatus1.fromBytes(Uint8List data)
      : elapsedTime = centis(u24(data, 0)),
        speed = u16(data, 3) / 1000,
        strokeRate = data[5],
        heartRate = readHeartRate(data[6]),
        currentPace = centis(u16(data, 7)),
        averagePace = centis(u16(data, 9)),
        restDistance = u16(data, 11),
        restTime = centis(u24(data, 13));

  Map<String, Object?> toDataMap() => {
        "status1.elapsed_time": elapsedTime,
        "status1.speed": speed,
        "status1.stroke_rate": strokeRate,
        "status1.heart_rate": heartRate,
        "status1.current_pace": currentPace,
        "status1.average_pace": averagePace,
        "status1.rest_distance": restDistance,
        "status1.rest_time": restTime,
      };
}

/// Interval count, averages and calories for the workout and current split.
///
/// Parsed from the Additional Status 2 BLE characteristic (0xCE060033).
class AdditionalStatus2 {
  Duration elapsedTime;
  int intervalCount;

  /// Watts.
  int averagePower;
  int totalCalories;

  /// Per 500m.
  Duration splitAveragePace;

  /// Watts.
  int splitAveragePower;

  /// Calories per hour.
  int splitAverageCalories;
  Duration lastSplitTime;
  int lastSplitDistance;

  AdditionalStatus2.fromBytes(Uint8List data)
      : elapsedTime = centis(u24(data, 0)),
        intervalCount = data[3],
        averagePower = u16(data, 4),
        totalCalories = u16(data, 6),
        splitAveragePace = centis(u16(data, 8)),
        splitAveragePower = u16(data, 10),
        splitAverageCalories = u16(data, 12),
        lastSplitTime = tenths(u24(data, 14)),
        lastSplitDistance = u24(data, 17);

  Map<String, Object?> toDataMap() => {
        "status2.elapsed_time": elapsedTime,
        "status2.interval_count": intervalCount,
        "status2.average_power": averagePower,
        "status2.total_calories": totalCalories,
        "status2.split_average_pace": splitAveragePace,
        "status2.split_average_power": splitAveragePower,
        "status2.split_average_calories": splitAverageCalories,
        "status2.last_split_time": lastSplitTime,
        "status2.last_split_distance": lastSplitDistance,
      };
}

/// Monitor state: operational state, current screen, last error, game and battery.
///
/// Parsed from the Additional Status 3 BLE characteristic (0xCE06003E), which only newer PM5
/// firmware exposes.
class AdditionalStatus3 {
  int operationalState;
  int verificationState;
  int screenNumber;
  int lastError;
  int gameId;
  int gameScore;

  /// Percent.
  int batteryLevel;

  AdditionalStatus3.fromBytes(Uint8List data)
      : operationalState = data[0],
        verificationState = data[1],
        screenNumber = u16(data, 2),
        lastError = u16(data, 4),
        gameId = data[9],
        gameScore = u16(data, 10),
        batteryLevel = data[12];

  Map<String, Object?> toDataMap() => {
        "status3.operational_state": operationalState,
        "status3.verification_state": verificationState,
        "status3.screen_number": screenNumber,
        "status3.last_error": lastError,
        "status3.game_id": gameId,
        "status3.game_score": gameScore,
        "status3.battery_level": batteryLevel,
      };
}
