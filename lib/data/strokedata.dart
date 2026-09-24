import 'dart:typed_data';

import 'package:csafe_fitness/csafe_fitness.dart';

import '../extensions.dart';

/// Per-stroke detail, sent once per stroke while rowing.
///
/// Parsed from the Stroke Data BLE characteristic (0xCE060035). Byte layout comes from the
/// Concept2 PM5 Bluetooth Smart Interface Definition.
class StrokeData {
  Duration elapsedTime;
  double distance;

  /// Length of the drive phase, in meters.
  double driveLength;
  Duration driveTime;
  Duration recoveryTime;

  /// Distance covered during this single stroke, in meters.
  double strokeDistance;

  /// Peak force applied to the handle during the drive, in lbs.
  double peakDriveForce;

  /// Force applied to the handle averaged over the drive, in lbs.
  double averageDriveForce;

  /// Work done on the flywheel during the drive, in joules.
  double workPerStroke;
  int strokeCount;

  StrokeData.fromBytes(Uint8List data)
      : elapsedTime = Concept2DurationExtension.fromBytes(data.sublist(0, 3)),
        distance = CsafeIntExtension.fromBytes(data.sublist(3, 6),
                endian: Endian.little) /
            10,
        driveLength = data.elementAt(6) / 100,
        driveTime = Duration(milliseconds: data.elementAt(7) * 10),
        recoveryTime = Duration(
            milliseconds: CsafeIntExtension.fromBytes(data.sublist(8, 10),
                    endian: Endian.little) *
                10),
        strokeDistance = CsafeIntExtension.fromBytes(data.sublist(10, 12),
                endian: Endian.little) /
            100,
        peakDriveForce = CsafeIntExtension.fromBytes(data.sublist(12, 14),
                endian: Endian.little) /
            10,
        averageDriveForce = CsafeIntExtension.fromBytes(data.sublist(14, 16),
                endian: Endian.little) /
            10,
        workPerStroke = CsafeIntExtension.fromBytes(data.sublist(16, 18),
                endian: Endian.little) /
            10,
        strokeCount = CsafeIntExtension.fromBytes(data.sublist(18, 20),
            endian: Endian.little);

  Map<String, Object?> toDataMap() => {
        "stroke.elapsed_time": elapsedTime,
        "stroke.distance": distance,
        "stroke.drive_length": driveLength,
        "stroke.drive_time": driveTime,
        "stroke.recovery_time": recoveryTime,
        "stroke.distance_per_stroke": strokeDistance,
        "stroke.drive_force.max": peakDriveForce,
        "stroke.drive_force.average": averageDriveForce,
        "stroke.work_per_stroke": workPerStroke,
        "stroke.count": strokeCount,
      };

  @override
  String toString() => "StrokeData("
      "driveLength: $driveLength, "
      "peakDriveForce: $peakDriveForce, "
      "averageDriveForce: $averageDriveForce)";
}

/// Additional per-stroke detail sent alongside [StrokeData], split into a second
/// characteristic because a single BLE notification can't carry both.
///
/// Parsed from the Additional Stroke Data BLE characteristic (0xCE060036).
class AdditionalStrokeData {
  Duration elapsedTime;

  /// Power produced by this stroke, in watts.
  int strokePower;

  /// Calories burned this stroke, expressed as a calories/hour rate.
  int strokeCalories;
  int strokeCount;
  Duration projectedWorkTime;
  int projectedWorkDistance;

  AdditionalStrokeData.fromBytes(Uint8List data)
      : elapsedTime = Concept2DurationExtension.fromBytes(data.sublist(0, 3)),
        strokePower = CsafeIntExtension.fromBytes(data.sublist(3, 5),
            endian: Endian.little),
        strokeCalories = CsafeIntExtension.fromBytes(data.sublist(5, 7),
            endian: Endian.little),
        strokeCount = CsafeIntExtension.fromBytes(data.sublist(7, 9),
            endian: Endian.little),
        projectedWorkTime = Duration(
            seconds: CsafeIntExtension.fromBytes(data.sublist(9, 12),
                endian: Endian.little)),
        projectedWorkDistance = CsafeIntExtension.fromBytes(
            data.sublist(12, 15),
            endian: Endian.little);

  Map<String, Object?> toDataMap() => {
        "stroke.power": strokePower,
        "stroke.calories": strokeCalories,
        "stroke.count": strokeCount,
        "stroke.projected_work_time": projectedWorkTime,
        "stroke.projected_work_distance": projectedWorkDistance,
      };

  @override
  String toString() => "AdditionalStrokeData(strokePower: $strokePower)";
}
