import 'package:c2bluetooth/constants.dart' as Identifiers;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ergometer.dart';

class ErgBleManager {
  /// Waits for the platform's Bluetooth adapter to finish powering on.
  ///
  /// Right after the OS grants Bluetooth permission (or on a cold app start), the adapter can
  /// briefly report a state of "unknown" before settling on "on" - starting a scan during that
  /// window fails outright rather than queueing, so callers should await this before scanning.
  Future<void> init() async {
    await FlutterBluePlus.adapterState
        .firstWhere((state) => state == BluetoothAdapterState.on);
  }

  /// Begin scanning for Ergs.
  ///
  /// This begins a scan for bluetooth devices with a filter applied so that only Concept2 Performance Monitors show up.
  /// Bluetooth must be on and adequate permissions must be granted to the app for this to work.
  Stream<Ergometer> startErgScan() {
    FlutterBluePlus.startScan(
      withServices: [Guid(Identifiers.C2_ROWING_BASE_UUID)],
    );

    return FlutterBluePlus.onScanResults
        .expand((results) => results)
        .map((scanResult) => Ergometer(scanResult.device));
  }

  /// Stops scanning for ergs
  Future<void> stopErgScan() {
    return FlutterBluePlus.stopScan();
  }

  /// Clean up/destroy/deallocate resources so that they are availalble again
  Future<void> destroy() {
    return stopErgScan();
  }
}
