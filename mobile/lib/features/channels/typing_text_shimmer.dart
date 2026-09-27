import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../shared/theme/theme.dart';

/// Single-line status text with a sweeping shimmer, used by typing and
/// working indicators. Renders plain text when animations are disabled.
class TypingTextShimmer extends HookWidget {
  final String text;
  final TextStyle? style;

  const TypingTextShimmer(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final animation = useAnimationController(
      duration: const Duration(milliseconds: 2600),
    );
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final baseColor = style?.color ?? context.colors.onSurfaceVariant;
    final highlightColor =
        Color.lerp(context.colors.surface, baseColor, 0.4) ?? baseColor;

    useEffect(() {
      if (reducedMotion) {
        animation
          ..stop()
          ..value = 0;
      } else {
        animation.repeat();
      }
      return animation.stop;
    }, [animation, reducedMotion]);

    final label = Text(text, style: style, overflow: TextOverflow.ellipsis);
    if (reducedMotion) return label;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: animation,
        child: label,
        builder: (context, child) {
          final center = 1.5 - (animation.value * 3);
          return ShaderMask(
            key: const ValueKey('channel-typing-shimmer'),
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(center - 1, 0),
              end: Alignment(center + 1, 0),
              colors: [
                baseColor,
                baseColor,
                highlightColor,
                baseColor,
                baseColor,
              ],
              stops: const [0, 0.34, 0.5, 0.66, 1],
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}
