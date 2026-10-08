import 'dart:io';
import 'dart:typed_data';

/// Streams mono PCM16 little-endian audio into a WAV file.
///
/// Audio goes straight to disk — a 2-hour recording is ~230 MB, far too much
/// to hold in memory. The header is written with zero lengths on [open] and
/// patched with the real lengths on [close].
class WavWriter {
  WavWriter._(this._file, this.sampleRate);

  static const _headerBytes = 44;

  final RandomAccessFile _file;
  final int sampleRate;

  /// Serializes writes; [add] can be called again before the last write ends.
  Future<void> _tail = Future.value();
  int _writtenBytes = 0;

  /// Trailing byte of an odd-length chunk, held until the next chunk so a
  /// sample is never split (which would shift every following sample).
  int? _carry;
  bool _closed = false;
  bool _headerFinalized = false;

  static Future<WavWriter> open(String path, {int sampleRate = 16000}) async {
    final file = await File(path).open(mode: FileMode.write);
    try {
      await file.writeFrom(_header(sampleRate: sampleRate, dataBytes: 0));
    } catch (_) {
      await file.close();
      rethrow;
    }
    return WavWriter._(file, sampleRate);
  }

  /// Whether [close] wrote the final header lengths. False after a failed
  /// patch: the file then claims zero audio and isn't worth keeping.
  bool get headerFinalized => _headerFinalized;

  /// PCM bytes actually written to disk so far.
  int get dataBytes => _writtenBytes;

  Duration get duration =>
      Duration(microseconds: _writtenBytes ~/ 2 * Duration.microsecondsPerSecond ~/ sampleRate);

  /// Appends [pcm16]. The returned future completes when it is on disk and
  /// fails if the write fails (e.g. disk full); later writes are skipped.
  Future<void> add(Uint8List pcm16) {
    if (_closed) throw StateError('WavWriter is closed');
    final aligned = _align(pcm16);
    if (aligned.isEmpty) return _tail;
    return _tail = _tail.then((_) async {
      await _file.writeFrom(aligned);
      _writtenBytes += aligned.length;
    });
  }

  /// Waits for pending writes, patches the header lengths and closes the
  /// file. A dangling odd byte (half a sample) is dropped.
  ///
  /// If a write failed, the header is still patched to cover the bytes that
  /// did reach disk, so the file stays playable; the write error is then
  /// rethrown.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? writeError;
    StackTrace? writeStack;
    try {
      await _tail;
    } catch (e, st) {
      writeError = e;
      writeStack = st;
    }
    try {
      await _file.setPosition(0);
      await _file.writeFrom(_header(sampleRate: sampleRate, dataBytes: _writtenBytes));
      _headerFinalized = true;
    } finally {
      await _file.close();
    }
    if (writeError != null) Error.throwWithStackTrace(writeError, writeStack!);
  }

  Uint8List _align(Uint8List bytes) {
    final carry = _carry;
    final total = bytes.length + (carry == null ? 0 : 1);
    if (carry == null && total.isEven) return bytes;

    final merged = Uint8List(total);
    var offset = 0;
    if (carry != null) merged[offset++] = carry;
    merged.setRange(offset, total, bytes);
    if (total.isOdd) {
      _carry = merged.last;
      return Uint8List.sublistView(merged, 0, total - 1);
    }
    _carry = null;
    return merged;
  }

  static Uint8List _header({required int sampleRate, required int dataBytes}) {
    const channels = 1;
    const bitsPerSample = 16;
    const blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(_headerBytes);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // fmt chunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * blockAlign, Endian.little); // byte rate
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);
    return header.buffer.asUint8List();
  }
}
