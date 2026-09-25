import 'dart:typed_data';

/// Little-endian readers for the PM5's BLE payloads.
int u16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
int u24(Uint8List b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
int u32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// Durations the PM5 reports in hundredths of a second.
Duration centis(int value) => Duration(milliseconds: value * 10);

/// Durations the PM5 reports in tenths of a second.
Duration tenths(int value) => Duration(milliseconds: value * 100);

/// Heart rate bytes use 0 and 255 to mean "no reading".
int? readHeartRate(int value) => value == 0 || value == 255 ? null : value;
