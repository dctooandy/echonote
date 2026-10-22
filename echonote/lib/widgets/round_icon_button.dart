import 'package:flutter/material.dart';

/// An icon on a round base, the app's one style of icon button (spec
/// feature-dark-theme).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Icon colour; the text colour by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: scheme.surfaceContainer,
          foregroundColor: color ?? scheme.onSurface,
          fixedSize: const Size.square(38),
          minimumSize: const Size.square(38),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
