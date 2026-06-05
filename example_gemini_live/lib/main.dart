import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const GeminiLiveApp());
}

class GeminiLiveApp extends StatelessWidget {
  const GeminiLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemini Live',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const GeminiLivePage(),
    );
  }
}

enum _ConnectionState { disconnected, connecting, connected, error }

class _GeminiConfig {
  static const model = 'models/gemini-2.0-flash-live';
  static const voiceName = 'Puck';
  static const inputMimeType = 'audio/pcm;rate=16000';
  static const wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai'
      '.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
}

class _SampleRates {
  static const input = 16000;
  static const output = 24000;
  static const ratio = output / input;
}

class _Playback {
  static const bytesPerSecond = _SampleRates.input * 2;

  // Extra grace added to the estimated drain time before the self-healing
  // watchdog lifts mic suppression. Covers playback/scheduling jitter so the
  // mic doesn't reopen a hair early and re-capture the tail of model audio.
  static const watchdogMargin = Duration(milliseconds: 250);
}

class GeminiLivePage extends StatefulWidget {
  const GeminiLivePage({super.key});

  @override
  State<GeminiLivePage> createState() => _GeminiLivePageState();
}

class _GeminiLivePageState extends State<GeminiLivePage> {
  final _apiKeyController = TextEditingController();
  var _state = _ConnectionState.disconnected;
  String _statusMessage = 'Enter your Gemini API key to begin';
  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<dynamic>? _wsSubscription;
  var _micSuppressed = false;
  DateTime? _playbackEndsAt;
  Timer? _resumeMicTimer;

  bool get _isActive =>
      _state == _ConnectionState.connected ||
      _state == _ConnectionState.connecting;

  @override
  void dispose() {
    _apiKeyController.dispose();
    unawaited(_disconnect());
    super.dispose();
  }

  Future<void> _connect() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() {
        _state = _ConnectionState.error;
        _statusMessage = 'Please enter an API key';
      });
      return;
    }

    setState(() {
      _state = _ConnectionState.connecting;
      _statusMessage = 'Connecting...';
    });

    try {
      final uri = Uri.parse('${_GeminiConfig.wsBaseUrl}?key=$apiKey');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _sendSetupMessage();
      _listenToWebSocket();
    } on Exception catch (e) {
      setState(() {
        _state = _ConnectionState.error;
        _statusMessage = 'Connection failed: $e';
      });
    }
  }

  void _sendSetupMessage() {
    final setup = jsonEncode({
      'setup': {
        'model': _GeminiConfig.model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {
                'voiceName': _GeminiConfig.voiceName,
              },
            },
          },
        },
      },
    });
    _channel?.sink.add(setup);
  }

  void _listenToWebSocket() {
    _wsSubscription = _channel?.stream.listen(
      (message) async {
        if (message is! String) return;
        final decoded = jsonDecode(message);
        if (decoded is! Map<String, dynamic>) return;

        if (decoded.containsKey('setupComplete')) {
          try {
            await _onSetupComplete();
          } on Exception catch (e) {
            if (!mounted) return;
            setState(() {
              _state = _ConnectionState.error;
              _statusMessage = 'Audio start failed: $e';
            });
            await _disconnect();
          }
          return;
        }

        _handleServerContent(decoded);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _state = _ConnectionState.error;
          _statusMessage = 'WebSocket error: $error';
        });
        _stopAudio();
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _state = _ConnectionState.disconnected;
          _statusMessage = 'Disconnected';
        });
        _stopAudio();
      },
    );
  }

  Future<void> _onSetupComplete() async {
    setState(() {
      _state = _ConnectionState.connected;
      _statusMessage = 'Connected — speak into your microphone';
    });

    await _startAudio();
  }

  Future<void> _startAudio() async {
    const config = AudioIoConfig(
      sampleRate: AudioIoSampleRate.rate16000,
      format: AudioIoFormat.pcm16,
      latency: AudioIoLatency.Realtime,
      // On web the browser controls the AudioContext rate (typically
      // 44.1/48 kHz), so 16 kHz can't be guaranteed. Opt in to the actual
      // rate; on native the device honours 16 kHz and this is ignored.
      allowSampleRateMismatch: true,
    );

    await AudioIo.instance.startWith(config);

    _audioSubscription = AudioIo.instance.inputBytes.listen((pcmChunk) {
      if (_micSuppressed) return;
      final encoded = base64Encode(pcmChunk);
      final message = jsonEncode({
        'realtimeInput': {
          'mediaChunks': [
            {
              'mimeType': _GeminiConfig.inputMimeType,
              'data': encoded,
            },
          ],
        },
      });
      _channel?.sink.add(message);
    });
  }

  void _handleServerContent(Map<String, dynamic> json) {
    final serverContent = json['serverContent'] as Map<String, dynamic>?;
    if (serverContent == null) return;

    _playModelAudio(serverContent);

    final turnComplete = serverContent['turnComplete'] == true;
    final interrupted = serverContent['interrupted'] == true;
    if (turnComplete || interrupted) {
      _resumeMicAfterPlayback();
    }
  }

  void _playModelAudio(Map<String, dynamic> serverContent) {
    final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
    if (modelTurn == null) return;

    final parts = modelTurn['parts'] as List<dynamic>?;
    if (parts == null) return;

    for (final part in parts) {
      if (part is! Map<String, dynamic>) continue;
      final inlineData = part['inlineData'] as Map<String, dynamic>?;
      if (inlineData == null) continue;

      final mimeType = inlineData['mimeType'] as String?;
      if (mimeType == null || !mimeType.startsWith('audio/pcm')) continue;

      final data = inlineData['data'] as String?;
      if (data == null) continue;

      final pcm24k = base64Decode(data);
      final pcm16k = _resample24kTo16k(Uint8List.fromList(pcm24k));
      AudioIo.instance.outputBytes.add(pcm16k);
      _suppressMicWhilePlaying(pcm16k.length);
    }
  }

  void _suppressMicWhilePlaying(int byteCount) {
    final now = DateTime.now();
    final base = (_playbackEndsAt != null && _playbackEndsAt!.isAfter(now))
        ? _playbackEndsAt!
        : now;
    final chunkMs = (byteCount * Duration.millisecondsPerSecond) ~/
        _Playback.bytesPerSecond;
    _playbackEndsAt = base.add(Duration(milliseconds: chunkMs));

    // Self-healing watchdog: re-arm the resume timer on every chunk so the mic
    // recovers even if the turnComplete/interrupted signal is dropped or the
    // socket hiccups mid-turn. Each new chunk pushes the deadline out; once
    // audio stops arriving the timer fires after the estimated drain time plus
    // a small margin and lifts suppression — without it a lost signal would
    // leave the mic muted for the rest of the session.
    _armMicResume(_Playback.watchdogMargin);

    if (!_micSuppressed) {
      setState(() => _micSuppressed = true);
    }
  }

  // Authoritative end-of-turn signal: resume as soon as the current audio has
  // drained, no watchdog margin needed.
  void _resumeMicAfterPlayback() => _armMicResume(Duration.zero);

  void _armMicResume(Duration margin) {
    final now = DateTime.now();
    final endsAt = _playbackEndsAt;
    final remaining = (endsAt != null && endsAt.isAfter(now))
        ? endsAt.difference(now)
        : Duration.zero;

    _resumeMicTimer?.cancel();
    _resumeMicTimer = Timer(remaining + margin, () {
      _playbackEndsAt = null;
      if (!mounted) return;
      setState(() => _micSuppressed = false);
    });
  }

  Future<void> _stopAudio() async {
    _resumeMicTimer?.cancel();
    _resumeMicTimer = null;
    _playbackEndsAt = null;
    _micSuppressed = false;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await AudioIo.instance.stop();
  }

  Future<void> _disconnect() async {
    await _stopAudio();
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> _toggleConnection() async {
    if (_isActive) {
      await _disconnect();
      setState(() {
        _state = _ConnectionState.disconnected;
        _statusMessage = 'Disconnected';
      });
    } else {
      await _connect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gemini Live')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatusText(
                state: _state,
                message: _statusMessage,
              ),
              const SizedBox(height: 32),
              _ApiKeyField(
                controller: _apiKeyController,
                enabled: !_isActive,
              ),
              const SizedBox(height: 48),
              _MicButton(
                isActive: _isActive,
                isConnecting: _state == _ConnectionState.connecting,
                onPressed: _toggleConnection,
              ),
              if (_state == _ConnectionState.connected) ...[
                const SizedBox(height: 24),
                _MicStatus(suppressed: _micSuppressed),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.state, required this.message});

  final _ConnectionState state;
  final String message;

  Color _color(BuildContext context) {
    return switch (state) {
      _ConnectionState.connected => Colors.green,
      _ConnectionState.connecting => Colors.orange,
      _ConnectionState.error => Colors.red,
      _ConnectionState.disconnected =>
        Theme.of(context).colorScheme.onSurfaceVariant,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: _color(context),
          ),
    );
  }
}

class _ApiKeyField extends StatelessWidget {
  const _ApiKeyField({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Gemini API Key',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.key),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.isActive,
    required this.isConnecting,
    required this.onPressed,
  });

  static const _buttonSize = 80.0;

  final bool isActive;
  final bool isConnecting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor =
        isActive ? colorScheme.error : colorScheme.primaryContainer;
    final iconColor =
        isActive ? colorScheme.onError : colorScheme.onPrimaryContainer;

    return SizedBox(
      width: _buttonSize,
      height: _buttonSize,
      child: FloatingActionButton.large(
        onPressed: isConnecting ? null : onPressed,
        backgroundColor: backgroundColor,
        child: isConnecting
            ? SizedBox(
                width: _buttonSize / 2,
                height: _buttonSize / 2,
                child: CircularProgressIndicator(color: iconColor),
              )
            : Icon(
                isActive ? Icons.stop : Icons.mic,
                color: iconColor,
                size: 36,
              ),
      ),
    );
  }
}

class _MicStatus extends StatelessWidget {
  const _MicStatus({required this.suppressed});

  final bool suppressed;

  @override
  Widget build(BuildContext context) {
    final color = suppressed ? Colors.orange : Colors.green;
    final icon = suppressed ? Icons.mic_off : Icons.mic;
    final label = suppressed ? 'Gemini speaking — mic muted' : 'Listening';

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}

Uint8List _resample24kTo16k(Uint8List pcm16At24k) {
  final input = ByteData.sublistView(pcm16At24k);
  final inputSamples = pcm16At24k.length ~/ 2;
  final outputSamples = (inputSamples * 2) ~/ 3;
  final output = ByteData(outputSamples * 2);
  for (var i = 0; i < outputSamples; i++) {
    final srcPos = i * _SampleRates.ratio;
    final srcIndex = srcPos.floor();
    final frac = srcPos - srcIndex;
    final s0 = input.getInt16(srcIndex * 2, Endian.little);
    final s1 = (srcIndex + 1 < inputSamples)
        ? input.getInt16((srcIndex + 1) * 2, Endian.little)
        : s0;
    final interpolated = (s0 + (s1 - s0) * frac).round();
    output.setInt16(i * 2, interpolated, Endian.little);
  }
  return output.buffer.asUint8List();
}
