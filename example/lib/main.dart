import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
  AudioIoInputSource _inputSource = AudioIoInputSource.microphone;
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

  void _setupAudioProcessing(AudioIoInputSource inputSource) {
    _audioSubscription?.cancel();
    _audioSubscription = AudioIo.instance.input.listen(
      (data) {
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

        // Echo the microphone back to the speaker. For system/tab audio we
        // only visualise the level: replaying captured system audio would
        // feed straight back into the capture and loop. Use the session's
        // captured source, not the mutable field: changing the selector mid
        // capture must not divert a live system-audio stream into the echo
        // branch.
        if (inputSource == AudioIoInputSource.microphone) {
          final out = List<double>.generate(
              data.length, (index) => data[index] * 0.9); // do things :)
          AudioIo.instance.output.add(out);
        }
      },
      onError: (Object e) {
        // System/tab audio on a non-Chromium browser surfaces here as a typed
        // AudioIoException with isSystemAudioUnsupported.
        if (!mounted) return;
        setState(() {
          _status = e is AudioIoException && e.isSystemAudioUnsupported
              ? 'System audio unavailable (Chromium only): ${e.message}'
              : 'Input error: $e';
          _inputLevel = 0.0;
        });
      },
      onDone: () {
        // The share ended (user clicked "Stop sharing" in the browser).
        if (!mounted) return;
        setState(() {
          _status = 'Sharing stopped';
          _inputLevel = 0.0;
        });
      },
    );
  }

  void startAudio() async {
    // Snapshot the selected source for the whole session. _inputSource is
    // mutable from the selector; capturing it once keeps permission checks,
    // processing, config, and status consistent even if the user changes the
    // selector while capture is running.
    final inputSource = _inputSource;
    try {
      // Only check microphone permission when actually using the mic.
      if (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          inputSource == AudioIoInputSource.microphone) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          setState(() {
            _status = 'Microphone permission denied';
          });
          return;
        }
      }

      // Subscribe to the input stream BEFORE startWith. On web the share
      // picker (getDisplayMedia) is triggered during start() and must run
      // while the initiating tap still carries transient user activation; if
      // we subscribed only after awaiting startWith, the picker would fire
      // outside that window and be rejected. The input stream is stable before
      // start, so this early listener stays attached and receives capture data
      // and the typed picker error.
      _setupAudioProcessing(inputSource);

      // startWith applies the latency and input source together. On web,
      // AudioIoInputSource.systemAudio triggers the browser's share picker
      // during start because a listener is already attached (above).
      await AudioIo.instance.startWith(
        AudioIoConfig(
          latency: _latencyValue,
          inputSource: inputSource,
        ),
      );

      final latency = await AudioIo.instance.currentLatency();
      final lstring = latency.toStringAsPrecision(2);
      await AudioIo.instance.getFormat();
      setState(() {
        _status = inputSource == AudioIoInputSource.systemAudio
            ? 'Started — pick a tab to share ($lstring ms)'
            : 'Started ($lstring ms)';
      });
    } on AudioIoException catch (e) {
      setState(() {
        _status = e.isSystemAudioUnsupported
            ? 'System audio not available: ${e.message}'
            : 'Failed: ${e.message}';
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
              const SizedBox(height: 8),
              inputSourceSelector(context),
              const SizedBox(height: 8),
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

  Widget inputSourceSelector(BuildContext context) {
    return SegmentedButton<AudioIoInputSource>(
      segments: const [
        ButtonSegment(
          value: AudioIoInputSource.microphone,
          label: Text('Microphone'),
          icon: Icon(Icons.mic),
        ),
        ButtonSegment(
          value: AudioIoInputSource.systemAudio,
          label: Text('System / tab audio'),
          icon: Icon(Icons.desktop_windows),
        ),
      ],
      selected: {_inputSource},
      onSelectionChanged: (selection) {
        setState(() {
          _inputSource = selection.first;
        });
      },
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
