import 'dart:typed_data';

import '../internal/bytes.dart';

/// Reassembles a stroke's force curve, which the PM5 sends split across several notifications
/// on the Force Curve characteristic (0xCE06003D, and 0xCE060043 on newer firmware).
///
/// Each packet's first byte holds the total packet count in its high nibble and the number of
/// 16-bit points in this packet in its low nibble; the second byte is the sequence number.
class ForceCurveAssembler {
  final List<int> _points = [];
  int? _expectedPackets;
  int _receivedPackets = 0;

  /// Adds one packet, returning the full curve once its last packet arrives and null otherwise.
  ///
  /// A curve always starts at sequence 0, so packets that arrive before one (e.g. from joining
  /// mid-stroke) are ignored.
  List<int>? add(Uint8List packet) {
    if (packet.length < 2) {
      return null;
    }

    int totalPackets = packet[0] >> 4;
    int pointCount = packet[0] & 0x0F;
    if (packet[1] == 0) {
      _points.clear();
      _receivedPackets = 0;
      _expectedPackets = totalPackets;
    }
    if (_expectedPackets == null) {
      return null;
    }

    for (int i = 0; i < pointCount && 3 + 2 * i < packet.length; i++) {
      _points.add(u16(packet, 2 + 2 * i));
    }
    _receivedPackets++;

    if (_receivedPackets < _expectedPackets!) {
      return null;
    }
    List<int> curve = List.of(_points);
    _points.clear();
    _receivedPackets = 0;
    _expectedPackets = null;
    return curve;
  }
}
