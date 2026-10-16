import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../theme/studio_theme.dart';
import 'glass_panel.dart';

Future<void> showCurrentViewfinder({
  required BuildContext context,
  required ValueListenable<Uint8List?> frame,
  required String camera,
  required double zoom,
}) {
  final screenSize = MediaQuery.sizeOf(context);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: math.min(560, screenSize.width - 24),
        height: math.min(640, screenSize.height - 48),
        child: LiquidGlassLayer(
          settings: StudioGlass.settings,
          fake: true,
          child: GlassPanel(
            padding: const EdgeInsets.all(14),
            radius: 22,
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.center_focus_strong_rounded,
                      size: 18,
                      color: StudioColors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${camera.toUpperCase()} CAMERA VIEWFINDER',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .3,
                        ),
                      ),
                    ),
                    Text(
                      '${zoom.toStringAsFixed(1)}×',
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Close viewfinder',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded, size: 17),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ColoredBox(
                      color: const Color(0x99070A10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ValueListenableBuilder<Uint8List?>(
                            valueListenable: frame,
                            builder: (context, bytes, _) => bytes == null
                                ? const Center(
                                    child: Text(
                                      'Waiting for simulator preview',
                                      style: TextStyle(
                                        color: StudioColors.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  )
                                : Image.memory(
                                    bytes,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                  ),
                          ),
                          const IgnorePointer(
                            child: CustomPaint(painter: _ViewfinderGuides()),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Live simulator feed · framing guides',
                    style: TextStyle(
                      fontSize: 10,
                      color: StudioColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ViewfinderGuides extends CustomPainter {
  const _ViewfinderGuides();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: .42)
      ..strokeWidth = 1;
    for (var index = 1; index <= 2; index++) {
      final x = size.width * index / 3;
      final y = size.height * index / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
    final center = Offset(size.width / 2, size.height / 2);
    final centerPaint = Paint()
      ..color = Colors.white.withValues(alpha: .72)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, 9, centerPaint);
    canvas.drawLine(
      Offset(center.dx - 4, center.dy),
      Offset(center.dx + 4, center.dy),
      centerPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 4),
      Offset(center.dx, center.dy + 4),
      centerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ViewfinderGuides oldDelegate) => false;
}
