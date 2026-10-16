import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/studio_theme.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 18,
    this.tint = StudioColors.panel,
    this.blurSigma = 0,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color tint;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: StudioColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x20000000),
            blurRadius: 18,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: blurSigma > 0
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: surface,
            )
          : surface,
    );
  }
}
