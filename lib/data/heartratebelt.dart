import 'dart:typed_data';

import '../internal/bytes.dart';

/// The heart rate monitor the PM5 is paired with.
///
/// Parsed from the Heart Rate Belt Info BLE characteristic (0xCE06003B).
class HeartRateBeltInfo {
  int manufacturerId;
  int deviceType;
  int beltId;

  HeartRateBeltInfo.fromBytes(Uint8List data)
      : manufacturerId = data[0],
        deviceType = data[1],
        beltId = u32(data, 2);

  Map<String, Object?> toDataMap() => {
        "hrbelt.manufacturer_id": manufacturerId,
        "hrbelt.device_type": deviceType,
        "hrbelt.belt_id": beltId,
      };
}
