import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import 'glass_panel.dart';

class LivePreviewPanel extends StatelessWidget {
  const LivePreviewPanel({
    required this.frame,
    required this.source,
    required this.isLive,
    required this.previewCamera,
    required this.targetCamera,
    required this.zoom,
    required this.onSwitchCamera,
    required this.onOpenViewfinder,
    super.key,
  });

  final ValueListenable<Uint8List?> frame;
  final CameraSourceType source;
  final bool isLive;
  final String previewCamera;
  final String targetCamera;
  final double zoom;
  final VoidCallback onSwitchCamera;
  final VoidCallback onOpenViewfinder;

  @override
  Widget build(BuildContext context) => GlassPanel(
    padding: const EdgeInsets.all(14),
    radius: 20,
    tint: StudioColors.panel,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final switchButton = OutlinedButton.icon(
              onPressed: onSwitchCamera,
              icon: const Icon(CupertinoIcons.arrow_left_right, size: 13),
              label: Text('${previewCamera.toUpperCase()} CAMERA'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFE4E8F2),
                textStyle: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                side: const BorderSide(color: Color(0x66444B63)),
              ),
            );
            final viewfinderButton = IconButton(
              tooltip: 'Open viewfinder',
              onPressed: onOpenViewfinder,
              icon: const Icon(CupertinoIcons.viewfinder, size: 17),
              visualDensity: VisualDensity.compact,
              color: StudioColors.textSecondary,
            );
            final title = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Live Preview',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 9),
                _statusPill(),
              ],
            );
            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [viewfinderButton, switchButton],
                  ),
                ],
              );
            }
            return Row(
              children: [title, const Spacer(), viewfinderButton, switchButton],
            );
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: const Color(0xFF08090E),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ValueListenableBuilder<Uint8List?>(
                    valueListenable: frame,
                    builder: (context, bytes, _) => bytes == null
                        ? _emptyState()
                        : Image.memory(
                            bytes,
                            // Passthrough is a screen mirror: fill the preview
                            // viewport so it does not look like a small phone
                            // feed floating between black side bars. The
                            // simulator camera output itself remains 9:16.
                            fit: source == CameraSourceType.passthrough
                                ? BoxFit.cover
                                : BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                  ),
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: _overlayLabel(
                      targetCamera == 'both'
                          ? 'Adjusting both cameras'
                          : 'Adjusting ${targetCamera.toUpperCase()} camera',
                    ),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _overlayLabel('${zoom.toStringAsFixed(1)}×'),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(source.icon, size: 14, color: const Color(0xFF60A5FA)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                source.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFA7ADBE)),
              ),
            ),
            Text(
              previewCamera.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF60A5FA),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _emptyState() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(source.icon, size: 38, color: const Color(0xFF60A5FA)),
      const SizedBox(height: 10),
      Text(
        source.title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFFCBD5E1),
        ),
      ),
      const SizedBox(height: 4),
      const Text(
        'Waiting for preview frames',
        style: TextStyle(fontSize: 11, color: Color(0xFF7F879B)),
      ),
    ],
  );

  Widget _statusPill() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: (isLive ? const Color(0xFF1C694F) : const Color(0xFF34394A))
          .withValues(alpha: .65),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          CupertinoIcons.circle_fill,
          size: 6,
          color: isLive ? const Color(0xFF38D996) : const Color(0xFF9BA2B3),
        ),
        const SizedBox(width: 5),
        Text(
          isLive ? 'LIVE' : 'STANDBY',
          style: const TextStyle(
            fontSize: 9,
            letterSpacing: .4,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  Widget _overlayLabel(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .68),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 10, color: Colors.white),
    ),
  );
}
