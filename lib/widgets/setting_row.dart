import 'package:flutter/material.dart';
import '../theme/studio_theme.dart';

class SettingRow extends StatelessWidget {
  const SettingRow({
    required this.label,
    required this.control,
    this.description,
    super.key,
  });

  final String label;
  final Widget control;
  final String? description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: StudioColors.textPrimary,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.1,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 2),
                Text(
                  description!,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: StudioColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 14),
        control,
      ],
    ),
  );
}
