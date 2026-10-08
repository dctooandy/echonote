import 'dart:async';

import 'package:flutter/services.dart';

enum MicPermission { granted, denied, permanentlyDenied, undetermined }

enum MicStreamErrorCode {
  permissionDenied,
  alreadyRunning,
  audioSessionError,
  formatUnsupported,

  /// Another app / a call took the audio session; the stream has ended.
  interrupted,

  /// The app went to the background; the stream has ended.
  backgrounded,
  unknown,
}

class MicStreamException implements Exception {
  MicStreamException(this.code, [this.message]);

  factory MicStreamException.fromPlatform(PlatformException e) {
    final code = switch (e.code) {
      'PERMISSION_DENIED' => MicStreamErrorCode.permissionDenied,
      'ALREADY_RUNNING' => MicStreamErrorCode.alreadyRunning,
      'AUDIO_SESSION_ERROR' => MicStreamErrorCode.audioSessionError,
      'FORMAT_UNSUPPORTED' => MicStreamErrorCode.formatUnsupported,
      'INTERRUPTED' => MicStreamErrorCode.interrupted,
      'BACKGROUNDED' => MicStreamErrorCode.backgrounded,
      _ => MicStreamErrorCode.unknown,
    };
    return MicStreamException(code, e.message ?? e.code);
  }

  final MicStreamErrorCode code;
  final String? message;

  @override
  String toString() => 'MicStreamException(${code.name}): $message';
}

/// Dart side of the native mic stream (`ios/Runner/MicStreamChannel.swift`).
///
/// Audio arrives as 16 kHz mono PCM16 little-endian chunks of [chunkMs]
/// milliseconds — the format `WhisperController.transcribeLive` expects.
class MicStreamService {
  static const sampleRate = 16000;
  static const chunkMs = 100;

  static const _methods = MethodChannel('echonote/mic');
  static const _events = EventChannel('echonote/mic/pcm');

  /// Non-null while a stream from [start] is open.
  StreamController<Uint8List>? _controller;

  /// Ends the open stream on the Dart side without waiting for native.
  void Function()? _closeLocally;

  Future<MicPermission> permissionStatus() async {
    final status = await _invoke<String>('getPermissionStatus');
    return MicPermission.values.asNameMap()[status] ?? MicPermission.undetermined;
  }

  Future<bool> requestPermission() async => await _invoke<bool>('requestPermission') ?? false;

  /// Starts capturing and returns the PCM stream.
  ///
  /// The stream ends after [stop], or with a [MicStreamException]
  /// (`interrupted` / `backgrounded`) when the system ends it. Cancelling the
  /// subscription also releases the mic.
  Future<Stream<Uint8List>> start() async {
    // Checked here, not left to native ALREADY_RUNNING: the EventChannel has a
    // single native sink, so listening again would hijack the running stream,
    // and cancelling that listen on failure would stop the mic.
    if (_controller != null) {
      throw MicStreamException(MicStreamErrorCode.alreadyRunning, 'Mic stream is already running');
    }
    final controller = _controller = StreamController<Uint8List>();
    void release() {
      if (identical(_controller, controller)) {
        _controller = null;
        _closeLocally = null;
      }
    }

    // Listen before `start` so the native event sink is attached by the time
    // the first chunk is produced; the controller buffers until the caller
    // listens.
    final subscription = _events.receiveBroadcastStream().listen(
      (chunk) => controller.add(chunk as Uint8List),
      onError: (Object e) =>
          controller.addError(e is PlatformException ? MicStreamException.fromPlatform(e) : e),
      onDone: () {
        release();
        controller.close();
      },
    );
    controller.onCancel = () {
      release();
      return subscription.cancel();
    };
    _closeLocally = () {
      release();
      subscription.cancel();
      // Not awaited: close() on a never-listened controller never completes.
      unawaited(controller.close());
    };

    try {
      await _invoke<void>('start', {'sampleRate': sampleRate, 'chunkMs': chunkMs});
    } catch (_) {
      release();
      await subscription.cancel();
      // Not awaited: close() on a never-listened controller never completes.
      unawaited(controller.close());
      rethrow;
    }
    return controller.stream;
  }

  /// Stops capturing; the stream from [start] then completes. Safe to call
  /// when not running.
  Future<void> stop() async {
    try {
      await _invoke<void>('stop');
    } finally {
      // Native normally ends the stream itself (endOfStream before replying).
      // If it was no longer running it sends nothing, and the stream would
      // stay open forever, blocking every later start() with alreadyRunning.
      _closeLocally?.call();
    }
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw MicStreamException.fromPlatform(e);
    }
  }
}
