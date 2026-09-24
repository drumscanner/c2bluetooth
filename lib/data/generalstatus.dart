import 'dart:typed_data';

import 'package:csafe_fitness/csafe_fitness.dart';

import '../extensions.dart';

/// Represents the erg's live "general status", which updates continuously while rowing.
///
/// Parsed from the General Status BLE characteristic (0xCE060031). Byte layout comes from
/// the Concept2 PM5 Bluetooth Smart Interface Definition.
class GeneralStatus {
  Duration elapsedTime;
  double distance;
  int workoutType;
  int intervalType;
  int workoutState;
  int rowingState;
  int strokeState;
  int totalWorkDistance;
  int workoutDurationType;

  /// Only meaningful when [workoutDurationType] is time-based (0); null otherwise, since the
  /// erg reuses this field for a distance or calorie count depending on the workout's goal.
  Duration? workoutDuration;

  int dragFactor;

  GeneralStatus.fromBytes(Uint8List data)
      : elapsedTime = Concept2DurationExtension.fromBytes(data.sublist(0, 3)),
        distance = CsafeIntExtension.fromBytes(data.sublist(3, 6),
                endian: Endian.little) /
            10,
        workoutType = data.elementAt(6),
        intervalType = data.elementAt(7),
        workoutState = data.elementAt(8),
        rowingState = data.elementAt(9),
        strokeState = data.elementAt(10),
        totalWorkDistance = CsafeIntExtension.fromBytes(data.sublist(11, 14),
            endian: Endian.little),
        workoutDurationType = data.elementAt(17),
        dragFactor = data.elementAt(18) {
    workoutDuration = workoutDurationType == 0
        ? Concept2DurationExtension.fromBytes(data.sublist(14, 17))
        : null;
  }

  Map<String, Object?> toDataMap() => {
        "general.elapsed_time": elapsedTime,
        "general.distance": distance,
        "general.workout_type": workoutType,
        "general.interval_type": intervalType,
        "general.workout_state": workoutState,
        "general.rowing_state": rowingState,
        "general.stroke_state": strokeState,
        "general.total_work_distance": totalWorkDistance,
        "general.workout_duration": workoutDuration,
        "general.drag_factor": dragFactor,
      };

  @override
  String toString() => "GeneralStatus("
      "elapsedTime: $elapsedTime, "
      "distance: $distance, "
      "dragFactor: $dragFactor)";
}
