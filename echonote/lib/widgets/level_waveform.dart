import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Maps normalized RMS to 0..1 on a dB scale: -60 dBFS (room tone) → 0,
/// 0 dBFS → 1. Speech sits around -35 to -15 dBFS, so a linear scale would
/// barely move. Range is provisional, tuned on device.
double levelToHeight(double rms) {
  if (rms <= 0) return 0;
  final db = 20 * math.log(rms) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

/// The last [capacity] input levels, one per 100 ms chunk.
class LevelHistory {
  LevelHistory({this.capacity = 60});

  /// 60 chunks of 100 ms: six seconds, enough to see that something was
  /// said a moment ago (spec feature-recording-indicator, decision 4).
  final int capacity;
  final _levels = ListQueue<double>();

  void add(double rms) {
    _levels.addLast(rms);
    if (_levels.length > capacity) _levels.removeFirst();
  }

  /// Bar heights in 0..1, oldest first and newest last, always [capacity]
  /// long: before the history fills up the left side is flat.
  List<double> get heights => [
    for (var i = _levels.length; i < capacity; i++) 0.0,
    for (final rms in _levels) levelToHeight(rms),
  ];
}

/// A waveform scrolling right to left as [levels] arrive.
class LevelWaveform extends StatefulWidget {
  const LevelWaveform({super.key, required this.levels, this.height = 48});

  final Stream<double>? levels;
  final double height;

  @override
  State<LevelWaveform> createState() => _LevelWaveformState();
}

class _LevelWaveformState extends State<LevelWaveform> {
  final _history = LevelHistory();
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(LevelWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.levels != widget.levels) {
      _sub?.cancel();
      _listen();
    }
  }

  void _listen() {
    _sub = widget.levels?.listen((rms) => setState(() => _history.add(rms)));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '輸入音量波形',
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _WaveformPainter(
            heights: _history.heights,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({required this.heights, required this.color});

  final List<double> heights;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / heights.length;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1, slot * 0.6);
    final mid = size.height / 2;
    // A silent slot still draws a short bar, so the baseline stays visible.
    final minHalf = paint.strokeWidth / 2;
    for (var i = 0; i < heights.length; i++) {
      final x = slot * (i + 0.5);
      final half = math.max(minHalf, heights[i] * mid);
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => true;
}
