import 'dart:typed_data';

/// Full-scale value for signed 16-bit PCM. Samples in `[-1.0, 1.0]` map to
/// `[-32767, 32767]`, matching the little-endian signed-int16 wire contract
/// shared with the native and web back ends.
const double pcm16FullScale = 32767;

/// Decodes little-endian signed 16-bit PCM [bytes] into doubles in `[-1, 1]`.
Float64List pcm16BytesToFloat64(Uint8List bytes) {
  final frameCount = bytes.length ~/ 2;
  final data = ByteData.sublistView(bytes);
  final samples = Float64List(frameCount);
  for (var i = 0; i < frameCount; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / pcm16FullScale;
  }
  return samples;
}

/// Encodes [samples] in `[-1, 1]` to little-endian signed 16-bit PCM bytes.
Uint8List float64ToPcm16Bytes(List<double> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    data.setInt16(i * 2, (clamped * pcm16FullScale).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}
