import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the screen from auto-locking while someone needs it: recording and
/// transcribing both stop when the app leaves the foreground (spec
/// feature-keep-screen-awake). Several screens can hold it at once, e.g. a
/// recording that hands over to a re-transcription; it stays on until the
/// last holder releases it.
class ScreenAwake {
  ScreenAwake({Future<void> Function(bool on)? setKeepAwake})
    : _setKeepAwake = setKeepAwake ?? _platformSetKeepAwake;

  /// Shared by every screen. Tests swap in one with a fake platform call.
  static ScreenAwake instance = ScreenAwake();

  static const _channel = MethodChannel('echonote/screen');

  static Future<void> _platformSetKeepAwake(bool on) =>
      _channel.invokeMethod<void>('setKeepAwake', on);

  final Future<void> Function(bool on) _setKeepAwake;
  final _holders = <Object>{};

  /// What the platform was last told; null before the first call.
  bool? _applied;

  /// Platform calls run one at a time, so the last state requested wins.
  Future<void> _queue = Future.value();

  bool get isOn => _holders.isNotEmpty;

  /// Keeps the screen on for [owner]. Holding again changes nothing.
  Future<void> hold(Object owner) {
    _holders.add(owner);
    return _sync();
  }

  /// Drops [owner]'s hold; safe to call when it holds nothing.
  Future<void> release(Object owner) {
    _holders.remove(owner);
    return _sync();
  }

  Future<void> _sync() => _queue = _queue.then((_) async {
    final on = isOn;
    if (on == _applied) return;
    try {
      await _setKeepAwake(on);
      _applied = on;
    } catch (e) {
      // No native side (tests, an unsupported platform): the screen just
      // auto-locks as usual.
      debugPrint('[ScreenAwake] setKeepAwake($on) failed: $e');
    }
  });
}
