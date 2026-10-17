import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/studio_theme.dart';

class QuickStatusPill extends StatelessWidget {
  const QuickStatusPill({
    required this.statusText,
    required this.isConnected,
    this.onTap,
    super.key,
  });

  final String statusText;
  final bool isConnected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xE61B1C22),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: StudioColors.border, width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x28000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.clock,
              size: 13,
              color: StudioColors.textSecondary,
            ),
            const SizedBox(width: 6),
            const Text(
              '09:41',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: StudioColors.textPrimary,
              ),
            ),
            const SizedBox(width: 16),
            Container(width: 1, height: 12, color: StudioColors.borderSubtle),
            const SizedBox(width: 16),
            Icon(
              isConnected ? CupertinoIcons.wifi : CupertinoIcons.wifi_slash,
              size: 13,
              color: isConnected
                  ? StudioColors.success
                  : StudioColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: isConnected
                    ? StudioColors.textPrimary
                    : StudioColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
