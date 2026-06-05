import 'dart:async';
import 'dart:math';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class _PassthroughConstants {
  static const volumeUpdateInterval = Duration(milliseconds: 33);
}

final _latencyValues = {
  AudioIoLatency.Realtime: 'Realtime',
  AudioIoLatency.Balanced: 'Balanced',
  AudioIoLatency.Powersave: 'Powersave',
};

class PassthroughScreen extends StatefulWidget {
  const PassthroughScreen({super.key});

  @override
  State<PassthroughScreen> createState() => _PassthroughScreenState();
}

class _PassthroughScreenState extends State<PassthroughScreen> {
  String _status = 'Stopped';
  AudioIoLatency _latencyValue = AudioIoLatency.Balanced;
  double _inputLevel = 0.0;
  DateTime _lastVolumeUpdate = DateTime.now();
  StreamSubscription<List<double>>? _audioSubscription;
  bool _isRunning = false;

  @override
  void dispose() {
    _stopAudio();
    super.dispose();
  }

  void _setupAudioProcessing() {
    _audioSubscription?.cancel();
    _audioSubscription = AudioIo.instance.input.listen((data) {
      final now = DateTime.now();
      if (now.difference(_lastVolumeUpdate) >=
          _PassthroughConstants.volumeUpdateInterval) {
        double sum = 0;
        for (final sample in data) {
          sum += sample * sample;
        }
        final rms = data.isEmpty ? 0.0 : sqrt(sum / data.length);

        if (mounted) {
          setState(() {
            _inputLevel = (rms * 5.0).clamp(0.0, 1.0);
            _lastVolumeUpdate = now;
          });
        }
      }

      AudioIo.instance.output.add(data);
    });
  }

  Future<void> _startAudio() async {
    if (_isRunning) return;

    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          setState(() {
            _status = 'Microphone permission denied';
          });
          return;
        }
      }

      await AudioIo.instance.requestLatency(_latencyValue);
      await AudioIo.instance.start();
      _setupAudioProcessing();

      final latency = await AudioIo.instance.currentLatency();
      final lstring = latency.toStringAsPrecision(2);
      await AudioIo.instance.getFormat();
      setState(() {
        _status = 'Running ($lstring ms)';
        _isRunning = true;
      });
    } on PlatformException {
      setState(() {
        _status = 'Failed';
        _isRunning = false;
      });
    }
  }

  Future<void> _stopAudio() async {
    if (!_isRunning) return;

    try {
      _audioSubscription?.cancel();
      _audioSubscription = null;
      await AudioIo.instance.stop();
      if (mounted) {
        setState(() {
          _status = 'Stopped';
          _inputLevel = 0.0;
          _isRunning = false;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          _status = 'Failed';
          _isRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio Passthrough'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLatencyDropdown(),
              const SizedBox(height: 24),
              _buildStatusCard(),
              const SizedBox(height: 24),
              _buildLevelMeter(),
              const SizedBox(height: 24),
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLatencyDropdown() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Latency Mode'),
            DropdownButton<AudioIoLatency>(
              value: _latencyValue,
              underline: const SizedBox(),
              onChanged: _isRunning
                  ? null
                  : (AudioIoLatency? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _latencyValue = newValue;
                        });
                      }
                    },
              items: AudioIoLatency.values
                  .map<DropdownMenuItem<AudioIoLatency>>((AudioIoLatency value) {
                return DropdownMenuItem<AudioIoLatency>(
                  value: value,
                  child: Text(_latencyValues[value]!),
                );
              }).toList(),
            ),
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
              _isRunning ? Icons.mic : Icons.mic_off,
              size: 32,
              color: _isRunning ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 16),
            Text(
              _status,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelMeter() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Input Level'),
                Text('${(_inputLevel * 100).toInt()}%'),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _inputLevel,
              minHeight: 10,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _inputLevel > 0.7
                    ? Colors.red
                    : _inputLevel > 0.4
                        ? Colors.orange
                        : Colors.green,
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
            onPressed: _isRunning ? null : _startAudio,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isRunning ? _stopAudio : null,
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
}
