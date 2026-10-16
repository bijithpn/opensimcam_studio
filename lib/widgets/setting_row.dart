import 'package:flutter/material.dart';

class SettingRow extends StatelessWidget {
  const SettingRow({required this.label, required this.control, super.key});

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Flexible(
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFCBD5E1),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      const SizedBox(width: 12),
      control,
    ],
  );
}
