import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/material.dart';

class _SineWaveConstants {
  static const defaultFrequency = 440.0;
  static const minFrequency = 20.0;
  static const maxFrequency = 2000.0;
  static const defaultSampleRate = 48000.0;
  static const defaultAmplitude = 0.3;
  static const defaultLatency = AudioIoLatency.Balanced;
  static const defaultBufferStrategy = AudioBufferStrategy.lowLatency;
  static const bufferHistoryLength = 100;
  static const graphHeight = 60.0;
}

abstract class _AudioCommand {}

class _StartCommand extends _AudioCommand {
  _StartCommand({
    required this.frequency,
    required this.amplitude,
    required this.sampleRate,
    required this.frameSizeFrames,
    required this.bufferThreshold,
  });
  final double frequency;
  final double amplitude;
  final double sampleRate;
  final int frameSizeFrames;
  final double bufferThreshold;
}

class _StopCommand extends _AudioCommand {}

class _UpdateParamsCommand extends _AudioCommand {
  _UpdateParamsCommand({
    required this.frequency,
    required this.amplitude,
    required this.bufferThreshold,
    required this.frameSizeFrames,
  });
  final double frequency;
  final double amplitude;
  final double bufferThreshold;
  final int frameSizeFrames;
}

class _BufferStatusCommand extends _AudioCommand {
  _BufferStatusCommand({
    required this.availableFrames,
    required this.capacityFrames,
  });
  final int availableFrames;
  final int capacityFrames;
}

abstract class _AudioEvent {}

class _SamplesEvent extends _AudioEvent {
  _SamplesEvent(this.samples);
  final Float64List samples;
}

class _StatsEvent extends _AudioEvent {
  _StatsEvent({
    required this.fillPercent,
    required this.latencyMs,
    required this.framesGenerated,
  });
  final int fillPercent;
  final double latencyMs;
  final int framesGenerated;
}

class _AudioGeneratorState {
  double frequency = _SineWaveConstants.defaultFrequency;
  double amplitude = _SineWaveConstants.defaultAmplitude;
  double sampleRate = _SineWaveConstants.defaultSampleRate;
  int frameSizeFrames = 4800;
  double bufferThreshold = 0.5;
  double phase = 0;
  int framesGenerated = 0;
  bool isRunning = false;
}

void _audioGeneratorEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  final state = _AudioGeneratorState();

  receivePort.listen((message) {
    if (message is _StartCommand) {
      state
        ..frequency = message.frequency
        ..amplitude = message.amplitude
        ..sampleRate = message.sampleRate
        ..frameSizeFrames = message.frameSizeFrames
        ..bufferThreshold = message.bufferThreshold
        ..phase = 0
        ..framesGenerated = 0
        ..isRunning = true;

      final primeFrames = state.frameSizeFrames * 3;
      final samples = _generateSineWave(state, primeFrames);
      mainSendPort.send(_SamplesEvent(samples));
    } else if (message is _StopCommand) {
      state.isRunning = false;
    } else if (message is _UpdateParamsCommand) {
      state
        ..frequency = message.frequency
        ..amplitude = message.amplitude
        ..bufferThreshold = message.bufferThreshold
        ..frameSizeFrames = message.frameSizeFrames;
    } else if (message is _BufferStatusCommand) {
      if (!state.isRunning) return;

      final capacityFrames = message.capacityFrames;
      final availableFrames = message.availableFrames;
      final fillRatio = capacityFrames > 0 ? availableFrames / capacityFrames : 0.0;
      final spaceAvailable = capacityFrames - availableFrames;

      final fillPercent = (fillRatio * 100).toInt();
      final latencyMs = (availableFrames / state.sampleRate) * 1000;

      mainSendPort.send(_StatsEvent(
        fillPercent: fillPercent,
        latencyMs: latencyMs,
        framesGenerated: state.framesGenerated,
      ));

      if (fillRatio >= state.bufferThreshold) return;

      final framesToGenerate =
          state.frameSizeFrames < spaceAvailable ? state.frameSizeFrames : spaceAvailable;
      if (framesToGenerate > 0) {
        final samples = _generateSineWave(state, framesToGenerate);
        mainSendPort.send(_SamplesEvent(samples));
      }
    }
  });
}

Float64List _generateSineWave(_AudioGeneratorState state, int frameCount) {
  final samples = Float64List(frameCount);
  final phaseIncrement = 2 * pi * state.frequency / state.sampleRate;

  for (var i = 0; i < frameCount; i++) {
    samples[i] = state.amplitude * sin(state.phase);
    state.phase += phaseIncrement;
    if (state.phase >= 2 * pi) {
      state.phase -= 2 * pi;
    }
  }

  state.framesGenerated += frameCount;
  return samples;
}

class SineWaveScreen extends StatefulWidget {
  const SineWaveScreen({super.key});

  @override
  State<SineWaveScreen> createState() => _SineWaveScreenState();
}

class _SineWaveScreenState extends State<SineWaveScreen> {
  double _frequency = _SineWaveConstants.defaultFrequency;
  double _amplitude = _SineWaveConstants.defaultAmplitude;
  double _sampleRate = _SineWaveConstants.defaultSampleRate;
  bool _isPlaying = false;
  String _status = 'Stopped';
  int _bufferFillPercent = 0;
  double _bufferLatencyMs = 0;
  int _framesGenerated = 0;
  final List<double> _bufferHistory = [];
  AudioIoLatency _latency = _SineWaveConstants.defaultLatency;
  AudioBufferStrategy _bufferStrategy =
      _SineWaveConstants.defaultBufferStrategy;

  double get _frameSizeSeconds => audioIoFrameSizeSeconds[_latency]!;
  int get _frameSizeFrames => (_sampleRate * _frameSizeSeconds).toInt();
  double get _bufferThreshold => audioBufferStrategyThreshold[_bufferStrategy]!;

  StreamSubscription<AudioBufferStatus>? _bufferStatusSubscription;
  Isolate? _audioIsolate;
  SendPort? _audioSendPort;
  ReceivePort? _audioReceivePort;
  Timer? _uiUpdateTimer;
  int _pendingFillPercent = 0;
  double _pendingLatencyMs = 0;
  int _pendingFramesGenerated = 0;
  bool _hasStatsUpdate = false;

  @override
  void dispose() {
    _stopAudio();
    super.dispose();
  }

  Future<void> _startAudio() async {
    if (_isPlaying) return;

    try {
      await AudioIo.instance.requestLatency(_latency);
      await AudioIo.instance.start();

      final format = await AudioIo.instance.getFormat();
      if (format != null && format['output'] != null) {
        final outputFormat = format['output'] as Map<String, dynamic>;
        _sampleRate = (outputFormat['sampleRate'] as num).toDouble();
      }

      _audioReceivePort = ReceivePort();
      _audioIsolate = await Isolate.spawn(
        _audioGeneratorEntry,
        _audioReceivePort!.sendPort,
      );

      final completer = Completer<SendPort>();
      _audioReceivePort!.listen((message) {
        if (message is SendPort) {
          completer.complete(message);
        } else if (message is _SamplesEvent) {
          AudioIo.instance.output.add(message.samples);
        } else if (message is _StatsEvent) {
          _bufferHistory.add(message.fillPercent / 100.0);
          if (_bufferHistory.length > _SineWaveConstants.bufferHistoryLength) {
            _bufferHistory.removeAt(0);
          }
          _pendingFillPercent = message.fillPercent;
          _pendingLatencyMs = message.latencyMs;
          _pendingFramesGenerated = message.framesGenerated;
          _hasStatsUpdate = true;
        }
      });

      _audioSendPort = await completer.future;

      _audioSendPort!.send(_StartCommand(
        frequency: _frequency,
        amplitude: _amplitude,
        sampleRate: _sampleRate,
        frameSizeFrames: _frameSizeFrames,
        bufferThreshold: _bufferThreshold,
      ));

      _bufferStatusSubscription =
          AudioIo.instance.bufferStatus.listen(_onBufferStatus);

      _uiUpdateTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _updateUi(),
      );

      setState(() {
        _isPlaying = true;
        _status = 'Playing ${_frequency.toInt()} Hz';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  void _onBufferStatus(AudioBufferStatus status) {
    _audioSendPort?.send(_BufferStatusCommand(
      availableFrames: status.availableFrames,
      capacityFrames: status.capacityFrames,
    ));
  }

  void _updateUi() {
    if (!_hasStatsUpdate || !mounted) return;
    _hasStatsUpdate = false;
    setState(() {
      _bufferFillPercent = _pendingFillPercent;
      _bufferLatencyMs = _pendingLatencyMs;
      _framesGenerated = _pendingFramesGenerated;
    });
  }

  Future<void> _stopAudio() async {
    if (!_isPlaying) return;

    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;

    _bufferStatusSubscription?.cancel();
    _bufferStatusSubscription = null;

    _audioSendPort?.send(_StopCommand());
    _audioIsolate?.kill(priority: Isolate.immediate);
    _audioIsolate = null;
    _audioSendPort = null;
    _audioReceivePort?.close();
    _audioReceivePort = null;

    await AudioIo.instance.stop();

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _status = 'Stopped';
        _bufferFillPercent = 0;
      });
    }
  }

  void _onFrequencyChanged(double value) {
    setState(() {
      _frequency = value;
      if (_isPlaying) {
        _status = 'Playing ${_frequency.toInt()} Hz';
        _audioSendPort?.send(_UpdateParamsCommand(
          frequency: _frequency,
          amplitude: _amplitude,
          bufferThreshold: _bufferThreshold,
          frameSizeFrames: _frameSizeFrames,
        ));
      }
    });
  }

  void _onAmplitudeChanged(double value) {
    setState(() {
      _amplitude = value;
      if (_isPlaying) {
        _audioSendPort?.send(_UpdateParamsCommand(
          frequency: _frequency,
          amplitude: _amplitude,
          bufferThreshold: _bufferThreshold,
          frameSizeFrames: _frameSizeFrames,
        ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sine Wave Generator'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildFrameSizeControl(),
            const SizedBox(height: 16),
            _buildBufferStrategyControl(),
            const SizedBox(height: 16),
            _buildFrequencyControl(),
            const SizedBox(height: 16),
            _buildAmplitudeControl(),
            const SizedBox(height: 16),
            _buildBufferStatus(),
            const SizedBox(height: 24),
            _buildControls(),
            const SizedBox(height: 16),
            _buildStats(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _isPlaying ? Icons.volume_up : Icons.volume_off,
              size: 32,
              color: _isPlaying ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _status,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'Sample Rate: ${_sampleRate.toInt()} Hz',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrameSizeControl() {
    final frameSizeMs = (_frameSizeSeconds * 1000).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Chunk Size'),
                Text('${frameSizeMs}ms per generation'),
              ],
            ),
            Text(
              'Amount of audio generated each time buffer needs refilling',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: AudioIoLatency.values
                  .map(
                    (latency) => ChoiceChip(
                      label: Text(latency.name),
                      selected: _latency == latency,
                      onSelected: _isPlaying
                          ? null
                          : (selected) {
                              if (selected) {
                                setState(() {
                                  _latency = latency;
                                });
                              }
                            },
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferStrategyControl() {
    final thresholdPercent = (_bufferThreshold * 100).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Buffer Target'),
                Text('Refill when < $thresholdPercent%'),
              ],
            ),
            Text(
              'Lower = less latency but higher underrun risk',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: AudioBufferStrategy.values
                  .map(
                    (strategy) => ChoiceChip(
                      label: Text(strategy.name),
                      selected: _bufferStrategy == strategy,
                      onSelected: _isPlaying
                          ? null
                          : (selected) {
                              if (selected) {
                                setState(() {
                                  _bufferStrategy = strategy;
                                });
                              }
                            },
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrequencyControl() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Frequency'),
                Text('${_frequency.toInt()} Hz'),
              ],
            ),
            Slider(
              value: _frequency,
              min: _SineWaveConstants.minFrequency,
              max: _SineWaveConstants.maxFrequency,
              onChanged: _onFrequencyChanged,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildFrequencyPreset('A4', 440),
                _buildFrequencyPreset('C5', 523),
                _buildFrequencyPreset('E5', 659),
                _buildFrequencyPreset('G5', 784),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrequencyPreset(String label, int freq) {
    return TextButton(
      onPressed: () => _onFrequencyChanged(freq.toDouble()),
      child: Text(label),
    );
  }

  Widget _buildAmplitudeControl() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Volume'),
                Text('${(_amplitude * 100).toInt()}%'),
              ],
            ),
            Slider(
              value: _amplitude,
              min: 0,
              max: 1,
              onChanged: _onAmplitudeChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferStatus() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Buffer Status'),
                Text('$_bufferFillPercent%'),
              ],
            ),
            Text(
              'Queued: ${_bufferLatencyMs.toStringAsFixed(0)}ms • '
              'Total latency: ${(_bufferLatencyMs + _frameSizeSeconds * 1000).toStringAsFixed(0)}ms',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: _SineWaveConstants.graphHeight,
              child: CustomPaint(
                size: Size.infinite,
                painter: _BufferGraphPainter(
                  history: _bufferHistory,
                  threshold: _bufferThreshold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isPlaying ? null : _startAudio,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isPlaying ? _stopAudio : null,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStats() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Statistics',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text('Frames Generated: $_framesGenerated'),
            Text(
                'Duration: ${(_framesGenerated / _sampleRate).toStringAsFixed(1)}s'),
          ],
        ),
      ),
    );
  }
}

class _BufferGraphPainter extends CustomPainter {
  _BufferGraphPainter({
    required this.history,
    required this.threshold,
  });

  final List<double> history;
  final double threshold;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..color = Colors.grey.shade200
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    if (history.isEmpty) return;

    final thresholdY = size.height * (1 - threshold);
    final thresholdPaint = Paint()
      ..color = Colors.blue.withAlpha(128)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, thresholdY),
      Offset(size.width, thresholdY),
      thresholdPaint,
    );

    final stepX = size.width / _SineWaveConstants.bufferHistoryLength;
    final linePaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (var i = 0; i < history.length; i++) {
      final fillRatio = history[i].clamp(0.0, 1.0);
      final x = i * stepX;
      final y = size.height * (1 - fillRatio);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final lastFillRatio = history.last.clamp(0.0, 1.0);
    if (lastFillRatio < 0.25) {
      linePaint.color = Colors.red;
    } else if (lastFillRatio < 0.5) {
      linePaint.color = Colors.orange;
    } else {
      linePaint.color = Colors.green;
    }

    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(_BufferGraphPainter oldDelegate) {
    return oldDelegate.history.length != history.length ||
        oldDelegate.threshold != threshold ||
        (history.isNotEmpty &&
            oldDelegate.history.isNotEmpty &&
            oldDelegate.history.last != history.last);
  }
}
