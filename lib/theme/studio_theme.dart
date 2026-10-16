import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

abstract final class StudioColors {
  static const canvas = Colors.transparent;
  static const panel = Color(0xCC202124);
  static const panelRaised = Color(0xFF2B2C2F);
  static const border = Color(0x26FFFFFF);
  static const controlFill = Color(0x14FFFFFF);
  static const accent = Color(0xFF0A84FF);
  static const textPrimary = Color(0xFFF5F6FA);
  static const textSecondary = Color(0xFFA1A1AA);
  static const success = Color(0xFF72B987);
  static const warning = Color(0xFFC7A56B);
  static const danger = Color(0xFFD97979);
}

abstract final class StudioTheme {
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: StudioColors.canvas,
    fontFamily: '.AppleSystemUIFont',
    colorScheme: const ColorScheme.dark(
      primary: StudioColors.accent,
      surface: Color(0xFF191C2B),
    ),
    sliderTheme: const SliderThemeData(trackHeight: 3),
  );
}

abstract final class StudioGlass {
  static const settings = LiquidGlassSettings(
    glassColor: Color(0x1220242B),
    thickness: 12,
    blur: 8,
    chromaticAberration: 0,
    lightIntensity: .22,
    ambientStrength: .04,
    refractiveIndex: 1.12,
    saturation: 1.05,
  );
}
