import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/camera_framing.dart';
import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import 'glass_panel.dart';
import 'setting_row.dart';
import 'studio_dropdown.dart';

class MainSettingsPanel extends StatelessWidget {
  const MainSettingsPanel({
    required this.currentSource,
    required this.targetCamera,
    required this.activeFraming,
    required this.isSimCameraActive,
    required this.simActiveCamera,
    required this.availableCameras,
    required this.selectedCameraId,
    required this.onCameraSelected,
    required this.onFitModeChanged,
    required this.onTargetCameraSelected,
    required this.onZoomChanged,
    required this.onOffsetXChanged,
    required this.onOffsetYChanged,
    required this.onRotationChanged,
    required this.onMirrorChanged,
    required this.onResetTransform,
    required this.bundledVideoAssets,
    required this.selectedBundledVideoAsset,
    required this.onBundledVideoSelected,
    required this.customImagePath,
    required this.onPickImage,
    required this.customVideoPath,
    required this.onPickVideo,
    required this.qrController,
    required this.onApplyQr,
    required this.hasScreenCapturePermission,
    required this.onRequestScreenCapturePermission,
    this.selectedTab = 0,
    this.onOpenSimulator,
    this.onStartSetup,
    this.onOpenViewfinder,
    super.key,
  });

  final CameraSourceType currentSource;
  final String targetCamera;
  final CameraFraming activeFraming;
  final bool isSimCameraActive;
  final String simActiveCamera;
  final List<Map<String, String>> availableCameras;
  final String? selectedCameraId;
  final ValueChanged<String> onCameraSelected;
  final ValueChanged<String> onFitModeChanged;
  final ValueChanged<String> onTargetCameraSelected;
  final ValueChanged<double> onZoomChanged;
  final ValueChanged<double> onOffsetXChanged;
  final ValueChanged<double> onOffsetYChanged;
  final ValueChanged<int> onRotationChanged;
  final ValueChanged<bool> onMirrorChanged;
  final VoidCallback onResetTransform;

  final List<String> bundledVideoAssets;
  final String selectedBundledVideoAsset;
  final ValueChanged<String> onBundledVideoSelected;
  final String? customImagePath;
  final VoidCallback onPickImage;
  final String? customVideoPath;
  final VoidCallback onPickVideo;
  final TextEditingController qrController;
  final VoidCallback onApplyQr;
  final bool hasScreenCapturePermission;
  final VoidCallback onRequestScreenCapturePermission;

  final int selectedTab;
  final VoidCallback? onOpenSimulator;
  final VoidCallback? onStartSetup;
  final VoidCallback? onOpenViewfinder;

  static const List<StudioDropdownItem<String>> _aspectRatioItems = [
    StudioDropdownItem(
      value: 'fill',
      label: 'Fill (Cover 9:16)',
      icon: CupertinoIcons.rectangle_fill,
    ),
    StudioDropdownItem(
      value: 'fit',
      label: 'Fit (Letterbox)',
      icon: CupertinoIcons.rectangle,
    ),
    StudioDropdownItem(
      value: 'stretch',
      label: 'Stretch',
      icon: CupertinoIcons.arrow_up_left_arrow_down_right,
    ),
    StudioDropdownItem(
      value: 'rotate90',
      label: 'Rotate 90° CW',
      icon: CupertinoIcons.rotate_right,
    ),
    StudioDropdownItem(
      value: 'rotate180',
      label: 'Rotate 180°',
      icon: CupertinoIcons.arrow_2_circlepath,
    ),
    StudioDropdownItem(
      value: 'rotate270',
      label: 'Rotate 270° CW',
      icon: CupertinoIcons.rotate_left,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      radius: StudioRadii.panel,
      tint: StudioColors.panel,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _buildCurrentView(context),
      ),
    );
  }

  Widget _buildCurrentView(BuildContext context) {
    switch (selectedTab) {
      case 1:
        return _buildFramingOnlyView(context);
      case 2:
        return _buildSimulatorControlsView(context);
      case 3:
        return _buildFineAdjustmentsView(context);
      case 4:
        return _buildMediaOptionsView(context);
      case 0:
      default:
        return _buildOverviewLayout(context);
    }
  }

  /// Default layout matching image.png exactly
  Widget _buildOverviewLayout(BuildContext context) {
    return Column(
      key: const ValueKey('tab_overview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Section 1: Camera Configuration
        _buildSectionHeader(
          title: 'Camera Configuration',
          trailing: _buildResetButton(),
        ),
        const SizedBox(height: 12),

        // Mac Camera (if webcam)
        if (currentSource == CameraSourceType.webcam &&
            availableCameras.isNotEmpty) ...[
          SettingRow(
            label: 'Mac Camera',
            control: StudioDropdown<String>(
              value: selectedCameraId,
              items: availableCameras
                  .map(
                    (c) => StudioDropdownItem<String>(
                      value: c['id'] ?? '',
                      label: c['name'] ?? 'Camera',
                      icon: CupertinoIcons.camera,
                    ),
                  )
                  .toList(),
              onChanged: (val) {
                if (val != null) onCameraSelected(val);
              },
            ),
          ),
          _buildSeparator(),
        ],

        // Aspect Ratio
        SettingRow(
          label: 'Aspect Ratio',
          control: StudioDropdown<String>(
            value: activeFraming.fitMode,
            items: _aspectRatioItems,
            onChanged: (val) {
              if (val != null) onFitModeChanged(val);
            },
          ),
        ),

        _buildSeparator(),

        // Dual Camera Stream status
        SettingRow(
          label: 'Dual Camera Stream',
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.checkmark_alt_circle_fill,
                size: 13,
                color: isSimCameraActive
                    ? StudioColors.success
                    : StudioColors.success,
              ),
              const SizedBox(width: 6),
              Text(
                isSimCameraActive
                    ? 'Streaming: ${simActiveCamera.toUpperCase()}'
                    : 'Streaming: FRONT',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: StudioColors.success,
                ),
              ),
            ],
          ),
        ),

        _buildSectionDivider(),

        // Section 2: Framing & Adjustments
        _buildSectionHeader(title: 'Framing & Adjustments'),
        const SizedBox(height: 12),

        // Target Selector: Both, Front, Back
        _buildTargetSegmentControl(),
        const SizedBox(height: 14),

        // Zoom Level Slider + Quick Presets
        _buildZoomControls(context),

        _buildSeparator(),

        // Pan Horizontal (X)
        _buildPanXControls(context),

        const SizedBox(height: 4),

        // Pan Vertical (Y)
        _buildPanYControls(context),

        _buildSeparator(),

        // Rotation
        _buildRotationRow(),

        const SizedBox(height: 10),

        // Mirror Back / Front Camera
        SettingRow(
          label: targetCamera == 'front'
              ? 'Mirror Front Camera'
              : (targetCamera == 'back'
                    ? 'Mirror Back Camera'
                    : 'Mirror Cameras'),
          control: Transform.scale(
            scale: 0.75,
            child: CupertinoSwitch(
              value: activeFraming.mirror,
              activeTrackColor: StudioColors.accent,
              onChanged: onMirrorChanged,
            ),
          ),
        ),

        _buildSectionDivider(),

        // Bundled Video
        SettingRow(
          label: 'Bundled Video',
          control: StudioDropdown<String>(
            value: bundledVideoAssets.contains(selectedBundledVideoAsset)
                ? selectedBundledVideoAsset
                : null,
            items: bundledVideoAssets
                .map(
                  (asset) => StudioDropdownItem<String>(
                    value: asset,
                    label: asset.split('/').last,
                    icon: CupertinoIcons.film,
                  ),
                )
                .toList(),
            onChanged: (val) {
              if (val != null) onBundledVideoSelected(val);
            },
          ),
        ),

        const SizedBox(height: 12),

        // Format selector bar: GIF | MP4 | PNG
        _buildFormatSelectorBar(),
      ],
    );
  }

  /// Focused Framing & Aspect view (Tab 1)
  Widget _buildFramingOnlyView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_framing'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(
          title: 'Framing & Aspect Ratio',
          trailing: _buildResetButton(),
        ),
        const SizedBox(height: 12),
        _buildTargetSegmentControl(),
        const SizedBox(height: 14),
        SettingRow(
          label: 'Aspect Ratio',
          control: StudioDropdown<String>(
            value: activeFraming.fitMode,
            items: _aspectRatioItems,
            onChanged: (val) {
              if (val != null) onFitModeChanged(val);
            },
          ),
        ),
        _buildSeparator(),
        _buildZoomControls(context),
        _buildSeparator(),
        _buildPanXControls(context),
        const SizedBox(height: 4),
        _buildPanYControls(context),
        _buildSeparator(),
        _buildRotationRow(),
        const SizedBox(height: 10),
        SettingRow(
          label: 'Mirror Active Camera',
          control: Transform.scale(
            scale: 0.75,
            child: CupertinoSwitch(
              value: activeFraming.mirror,
              activeTrackColor: StudioColors.accent,
              onChanged: onMirrorChanged,
            ),
          ),
        ),
      ],
    );
  }

  /// Simulator Controls view (Tab 2)
  Widget _buildSimulatorControlsView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_simulator'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(title: 'Simulator Controls'),
        const SizedBox(height: 12),
        SettingRow(
          label: 'Simulator Link',
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.checkmark_alt_circle_fill,
                size: 13,
                color: isSimCameraActive
                    ? StudioColors.success
                    : StudioColors.accent,
              ),
              const SizedBox(width: 5),
              Text(
                isSimCameraActive ? 'Connected' : 'Ready',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isSimCameraActive
                      ? StudioColors.success
                      : StudioColors.accent,
                ),
              ),
            ],
          ),
        ),
        _buildSeparator(),
        const Text(
          'Target Stream',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: StudioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        _buildTargetSegmentControl(),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _buildSmallButton(
                label: 'Open Simulator',
                icon: CupertinoIcons.device_phone_portrait,
                onTap: onOpenSimulator ?? () {},
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSmallButton(
                label: 'Apply Setup',
                icon: CupertinoIcons.bolt_fill,
                isPrimary: true,
                onTap: onStartSetup ?? () {},
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Precision Adjustments view (Tab 3)
  Widget _buildFineAdjustmentsView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_fine_tuning'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(
          title: 'Fine Adjustments',
          trailing: _buildResetButton(),
        ),
        const SizedBox(height: 12),
        _buildTargetSegmentControl(),
        const SizedBox(height: 14),
        _buildZoomControls(context),
        _buildSeparator(),
        _buildPanXControls(context),
        const SizedBox(height: 4),
        _buildPanYControls(context),
        _buildSeparator(),
        _buildRotationRow(),
        const SizedBox(height: 10),
        SettingRow(
          label: 'Mirror Flip',
          control: Transform.scale(
            scale: 0.75,
            child: CupertinoSwitch(
              value: activeFraming.mirror,
              activeTrackColor: StudioColors.accent,
              onChanged: onMirrorChanged,
            ),
          ),
        ),
      ],
    );
  }

  /// Media & Output Options view (Tab 4)
  Widget _buildMediaOptionsView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_media'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(title: 'Media Sources & Output'),
        const SizedBox(height: 12),
        SettingRow(
          label: 'Bundled Video',
          control: StudioDropdown<String>(
            value: bundledVideoAssets.contains(selectedBundledVideoAsset)
                ? selectedBundledVideoAsset
                : null,
            items: bundledVideoAssets
                .map(
                  (asset) => StudioDropdownItem<String>(
                    value: asset,
                    label: asset.split('/').last,
                    icon: CupertinoIcons.film,
                  ),
                )
                .toList(),
            onChanged: (val) {
              if (val != null) onBundledVideoSelected(val);
            },
          ),
        ),
        _buildSeparator(),
        if (customVideoPath != null ||
            currentSource == CameraSourceType.video) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  customVideoPath != null
                      ? customVideoPath!.split('/').last
                      : 'No video selected',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: StudioColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildSmallButton(label: 'Browse', onTap: onPickVideo),
            ],
          ),
          _buildSeparator(),
        ],
        if (customImagePath != null ||
            currentSource == CameraSourceType.image) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  customImagePath != null
                      ? customImagePath!.split('/').last
                      : 'No image selected',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: StudioColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildSmallButton(label: 'Browse', onTap: onPickImage),
            ],
          ),
          _buildSeparator(),
        ],
        _buildFormatSelectorBar(),
      ],
    );
  }

  Widget _buildSectionHeader({required String title, Widget? trailing}) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Expanded(
        child: Text(
          title,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: StudioColors.textPrimary,
            letterSpacing: -0.1,
          ),
        ),
      ),
      ?trailing,
    ],
  );

  Widget _buildResetButton() => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onResetTransform,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          'Reset',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: StudioColors.accent,
          ),
        ),
      ),
    ),
  );

  Widget _buildTargetSegmentControl() => Container(
    height: 30,
    padding: const EdgeInsets.all(2.5),
    decoration: BoxDecoration(
      color: StudioColors.controlFill,
      borderRadius: BorderRadius.circular(StudioRadii.control),
      border: Border.all(color: StudioColors.controlBorder, width: 0.8),
    ),
    child: Row(
      children: [
        _buildTargetSegment(
          'both',
          'Both (Synced)',
          CupertinoIcons.arrow_2_circlepath,
        ),
        _buildTargetSegment(
          'front',
          'Front Cam',
          CupertinoIcons.person_crop_circle,
        ),
        _buildTargetSegment('back', 'Back Cam', CupertinoIcons.camera_fill),
      ],
    ),
  );

  Widget _buildTargetSegment(String target, String title, IconData icon) {
    final isSelected = targetCamera == target;
    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTargetCameraSelected(target),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: isSelected ? StudioColors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(5.5),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 11,
                  color: isSelected ? Colors.white : StudioColors.textSecondary,
                ),
                const SizedBox(width: 4.5),
                Flexible(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isSelected
                          ? Colors.white
                          : StudioColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZoomControls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Zoom Level',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: StudioColors.textPrimary,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: StudioColors.controlFill,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: StudioColors.controlBorder, width: 0.5),
            ),
            child: Text(
              '${activeFraming.zoom.toStringAsFixed(2)}x',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: StudioColors.accent,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 2),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2.5,
          activeTrackColor: StudioColors.accent,
          inactiveTrackColor: const Color(0x28FFFFFF),
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        ),
        child: Slider(
          value: activeFraming.zoom,
          min: 0.5,
          max: 3.0,
          onChanged: onZoomChanged,
        ),
      ),
      const SizedBox(height: 2),
      Row(
        children: [0.75, 1.0, 1.25, 1.5, 2.0].map((preset) {
          final isSelected = (activeFraming.zoom - preset).abs() < 0.05;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onZoomChanged(preset),
                  child: Container(
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? StudioColors.accent
                          : StudioColors.controlFill,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: isSelected
                            ? Colors.transparent
                            : StudioColors.controlBorder,
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      '${preset}x',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? Colors.white
                            : StudioColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    ],
  );

  Widget _buildPanXControls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Pan Horizontal (X)',
            style: TextStyle(fontSize: 11.5, color: StudioColors.textPrimary),
          ),
          Text(
            '${(activeFraming.offsetX * 100).toInt()}%',
            style: const TextStyle(
              fontSize: 11,
              color: StudioColors.textSecondary,
            ),
          ),
        ],
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2.5,
          activeTrackColor: StudioColors.accent,
          inactiveTrackColor: const Color(0x28FFFFFF),
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        ),
        child: Slider(
          value: activeFraming.offsetX,
          min: -1.0,
          max: 1.0,
          onChanged: onOffsetXChanged,
        ),
      ),
    ],
  );

  Widget _buildPanYControls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Pan Vertical (Y)',
            style: TextStyle(fontSize: 11.5, color: StudioColors.textPrimary),
          ),
          Text(
            '${(activeFraming.offsetY * 100).toInt()}%',
            style: const TextStyle(
              fontSize: 11,
              color: StudioColors.textSecondary,
            ),
          ),
        ],
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2.5,
          activeTrackColor: StudioColors.accent,
          inactiveTrackColor: const Color(0x28FFFFFF),
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        ),
        child: Slider(
          value: activeFraming.offsetY,
          min: -1.0,
          max: 1.0,
          onChanged: onOffsetYChanged,
        ),
      ),
    ],
  );

  Widget _buildRotationRow() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      const Expanded(
        child: Text(
          'Rotation',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: StudioColors.textPrimary),
        ),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [0, 90, 180, 270].map((deg) {
          final isSelected = activeFraming.rotation == deg;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onRotationChanged(deg),
              child: Container(
                margin: const EdgeInsets.only(left: 3.5),
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? StudioColors.accent
                      : StudioColors.controlFill,
                  borderRadius: BorderRadius.circular(4.5),
                  border: Border.all(
                    color: isSelected
                        ? Colors.transparent
                        : StudioColors.controlBorder,
                    width: 0.5,
                  ),
                ),
                child: Text(
                  '$deg°',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Colors.white
                        : StudioColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    ],
  );

  Widget _buildSmallButton({
    required String label,
    required VoidCallback onTap,
    IconData? icon,
    bool isPrimary = false,
  }) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isPrimary ? StudioColors.accent : StudioColors.controlFill,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isPrimary ? Colors.transparent : StudioColors.controlBorder,
            width: 0.8,
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 11,
                color: isPrimary ? Colors.white : StudioColors.textPrimary,
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: isPrimary ? Colors.white : StudioColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildFormatSelectorBar() => Container(
    height: 30,
    padding: const EdgeInsets.all(2.5),
    decoration: BoxDecoration(
      color: StudioColors.controlFill,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: StudioColors.controlBorder, width: 0.6),
    ),
    child: Row(
      children: ['GIF', 'MP4', 'PNG'].map((format) {
        final isSelected = format == 'MP4';
        return Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.white.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4.5),
            ),
            alignment: Alignment.center,
            child: Text(
              format,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? Colors.white : StudioColors.textMuted,
              ),
            ),
          ),
        );
      }).toList(),
    ),
  );

  Widget _buildSeparator() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 5),
    child: Divider(color: Color(0x12FFFFFF), height: 1),
  );

  Widget _buildSectionDivider() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 12),
    child: Divider(color: Color(0x1EFFFFFF), height: 1),
  );
}
