import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import 'glass_panel.dart';

/// Compact presentation for simulator discovery, camera source selection,
/// connection state, and the native setup action.
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

  bool get _hasSimulator => simulatorName != null;

  @override
  Widget build(BuildContext context) {
    final statusColor = isDiscovering
        ? StudioColors.textSecondary
        : isConnected
        ? StudioColors.success
        : (_hasSimulator ? StudioColors.textSecondary : StudioColors.danger);
    final statusText = isDiscovering
        ? 'Checking'
        : isConnected
        ? 'Connected'
        : (_hasSimulator ? 'Simulator ready' : 'No simulator');

    return GlassPanel(
      padding: const EdgeInsets.all(18),
      radius: 20,
      blurSigma: 22,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Simulator Camera',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: StudioColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                label: 'Simulator status: $statusText',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusText,
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _sourceSelector(),
          const SizedBox(height: 12),
          _simulatorDetails(),
          if (setupError != null || setupMessage != null || setupComplete) ...[
            const SizedBox(height: 10),
            _setupFeedback(),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 34,
            child: ElevatedButton(
              onPressed: _hasSimulator && !isSettingUp && !isDiscovering
                  ? onStartSetup
                  : null,
              style:
                  ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: StudioColors.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white.withValues(
                      alpha: .07,
                    ),
                    disabledForegroundColor: StudioColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ).copyWith(
                    overlayColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.pressed)) {
                        return Colors.white.withValues(alpha: .12);
                      }
                      if (states.contains(WidgetState.hovered)) {
                        return Colors.white.withValues(alpha: .07);
                      }
                      return null;
                    }),
                    side: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.focused)
                          ? const BorderSide(
                              color: Color(0xFF8FC5FF),
                              width: 1.5,
                            )
                          : BorderSide.none,
                    ),
                  ),
              child: isSettingUp
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Start Setup'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceSelector() => Container(
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .055),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: Colors.white.withValues(alpha: .11)),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<CameraSourceType>(
        value: source,
        isExpanded: true,
        borderRadius: BorderRadius.circular(9),
        dropdownColor: const Color(0xFF292A2D),
        icon: const Icon(CupertinoIcons.chevron_down, size: 13),
        style: const TextStyle(fontSize: 12, color: StudioColors.textPrimary),
        items: CameraSourceType.values
            .map(
              (item) => DropdownMenuItem(
                value: item,
                child: Text(item.title, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(growable: false),
        onChanged: (value) {
          if (value != null) onSourceChanged(value);
        },
      ),
    ),
  );

  Widget _simulatorDetails() {
    final simulator = isDiscovering
        ? 'Checking for simulators…'
        : (simulatorName ?? 'No booted simulator detected');
    final appDescription = appBundle == null
        ? (isDiscovering
              ? 'Detecting booted devices'
              : (_hasSimulator
                    ? 'Waiting for an app connection'
                    : 'Open a simulator to begin'))
        : '${appBundle!.split('.').last} · ${isCameraActive ? 'Camera active ($activeCamera)' : 'Connected'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          simulator,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: StudioColors.textPrimary),
        ),
        const SizedBox(height: 3),
        Text(
          appDescription,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            color: StudioColors.textSecondary,
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
            ? CupertinoIcons.checkmark_circle_fill
            : CupertinoIcons.exclamationmark_circle_fill,
        size: 13,
        color: setupError == null ? StudioColors.success : StudioColors.danger,
      ),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          setupError ?? setupMessage ?? 'Setup is active for this simulator.',
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: setupError == null
                ? StudioColors.textSecondary
                : StudioColors.danger,
          ),
        ),
      ),
    ],
  );
}
