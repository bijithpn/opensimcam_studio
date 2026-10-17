import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/camera_framing.dart';
import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import 'glass_panel.dart';
import 'setting_row.dart';
import 'studio_dropdown.dart';

class MainSettingsPanel extends StatefulWidget {
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

  @override
  State<MainSettingsPanel> createState() => _MainSettingsPanelState();
}

class _MainSettingsPanelState extends State<MainSettingsPanel> {
  String _activeMediaMode = 'demo'; // 'demo', 'video', 'image'

  @override
  void initState() {
    super.initState();
    _syncMediaMode();
  }

  @override
  void didUpdateWidget(MainSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSource != widget.currentSource) {
      _syncMediaMode();
    }
  }

  void _syncMediaMode() {
    if (widget.currentSource == CameraSourceType.image) {
      _activeMediaMode = 'image';
    } else if (widget.customVideoPath != null &&
        widget.currentSource == CameraSourceType.video) {
      _activeMediaMode = 'video';
    } else {
      _activeMediaMode = 'demo';
    }
  }

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
    switch (widget.selectedTab) {
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
        return _buildCameraStreamView(context);
    }
  }

  /// Dedicated Camera Configuration view (Tab 0)
  Widget _buildCameraStreamView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_camera_stream'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(
          title: 'Camera Configuration',
          trailing: _buildResetButton(),
        ),
        const SizedBox(height: 14),

        // Active Stream Source
        SettingRow(
          label: 'Active Source',
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.currentSource == CameraSourceType.webcam
                    ? CupertinoIcons.camera
                    : (widget.currentSource == CameraSourceType.video
                          ? CupertinoIcons.film
                          : CupertinoIcons.photo),
                size: 13,
                color: StudioColors.accent,
              ),
              const SizedBox(width: 6),
              Text(
                widget.currentSource == CameraSourceType.webcam
                    ? 'Mac Webcam'
                    : (widget.currentSource == CameraSourceType.video
                          ? 'Video Loop'
                          : 'Still Image'),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: StudioColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        _buildSeparator(),

        // Mac Camera (if webcam)
        if (widget.currentSource == CameraSourceType.webcam &&
            widget.availableCameras.isNotEmpty) ...[
          SettingRow(
            label: 'Mac Camera',
            control: SizedBox(
              width: 145,
              child: StudioDropdown<String>(
                value: widget.selectedCameraId,
                items: widget.availableCameras
                    .map(
                      (c) => StudioDropdownItem<String>(
                        value: c['id'] ?? '',
                        label: c['name'] ?? 'Camera',
                        icon: CupertinoIcons.camera,
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val != null) widget.onCameraSelected(val);
                },
              ),
            ),
          ),
          _buildSeparator(),
        ],

        // Dual Camera Stream status
        SettingRow(
          label: 'Dual Camera Stream',
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.checkmark_alt_circle_fill,
                size: 13,
                color: StudioColors.success,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.isSimCameraActive
                      ? 'Streaming: ${widget.simActiveCamera.toUpperCase()}'
                      : 'Streaming: FRONT',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: StudioColors.success,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Focused Framing & Aspect view (Tab 1) - Aspect ratio, fit modes, rotation presets & mirror
  Widget _buildFramingOnlyView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_framing'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(
          title: 'Aspect Ratio & Framing',
          trailing: _buildResetButton(),
        ),
        const SizedBox(height: 14),

        // Aspect Ratio Dropdown
        SettingRow(
          label: 'Aspect Ratio',
          control: SizedBox(
            width: 155,
            child: StudioDropdown<String>(
              value: widget.activeFraming.fitMode,
              items: _aspectRatioItems,
              onChanged: (val) {
                if (val != null) widget.onFitModeChanged(val);
              },
            ),
          ),
        ),
        _buildSeparator(),

        // Rotation Row
        _buildRotationRow(),
        _buildSeparator(),

        const SizedBox(height: 10),

        // Mirror Active Camera
        SettingRow(
          label: widget.targetCamera == 'front'
              ? 'Mirror Front Camera'
              : (widget.targetCamera == 'back'
                    ? 'Mirror Back Camera'
                    : 'Mirror Cameras'),
          control: Transform.scale(
            scale: 0.75,
            child: CupertinoSwitch(
              value: widget.activeFraming.mirror,
              activeTrackColor: StudioColors.accent,
              onChanged: widget.onMirrorChanged,
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
                color: widget.isSimCameraActive
                    ? StudioColors.success
                    : StudioColors.accent,
              ),
              const SizedBox(width: 5),
              Text(
                widget.isSimCameraActive ? 'Connected' : 'Ready',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: widget.isSimCameraActive
                      ? StudioColors.success
                      : StudioColors.accent,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _buildSmallButton(
                label: 'Open Simulator',
                icon: CupertinoIcons.device_phone_portrait,
                onTap: widget.onOpenSimulator ?? () {},
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSmallButton(
                label: 'Apply Setup',
                icon: CupertinoIcons.bolt_fill,
                isPrimary: true,
                onTap: widget.onStartSetup ?? () {},
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Precision Adjustments view (Tab 3) - Sliders, Zoom, Pan X/Y with breathing space
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
        const SizedBox(height: 14),
        _buildTargetSegmentControl(),
        const SizedBox(height: 16),

        // Zoom Controls
        _buildZoomControls(context),
        _buildSeparator(),

        // Pan Horizontal (X)
        _buildPanXControls(context),
        const SizedBox(height: 8),

        // Pan Vertical (Y)
        _buildPanYControls(context),
        _buildSeparator(),

        // Quick Centering & Reset Row
        Row(
          children: [
            Expanded(
              child: _buildSmallButton(
                label: 'Center Pan (0,0)',
                icon: CupertinoIcons.scope,
                onTap: () {
                  widget.onOffsetXChanged(0.0);
                  widget.onOffsetYChanged(0.0);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSmallButton(
                label: 'Reset Zoom (1.0x)',
                icon: CupertinoIcons.arrow_counterclockwise,
                onTap: () => widget.onZoomChanged(1.0),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Media & Output Options view (Tab 4) - Interactive Demo / Custom Video / Still Image selection
  Widget _buildMediaOptionsView(BuildContext context) {
    return Column(
      key: const ValueKey('tab_media'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(title: 'Media Sources & Output'),
        const SizedBox(height: 14),

        // Interactive Media Mode Selector: Demo Video (Default) | Video File | Image File
        _buildMediaModeSelector(),
        const SizedBox(height: 14),

        if (_activeMediaMode == 'demo') ...[
          SettingRow(
            label: 'Bundled Video',
            control: SizedBox(
              width: 155,
              child: StudioDropdown<String>(
                value:
                    widget.bundledVideoAssets.contains(
                      widget.selectedBundledVideoAsset,
                    )
                    ? widget.selectedBundledVideoAsset
                    : null,
                items: widget.bundledVideoAssets
                    .map(
                      (asset) => StudioDropdownItem<String>(
                        value: asset,
                        label: asset.split('/').last,
                        icon: CupertinoIcons.film,
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val != null) widget.onBundledVideoSelected(val);
                },
              ),
            ),
          ),
          _buildSeparator(),
          Row(
            children: [
              const Icon(
                CupertinoIcons.repeat,
                size: 12,
                color: StudioColors.accent,
              ),
              Expanded(
                child: Text(
                  'Auto-loops bundled demo video',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: StudioColors.textSecondary.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ] else if (_activeMediaMode == 'video') ...[
          SettingRow(
            label: 'Custom Video',
            control: _buildSmallButton(
              label: 'Browse',
              icon: CupertinoIcons.folder,
              onTap: widget.onPickVideo,
            ),
          ),
          _buildSeparator(),
          Row(
            children: [
              const Icon(
                CupertinoIcons.videocam_fill,
                size: 13,
                color: StudioColors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.customVideoPath != null
                      ? widget.customVideoPath!.split('/').last
                      : 'No video selected (click Browse to choose)',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: StudioColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ] else if (_activeMediaMode == 'image') ...[
          SettingRow(
            label: 'Custom Image',
            control: _buildSmallButton(
              label: 'Browse',
              icon: CupertinoIcons.folder,
              onTap: widget.onPickImage,
            ),
          ),
          _buildSeparator(),
          Row(
            children: [
              const Icon(
                CupertinoIcons.photo,
                size: 13,
                color: StudioColors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.customImagePath != null
                      ? widget.customImagePath!.split('/').last
                      : 'No image selected (click Browse to choose)',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: StudioColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMediaModeSelector() {
    return Container(
      height: 32,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: StudioColors.controlFill,
        borderRadius: BorderRadius.circular(StudioRadii.control),
        border: Border.all(color: StudioColors.controlBorder, width: 0.8),
      ),
      child: Row(
        children: [
          _buildMediaModeSegment('demo', 'Demo', CupertinoIcons.film),
          _buildMediaModeSegment(
            'video',
            'Video',
            CupertinoIcons.videocam_fill,
          ),
          _buildMediaModeSegment('image', 'Image', CupertinoIcons.photo),
        ],
      ),
    );
  }

  Widget _buildMediaModeSegment(String mode, String label, IconData icon) {
    final isSelected = _activeMediaMode == mode;
    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _activeMediaMode = mode);
            if (mode == 'demo') {
              widget.onBundledVideoSelected(widget.selectedBundledVideoAsset);
            } else if (mode == 'video') {
              if (widget.customVideoPath == null) {
                widget.onPickVideo();
              }
            } else if (mode == 'image') {
              if (widget.customImagePath == null) {
                widget.onPickImage();
              }
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? StudioColors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(5.5),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: StudioColors.accent.withValues(alpha: 0.35),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 11.5,
                  color: isSelected ? Colors.white : StudioColors.textSecondary,
                ),
                const SizedBox(width: 4.5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: -0.1,
                    color: isSelected
                        ? Colors.white
                        : StudioColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
      onTap: widget.onResetTransform,
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
    height: 32,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: StudioColors.controlFill,
      borderRadius: BorderRadius.circular(StudioRadii.control),
      border: Border.all(color: StudioColors.controlBorder, width: 0.8),
    ),
    child: Row(
      children: [
        _buildTargetSegment('both', 'Both', CupertinoIcons.arrow_2_circlepath),
        _buildTargetSegment(
          'front',
          'Front',
          CupertinoIcons.person_crop_circle,
        ),
        _buildTargetSegment('back', 'Back', CupertinoIcons.camera_fill),
      ],
    ),
  );

  Widget _buildTargetSegment(String target, String title, IconData icon) {
    final isSelected = widget.targetCamera == target;
    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onTargetCameraSelected(target),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: isSelected ? StudioColors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(5.5),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: StudioColors.accent.withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 11.5,
                  color: isSelected ? Colors.white : StudioColors.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: -0.1,
                    color: isSelected
                        ? Colors.white
                        : StudioColors.textSecondary,
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
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: StudioColors.textPrimary,
              letterSpacing: -0.1,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: StudioColors.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: StudioColors.accent.withValues(alpha: 0.35),
                width: 0.8,
              ),
            ),
            child: Text(
              '${widget.activeFraming.zoom.toStringAsFixed(2)}x',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: StudioColors.accent,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3.0,
          activeTrackColor: StudioColors.accent,
          inactiveTrackColor: const Color(0x28FFFFFF),
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          value: widget.activeFraming.zoom,
          min: 0.5,
          max: 3.0,
          onChanged: widget.onZoomChanged,
        ),
      ),
      const SizedBox(height: 8),
      Container(
        height: 28,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          color: StudioColors.controlFill,
          borderRadius: BorderRadius.circular(StudioRadii.control),
          border: Border.all(color: StudioColors.controlBorder, width: 0.8),
        ),
        child: Row(
          children: [0.75, 1.0, 1.25, 1.5, 2.0].map((preset) {
            final isSelected =
                (widget.activeFraming.zoom - preset).abs() < 0.05;
            return Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onZoomChanged(preset),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? StudioColors.accent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: StudioColors.accent.withValues(
                                  alpha: 0.35,
                                ),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      '${preset}x',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        letterSpacing: -0.1,
                        color: isSelected
                            ? Colors.white
                            : StudioColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: StudioColors.textPrimary,
              letterSpacing: -0.1,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: StudioColors.controlFill,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: StudioColors.controlBorder, width: 0.6),
            ),
            child: Text(
              '${(widget.activeFraming.offsetX * 100).toInt()}%',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: StudioColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3.0,
          activeTrackColor: StudioColors.accent,
          inactiveTrackColor: const Color(0x28FFFFFF),
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          value: widget.activeFraming.offsetX,
          min: -1.0,
          max: 1.0,
          onChanged: widget.onOffsetXChanged,
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: StudioColors.textPrimary,
              letterSpacing: -0.1,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: StudioColors.controlFill,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: StudioColors.controlBorder, width: 0.6),
            ),
            child: Text(
              '${(widget.activeFraming.offsetY * 100).toInt()}%',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: StudioColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3.0,
          activeTrackColor: StudioColors.accent,
          inactiveTrackColor: const Color(0x28FFFFFF),
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          value: widget.activeFraming.offsetY,
          min: -1.0,
          max: 1.0,
          onChanged: widget.onOffsetYChanged,
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
          final isSelected = widget.activeFraming.rotation == deg;
          return Padding(
            padding: const EdgeInsets.only(left: 4),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onRotationChanged(deg),
                child: Container(
                  width: 32,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? StudioColors.accent
                        : StudioColors.controlFill,
                    borderRadius: BorderRadius.circular(4),
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
                      fontSize: 9.5,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isSelected
                          ? Colors.white
                          : StudioColors.textSecondary,
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

  Widget _buildSeparator() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 5),
    child: Divider(color: Color(0x12FFFFFF), height: 1),
  );
}
