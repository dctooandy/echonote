import 'dart:io';
import 'dart:typed_data';

import 'package:echonote/services/wav_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wav_writer_test');
    path = '${dir.path}/out.wav';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ByteData readHeader() => ByteData.sublistView(File(path).readAsBytesSync(), 0, 44);

  String ascii(ByteData h, int offset) =>
      String.fromCharCodes(List.generate(4, (i) => h.getUint8(offset + i)));

  Uint8List dataOf() => File(path).readAsBytesSync().sublist(44);

  test('header describes 16 kHz mono 16-bit PCM with correct lengths', () async {
    final writer = await WavWriter.open(path);
    await writer.add(Uint8List(3200)); // 100 ms
    await writer.add(Uint8List(3200));
    await writer.close();

    final h = readHeader();
    expect(ascii(h, 0), 'RIFF');
    expect(h.getUint32(4, Endian.little), 36 + 6400);
    expect(ascii(h, 8), 'WAVE');
    expect(ascii(h, 12), 'fmt ');
    expect(h.getUint32(16, Endian.little), 16);
    expect(h.getUint16(20, Endian.little), 1); // PCM
    expect(h.getUint16(22, Endian.little), 1); // mono
    expect(h.getUint32(24, Endian.little), 16000);
    expect(h.getUint32(28, Endian.little), 32000); // byte rate
    expect(h.getUint16(32, Endian.little), 2); // block align
    expect(h.getUint16(34, Endian.little), 16);
    expect(ascii(h, 36), 'data');
    expect(h.getUint32(40, Endian.little), 6400);
    expect(File(path).lengthSync(), 44 + 6400);
    expect(writer.duration, const Duration(milliseconds: 200));
  });

  test('audio bytes are written in order, unmodified', () async {
    final writer = await WavWriter.open(path);
    // Not awaited between adds: writes must still land in order.
    writer.add(Uint8List.fromList([1, 2, 3, 4]));
    writer.add(Uint8List.fromList([5, 6]));
    await writer.close();

    expect(dataOf(), [1, 2, 3, 4, 5, 6]);
  });

  test('odd-length chunks never split a sample; a dangling byte is dropped', () async {
    final writer = await WavWriter.open(path);
    await writer.add(Uint8List.fromList([1, 2, 3]));
    await writer.add(Uint8List.fromList([4, 5]));
    await writer.close();

    expect(dataOf(), [1, 2, 3, 4]);
    expect(readHeader().getUint32(40, Endian.little), 4);
  });

  test('closing with no audio leaves a valid, empty WAV', () async {
    final writer = await WavWriter.open(path);
    await writer.close();

    final h = readHeader();
    expect(h.getUint32(4, Endian.little), 36);
    expect(h.getUint32(40, Endian.little), 0);
    expect(File(path).lengthSync(), 44);
  });

  test('close is idempotent and add after close throws', () async {
    final writer = await WavWriter.open(path);
    await writer.close();
    await writer.close();

    expect(() => writer.add(Uint8List(2)), throwsStateError);
  });
}
