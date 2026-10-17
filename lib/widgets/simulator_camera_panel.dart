import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import 'glass_panel.dart';
import 'studio_dropdown.dart';

class SimulatorCameraPanel extends StatelessWidget {
  const SimulatorCameraPanel({
    required this.source,
    required this.onSourceChanged,
    required this.simulatorName,
    required this.isDiscovering,
    required this.appBundle,
    required this.isConnected,
    required this.isCameraActive,
    required this.activeCamera,
    required this.isSettingUp,
    required this.setupComplete,
    required this.setupMessage,
    required this.setupError,
    required this.onStartSetup,
    required this.onOpenSimulator,
    super.key,
  });

  final CameraSourceType source;
  final ValueChanged<CameraSourceType> onSourceChanged;
  final String? simulatorName;
  final bool isDiscovering;
  final String? appBundle;
  final bool isConnected;
  final bool isCameraActive;
  final String activeCamera;
  final bool isSettingUp;
  final bool setupComplete;
  final String? setupMessage;
  final String? setupError;
  final VoidCallback onStartSetup;
  final VoidCallback onOpenSimulator;

  bool get _hasSimulator => simulatorName != null;

  @override
  Widget build(BuildContext context) {
    final Color statusColor;
    final String statusText;

    if (isDiscovering) {
      statusColor = StudioColors.warning;
      statusText = 'Checking';
    } else if (isConnected) {
      statusColor = StudioColors.success;
      statusText = 'Connected';
    } else if (_hasSimulator) {
      statusColor = const Color(0xFF38BDF8); // Crisp Sky Blue
      statusText = 'Simulator Ready';
    } else {
      statusColor = StudioColors.danger;
      statusText = 'No Simulator';
    }

    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      radius: StudioRadii.panel,
      tint: StudioColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with Title and Styled Status Capsule
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Simulator Camera',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: StudioColors.textPrimary,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.32),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withValues(alpha: 0.6),
                            blurRadius: 4,
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Native macOS Dropdown for Camera Source with custom icons
          StudioDropdown<CameraSourceType>(
            value: source,
            height: 36,
            isExpanded: true,
            fontSize: 12,
            items: CameraSourceType.values.map((item) {
              return StudioDropdownItem<CameraSourceType>(
                value: item,
                label: item.title,
                icon: item.icon,
                iconColor: StudioColors.accent,
              );
            }).toList(),
            onChanged: (val) {
              if (val != null) onSourceChanged(val);
            },
          ),
          const SizedBox(height: 12),

          // Contextual status info
          _simulatorDetails(),

          if (setupError != null ||
              setupMessage != null ||
              (!isConnected && _hasSimulator)) ...[
            const SizedBox(height: 8),
            _setupFeedback(),
          ],

          if (!isConnected || isSettingUp || !_hasSimulator) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 32,
              child: ElevatedButton(
                onPressed: isDiscovering || isSettingUp
                    ? null
                    : _hasSimulator
                    ? onStartSetup
                    : onOpenSimulator,
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  backgroundColor: StudioColors.accent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white.withValues(alpha: .06),
                  disabledForegroundColor: StudioColors.textMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(StudioRadii.control),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
                child: isSettingUp
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(_hasSimulator ? 'Start Setup' : 'Open Simulator'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _simulatorDetails() {
    final simulator = isDiscovering
        ? 'Checking for simulators…'
        : (simulatorName ?? 'No booted simulator detected');

    final appDescription = appBundle == null
        ? (isDiscovering
              ? 'Detecting active device'
              : (_hasSimulator
                    ? 'Waiting for an app connection'
                    : 'Open iOS Simulator to begin'))
        : '${appBundle!.split('.').last} · ${isCameraActive
              ? 'Active ($activeCamera)'
              : isConnected
              ? 'Connected'
              : 'Waiting for camera'}';

    return Row(
      children: [
        const Icon(
          CupertinoIcons.device_phone_portrait,
          size: 12,
          color: StudioColors.textMuted,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: simulator,
                  style: TextStyle(
                    fontWeight: _hasSimulator
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: _hasSimulator
                        ? StudioColors.textPrimary
                        : StudioColors.textMuted,
                  ),
                ),
                TextSpan(
                  text: ' · $appDescription',
                  style: const TextStyle(color: StudioColors.textSecondary),
                ),
              ],
            ),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _setupFeedback() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        setupError == null
            ? CupertinoIcons.checkmark_alt_circle_fill
            : CupertinoIcons.exclamationmark_circle_fill,
        size: 13,
        color: setupError == null ? StudioColors.success : StudioColors.danger,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          setupError ?? setupMessage ?? 'Camera setup is active.',
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.25,
            color: setupError == null
                ? StudioColors.textSecondary
                : StudioColors.danger,
          ),
        ),
      ),
    ],
  );
}
