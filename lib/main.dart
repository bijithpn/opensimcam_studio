import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenSimCamApp());
}

class OpenSimCamApp extends StatelessWidget {
  const OpenSimCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenSimCam Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0C0E14),
        fontFamily: '.AppleSystemUIFont',
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF8B5CF6),
          surface: Color(0xFF141824),
        ),
      ),
      home: const OpenSimCamStudioHome(),
    );
  }
}

enum CameraSourceType {
  demoVideo(
    title: 'Demo Video',
    icon: CupertinoIcons.play_rectangle_fill,
    tooltip: 'Looping demo motion video',
  ),
  passthrough(
    title: 'Passthrough',
    icon: CupertinoIcons.macwindow,
    tooltip: 'Mac UI behind Simulator',
  ),
  webcam(
    title: 'Webcam',
    icon: CupertinoIcons.video_camera_solid,
    tooltip: 'FaceTime HD / USB camera',
  ),
  image(
    title: 'Image',
    icon: CupertinoIcons.photo_fill,
    tooltip: 'Custom PNG, JPG or HEIC image',
  ),
  video(
    title: 'Video',
    icon: CupertinoIcons.film_fill,
    tooltip: 'Custom MP4 or MOV video',
  ),
  qrCode(
    title: 'QR Code',
    icon: CupertinoIcons.qrcode,
    tooltip: 'Dynamic QR generator & barcode metadata',
  ),
  testPattern(
    title: 'Test Bars',
    icon: CupertinoIcons.tv_fill,
    tooltip: 'SMPTE diagnostic color bars',
  );

  final String title;
  final IconData icon;
  final String tooltip;
  const CameraSourceType({
    required this.title,
    required this.icon,
    required this.tooltip,
  });
}

class OpenSimCamStudioHome extends StatefulWidget {
  const OpenSimCamStudioHome({super.key});

  @override
  State<OpenSimCamStudioHome> createState() => _OpenSimCamStudioHomeState();
}

class _OpenSimCamStudioHomeState extends State<OpenSimCamStudioHome> {
  static const MethodChannel _controlChannel =
      MethodChannel('com.opensimcam.studio/control');
  static const EventChannel _previewChannel =
      EventChannel('com.opensimcam.studio/preview');

  // Default to demoVideo so no permissions are requested on startup!
  CameraSourceType _currentSource = CameraSourceType.demoVideo;
  StreamSubscription? _previewSubscription;
  Timer? _statusPollTimer;
  Uint8List? _previewFrame;

  List<Map<String, dynamic>> _bootedSimulators = [];
  String? _connectedAppBundle;
  List<Map<String, String>> _availableCameras = [];
  String? _selectedCameraId;
  String _fitMode = 'fill';
  bool _hasScreenCapturePermission = true;

  // Custom paths
  String? _customImagePath;
  String? _customVideoPath;
  final TextEditingController _qrController =
      TextEditingController(text: 'https://github.com');

  @override
  void initState() {
    super.initState();
    _initMethodChannelHandler();
    _initPreviewStream();
    _loadInitialState();
    _startPeriodicStatusCheck();
  }

  @override
  void dispose() {
    _previewSubscription?.cancel();
    _statusPollTimer?.cancel();
    _qrController.dispose();
    super.dispose();
  }

  void _initMethodChannelHandler() {
    _controlChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSimulatorsUpdated':
          if (call.arguments is List) {
            final list = (call.arguments as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            if (mounted) {
              setState(() {
                _bootedSimulators = list;
              });
            }
          }
          break;
        case 'onClientConnected':
          if (call.arguments is Map) {
            final args = call.arguments as Map;
            if (mounted) {
              setState(() {
                _connectedAppBundle = args['bundleId']?.toString();
              });
            }
          }
          break;
      }
    });
  }

  void _initPreviewStream() {
    _previewSubscription =
        _previewChannel.receiveBroadcastStream().listen((dynamic event) {
      if (event is Uint8List && mounted) {
        setState(() {
          _previewFrame = event;
        });
      }
    }, onError: (e) {
      debugPrint('Preview stream error: $e');
    });
  }

  Future<void> _loadInitialState() async {
    await _fetchCameras();
    await _fetchSimulators();
    await _activateSource(_currentSource);
  }

  void _startPeriodicStatusCheck() {
    _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchSimulators();
    });
  }

  Future<void> _fetchCameras() async {
    try {
      final cameras =
          await _controlChannel.invokeListMethod<Map>('getCameras');
      if (cameras != null && mounted) {
        setState(() {
          _availableCameras = cameras
              .map((c) => {
                    'name': c['name']?.toString() ?? 'Camera',
                    'id': c['id']?.toString() ?? '',
                  })
              .toList();
          if (_availableCameras.isNotEmpty && _selectedCameraId == null) {
            _selectedCameraId = _availableCameras.first['id'];
          }
        });
      }
    } catch (e) {
      debugPrint('Error fetching cameras: $e');
    }
  }

  Future<void> _fetchSimulators() async {
    try {
      final sims =
          await _controlChannel.invokeListMethod<Map>('getBootedSimulators');
      if (sims != null && mounted) {
        setState(() {
          _bootedSimulators = sims
              .map((s) => Map<String, dynamic>.from(s))
              .toList();
        });
      }
    } catch (e) {
      debugPrint('Error fetching simulators: $e');
    }
  }

  Future<void> _activateSource(CameraSourceType source) async {
    setState(() => _currentSource = source);
    try {
      switch (source) {
        case CameraSourceType.passthrough:
          final hasPerm = await _controlChannel
                  .invokeMethod<bool>('checkScreenCapturePermission') ??
              false;
          setState(() => _hasScreenCapturePermission = hasPerm);
          if (!hasPerm) {
            // Request permission once without looping
            await _controlChannel
                .invokeMethod('requestScreenCapturePermission');
            return;
          }
          await _controlChannel.invokeMethod('startPassthrough');
          break;

        case CameraSourceType.webcam:
          await _controlChannel.invokeMethod('startCamera', {
            'deviceId': _selectedCameraId,
          });
          break;

        case CameraSourceType.demoVideo:
          final tempDir = Directory.systemTemp;
          final demoPath = '${tempDir.path}/opensimcam_demo_video.mp4';
          final file = File(demoPath);
          if (!await file.exists()) {
            final byteData = await rootBundle.load('assets/demo_video.mp4');
            await file.writeAsBytes(byteData.buffer.asUint8List());
          }
          await _controlChannel.invokeMethod('startVideo', {'path': demoPath});
          break;

        case CameraSourceType.image:
          if (_customImagePath != null) {
            await _controlChannel
                .invokeMethod('startImage', {'path': _customImagePath});
          }
          break;

        case CameraSourceType.video:
          if (_customVideoPath != null) {
            await _controlChannel
                .invokeMethod('startVideo', {'path': _customVideoPath});
          }
          break;

        case CameraSourceType.qrCode:
          await _controlChannel
              .invokeMethod('startQR', {'text': _qrController.text});
          break;

        case CameraSourceType.testPattern:
          await _controlChannel.invokeMethod('startTestPattern');
          break;
      }
    } catch (e) {
      debugPrint('Error activating source $source: $e');
    }
  }

  Future<void> _openSystemSettings() async {
    await _controlChannel.invokeMethod('openSystemPreferencesScreenCapture');
  }

  Future<void> _pickImageFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'heic', 'webp', 'tiff'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _customImagePath = result.files.single.path;
      });
      await _activateSource(CameraSourceType.image);
    }
  }

  Future<void> _pickVideoFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'm4v'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _customVideoPath = result.files.single.path;
      });
      await _activateSource(CameraSourceType.video);
    }
  }

  Future<void> _toggleFitMode() async {
    final newMode = _fitMode == 'fill' ? 'fit' : 'fill';
    setState(() => _fitMode = newMode);
    await _controlChannel.invokeMethod('setFitMode', {'mode': newMode});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient Mesh
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.0, -0.6),
                  radius: 1.2,
                  colors: [
                    Color(0xFF161C2C),
                    Color(0xFF0C0E14),
                  ],
                ),
              ),
            ),
          ),

          // Compact Companion Layout
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                children: [
                  const SizedBox(height: 8),

                  // Compact Header
                  _buildHeaderBar(),
                  const SizedBox(height: 8),

                  // Simulator Auto-Detect Status Pill
                  _buildSimulatorStatusPill(),
                  const SizedBox(height: 10),

                  // Main Viewfinder
                  Expanded(
                    child: Center(
                      child: _buildCentralViewfinder(),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Contextual Controls (Dropdown / Pickers / QR Field)
                  _buildContextualControlsBar(),
                  const SizedBox(height: 8),

                  // Bottom Dock (Source Selector)
                  _buildFloatingDock(),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderBar() {
    return Row(
      children: [
        // App Title
        _buildGlassPill(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF3B82F6), Color(0xFF6366F1)],
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Icon(
                  CupertinoIcons.camera_fill,
                  size: 11,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'OpenSimCam',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),

        const Spacer(),

        // Aspect Fill / Fit Switch
        GestureDetector(
          onTap: _toggleFitMode,
          child: _buildGlassPill(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _fitMode == 'fill'
                      ? CupertinoIcons.arrow_up_left_arrow_down_right
                      : CupertinoIcons.viewfinder,
                  size: 12,
                  color: const Color(0xFF60A5FA),
                ),
                const SizedBox(width: 6),
                Text(
                  _fitMode == 'fill' ? 'Fill' : 'Fit',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _relaunchApp(String bundleId, String udid) async {
    try {
      await _controlChannel.invokeMethod('relaunchApp', {
        'bundleId': bundleId,
        'udid': udid,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Relaunched $bundleId with camera hooked!'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error relaunching app: $e');
    }
  }

  Widget _buildSimulatorStatusPill() {
    final hasBootedSim = _bootedSimulators.isNotEmpty;
    final firstSim = hasBootedSim ? _bootedSimulators.first : null;
    final simName = firstSim?['name'];
    final runningApp = firstSim?['runningAppBundle']?.toString();
    final targetBundle = _connectedAppBundle ?? runningApp;

    return _buildGlassPill(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasBootedSim
                  ? const Color(0xFF10B981)
                  : const Color(0xFF9CA3AF),
              boxShadow: hasBootedSim
                  ? [
                      BoxShadow(
                        color: const Color(0xFF10B981).withOpacity(0.5),
                        blurRadius: 5,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasBootedSim
                  ? 'Sim: $simName (Auto-Synced)'
                  : 'Waiting for iOS Simulator...',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: hasBootedSim ? Colors.white : const Color(0xFF9CA3AF),
              ),
            ),
          ),
          if (targetBundle != null && firstSim != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _relaunchApp(targetBundle, firstSim['udid']),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: const Color(0xFF10B981).withOpacity(0.35),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.arrow_2_circlepath,
                      size: 9,
                      color: Color(0xFF6EE7B7),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      targetBundle.split('.').last,
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6EE7B7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCentralViewfinder() {
    final isPassthroughDenied =
        _currentSource == CameraSourceType.passthrough &&
            !_hasScreenCapturePermission;

    return AspectRatio(
      aspectRatio: 9 / 16,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: const Color(0xFF3B82F6).withOpacity(0.06),
              blurRadius: 30,
              spreadRadius: 1,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Dark Frame Backdrop
              Container(color: const Color(0xFF07080D)),

              // Live Preview Feed
              if (_previewFrame != null && !isPassthroughDenied)
                Image.memory(
                  _previewFrame!,
                  gaplessPlayback: true,
                  fit: _fitMode == 'fill' ? BoxFit.cover : BoxFit.contain,
                )
              else if (!isPassthroughDenied)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.04),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Icon(
                        _currentSource.icon,
                        size: 26,
                        color: const Color(0xFF60A5FA),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _currentSource.title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Streaming to Simulator camera',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),

              // Screen Recording Permission Request Overlay
              if (isPassthroughDenied)
                Container(
                  padding: const EdgeInsets.all(20),
                  color: Colors.black.withOpacity(0.85),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.lock_shield_fill,
                          size: 32,
                          color: Color(0xFFFBBF24),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Screen Recording Required',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'To capture what is behind the Simulator, grant Screen Recording access in macOS System Settings.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _openSystemSettings,
                        icon: const Icon(CupertinoIcons.settings, size: 13),
                        label: const Text(
                          'Open System Settings',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => _activateSource(CameraSourceType.passthrough),
                        child: const Text(
                          'I Granted It (Retry)',
                          style: TextStyle(fontSize: 11, color: Color(0xFF60A5FA)),
                        ),
                      ),
                    ],
                  ),
                ),

              // Glass Live Badge (Top-Left)
              Positioned(
                top: 10,
                left: 10,
                child: _buildGlassPill(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Colors.white.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Source Badge (Bottom-Left)
              Positioned(
                bottom: 10,
                left: 10,
                child: _buildGlassPill(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _currentSource.icon,
                        size: 11,
                        color: const Color(0xFF93C5FD),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _currentSource.title,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE2E8F0),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContextualControlsBar() {
    Widget? content;

    if (_currentSource == CameraSourceType.webcam) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Camera:',
            style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedCameraId,
              dropdownColor: const Color(0xFF1E2436),
              borderRadius: BorderRadius.circular(8),
              style: const TextStyle(fontSize: 11, color: Colors.white),
              items: _availableCameras.map((c) {
                return DropdownMenuItem<String>(
                  value: c['id'],
                  child: Text(c['name'] ?? 'Camera'),
                );
              }).toList(),
              onChanged: (id) {
                setState(() => _selectedCameraId = id);
                _activateSource(CameraSourceType.webcam);
              },
            ),
          ),
        ],
      );
    } else if (_currentSource == CameraSourceType.image) {
      final name = _customImagePath != null
          ? _customImagePath!.split('/').last
          : 'No file';
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          const SizedBox(width: 8),
          _buildActionBtn('Choose Image', CupertinoIcons.photo, _pickImageFile),
        ],
      );
    } else if (_currentSource == CameraSourceType.video) {
      final name = _customVideoPath != null
          ? _customVideoPath!.split('/').last
          : 'No file';
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          const SizedBox(width: 8),
          _buildActionBtn('Choose Video', CupertinoIcons.film, _pickVideoFile),
        ],
      );
    } else if (_currentSource == CameraSourceType.qrCode) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 170,
            child: CupertinoTextField(
              controller: _qrController,
              placeholder: 'URL or barcode text...',
              style: const TextStyle(fontSize: 11, color: Colors.white),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              onSubmitted: (_) => _activateSource(CameraSourceType.qrCode),
            ),
          ),
          const SizedBox(width: 6),
          _buildActionBtn('Apply', CupertinoIcons.arrow_clockwise, () {
            _activateSource(CameraSourceType.qrCode);
          }),
        ],
      );
    }

    if (content == null) {
      return const SizedBox.shrink();
    }

    return _buildGlassPill(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: content,
    );
  }

  Widget _buildActionBtn(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF3B82F6).withOpacity(0.2),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: const Color(0xFF60A5FA)),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF93C5FD),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingDock() {
    return _buildGlassPill(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: CameraSourceType.values.map((src) {
            final isSelected = _currentSource == src;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Tooltip(
                message: src.tooltip,
                child: GestureDetector(
                  onTap: () async {
                    if (src == CameraSourceType.image && _customImagePath == null) {
                      await _pickImageFile();
                    } else if (src == CameraSourceType.video &&
                        _customVideoPath == null) {
                      await _pickVideoFile();
                    } else {
                      await _activateSource(src);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF3B82F6).withOpacity(0.25)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF3B82F6).withOpacity(0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          src.icon,
                          size: 13,
                          color: isSelected
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFF94A3B8),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          src.title,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w500,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildGlassPill({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(10),
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.045),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
