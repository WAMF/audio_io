import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:audio_io/audio_io.dart';

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
  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    AudioIo.instance.input.listen((data) {
      final out = List<double>.generate(
          data.length, (index) => data[index] * 0.9); // do things :)
      AudioIo.instance.output
          .add(out); // send back out to output (headset speaker or headphones)
    });

    if (!mounted) return;
    setState(() {
      _status = _status;
    });
  }

  void startAudio() async {
    try {
      await AudioIo.instance.start();
      final latency = await AudioIo.instance.currentLatency();
      final lstring = latency.toStringAsPrecision(2);
      final format = await AudioIo.instance.getFormat();
      setState(() {
        _status = 'Started ($lstring ms)';
      });
      print(format);
    } on PlatformException {
      setState(() {
        _status = 'Failed';
      });
    }
  }

  void stopAudio() async {
    try {
      await AudioIo.instance.stop();
      setState(() {
        _status = 'Stopped';
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
          child: Column(children: [
            latencyDropdown(context),
            Text('Status: $_status\n'),
            TextButton(onPressed: startAudio, child: Text('Start')),
            TextButton(onPressed: stopAudio, child: Text('Stop')),
          ]),
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
      }).toList(),
    );
  }
}
