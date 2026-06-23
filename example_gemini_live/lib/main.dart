import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
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
  static const model = 'models/gemini-3.1-flash-live-preview';
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

  // Burst/jitter buffer. Gemini streams a whole turn faster than real time, but
  // the engine's output is a small real-time ring buffer (~43ms). Feeding it
  // directly overruns it and drops audio (choppy playback). Instead queue the
  // model PCM and drain it to [AudioIo.outputBytes] at the real-time byte rate.
  final Queue<Uint8List> _playbackQueue = Queue<Uint8List>();
  int _queuedBytes = 0;
  int _playbackHeadOffset = 0;
  Timer? _playbackTimer;
  var _playbackPrimed = false;

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
        final String text;
        if (message is String) {
          text = message;
        } else if (message is List<int>) {
          text = utf8.decode(message);
        } else {
          return;
        }
        final decoded = jsonDecode(text);
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
    // The native side (AppDelegate on iOS/macOS) requests microphone access on
    // launch, which is the reliable prompt path. This is a secondary nudge on
    // platforms where permission_handler is available; the engine's own
    // authorization check in start() is the final gate.
    try {
      await Permission.microphone.request();
    } on MissingPluginException catch (_) {
      // No permission_handler implementation on this platform (e.g. macOS); the
      // native request and the engine's authorization check cover it.
    }

    const config = AudioIoConfig(
      sampleRate: AudioIoSampleRate.rate16000,
      format: AudioIoFormat.pcm16,
      latency: AudioIoLatency.Realtime,
    );

    await AudioIo.instance.startWith(config);

    _audioSubscription = AudioIo.instance.inputBytes.listen((pcmChunk) {
      if (_micSuppressed) return;
      final encoded = base64Encode(pcmChunk);
      final message = jsonEncode({
        'realtimeInput': {
          'audio': {
            'mimeType': _GeminiConfig.inputMimeType,
            'data': encoded,
          },
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
    if (interrupted) {
      _handleInterruption();
    } else if (turnComplete) {
      _resumeMicAfterPlayback();
    }
  }

  // Gemini reports the turn was interrupted: drop everything still queued for
  // playback so stale audio is not played over the next turn, and reopen the
  // mic immediately rather than waiting for a drain that no longer applies.
  void _handleInterruption() {
    _clearPlayback();
    unawaited(AudioIo.instance.clearOutput());
    _resumeMicTimer?.cancel();
    _resumeMicTimer = null;
    _playbackEndsAt = null;
    if (_micSuppressed) {
      setState(() => _micSuppressed = false);
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
      _enqueuePlayback(pcm16k);
      _suppressMicWhilePlaying(pcm16k.length);
    }
  }

  static const _playbackTickMs = 10;
  static const _playbackPrimeTicks = 3;

  void _enqueuePlayback(Uint8List pcm) {
    _playbackQueue.add(pcm);
    _queuedBytes += pcm.length;
    _playbackTimer ??= Timer.periodic(
      const Duration(milliseconds: _playbackTickMs),
      (_) => _drainPlayback(),
    );
  }

  void _drainPlayback() {
    if (_queuedBytes == 0) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      _playbackPrimed = false;
      return;
    }

    final ticks = _playbackPrimed ? 1 : _playbackPrimeTicks;
    _playbackPrimed = true;
    var budget = _Playback.bytesPerSecond *
        _playbackTickMs *
        ticks ~/
        Duration.millisecondsPerSecond;
    if (budget.isOdd) budget -= 1;

    final out = BytesBuilder(copy: false);
    var taken = 0;
    while (taken < budget && _playbackQueue.isNotEmpty) {
      final head = _playbackQueue.first;
      final available = head.length - _playbackHeadOffset;
      final want = budget - taken;
      final n = available <= want ? available : want;
      final end = _playbackHeadOffset + n;
      out.add(Uint8List.sublistView(head, _playbackHeadOffset, end));
      taken += n;
      _playbackHeadOffset += n;
      _queuedBytes -= n;
      if (_playbackHeadOffset >= head.length) {
        _playbackQueue.removeFirst();
        _playbackHeadOffset = 0;
      }
    }

    if (taken > 0) {
      AudioIo.instance.outputBytes.add(out.toBytes());
    }
  }

  void _clearPlayback() {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _playbackPrimed = false;
    _playbackQueue.clear();
    _queuedBytes = 0;
    _playbackHeadOffset = 0;
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
    _clearPlayback();
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
