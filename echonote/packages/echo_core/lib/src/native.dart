import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'echo_core_bindings_generated.dart';
import 'vad_config.dart';

// Zero-copy path: Dart's own Int16List / Float32List memory goes straight
// to C. `.address` is only allowed as an argument to a leaf call, which is
// why every echo_core function is bound with isLeaf: true (they are short
// and never call back into Dart). No native memory is allocated.

/// PCM16 → float in [-1, 1).
Float32List pcm16ToFloat(Int16List samples) {
  final out = Float32List(samples.length);
  if (samples.isEmpty) return out;
  ec_pcm16_to_float(samples.address, out.address, samples.length);
  return out;
}

/// Normalized RMS level, 0..1.
double rms(Int16List samples) {
  if (samples.isEmpty) return 0;
  return ec_rms_pcm16(samples.address, samples.length);
}

/// Peak absolute value of each of [buckets] equal runs, 0..1. Returns
/// min([buckets], samples.length) values.
Float32List waveform(Int16List samples, int buckets) {
  if (samples.isEmpty || buckets <= 0) return Float32List(0);
  final out = Float32List(math.min(buckets, samples.length));
  ec_waveform_downsample(samples.address, samples.length, out.address, out.length);
  return out;
}

/// Native-buffer path: samples are copied into memory this object
/// allocated with malloc and reuses across calls, growing it when a call
/// needs more. This is what passing data to C costs when zero-copy isn't an
/// option (e.g. a non-leaf call, or C that keeps the pointer); the benchmark
/// compares it against the zero-copy functions above.
///
/// Call [dispose] when done; a [NativeFinalizer] frees the buffers if the
/// object is garbage-collected first.
class EchoBufferedCore implements Finalizable {
  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  Pointer<Int16> _input = nullptr;
  Pointer<Float> _output = nullptr;
  int _inputCapacity = 0;
  int _outputCapacity = 0;
  // Separate detach keys: each buffer is attached to the finalizer on its own
  // and detached on its own when it is regrown.
  final _inputToken = Object();
  final _outputToken = Object();
  bool _disposed = false;

  /// How many times a buffer had to be (re)allocated; the benchmark reports
  /// it.
  int get allocations => _allocations;
  int _allocations = 0;

  Float32List pcm16ToFloat(Int16List samples) {
    final n = samples.length;
    if (n == 0) return Float32List(0);
    final input = _copyIn(samples);
    final output = _ensureOutput(n);
    ec_pcm16_to_float(input, output, n);
    return Float32List.fromList(output.asTypedList(n));
  }

  double rms(Int16List samples) {
    if (samples.isEmpty) return 0;
    return ec_rms_pcm16(_copyIn(samples), samples.length);
  }

  Float32List waveform(Int16List samples, int buckets) {
    final n = samples.length;
    if (n == 0 || buckets <= 0) return Float32List(0);
    final count = math.min(buckets, n);
    final input = _copyIn(samples);
    final output = _ensureOutput(count);
    ec_waveform_downsample(input, n, output, count);
    return Float32List.fromList(output.asTypedList(count));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _free(_input, _inputToken);
    _free(_output, _outputToken);
    _input = nullptr;
    _output = nullptr;
  }

  Pointer<Int16> _copyIn(Int16List samples) {
    _checkAlive();
    if (samples.length > _inputCapacity) {
      _free(_input, _inputToken);
      _input = malloc<Int16>(samples.length);
      _inputCapacity = samples.length;
      _attach(_input, _inputToken);
    }
    _input.asTypedList(samples.length).setAll(0, samples);
    return _input;
  }

  Pointer<Float> _ensureOutput(int n) {
    if (n > _outputCapacity) {
      _free(_output, _outputToken);
      _output = malloc<Float>(n);
      _outputCapacity = n;
      _attach(_output, _outputToken);
    }
    return _output;
  }

  void _attach(Pointer<NativeType> buffer, Object token) {
    _allocations++;
    _finalizer.attach(this, buffer.cast(), detach: token);
  }

  void _free(Pointer<NativeType> buffer, Object token) {
    if (buffer == nullptr) return;
    _finalizer.detach(token);
    malloc.free(buffer);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('EchoBufferedCore is disposed');
  }
}

/// Converts PCM16 into a reused native float buffer, for C calls that need
/// native memory because they aren't leaf calls (e.g. whisper's
/// `stream_feed`, which runs inference). The input still goes to C without
/// copying; only the output lives in malloc'ed memory, allocated on the
/// first call and regrown only when a call needs more.
///
/// Call [dispose] when done; a [NativeFinalizer] frees the buffer if the
/// object is garbage-collected first.
class PcmFloatBuffer implements Finalizable {
  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  Pointer<Float> _buffer = nullptr;
  int _capacity = 0;
  bool _disposed = false;

  /// How many times the buffer had to be (re)allocated.
  int get allocations => _allocations;
  int _allocations = 0;

  /// Converts [samples] and returns the buffer holding the result. The
  /// pointer is only valid until the next [convert] or [dispose]. Empty
  /// input returns `nullptr` without calling C.
  Pointer<Float> convert(Int16List samples) {
    if (_disposed) throw StateError('PcmFloatBuffer is disposed');
    final n = samples.length;
    if (n == 0) return nullptr;
    if (n > _capacity) {
      _free();
      _buffer = malloc<Float>(n);
      _capacity = n;
      _allocations++;
      _finalizer.attach(this, _buffer.cast(), detach: this);
    }
    ec_pcm16_to_float(samples.address, _buffer, n);
    return _buffer;
  }

  /// Frees the buffer now. Safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _free();
  }

  void _free() {
    if (_buffer == nullptr) return;
    _finalizer.detach(this);
    malloc.free(_buffer);
    _buffer = nullptr;
    _capacity = 0;
  }
}

/// Energy-gate voice activity detector backed by a native `ec_vad`.
///
/// Call [dispose] when done; a [NativeFinalizer] frees the native state if
/// the object is garbage-collected first. Not for sharing across isolates.
class EchoVad implements Finalizable {
  EchoVad([EchoVadConfig config = const EchoVadConfig()]) {
    final c = Struct.create<ec_vad_config>()
      ..initial_noise_floor = config.initialNoiseFloor
      ..rms_min = config.rmsMin
      ..voice_ratio = config.voiceRatio
      ..noise_floor_cap = config.noiseFloorCap
      ..fall_rate = config.fallRate
      ..rise_rate = config.riseRate;
    final vad = ec_vad_create(c);
    if (vad == nullptr) throw StateError('ec_vad_create failed: out of memory');
    _vad = vad;
    _finalizer.attach(this, vad.cast(), detach: this);
  }

  static final _finalizer = NativeFinalizer(addresses.ec_vad_destroy.cast());

  Pointer<ec_vad> _vad = nullptr;

  /// True when [samples] is voiced. Empty input returns false without
  /// touching the state.
  bool process(Int16List samples) {
    _checkAlive();
    if (samples.isEmpty) return false;
    return ec_vad_process(_vad, samples.address, samples.length) == 1;
  }

  void reset() {
    _checkAlive();
    ec_vad_reset(_vad);
  }

  /// Frees the native state now. Safe to call twice.
  void dispose() {
    if (_vad == nullptr) return;
    // Detach first so the finalizer can never free it a second time.
    _finalizer.detach(this);
    ec_vad_destroy(_vad);
    _vad = nullptr;
  }

  void _checkAlive() {
    if (_vad == nullptr) throw StateError('EchoVad is disposed');
  }
}

/// The C side's defaults, to check [EchoVadConfig] stays in sync.
EchoVadConfig nativeDefaultVadConfig() {
  final c = ec_vad_default_config();
  return EchoVadConfig(
    initialNoiseFloor: c.initial_noise_floor,
    rmsMin: c.rms_min,
    voiceRatio: c.voice_ratio,
    noiseFloorCap: c.noise_floor_cap,
    fallRate: c.fall_rate,
    riseRate: c.rise_rate,
  );
}
