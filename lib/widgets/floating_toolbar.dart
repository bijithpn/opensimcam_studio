import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/studio_theme.dart';

class FloatingToolbar extends StatefulWidget {
  const FloatingToolbar({
    required this.selectedIndex,
    required this.onTabSelected,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  @override
  State<FloatingToolbar> createState() => _FloatingToolbarState();
}

class _FloatingToolbarState extends State<FloatingToolbar> {
  int? _hoveredIndex;

  static const List<IconData> _icons = [
    CupertinoIcons.camera_fill,
    CupertinoIcons.crop,
    CupertinoIcons.command,
    CupertinoIcons.slider_horizontal_3,
    CupertinoIcons.ellipsis,
  ];

  static const List<String> _tooltips = [
    'Camera Configuration',
    'Aspect Ratio & Framing',
    'Simulator Controls',
    'Fine Adjustments',
    'Media Sources & Output',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xF016171D),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: StudioColors.border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_icons.length, (index) {
          final isSelected = widget.selectedIndex == index;
          final isHovered = _hoveredIndex == index;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.5),
            child: Tooltip(
              message: _tooltips[index],
              waitDuration: const Duration(milliseconds: 300),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hoveredIndex = index),
                onExit: (_) => setState(() => _hoveredIndex = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onTabSelected(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    width: 38,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? StudioColors.accent
                          : (isHovered
                                ? const Color(0x22FFFFFF)
                                : Colors.transparent),
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: StudioColors.accent.withValues(
                                  alpha: 0.35,
                                ),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                      _icons[index],
                      size: 16,
                      color: isSelected
                          ? Colors.white
                          : (isHovered
                                ? Colors.white
                                : StudioColors.textSecondary),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
