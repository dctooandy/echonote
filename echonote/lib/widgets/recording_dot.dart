import 'package:flutter/material.dart';

/// The red recording dot. While [active] it breathes (fades in and out over
/// about a second) so the screen visibly shows recording is under way; with
/// the system's reduce-motion setting on it stays solid instead.
class RecordingDot extends StatefulWidget {
  const RecordingDot({super.key, this.active = true, this.size = 24});

  final bool active;
  final double size;

  @override
  State<RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<RecordingDot> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    lowerBound: 0.25,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RecordingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final breathe = widget.active && !MediaQuery.disableAnimationsOf(context);
    if (breathe) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Icon(Icons.fiber_manual_record, color: Colors.red, size: widget.size, semanticLabel: '錄音中'),
    );
  }
}
