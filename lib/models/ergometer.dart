import 'dart:async';
import 'dart:typed_data';

import 'package:c2bluetooth/c2bluetooth.dart';
import '../internal/commands.dart';
import '../internal/datatypes.dart';
import 'package:csafe_fitness/csafe_fitness.dart';
import '../helpers.dart';
import 'workout.dart';
import 'package:c2bluetooth/constants.dart' as Identifiers;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rxdart/rxdart.dart';

enum ErgometerConnectionState { connecting, connected, disconnected }

/// Which BLE characteristic a given [Ergometer.monitorForData] key is sourced from.
enum _ErgDataSource { generalStatus, strokeData, additionalStrokeData }

/// Maps every data key supported by [Ergometer.monitorForData] to the characteristic that
/// provides it. See [GeneralStatus.toDataMap], [StrokeData.toDataMap], and
/// [AdditionalStrokeData.toDataMap] for where these keys are produced.
const Map<String, _ErgDataSource> _dataKeySources = {
  "general.elapsed_time": _ErgDataSource.generalStatus,
  "general.distance": _ErgDataSource.generalStatus,
  "general.workout_type": _ErgDataSource.generalStatus,
  "general.interval_type": _ErgDataSource.generalStatus,
  "general.workout_state": _ErgDataSource.generalStatus,
  "general.rowing_state": _ErgDataSource.generalStatus,
  "general.stroke_state": _ErgDataSource.generalStatus,
  "general.total_work_distance": _ErgDataSource.generalStatus,
  "general.workout_duration": _ErgDataSource.generalStatus,
  "general.drag_factor": _ErgDataSource.generalStatus,
  "stroke.elapsed_time": _ErgDataSource.strokeData,
  "stroke.distance": _ErgDataSource.strokeData,
  "stroke.drive_length": _ErgDataSource.strokeData,
  "stroke.drive_time": _ErgDataSource.strokeData,
  "stroke.recovery_time": _ErgDataSource.strokeData,
  "stroke.distance_per_stroke": _ErgDataSource.strokeData,
  "stroke.drive_force.max": _ErgDataSource.strokeData,
  "stroke.drive_force.average": _ErgDataSource.strokeData,
  "stroke.work_per_stroke": _ErgDataSource.strokeData,
  "stroke.count": _ErgDataSource.strokeData,
  "stroke.power": _ErgDataSource.additionalStrokeData,
  "stroke.calories": _ErgDataSource.additionalStrokeData,
  "stroke.projected_work_time": _ErgDataSource.additionalStrokeData,
  "stroke.projected_work_distance": _ErgDataSource.additionalStrokeData,
};

class Ergometer {
  final BluetoothDevice _device;
  Csafe? _csafeClient;

  // Completes once [connectAndDiscover] has finished discovering services, so that callers who
  // start monitoring characteristics right away (without awaiting connectAndDiscover first, e.g.
  // from a widget's build method) wait for discovery instead of racing it.
  Completer<void> _discoveryComplete = Completer<void>();

  /// Get the name of this erg. i.e. "PM5" + serial number
  ///
  /// Returns "Unknown" if the erg does not report a name
  String get name => _device.platformName.isNotEmpty ? _device.platformName : "Unknown";

  /// Create an Ergometer from a FlutterBluePlus device object
  ///
  /// This is mainly intended for internal use
  Ergometer(this._device);

  /// Two [Ergometer]s are equal if they wrap the same underlying device, regardless of which
  /// scan result discovered them - lets callers dedupe repeated scan sightings of the same erg.
  @override
  bool operator ==(Object other) =>
      other is Ergometer && _device.remoteId == other._device.remoteId;

  @override
  int get hashCode => _device.remoteId.hashCode;

  /// Connect to this erg and discover the services and characteristics that it offers
  Future<void> connectAndDiscover() async {
    // Nonprofit use covers this library's personal/community/educational use; see the
    // FlutterBluePlus license for what requires a commercial license.
    await _device.connect(license: License.nonprofit);
    await _device.discoverServices();

    _csafeClient = Csafe(_readCsafe, _writeCsafe);
    _discoveryComplete.complete();
  }

  /// Disconnect from this erg or cancel the connection
  Future<void> disconnectOrCancel() async {
    return _device.disconnect();
  }

  /// Returns a stream of [WorkoutSummary] objects upon completion of any programmed piece or a "just row" piece that is longer than 1 minute.
  Stream<WorkoutSummary> monitorForWorkoutSummary() {
    Stream<Uint8List> ws1 = _monitorCharacteristic(
        Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID,
        Identifiers.C2_ROWING_END_OF_WORKOUT_SUMMARY_CHARACTERISTIC_UUID);

    Stream<Uint8List> ws2 = _monitorCharacteristic(
        Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID,
        Identifiers.C2_ROWING_END_OF_WORKOUT_SUMMARY_CHARACTERISTIC2_UUID);

    return Rx.zip2(ws1, ws2, (Uint8List ws1Result, Uint8List ws2Result) {
      List<int> combinedList = ws1Result.toList();
      combinedList.addAll(ws2Result.toList());
      return WorkoutSummary.fromBytes(Uint8List.fromList(combinedList));
    });
  }

  /// Returns a stream of live data from the erg, restricted to the fields named in [dataKeys].
  ///
  /// Each emitted [Map] carries every field from whichever underlying BLE characteristic just
  /// updated, keyed by dotted names such as "general.distance" or "stroke.power" - not only the
  /// keys that were asked for. Only characteristics needed to cover [dataKeys] are subscribed
  /// to. See [_dataKeySources] for the full list of supported keys.
  Stream<Map<String, Object?>> monitorForData(Set<String> dataKeys) {
    Set<_ErgDataSource> sources = dataKeys
        .map((key) => _dataKeySources[key])
        .whereType<_ErgDataSource>()
        .toSet();

    List<Stream<Map<String, Object?>>> streams = [];

    if (sources.contains(_ErgDataSource.generalStatus)) {
      streams.add(_monitorCharacteristic(
              Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID,
              Identifiers.C2_ROWING_GENERAL_STATUS_CHARACTERISTIC_UUID)
          .map((bytes) => GeneralStatus.fromBytes(bytes).toDataMap()));
    }
    if (sources.contains(_ErgDataSource.strokeData)) {
      streams.add(_monitorCharacteristic(
              Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID,
              Identifiers.C2_ROWING_STROKE_DATA_CHARACTERISTIC_UUID)
          .map((bytes) => StrokeData.fromBytes(bytes).toDataMap()));
    }
    if (sources.contains(_ErgDataSource.additionalStrokeData)) {
      streams.add(_monitorCharacteristic(
              Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID,
              Identifiers.C2_ROWING_ADDITIONAL_STROKE_DATA_CHARACTERISTIC_UUID)
          .map((bytes) => AdditionalStrokeData.fromBytes(bytes).toDataMap()));
    }

    return Rx.merge(streams);
  }

  /// Finds a characteristic among the services discovered by [connectAndDiscover] and streams
  /// its notified values. Enables notifications on first subscription.
  ///
  /// Uses [BluetoothCharacteristic.onValueReceived] rather than `lastValueStream`, which
  /// synthetically replays an empty value to every new subscriber before any real notification
  /// arrives - that empty value would otherwise reach parsers (like the CSAFE frame decoder)
  /// that assume a non-empty payload and crash on it.
  ///
  /// Awaits [_discoveryComplete] first since callers (e.g. a widget's build method) may start
  /// monitoring before awaiting [connectAndDiscover] themselves.
  Stream<Uint8List> _monitorCharacteristic(
      String serviceUuid, String characteristicUuid) async* {
    await _discoveryComplete.future;
    BluetoothCharacteristic characteristic =
        await _findCharacteristic(serviceUuid, characteristicUuid);
    await characteristic.setNotifyValue(true);
    yield* characteristic.onValueReceived
        .map((bytes) => Uint8List.fromList(bytes));
  }

  Future<BluetoothCharacteristic> _findCharacteristic(
      String serviceUuid, String characteristicUuid) async {
    Guid serviceGuid = Guid(serviceUuid);
    Guid characteristicGuid = Guid(characteristicUuid);

    // BluetoothDevice.servicesList only lists primary services - the PM5's "Rowing" service
    // (and others) are declared as secondary/included services in its GATT layout, so they're
    // only reachable through their parent's includedServices.
    List<BluetoothService> allServices = _device.servicesList
        .expand((service) => [service, ...service.includedServices])
        .toList();

    BluetoothService service =
        allServices.firstWhere((service) => service.uuid == serviceGuid);

    return service.characteristics
        .firstWhere((characteristic) => characteristic.uuid == characteristicGuid);
  }

  /// Expose a stream of events to enable monitoring the erg's connection state
  /// This acts as a wrapper around the state provided by the internal bluetooth library to aid with swapping it out later.
  Stream<ErgometerConnectionState> monitorConnectionState() {
    return _device.connectionState.map((connectionState) {
      switch (connectionState) {
        case BluetoothConnectionState.connected:
          return ErgometerConnectionState.connected;
        case BluetoothConnectionState.disconnected:
          return ErgometerConnectionState.disconnected;
      }
    });
  }

  /// A read function for the PM over bluetooth.
  ///
  /// Intended for passing to the csafe_fitness library to allow it to read data from the erg
  Stream<Uint8List> _readCsafe() {
    return _monitorCharacteristic(Identifiers.C2_ROWING_CONTROL_SERVICE_UUID,
        Identifiers.C2_ROWING_PM_TRANSMIT_CHARACTERISTIC_UUID);
  }

  /// A write function for the PM over bluetooth.
  ///
  /// Intended for passing to the csafe_fitness library to allow it to write data to the erg
  Future<void> _writeCsafe(Uint8List value) async {
    BluetoothCharacteristic characteristic = await _findCharacteristic(
        Identifiers.C2_ROWING_CONTROL_SERVICE_UUID,
        Identifiers.C2_ROWING_PM_RECEIVE_CHARACTERISTIC_UUID);
    await characteristic.write(value, withoutResponse: true);
  }

  @Deprecated("This is a temporary function for development/experimentation and will be gone very soon")
  void configure2kWorkout() async {
    //Workout workout
    await _csafeClient!.sendCommands([
      CsafeCmdSetHorizontal(CsafeIntegerWithUnits.kilometers(2))
    ]).then((value) => print(value));
//(CSAFE_SETUSERCFG1_CMD, CSAFE_PM_SET_SPLITDURATION, distance, 500m)
    await _csafeClient!.sendCommands([
      CsafeCmdUserCfg1(
          Uint8List.fromList([0x05, 0x05, 0x80, 0xF4, 0x01, 0x00, 0x00])
              .asCsafe())
    ]).then((value) => print(value));

    await _csafeClient!.sendCommands([
      CsafeCmdSetPower(CsafeIntegerWithUnits.watts(300))
    ]).then((value) => print(value));

    //(CSAFE_SETPROGRAM_CMD, programmed workout)
    await _csafeClient!.sendCommands([
      CsafeCmdSetProgram(Uint8List.fromList([0x00, 0x00]).asCsafe())
    ]).then((value) => print(value));

    await _csafeClient!
        .sendCommands([cmdGoInUse]).then((value) => print(value));
  }

  @Deprecated(
      "This is a temporary function for development/experimentation and will be gone very soon")
  void configure10kWorkout() async {
    //(CSAFE_SETPROGRAM_CMD, standard list workout #1)
    await _csafeClient!.sendCommands([
      CsafeCmdSetProgram(Uint8List.fromList([0x03, 0x00]).asCsafe())
    ]).then((value) => print(value));
    await _csafeClient!
        .sendCommands([cmdGoInUse]).then((value) => print(value));
  }

  /// Program a workout into the PM with particular parameters
  ///
  ///Currently only the more basic of workout types are supported, such as basic single intervals, single distance, and single time pieces
  void configureWorkout(Workout workout, [bool startImmediately = true]) async {
    //Workout workout

    List<WorkoutType> unimplementedWorkouts = [
      WorkoutType.JUSTROW_NOSPLITS,
      WorkoutType.JUSTROW_SPLITS,
      WorkoutType.FIXED_WATTMINUTES,
      WorkoutType.FIXED_CALORIE,
      WorkoutType.FIXEDCALS_INTERVAL,
      WorkoutType.VARIABLE_INTERVAL,
      WorkoutType.VARIABLE_UNDEFINEDREST_INTERVAL
    ];
    if (unimplementedWorkouts.contains(workout.getC2WorkoutType())) {
      throw new FormatException(
          "The workout type ${workout.getC2WorkoutType()} is not yet supported");
    }

    bool shouldUseC2ProprietaryAPI = workout.isInterval ||
        workout.goalTypes.contains(DurationType.CALORIES) ||
        workout.goalTypes.contains(DurationType.WATTMIN);

    if (shouldUseC2ProprietaryAPI) {
      _configureProprietaryWorkout(
          workout, startImmediately = startImmediately);
      return;
    }

    List<CsafeCommand> commands = [];
    //at this point there should be one and only one goal defined
    if (workout.goals.first.type == DurationType.DISTANCE) {
      //for fixed distance workouts
      commands.add(
          CsafeCmdSetHorizontalGoal(workout.goals.first.asCsafeDistance()));
    } else if (workout.goals.first.type == DurationType.TIME) {
      // fixed time workouts
      commands
          .add(CsafeCmdSetTimeGoal(workout.goals.first.asDuration().asCsafe()));
    }

    if (workout.hasSplits) {
      commands
          .add(CsafeCmdUserCfg1(CsafePMSetSplitDuration(workout.splitLength!)));
    }

    if (workout.targetPacePer500 != null) {
      commands.add(CsafeCmdSetPower(CsafeIntegerWithUnits(
          splitToWatts(workout.targetPacePer500!), CsafeUnits.watts)));
    }

    commands.add(CsafeCmdSetProgram(Concept2WorkoutPreset.programmed()));

    await _csafeClient!.sendCommands(commands).then((value) => print(value));

    if (startImmediately) {
      _startWorkout();
    }
  }

  void _startWorkout() async {
    await _csafeClient!
        .sendCommands([cmdGoInUse]).then((value) => print(value));
  }

  void _startWorkoutProprietary() async {
    await _csafeClient!.sendCommands([
      C2ProprietaryWrapper(
          [CsafePMSetScreenState(WorkoutScreenValue.PREPARETOROWWORKOUT)])
    ]).then((value) => print(value));
  }

  void _configureProprietaryWorkout(Workout workout,
      [bool startImmediately = true]) async {
    List<Concept2Command> commands = [];

    commands.add(CsafePMSetWorkoutType(workout.getC2WorkoutType()));

    if (workout.isInterval) {
      // for each interval
      commands.add(CsafePmSetWorkoutDuration(workout.goals.first.toC2()));
      commands.add(CsafePmSetWorkoutDuration(workout.rests.first.toC2()));
    } else {
      // if (workout.goals.first.type == DurationType.CALORIES) {
      //   commands.add(CsafePmSetWorkoutDuration(workout.goals.first.))
      // } else if (workout.goals.first.type == DurationType.WATTMIN) {}
    }

    if (workout.hasSplits) {
      commands.add(CsafePMSetSplitDuration(workout.splitLength!));
    }

    await _sendProprietaryCommands(commands);

    if (startImmediately) {
      _startWorkoutProprietary();
    }
  }

  Future<List<CsafeCommandResponse>> _sendProprietaryCommands(
      List<Concept2Command> commands) async {
    // wrap each command in an individual proprietary wrapper so that its more likely to fit within the 20 byte limit for messages sent to and from the Erg.
    return _csafeClient!
        .sendCommands(commands.map((e) => C2ProprietaryWrapper([e])).toList());
    // .then((value) => print(value));
  }
}
