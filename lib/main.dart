import 'dart:async';
import 'dart:io';
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
        scaffoldBackgroundColor: const Color(0xFF0F111A),
        fontFamily: '.AppleSystemUIFont',
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          surface: Color(0xFF161926),
        ),
      ),
      home: const OpenSimCamInspectorHome(),
    );
  }
}

enum CameraSourceType {
  webcam('FaceTime HD Camera', CupertinoIcons.video_camera_solid),
  passthrough('Screen Passthrough', CupertinoIcons.macwindow),
  demoVideo('Demo Video Loop', CupertinoIcons.play_rectangle_fill),
  image('Custom Image File...', CupertinoIcons.photo_fill),
  video('Custom Video File...', CupertinoIcons.film_fill),
  qrCode('Dynamic QR Code', CupertinoIcons.qrcode),
  testPattern('SMPTE Test Bars', CupertinoIcons.tv_fill);

  final String title;
  final IconData icon;
  const CameraSourceType(this.title, this.icon);
}

class CameraFraming {
  String fitMode;
  double zoom;
  double offsetX;
  double offsetY;
  int rotation;
  bool mirror;

  CameraFraming({
    this.fitMode = 'fill',
    this.zoom = 1.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.rotation = 0,
    required this.mirror,
  });

  Map<String, dynamic> toMap(String target) => {
        'target': target,
        'fitMode': fitMode,
        'zoom': zoom,
        'offsetX': offsetX,
        'offsetY': offsetY,
        'rotation': rotation,
        'mirror': mirror,
      };
}

class OpenSimCamInspectorHome extends StatefulWidget {
  const OpenSimCamInspectorHome({super.key});

  @override
  State<OpenSimCamInspectorHome> createState() =>
      _OpenSimCamInspectorHomeState();
}

class _OpenSimCamInspectorHomeState extends State<OpenSimCamInspectorHome> {
  static const MethodChannel _controlChannel =
      MethodChannel('com.opensimcam.studio/control');
  static const EventChannel _previewChannel =
      EventChannel('com.opensimcam.studio/preview');

  int _selectedTab = 0; // 0: Camera, 1: Device, 2: Actions, 3: Settings
  CameraSourceType _currentSource = CameraSourceType.demoVideo;

  // Dual camera independent framing configurations
  final CameraFraming _frontFraming = CameraFraming(mirror: true);
  final CameraFraming _backFraming = CameraFraming(mirror: false);
  String _targetCamera = 'both'; // 'both', 'front', 'back'
  String _previewTarget = 'back'; // 'back', 'front'
  bool _isSimCameraActive = false;
  String _simActiveCamera = 'back';

  CameraFraming get _activeFraming {
    if (_targetCamera == 'front') return _frontFraming;
    return _backFraming;
  }

  StreamSubscription? _previewSubscription;
  Timer? _statusPollTimer;
  Uint8List? _previewFrame;

  List<Map<String, dynamic>> _bootedSimulators = [];
  String? _connectedAppBundle;
  List<Map<String, String>> _availableCameras = [];
  String? _selectedCameraId;
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
                _isSimCameraActive = true;
              });
            }
          }
          break;
        case 'onClientDisconnected':
          if (mounted) {
            setState(() {
              _connectedAppBundle = null;
              _isSimCameraActive = false;
            });
          }
          break;
        case 'onCameraStateChanged':
          if (call.arguments is Map && mounted) {
            final args = call.arguments as Map;
            setState(() {
              _isSimCameraActive = args['isActive'] == true;
              _simActiveCamera = args['camera']?.toString() ?? 'back';
            });
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
          // If no simulator or app is running, clear connected state
          if (_bootedSimulators.isEmpty ||
              _bootedSimulators.first['runningAppBundle'] == null) {
            if (_connectedAppBundle != null) {
              _connectedAppBundle = null;
              _isSimCameraActive = false;
            }
          }
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
            await _controlChannel
                .invokeMethod('requestScreenCapturePermission');
            return;
          }
          await _controlChannel.invokeMethod('startPassthrough');
          break;

        case CameraSourceType.webcam:
          final hasCameraPerm = await _controlChannel
                  .invokeMethod<bool>('checkCameraPermission') ??
              false;
          if (!hasCameraPerm) {
            await _controlChannel.invokeMethod('requestCameraPermission');
          }
          await _fetchCameras();
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

  Future<void> _setFitMode(String mode) async {
    setState(() {
      if (_targetCamera == 'both') {
        _backFraming.fitMode = mode;
        _frontFraming.fitMode = mode;
      } else if (_targetCamera == 'front') {
        _frontFraming.fitMode = mode;
      } else {
        _backFraming.fitMode = mode;
      }
    });
    await _updateTransformSettings();
  }

  Future<void> _setPreviewCamera(String cam) async {
    setState(() => _previewTarget = cam);
    try {
      await _controlChannel.invokeMethod('setPreviewCamera', {'camera': cam});
    } catch (e) {
      debugPrint('Error setting preview camera: $e');
    }
  }

  void _selectTargetCamera(String target) {
    setState(() {
      _targetCamera = target;
      if (target == 'front') {
        _setPreviewCamera('front');
      } else if (target == 'back') {
        _setPreviewCamera('back');
      }
    });
  }

  Future<void> _updateTransformSettings() async {
    try {
      if (_targetCamera == 'both') {
        _frontFraming.fitMode = _backFraming.fitMode;
        _frontFraming.zoom = _backFraming.zoom;
        _frontFraming.offsetX = _backFraming.offsetX;
        _frontFraming.offsetY = _backFraming.offsetY;
        _frontFraming.rotation = _backFraming.rotation;

        await _controlChannel.invokeMethod(
          'updateTransformSettings',
          _backFraming.toMap('back'),
        );
        await _controlChannel.invokeMethod(
          'updateTransformSettings',
          _frontFraming.toMap('front'),
        );
      } else if (_targetCamera == 'front') {
        await _controlChannel.invokeMethod(
          'updateTransformSettings',
          _frontFraming.toMap('front'),
        );
      } else {
        await _controlChannel.invokeMethod(
          'updateTransformSettings',
          _backFraming.toMap('back'),
        );
      }
    } catch (e) {
      debugPrint('Error updating transform settings: $e');
    }
  }

  void _resetTransform() {
    setState(() {
      if (_targetCamera == 'front' || _targetCamera == 'both') {
        _frontFraming.fitMode = 'fill';
        _frontFraming.zoom = 1.0;
        _frontFraming.offsetX = 0.0;
        _frontFraming.offsetY = 0.0;
        _frontFraming.rotation = 0;
        _frontFraming.mirror = true;
      }
      if (_targetCamera == 'back' || _targetCamera == 'both') {
        _backFraming.fitMode = 'fill';
        _backFraming.zoom = 1.0;
        _backFraming.offsetX = 0.0;
        _backFraming.offsetY = 0.0;
        _backFraming.rotation = 0;
        _backFraming.mirror = false;
      }
    });
    _updateTransformSettings();
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
            content: Text('Relaunched $bundleId with camera synced!'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error relaunching app: $e');
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111420),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            children: [
              // 1. Top Segmented Icon Bar (Matching ui.webp)
              _buildTopSegmentedBar(),
              const SizedBox(height: 12),

              // 2. Main Content Card (Matching ui.webp inspector)
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildCameraSettingsCard(),
                      const SizedBox(height: 12),

                      _buildAdjustViewCard(),
                      const SizedBox(height: 12),

                      if (_currentSource == CameraSourceType.image ||
                          _currentSource == CameraSourceType.video ||
                          _currentSource == CameraSourceType.qrCode ||
                          _currentSource == CameraSourceType.passthrough)
                        _buildContextualCard(),
                      if (_currentSource == CameraSourceType.image ||
                          _currentSource == CameraSourceType.video ||
                          _currentSource == CameraSourceType.qrCode ||
                          _currentSource == CameraSourceType.passthrough)
                        const SizedBox(height: 12),

                      // 3. Bottom Simulator Camera Card (Orange arrow in ui.webp)
                      _buildSimulatorCameraBottomCard(),
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

  // --- WIDGET BUILDERS ---

  Widget _buildTopSegmentedBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1E2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF282D42)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildTabIcon(0, CupertinoIcons.camera_fill),
          _buildTabIcon(1, CupertinoIcons.device_phone_portrait),
          _buildTabIcon(2, CupertinoIcons.command),
          _buildTabIcon(3, CupertinoIcons.slider_horizontal_3),
          _buildTabIcon(4, CupertinoIcons.ellipsis),
        ],
      ),
    );
  }

  Widget _buildTabIcon(int index, IconData icon) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF2D3748) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected
                  ? const Color(0xFF60A5FA)
                  : const Color(0xFF718096),
            ),
            if (isSelected)
              Container(
                margin: const EdgeInsets.only(top: 2),
                width: 14,
                height: 2,
                decoration: BoxDecoration(
                  color: const Color(0xFF60A5FA),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraSettingsCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF171A27),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF262B3F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Live Mini Viewfinder
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 190,
              width: double.infinity,
              color: const Color(0xFF08090E),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_previewFrame != null)
                    Image.memory(
                      _previewFrame!,
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                    )
                  else
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _currentSource.icon,
                          size: 30,
                          color: const Color(0xFF60A5FA),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _currentSource.title,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFCBD5E1),
                          ),
                        ),
                      ],
                    ),

                  // LIVE / STANDBY badge (Top Left)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.circle_fill,
                            size: 6,
                            color: _connectedAppBundle != null
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF94A3B8),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _connectedAppBundle != null
                                ? (_isSimCameraActive
                                    ? 'LIVE • ${_simActiveCamera.toUpperCase()}'
                                    : 'CONNECTED • STANDBY')
                                : 'STANDBY (NO CLIENT)',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                              color: _connectedAppBundle != null
                                  ? Colors.white
                                  : const Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Preview Target & Zoom badge (Top Right)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: () {
                        _setPreviewCamera(_previewTarget == 'back' ? 'front' : 'back');
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFF3B82F6).withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '👁 ${_previewTarget.toUpperCase()}',
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF60A5FA),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${(_previewTarget == 'front' ? _frontFraming.zoom : _backFraming.zoom).toStringAsFixed(1)}x',
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Framing Target mode badge (Bottom Left)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _targetCamera == 'both'
                            ? 'Adjusting: Both (Synced)'
                            : (_targetCamera == 'front'
                                ? 'Adjusting: Front (Selfie)'
                                : 'Adjusting: Back Camera'),
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF10B981),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Setting Row: Source
          _buildSettingRow(
            label: 'Source',
            control: DropdownButtonHideUnderline(
              child: DropdownButton<CameraSourceType>(
                value: _currentSource,
                dropdownColor: const Color(0xFF1E2235),
                borderRadius: BorderRadius.circular(10),
                isDense: true,
                style: const TextStyle(fontSize: 12, color: Colors.white),
                items: CameraSourceType.values.map((src) {
                  return DropdownMenuItem<CameraSourceType>(
                    value: src,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          src.icon,
                          size: 12,
                          color: const Color(0xFF60A5FA),
                        ),
                        const SizedBox(width: 6),
                        Text(src.title),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) _activateSource(val);
                },
              ),
            ),
          ),

          const Divider(color: Color(0xFF222639), height: 16),

          // If Webcam selected, allow picking Mac Camera
          if (_currentSource == CameraSourceType.webcam &&
              _availableCameras.isNotEmpty) ...[
            _buildSettingRow(
              label: 'Mac Camera',
              control: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedCameraId,
                  dropdownColor: const Color(0xFF1E2235),
                  borderRadius: BorderRadius.circular(10),
                  isDense: true,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  items: _availableCameras.map((c) {
                    return DropdownMenuItem<String>(
                      value: c['id'],
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          c['name'] ?? 'Camera',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedCameraId = val);
                      _activateSource(CameraSourceType.webcam);
                    }
                  },
                ),
              ),
            ),
            const Divider(color: Color(0xFF222639), height: 16),
          ],

          // Setting Row: Ratio (Letterbox Fit, Fill, Stretch, Rotate 90)
          _buildSettingRow(
            label: 'Aspect Ratio',
            control: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _activeFraming.fitMode,
                dropdownColor: const Color(0xFF1E2235),
                borderRadius: BorderRadius.circular(10),
                isDense: true,
                style: const TextStyle(fontSize: 12, color: Colors.white),
                items: const [
                  DropdownMenuItem(value: 'fit', child: Text('Fit (Letterbox)')),
                  DropdownMenuItem(
                    value: 'fill',
                    child: Text('Fill (Cover 9:16)'),
                  ),
                  DropdownMenuItem(
                    value: 'stretch',
                    child: Text('Stretch (Full)'),
                  ),
                  DropdownMenuItem(
                    value: 'rotate90',
                    child: Text('Rotate 90° CW'),
                  ),
                  DropdownMenuItem(
                    value: 'rotate180',
                    child: Text('Rotate 180°'),
                  ),
                  DropdownMenuItem(
                    value: 'rotate270',
                    child: Text('Rotate 270° CW'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) _setFitMode(val);
                },
              ),
            ),
          ),

          const Divider(color: Color(0xFF222639), height: 16),

          // Setting Row: Dual Camera Stream (Front & Back)
          _buildSettingRow(
            label: 'Front & Back Cameras',
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  CupertinoIcons.checkmark_alt_circle_fill,
                  size: 14,
                  color: Color(0xFF10B981),
                ),
                const SizedBox(width: 4),
                Text(
                  _isSimCameraActive
                      ? 'Streaming: ${_simActiveCamera.toUpperCase()}'
                      : 'Dual Ready',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF10B981),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdjustViewCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF171A27),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF262B3F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(
                    CupertinoIcons.slider_horizontal_3,
                    size: 14,
                    color: Color(0xFF60A5FA),
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Framing & Adjustments',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _resetTransform,
                minimumSize: Size(0, 0),
                child: const Text(
                  'Reset',
                  style: TextStyle(fontSize: 11, color: Color(0xFF60A5FA)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Camera Target Selector: Both, Front, Back
          Container(
            height: 32,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2235),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2B324B)),
            ),
            child: Row(
              children: [
                _buildTargetSegment('both', 'Both (Synced)', CupertinoIcons.arrow_2_circlepath),
                _buildTargetSegment('front', 'Front Cam', CupertinoIcons.person_crop_circle),
                _buildTargetSegment('back', 'Back Cam', CupertinoIcons.camera),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Zoom control
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Zoom Level',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF222639),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${_activeFraming.zoom.toStringAsFixed(2)}x',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF60A5FA),
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: const Color(0xFF3B82F6),
              inactiveTrackColor: const Color(0xFF252A3D),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: _activeFraming.zoom,
              min: 0.5,
              max: 3.0,
              onChanged: (val) {
                setState(() => _activeFraming.zoom = val);
                _updateTransformSettings();
              },
            ),
          ),

          // Zoom quick presets
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [0.75, 1.0, 1.25, 1.5, 2.0].map((preset) {
              final isSelected = (_activeFraming.zoom - preset).abs() < 0.05;
              return GestureDetector(
                onTap: () {
                  setState(() => _activeFraming.zoom = preset);
                  _updateTransformSettings();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF3B82F6)
                        : const Color(0xFF1E2235),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${preset}x',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color:
                          isSelected ? Colors.white : const Color(0xFF94A3B8),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const Divider(color: Color(0xFF222639), height: 16),

          // Horizontal Pan
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Pan Horizontal (X)',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
              Text(
                '${(_activeFraming.offsetX * 100).toInt()}%',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: const Color(0xFF3B82F6),
              inactiveTrackColor: const Color(0xFF252A3D),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: _activeFraming.offsetX,
              min: -1.0,
              max: 1.0,
              onChanged: (val) {
                setState(() => _activeFraming.offsetX = val);
                _updateTransformSettings();
              },
            ),
          ),

          // Vertical Pan
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Pan Vertical (Y)',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
              Text(
                '${(_activeFraming.offsetY * 100).toInt()}%',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: const Color(0xFF3B82F6),
              inactiveTrackColor: const Color(0xFF252A3D),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: _activeFraming.offsetY,
              min: -1.0,
              max: 1.0,
              onChanged: (val) {
                setState(() => _activeFraming.offsetY = val);
                _updateTransformSettings();
              },
            ),
          ),

          const Divider(color: Color(0xFF222639), height: 16),

          // Rotation & Mirror
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Rotation',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
              Row(
                children: [0, 90, 180, 270].map((deg) {
                  final isSelected = _activeFraming.rotation == deg;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _activeFraming.rotation = deg);
                      _updateTransformSettings();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF3B82F6)
                            : const Color(0xFF1E2235),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$deg°',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          const SizedBox(height: 10),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _targetCamera == 'front'
                    ? 'Mirror Front Camera (Selfie)'
                    : (_targetCamera == 'back'
                        ? 'Mirror Back Camera'
                        : 'Mirror Camera'),
                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
              Transform.scale(
                scale: 0.75,
                child: CupertinoSwitch(
                  value: _activeFraming.mirror,
                  activeTrackColor: const Color(0xFF3B82F6),
                  onChanged: (val) {
                    setState(() {
                      _activeFraming.mirror = val;
                      if (_targetCamera == 'both') {
                        _frontFraming.mirror = val;
                        _backFraming.mirror = val;
                      }
                    });
                    _updateTransformSettings();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTargetSegment(String target, String title, IconData icon) {
    final isSelected = _targetCamera == target;
    final isSimActive = _isSimCameraActive && _simActiveCamera == target;
    return Expanded(
      child: GestureDetector(
        onTap: () => _selectTargetCamera(target),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF3B82F6) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 11,
                color: isSelected ? Colors.white : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                  ),
                ),
              ),
              if (isSimActive) ...[
                const SizedBox(width: 4),
                Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContextualCard() {
    Widget content = const SizedBox.shrink();

    if (_currentSource == CameraSourceType.image) {
      final name = _customImagePath != null
          ? _customImagePath!.split('/').last
          : 'No file selected';
      content = Row(
        children: [
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          const SizedBox(width: 8),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: const Color(0xFF2D3748),
            borderRadius: BorderRadius.circular(6),
            onPressed: _pickImageFile,
            child: const Text('Browse', style: TextStyle(fontSize: 11)),
          ),
        ],
      );
    } else if (_currentSource == CameraSourceType.video) {
      final name = _customVideoPath != null
          ? _customVideoPath!.split('/').last
          : 'No file selected';
      content = Row(
        children: [
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          const SizedBox(width: 8),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: const Color(0xFF2D3748),
            borderRadius: BorderRadius.circular(6),
            onPressed: _pickVideoFile,
            child: const Text('Browse', style: TextStyle(fontSize: 11)),
          ),
        ],
      );
    } else if (_currentSource == CameraSourceType.qrCode) {
      content = Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              controller: _qrController,
              placeholder: 'Payload URL or text...',
              style: const TextStyle(fontSize: 11, color: Colors.white),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2235),
                borderRadius: BorderRadius.circular(6),
              ),
              onSubmitted: (_) => _activateSource(CameraSourceType.qrCode),
            ),
          ),
          const SizedBox(width: 8),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: const Color(0xFF2563EB),
            borderRadius: BorderRadius.circular(6),
            onPressed: () => _activateSource(CameraSourceType.qrCode),
            child: const Text('Apply', style: TextStyle(fontSize: 11)),
          ),
        ],
      );
    } else if (_currentSource == CameraSourceType.passthrough) {
      content = Row(
        children: [
          const Icon(
            CupertinoIcons.macwindow,
            size: 14,
            color: Color(0xFF60A5FA),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Capturing screen behind Simulator',
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          if (!_hasScreenCapturePermission)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: const Color(0xFFDC2626),
              borderRadius: BorderRadius.circular(6),
              onPressed: () async {
                await _controlChannel.invokeMethod(
                  'openSystemPreferencesScreenCapture',
                );
              },
              child: const Text('Grant Access', style: TextStyle(fontSize: 10)),
            ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF171A27),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF262B3F)),
      ),
      child: content,
    );
  }

  // Bottom Card matching orange arrow in ui.webp
  Widget _buildSimulatorCameraBottomCard() {
    final hasBootedSim = _bootedSimulators.isNotEmpty;
    final firstSim = hasBootedSim ? _bootedSimulators.first : null;
    final simName = firstSim?['name'] ?? 'No Simulator';
    final runningApp = firstSim?['runningAppBundle']?.toString();
    final targetBundle = _connectedAppBundle ?? runningApp;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF171A27),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF262B3F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Simulator Camera',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE2E8F0),
                ),
              ),
              const Spacer(),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _connectedAppBundle != null
                      ? const Color(0xFF10B981)
                      : (hasBootedSim
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFFEF4444)),
                  boxShadow: _connectedAppBundle != null
                      ? [
                          BoxShadow(
                            color: const Color(0xFF10B981).withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Dropdown selector matching ui.webp
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF22273B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2D354E)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<CameraSourceType>(
                isExpanded: true,
                value: _currentSource,
                dropdownColor: const Color(0xFF1E2235),
                style: const TextStyle(fontSize: 12, color: Colors.white),
                items: CameraSourceType.values.map((src) {
                  return DropdownMenuItem<CameraSourceType>(
                    value: src,
                    child: Text(src.title),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) _activateSource(val);
                },
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Target App Status & Relaunch Button
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sim: $simName',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF718096),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _connectedAppBundle != null
                          ? 'App: ${_connectedAppBundle!.split('.').last} (${_isSimCameraActive ? "Feeding ${_simActiveCamera.toUpperCase()}" : "Connected"})'
                          : (runningApp != null
                              ? 'App: ${runningApp.split('.').last} (Standby)'
                              : (hasBootedSim
                                  ? 'App: Disconnected / Closed'
                                  : 'No simulator booted')),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _connectedAppBundle != null
                            ? const Color(0xFF6EE7B7)
                            : (_isSimCameraActive
                                ? const Color(0xFF60A5FA)
                                : const Color(0xFF94A3B8)),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (targetBundle != null && firstSim != null)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: const Color(0xFF2D3748),
                  borderRadius: BorderRadius.circular(8),
                  onPressed: () => _relaunchApp(targetBundle, firstSim['udid']),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        CupertinoIcons.arrow_2_circlepath,
                        size: 11,
                        color: Color(0xFF60A5FA),
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Relaunch App',
                        style: TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettingRow({required String label, required Widget control}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFCBD5E1),
            fontWeight: FontWeight.w500,
          ),
        ),
        control,
      ],
    );
  }
}
