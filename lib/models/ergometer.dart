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

/// Turns one notification's bytes into named data fields, or null if it doesn't complete a
/// data point on its own (e.g. a force curve packet that isn't the curve's last).
typedef _DataParser = Map<String, Object?>? Function(Uint8List bytes);

class Ergometer {
  final BluetoothDevice _device;
  Csafe? _csafeClient;

  // Completes once [connectAndDiscover] has finished discovering services, so that callers who
  // start monitoring characteristics right away (without awaiting connectAndDiscover first, e.g.
  // from a widget's build method) wait for discovery instead of racing it.
  Completer<void> _discoveryComplete = Completer<void>();

  // Every parsed notification from every data characteristic flows through this one stream, so
  // each characteristic is subscribed to exactly once no matter how many listeners there are.
  final StreamController<Map<String, Object?>> _dataHub =
      StreamController<Map<String, Object?>>.broadcast();
  final List<StreamSubscription<List<int>>> _dataHubSubscriptions = [];

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
    await _startDataHub();
  }

  /// Disconnect from this erg or cancel the connection
  Future<void> disconnectOrCancel() async {
    await _stopDataHub();
    return _device.disconnect();
  }

  /// Sets how often the PM5 sends its status notifications. The PM5 defaults to
  /// [ErgSampleRate.ms500] each time it connects.
  Future<void> setSampleRate(ErgSampleRate rate) async {
    await _discoveryComplete.future;
    BluetoothCharacteristic? characteristic = _tryFindCharacteristic(
        Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID,
        Identifiers.C2_ROWING_SAMPLE_RATE_CHARACTERISTIC_UUID);
    await characteristic?.write([rate.value]);
  }

  /// The parser for each data characteristic in the rowing service. Built per connection since
  /// the force curve assemblers carry state between packets.
  Map<String, _DataParser> _createDataParsers() {
    ForceCurveAssembler forceCurve = ForceCurveAssembler();
    ForceCurveAssembler forceCurve2 = ForceCurveAssembler();
    return {
      Identifiers.C2_ROWING_GENERAL_STATUS_CHARACTERISTIC_UUID: (bytes) =>
          GeneralStatus.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_ADDITIONAL_STATUS1_CHARACTERISTIC_UUID: (bytes) =>
          AdditionalStatus1.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_ADDITIONAL_STATUS2_CHARACTERISTIC_UUID: (bytes) =>
          AdditionalStatus2.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_STROKE_DATA_CHARACTERISTIC_UUID: (bytes) =>
          StrokeData.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_ADDITIONAL_STROKE_DATA_CHARACTERISTIC_UUID:
          (bytes) => AdditionalStrokeData.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_SPLIT_INTERVAL_DATA_CHARACTERISTIC_UUID: (bytes) =>
          SplitIntervalData.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_SPLIT_INTERVAL_DATA_CHARACTERISTIC2_UUID: (bytes) =>
          AdditionalSplitIntervalData.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_END_OF_WORKOUT_SUMMARY_CHARACTERISTIC_UUID:
          (bytes) => WorkoutSummary.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_END_OF_WORKOUT_SUMMARY_CHARACTERISTIC2_UUID:
          (bytes) => WorkoutSummary2.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_HEART_RATE_BELT_INFO_CHARACTERISTIC_UUID: (bytes) =>
          HeartRateBeltInfo.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_ADDITIONAL_STATUS3_CHARACTERISTIC_UUID: (bytes) =>
          AdditionalStatus3.fromBytes(bytes).toDataMap(),
      Identifiers.C2_ROWING_FORCE_CURVE_CHARACTERISTIC_UUID: (bytes) {
        List<int>? curve = forceCurve.add(bytes);
        return curve == null ? null : {"force_curve.points": curve};
      },
      Identifiers.C2_ROWING_FORCE_CURVE2_CHARACTERISTIC_UUID: (bytes) {
        List<int>? curve = forceCurve2.add(bytes);
        return curve == null ? null : {"force_curve_v2.points": curve};
      },
    };
  }

  /// Subscribes to every data characteristic this PM5's firmware has, feeding [_dataHub].
  Future<void> _startDataHub() async {
    await _stopDataHub();

    for (MapEntry<String, _DataParser> entry in _createDataParsers().entries) {
      BluetoothCharacteristic? characteristic = _tryFindCharacteristic(
          Identifiers.C2_ROWING_PRIMARY_SERVICE_UUID, entry.key);
      if (characteristic == null || !characteristic.properties.notify) {
        continue;
      }

      _dataHubSubscriptions.add(characteristic.onValueReceived.listen((bytes) {
        // Payload lengths vary across firmware revisions; a packet too short for its parser
        // is dropped rather than erroring the stream every listener shares.
        try {
          Map<String, Object?>? data = entry.value(Uint8List.fromList(bytes));
          if (data != null) {
            _dataHub.add(data);
          }
        } on RangeError {
          return;
        }
      }));
      await characteristic.setNotifyValue(true);
    }
  }

  Future<void> _stopDataHub() async {
    for (StreamSubscription<List<int>> subscription in _dataHubSubscriptions) {
      await subscription.cancel();
    }
    _dataHubSubscriptions.clear();
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

  /// Returns a stream of every data field the erg reports, from every data characteristic in
  /// the rowing service (see [_createDataParsers]). Each emitted [Map] holds the fields of one
  /// notification, keyed by dotted names like "general.distance", "status1.heart_rate",
  /// "split.power" or "force_curve.points".
  ///
  /// Data flows from the moment [connectAndDiscover] completes, whether or not anyone listens.
  Stream<Map<String, Object?>> monitorAllData() => _dataHub.stream;

  /// Like [monitorAllData], restricted to notifications that carry at least one of [dataKeys].
  /// Each emitted [Map] still holds every field of that notification, not only the ones asked for.
  Stream<Map<String, Object?>> monitorForData(Set<String> dataKeys) =>
      _dataHub.stream.where((data) => data.keys.any(dataKeys.contains));

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
        _findCharacteristic(serviceUuid, characteristicUuid);
    await characteristic.setNotifyValue(true);
    yield* characteristic.onValueReceived
        .map((bytes) => Uint8List.fromList(bytes));
  }

  BluetoothCharacteristic _findCharacteristic(
          String serviceUuid, String characteristicUuid) =>
      _tryFindCharacteristic(serviceUuid, characteristicUuid) ??
      (throw StateError(
          "Characteristic $characteristicUuid not found in service $serviceUuid"));

  /// Returns null when this PM5's firmware doesn't have the characteristic.
  BluetoothCharacteristic? _tryFindCharacteristic(
      String serviceUuid, String characteristicUuid) {
    Guid serviceGuid = Guid(serviceUuid);
    Guid characteristicGuid = Guid(characteristicUuid);

    // BluetoothDevice.servicesList only lists primary services - the PM5's "Rowing" service
    // (and others) are declared as secondary/included services in its GATT layout, so they're
    // only reachable through their parent's includedServices.
    List<BluetoothService> allServices = _device.servicesList
        .expand((service) => [service, ...service.includedServices])
        .toList();

    for (BluetoothService service in allServices) {
      if (service.uuid != serviceGuid) {
        continue;
      }
      for (BluetoothCharacteristic characteristic in service.characteristics) {
        if (characteristic.uuid == characteristicGuid) {
          return characteristic;
        }
      }
    }
    return null;
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
    BluetoothCharacteristic characteristic = _findCharacteristic(
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
