import 'package:flutter/material.dart';
import '../theme/studio_theme.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = StudioRadii.panel,
    this.tint = StudioColors.panel,
    this.border = StudioColors.border,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color tint;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border, width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: Color(0x45000000),
            blurRadius: 20,
            offset: Offset(0, 8),
            spreadRadius: -2,
          ),
        ],
      ),
      child: child,
    );
  }
}
