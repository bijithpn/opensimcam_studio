import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opensc/main.dart';
import 'package:opensc/widgets/floating_toolbar.dart';
import 'package:opensc/widgets/main_settings_panel.dart';
import 'package:opensc/widgets/quick_status_pill.dart';
import 'package:opensc/widgets/simulator_camera_panel.dart';

void main() {
  testWidgets('OpenSC loads transparent floating companion tools', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1500);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const OpenSCApp());
    await tester.pumpAndSettle();

    // Verify key native desktop UI components
    expect(find.byTooltip('Close window'), findsOneWidget);
    expect(find.byTooltip('Minimize window'), findsOneWidget);
    expect(find.text('DRAG'), findsOneWidget);
    expect(find.byType(FloatingToolbar), findsOneWidget);
    expect(find.byType(MainSettingsPanel), findsOneWidget);
    expect(find.byType(QuickStatusPill), findsOneWidget);
    expect(find.byType(SimulatorCameraPanel), findsOneWidget);

    // Verify presence of core controls on Tab 0 (Camera Configuration)
    expect(find.text('Camera Configuration'), findsOneWidget);
    expect(find.text('Reset'), findsOneWidget);
    expect(find.text('Dual Camera Stream'), findsOneWidget);
    expect(find.text('09:41'), findsOneWidget);
    expect(find.text('Simulator Camera'), findsOneWidget);

    // Test clicking tabs in FloatingToolbar to verify responsive, non-repeating navigation
    // Click Tab 1 (Crop) - Aspect Ratio and framing live EXCLUSIVELY here
    await tester.tap(find.byTooltip('Aspect Ratio & Framing'));
    await tester.pumpAndSettle();
    expect(find.text('Aspect Ratio & Framing'), findsOneWidget);
    expect(find.text('Aspect Ratio'), findsOneWidget);
    expect(find.text('Rotation'), findsOneWidget);

    // Click Tab 2 (Simulator Controls)
    await tester.tap(find.byTooltip('Simulator Controls'));
    await tester.pumpAndSettle();
    expect(find.text('Simulator Controls'), findsOneWidget);

    // Click Tab 3 (Fine Adjustments) - Target camera, Zoom, and Pan sliders live EXCLUSIVELY here
    await tester.tap(find.byTooltip('Fine Adjustments'));
    await tester.pumpAndSettle();
    expect(find.text('Fine Adjustments'), findsOneWidget);
    expect(find.text('Both'), findsOneWidget);
    expect(find.text('Front'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Zoom Level'), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);
    expect(find.text('Pan Horizontal (X)'), findsOneWidget);
    expect(find.text('Pan Vertical (Y)'), findsOneWidget);

    // Click Tab 4 (Media Sources & Output) - Media assets and export live EXCLUSIVELY here
    await tester.tap(find.byTooltip('Media Sources & Output'));
    await tester.pumpAndSettle();
    expect(find.text('Media Sources & Output'), findsOneWidget);
    expect(find.text('Bundled Video'), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);

    // Click Tab 0 (Camera Configuration)
    await tester.tap(find.byTooltip('Camera Configuration'));
    await tester.pumpAndSettle();
    expect(find.text('Camera Configuration'), findsOneWidget);
  });
}
