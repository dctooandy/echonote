import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:echonote/screens/live_record_screen.dart';
import 'package:echonote/services/live_transcription_service.dart';
import 'package:echonote/services/mic_stream_service.dart';
import 'package:echonote/services/settings_store.dart';
import 'package:echonote/services/wav_writer.dart';
import 'package:echonote/widgets/level_waveform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _FakeMic extends MicStreamService {
  final chunks = StreamController<Uint8List>();

  @override
  Future<MicPermission> permissionStatus() async => MicPermission.granted;

  @override
  Future<Stream<Uint8List>> start() async => chunks.stream;

  @override
  Future<void> stop() async {
    if (!chunks.isClosed) await chunks.close();
  }
}

class _FakePreview implements PreviewSession {
  final partialsCtl = StreamController<String>.broadcast();

  @override
  Stream<String> get partials => partialsCtl.stream;

  @override
  Stream<Map<String, dynamic>> get metrics => const Stream.empty();

  @override
  Future<String> stop() async {
    await partialsCtl.close();
    return '';
  }
}

class _FakeService extends LiveTranscriptionService {
  _FakeService(this.fakeMic, {this.previewModelError}) : super(mic: fakeMic);

  final _FakeMic fakeMic;
  final Object? previewModelError;
  final previews = <_FakePreview>[];

  @override
  Future<void> ensureModels({
    void Function(WhisperModel model, int received, int? total)? onProgress,
  }) async {}

  @override
  Future<void> ensurePreviewModel({
    LivePreviewConfig config = kLivePreviewConfig,
    void Function(WhisperModel model, int received, int? total)? onProgress,
  }) async {
    if (previewModelError != null) throw previewModelError!;
  }

  @override
  Future<LiveRecording> start({
    required String wavPath,
    required bool livePreview,
    LivePreviewConfig config = kLivePreviewConfig,
  }) async {
    final wav = await WavWriter.open(wavPath);
    final rec = LiveRecording(
      mic: fakeMic,
      micStream: await fakeMic.start(),
      wav: wav,
      openPreview: (_) async {
        final preview = _FakePreview();
        previews.add(preview);
        return preview;
      },
    );
    if (livePreview) await rec.startPreview();
    return rec;
  }
}

void main() {
  late Directory dir;
  late _FakeMic mic;
  late SettingsStore settings;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('live_screen_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    mic = _FakeMic();
    settings = SettingsStore(documentsDir: () async => dir);
  });

  tearDown(() => dir.delete(recursive: true));

  /// Lets real file I/O (WAV, settings) finish between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<_FakeService> open(WidgetTester tester, {Object? previewModelError}) async {
    final service = _FakeService(mic, previewModelError: previewModelError);
    await tester.pumpWidget(
      MaterialApp(home: LiveRecordScreen(mic: mic, service: service, settings: settings)),
    );
    await settle(tester);
    return service;
  }

  Switch liveSwitch(WidgetTester tester) => tester.widget<Switch>(find.byType(Switch));

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }

  testWidgets('live text is off by default: no recognizer, no preview, big waveform', (tester) async {
    final service = await open(tester);

    expect(find.text('即時文字（草稿）'), findsOneWidget);
    expect(liveSwitch(tester).value, isFalse);
    expect(service.previews, isEmpty);
    expect(find.textContaining('即時預覽'), findsNothing);
    expect(tester.widget<LevelWaveform>(find.byType(LevelWaveform)).height, 120);
    await leave(tester);
  });

  testWidgets('a remembered choice starts with live text on', (tester) async {
    await tester.runAsync(() => settings.setLivePreview(true));

    final service = await open(tester);

    expect(liveSwitch(tester).value, isTrue);
    expect(service.previews, hasLength(1));
    expect(find.text('即時預覽（停止後會重新產生正式逐字稿）'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('turning it on mid-recording says it starts from now, and is remembered', (tester) async {
    final service = await open(tester);
    for (var i = 0; i < 12; i++) {
      mic.chunks.add(Uint8List(3200)); // 1.2 s of audio
    }
    await settle(tester);

    await tester.tap(find.byType(Switch));
    await settle(tester);

    expect(liveSwitch(tester).value, isTrue);
    expect(service.previews, hasLength(1));
    expect(find.textContaining('從現在開始'), findsOneWidget);
    expect(tester.widget<LevelWaveform>(find.byType(LevelWaveform)).height, 48);

    service.previews.single.partialsCtl.add('大家好');
    await settle(tester);
    expect(find.text('大家好'), findsOneWidget);
    expect(await tester.runAsync(settings.livePreview), isTrue);
    await leave(tester);
  });

  testWidgets('turning it off hides the preview and is remembered', (tester) async {
    await tester.runAsync(() => settings.setLivePreview(true));
    await open(tester);

    await tester.tap(find.byType(Switch));
    await settle(tester);

    expect(liveSwitch(tester).value, isFalse);
    expect(find.textContaining('即時預覽'), findsNothing);
    expect(await tester.runAsync(settings.livePreview), isFalse);
    await leave(tester);
  });

  testWidgets('if the preview model fails, the switch goes back off and recording goes on', (tester) async {
    final service = await open(tester, previewModelError: const SocketException('offline'));

    await tester.tap(find.byType(Switch));
    await settle(tester);

    expect(liveSwitch(tester).value, isFalse);
    expect(service.previews, isEmpty);
    expect(find.textContaining('無法開啟即時文字，錄音照常進行'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(await tester.runAsync(settings.livePreview), isFalse);
    await leave(tester);
  });
}
