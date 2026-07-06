import 'dart:typed_data';

/// Full-scale value for signed 16-bit PCM. Samples in `[-1.0, 1.0]` map to
/// `[-32767, 32767]`, matching the little-endian signed-int16 wire contract
/// shared with the native and web back ends.
const double pcm16FullScale = 32767;

/// Decodes little-endian signed 16-bit PCM [bytes] into doubles in `[-1, 1]`.
///
/// Uses an [Int16List] view when the bytes are 2-byte aligned on a
/// little-endian host (the common case for network buffers), avoiding the
/// per-sample [ByteData] call overhead of the fallback path.
Float64List pcm16BytesToFloat64(Uint8List bytes) {
  final frameCount = bytes.length ~/ 2;
  final samples = Float64List(frameCount);
  if (Endian.host == Endian.little && bytes.offsetInBytes.isEven) {
    final values =
        Int16List.view(bytes.buffer, bytes.offsetInBytes, frameCount);
    for (var i = 0; i < frameCount; i++) {
      samples[i] = values[i] / pcm16FullScale;
    }
    return samples;
  }
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < frameCount; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / pcm16FullScale;
  }
  return samples;
}

/// Encodes [samples] in `[-1, 1]` to little-endian signed 16-bit PCM bytes.
Uint8List float64ToPcm16Bytes(List<double> samples) {
  if (Endian.host == Endian.little) {
    final values = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      values[i] = (samples[i].clamp(-1.0, 1.0) * pcm16FullScale).round();
    }
    return values.buffer.asUint8List();
  }
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    data.setInt16(i * 2, (clamped * pcm16FullScale).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}
