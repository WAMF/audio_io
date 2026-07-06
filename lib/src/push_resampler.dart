import 'dart:typed_data';

/// Stateful linear resampler used on the push path when the AudioContext
/// runs at a rate other than the 48 kHz contract rate.
class PushResampler {
  PushResampler(this.sourceRate, this.targetRate) : _phase = targetRate;

  final int sourceRate;
  final int targetRate;

  double _previous = 0;

  /// Position between [_previous] and the next input sample, in units of
  /// 1/[targetRate] of an input-sample interval; starts at [targetRate]
  /// so the first input is consumed without producing output.
  int _phase;

  Float32List process(List<double> input) {
    if (sourceRate == targetRate) {
      return input is Float32List ? input : Float32List.fromList(input);
    }

    final out = Float32List(input.length * targetRate ~/ sourceRate + 2);
    var written = 0;
    for (var i = 0; i < input.length; i++) {
      final sample = input[i];
      while (_phase < targetRate) {
        out[written++] =
            _previous + (sample - _previous) * (_phase / targetRate);
        _phase += sourceRate;
      }
      _phase -= targetRate;
      _previous = sample;
    }
    return Float32List.sublistView(out, 0, written);
  }
}
