import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// One line that slowly scrolls, over and over, only when it doesn't fit;
/// a line that fits just sits still (spec feature-chain-links, decision
/// 15). Still, cut off, when the system asks for less motion.
class Marquee extends StatefulWidget {
  const Marquee({super.key, required this.child, this.gap = 32, this.speed = 25});

  final Widget child;

  /// Space between the end of one pass and the start of the next.
  final double gap;

  /// Logical pixels per second.
  final double speed;

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  final _childKey = GlobalKey();
  final _scroll = ScrollController();
  late final Ticker _ticker = createTicker(_tick);

  /// The child's own width, once laid out; null until then.
  double? _childWidth;
  double _maxWidth = 0;

  bool get _overflows => _childWidth != null && _childWidth! > _maxWidth;

  @override
  void dispose() {
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final loop = _childWidth! + widget.gap;
    final offset = (elapsed.inMicroseconds / 1e6 * widget.speed) % loop;
    if (_scroll.hasClients) _scroll.jumpTo(offset);
  }

  /// After each layout: measure the child, then start or stop scrolling.
  void _measure() {
    if (!mounted) return;
    final width = _childKey.currentContext?.size?.width;
    if (width != null && width != _childWidth) setState(() => _childWidth = width);
    final animate = _overflows && !MediaQuery.of(context).disableAnimations;
    if (animate && !_ticker.isActive) {
      _ticker.start();
    } else if (!animate && _ticker.isActive) {
      _ticker.stop();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maxWidth = constraints.maxWidth;
        SchedulerBinding.instance.addPostFrameCallback((_) => _measure());
        final scrolling = _overflows && !MediaQuery.of(context).disableAnimations;
        return ClipRect(
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              children: [
                KeyedSubtree(key: _childKey, child: widget.child),
                if (scrolling) ...[SizedBox(width: widget.gap), widget.child],
              ],
            ),
          ),
        );
      },
    );
  }
}
