import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

abstract final class StudioColors {
  // Transparent macOS utility canvas
  static const canvas = Colors.transparent;
  static const canvasGradientStart = Colors.transparent;
  static const canvasGradientEnd = Colors.transparent;

  static const panel = Color(0xF216171D);
  static const panelElevated = Color(0xF81A1B22);
  static const panelMuted = Color(0xB315161C);

  static const border = Color(0x22FFFFFF);
  static const borderSubtle = Color(0x14FFFFFF);

  static const controlFill = Color(0x14FFFFFF);
  static const controlFillHover = Color(0x20FFFFFF);
  static const controlBorder = Color(0x1AFFFFFF);

  static const accent = Color(0xFF0A84FF);
  static const accentMuted = Color(0x280A84FF);

  static const textPrimary = Color(0xFFF3F4F6);
  static const textSecondary = Color(0xFF9CA3AF);
  static const textMuted = Color(0xFF6B7280);

  static const success = Color(0xFF30D158);
  static const warning = Color(0xFFFF9F0A);
  static const danger = Color(0xFFFF453A);
}

abstract final class StudioRadii {
  static const double panel = 18.0;
  static const double card = 14.0;
  static const double control = 8.0;
  static const double pill = 24.0;
}

abstract final class StudioTheme {
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    fontFamily: '.AppleSystemUIFont',
    colorScheme: const ColorScheme.dark(
      primary: StudioColors.accent,
      surface: StudioColors.panel,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 2.5,
      activeTrackColor: StudioColors.accent,
      inactiveTrackColor: Color(0x28FFFFFF),
      thumbColor: Colors.white,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thumbVisibility: WidgetStatePropertyAll(false),
      trackVisibility: WidgetStatePropertyAll(false),
      interactive: false,
    ),
  );
}

abstract final class StudioGlass {
  static const settings = LiquidGlassSettings(
    glassColor: Color(0x1A16171D),
    thickness: 12,
    blur: 16,
    chromaticAberration: 0,
    lightIntensity: .22,
    ambientStrength: .04,
    refractiveIndex: 1.12,
    saturation: 1.05,
  );
}
