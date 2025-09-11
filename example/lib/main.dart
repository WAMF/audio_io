import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:audio_io/audio_io.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(MyApp());

final _latencyValues = {
  AudioIoLatency.Realtime: 'Realtime',
  AudioIoLatency.Balanced: 'Balanced',
  AudioIoLatency.Powersave: 'Powersave',
};

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _status = 'Unknown';
  AudioIoLatency _latencyValue = AudioIoLatency.Balanced;
  double _inputLevel = 0.0;
  DateTime _lastVolumeUpdate = DateTime.now();
  static const _volumeUpdateInterval = Duration(milliseconds: 33); // ~30 FPS
  StreamSubscription<List<double>>? _audioSubscription;

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    super.dispose();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    if (!mounted) return;
    setState(() {
      _status = _status;
    });
  }

  void _setupAudioProcessing() {
    _audioSubscription?.cancel();
    _audioSubscription = AudioIo.instance.input.listen((data) {
      // Calculate RMS (Root Mean Square) for volume level
      final now = DateTime.now();
      if (now.difference(_lastVolumeUpdate) >= _volumeUpdateInterval) {
        double sum = 0;
        for (final sample in data) {
          sum += sample * sample;
        }
        final rms = data.isEmpty ? 0.0 : sqrt(sum / data.length);

        // Update UI with amplified value for better visualization
        if (mounted) {
          setState(() {
            _inputLevel = (rms * 5.0).clamp(0.0, 1.0);
            _lastVolumeUpdate = now;
          });
        }
      }

      final out = List<double>.generate(
          data.length, (index) => data[index] * 0.9); // do things :)
      AudioIo.instance.output
          .add(out); // send back out to output (headset speaker or headphones)
    });
  }

  void startAudio() async {
    try {
      if (Platform.isAndroid) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          setState(() {
            _status = 'Microphone permission denied';
          });
          return;
        }
      }

      await AudioIo.instance.start();
      _setupAudioProcessing(); // Set up audio processing after starting

      final latency = await AudioIo.instance.currentLatency();
      final lstring = latency.toStringAsPrecision(2);
      await AudioIo.instance.getFormat();
      setState(() {
        _status = 'Started ($lstring ms)';
      });
    } on PlatformException {
      setState(() {
        _status = 'Failed';
      });
    }
  }

  void stopAudio() async {
    try {
      _audioSubscription?.cancel();
      _audioSubscription = null;
      await AudioIo.instance.stop();
      setState(() {
        _status = 'Stopped';
        _inputLevel = 0.0;
      });
    } on PlatformException {
      setState(() {
        _status = 'Failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              latencyDropdown(context),
              Text('Status: $_status\n'),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                child: Column(
                  children: [
                    Text('Input Level', style: TextStyle(fontSize: 16)),
                    SizedBox(height: 8),
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
              TextButton(onPressed: startAudio, child: Text('Start')),
              TextButton(onPressed: stopAudio, child: Text('Stop')),
            ],
          ),
        ),
      ),
    );
  }

  Widget latencyDropdown(BuildContext context) {
    return DropdownButton<AudioIoLatency>(
        value: _latencyValue,
        icon: Icon(Icons.arrow_downward),
        iconSize: 24,
        elevation: 16,
        underline: Container(
          height: 2,
          color: Colors.blueAccent,
        ),
        onChanged: (AudioIoLatency? newValue) {
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
        }).toList());
  }
}
