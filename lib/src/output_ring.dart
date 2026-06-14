import 'dart:math' as math;
import 'dart:typed_data';

/// Single-producer single-consumer Float32 ring buffer with O(1) writes and
/// a linear-interpolating resampled drain.
///
/// Replaces the previous growable `List<double>` output queue, whose
/// per-sample `removeAt(0)` made the audio callback O(n^2) and caused
/// dropouts on the web under load.
class OutputRing {
  OutputRing(int minCapacity) : _buffer = Float32List(_nextPow2(minCapacity)) {
    _mask = _buffer.length - 1;
  }

  final Float32List _buffer;
  late final int _mask;

  int _head = 0; // next write index
  int _tail = 0; // next read position (integer part)
  double _fraction = 0; // fractional read position for resampling
  double _previousSample = 0;

  /// Frames discarded because the ring was full.
  int droppedFrames = 0;

  int get capacity => _buffer.length;

  int get available => _head - _tail;

  /// Writes [data], dropping any frames that do not fit.
  /// Returns the number of frames accepted.
  int write(List<double> data) {
    final free = capacity - available;
    final accepted = math.min(data.length, free);

    for (var i = 0; i < accepted; i++) {
      _buffer[(_head + i) & _mask] = data[i];
    }
    _head += accepted;
    droppedFrames += data.length - accepted;
    return accepted;
  }

  /// Fills [dest] with [count] frames, consuming ring frames at [ratio]
  /// source frames per output frame (sourceRate / outputRate) with linear
  /// interpolation. Underruns produce silence.
  void readResampled(Float32List dest, int count, double ratio) {
    for (var i = 0; i < count; i++) {
      if (available <= 0) {
        dest[i] = 0;
        continue;
      }

      final current = _buffer[_tail & _mask];
      dest[i] = _previousSample + (current - _previousSample) * _fraction;

      _fraction += ratio;
      while (_fraction >= 1.0 && available > 0) {
        _previousSample = _buffer[_tail & _mask];
        _tail++;
        _fraction -= 1.0;
      }
    }
  }

  void clear() {
    _head = 0;
    _tail = 0;
    _fraction = 0;
    _previousSample = 0;
    droppedFrames = 0;
  }

  static int _nextPow2(int value) {
    var result = 1;
    while (result < value) {
      result <<= 1;
    }
    return result;
  }
}
