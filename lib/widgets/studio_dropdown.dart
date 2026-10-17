import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/studio_theme.dart';

class StudioDropdownItem<T> {
  const StudioDropdownItem({
    required this.value,
    required this.label,
    this.icon,
    this.iconColor,
  });

  final T value;
  final String label;
  final IconData? icon;
  final Color? iconColor;
}

class StudioDropdown<T> extends StatelessWidget {
  const StudioDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.height = 28.0,
    this.isExpanded = false,
    this.fontSize = 11.5,
    this.leadingIcon,
    this.backgroundColor,
    super.key,
  });

  final T? value;
  final List<StudioDropdownItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double height;
  final bool isExpanded;
  final double fontSize;
  final IconData? leadingIcon;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: backgroundColor ?? StudioColors.controlFill,
        borderRadius: BorderRadius.circular(StudioRadii.control),
        border: Border.all(color: StudioColors.controlBorder, width: 0.8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: isExpanded,
          borderRadius: BorderRadius.circular(8),
          dropdownColor: const Color(0xFF1E2028),
          icon: const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: 11,
              color: StudioColors.textSecondary,
            ),
          ),
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            color: StudioColors.textPrimary,
            fontFamily: '.AppleSystemUIFont',
          ),
          items: items
              .map((item) {
                return DropdownMenuItem<T>(
                  value: item.value,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.icon != null) ...[
                        Icon(
                          item.icon,
                          size: fontSize + 1,
                          color: item.iconColor ?? StudioColors.accent,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          item.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: fontSize,
                            fontWeight: FontWeight.w500,
                            color: StudioColors.textPrimary,
                            fontFamily: '.AppleSystemUIFont',
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              })
              .toList(growable: false),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
