import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import '../models/camera_framing.dart';
import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import '../widgets/glass_panel.dart';
import '../widgets/setting_row.dart';
import '../widgets/live_preview_panel.dart';
import '../widgets/simulator_camera_panel.dart';

class OpenSimCamInspectorHome extends StatefulWidget {
  const OpenSimCamInspectorHome({super.key});

  @override
  State<OpenSimCamInspectorHome> createState() =>
      _OpenSimCamInspectorHomeState();
}

class _OpenSimCamInspectorHomeState extends State<OpenSimCamInspectorHome> {
  static const MethodChannel _controlChannel = MethodChannel(
    'com.opensimcam.studio/control',
  );
  static const EventChannel _previewChannel = EventChannel(
    'com.opensimcam.studio/preview',
  );

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
  final ValueNotifier<Uint8List?> _previewFrameNotifier =
      ValueNotifier<Uint8List?>(null);

  List<Map<String, dynamic>> _bootedSimulators = [];
  String? _connectedAppBundle;
  List<Map<String, String>> _availableCameras = [];
  String? _selectedCameraId;
  bool _hasScreenCapturePermission = true;
  bool _isDiscoveringSimulators = true;
  bool _isSimulatorSetupRunning = false;
  bool _simulatorSetupComplete = false;
  String? _simulatorSetupMessage;
  String? _simulatorSetupError;

  // Custom paths
  String? _customImagePath;
  String? _customVideoPath;
  final TextEditingController _qrController = TextEditingController(
    text: 'https://github.com',
  );

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
    _previewFrameNotifier.dispose();
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
    _previewSubscription = _previewChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Uint8List && mounted) {
          _previewFrameNotifier.value = event;
        }
      },
      onError: (e) {
        debugPrint('Preview stream error: $e');
      },
    );
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
      final cameras = await _controlChannel.invokeListMethod<Map>('getCameras');
      if (cameras != null && mounted) {
        setState(() {
          _availableCameras = cameras
              .map(
                (c) => {
                  'name': c['name']?.toString() ?? 'Camera',
                  'id': c['id']?.toString() ?? '',
                },
              )
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
      final sims = await _controlChannel.invokeListMethod<Map>(
        'getBootedSimulators',
      );
      if (sims != null && mounted) {
        setState(() {
          _isDiscoveringSimulators = false;
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
      } else if (mounted && _isDiscoveringSimulators) {
        setState(() => _isDiscoveringSimulators = false);
      }
    } catch (e) {
      debugPrint('Error fetching simulators: $e');
      if (mounted && _isDiscoveringSimulators) {
        setState(() => _isDiscoveringSimulators = false);
      }
    }
  }

  Future<void> _activateSource(CameraSourceType source) async {
    setState(() => _currentSource = source);
    try {
      switch (source) {
        case CameraSourceType.passthrough:
          final hasPerm =
              await _controlChannel.invokeMethod<bool>(
                'checkScreenCapturePermission',
              ) ??
              false;
          setState(() => _hasScreenCapturePermission = hasPerm);
          if (!hasPerm) {
            await _controlChannel.invokeMethod(
              'requestScreenCapturePermission',
            );
            return;
          }
          await _controlChannel.invokeMethod('startPassthrough');
          break;

        case CameraSourceType.webcam:
          final hasCameraPerm =
              await _controlChannel.invokeMethod<bool>(
                'checkCameraPermission',
              ) ??
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
            await _controlChannel.invokeMethod('startImage', {
              'path': _customImagePath,
            });
          }
          break;

        case CameraSourceType.video:
          if (_customVideoPath != null) {
            await _controlChannel.invokeMethod('startVideo', {
              'path': _customVideoPath,
            });
          }
          break;

        case CameraSourceType.qrCode:
          await _controlChannel.invokeMethod('startQR', {
            'text': _qrController.text,
          });
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

  Future<void> _startSimulatorSetup() async {
    if (_isSimulatorSetupRunning || _bootedSimulators.isEmpty) return;
    final simulator = _bootedSimulators.first;
    final udid = simulator['udid']?.toString();
    if (udid == null || udid.isEmpty) return;

    setState(() {
      _isSimulatorSetupRunning = true;
      _simulatorSetupComplete = false;
      _simulatorSetupMessage = null;
      _simulatorSetupError = null;
    });

    try {
      final injected = await _controlChannel.invokeMethod<bool>(
        'injectSimulator',
        {'udid': udid},
      );
      if (injected != true) {
        throw PlatformException(
          code: 'SIMULATOR_SETUP_FAILED',
          message: 'Could not configure this simulator.',
        );
      }

      final appBundle =
          _connectedAppBundle ?? simulator['runningAppBundle']?.toString();
      if (appBundle != null && appBundle.isNotEmpty) {
        await _controlChannel.invokeMethod('relaunchApp', {
          'bundleId': appBundle,
          'udid': udid,
        });
      }
      if (!mounted) return;
      setState(() {
        _simulatorSetupComplete = true;
        _simulatorSetupMessage = appBundle == null || appBundle.isEmpty
            ? 'Setup complete. Launch an app in the simulator to connect.'
            : 'Setup complete. Relaunched ${appBundle.split('.').last}.';
      });
    } on PlatformException catch (error) {
      debugPrint('Simulator setup failed: ${error.code} ${error.message}');
      if (!mounted) return;
      setState(() {
        _simulatorSetupError = error.message ?? 'Simulator setup failed.';
      });
    } catch (error) {
      debugPrint('Simulator setup failed: $error');
      if (!mounted) return;
      setState(() => _simulatorSetupError = 'Simulator setup failed.');
    } finally {
      if (mounted) setState(() => _isSimulatorSetupRunning = false);
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
      backgroundColor: StudioColors.canvas,
      body: LiquidGlassLayer(
        settings: StudioGlass.settings,
        child: ScrollConfiguration(
          behavior: ScrollBehavior().copyWith(scrollbars: false),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              child: Column(
                children: [
                  _buildAppHeader(),
                  const SizedBox(height: 18),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 900;
                        if (!wide) {
                          return SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildSimulatorCameraBottomCard(),
                                const SizedBox(height: 14),
                                SizedBox(
                                  height: 360,
                                  child: _buildWorkspacePreview(),
                                ),
                                const SizedBox(height: 16),
                                _buildSettingsContents(),
                              ],
                            ),
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 7, child: _buildWorkspacePreview()),
                            const SizedBox(width: 18),
                            SizedBox(width: 370, child: _buildInspector()),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppHeader() {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFF2495FF).withValues(alpha: .22),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            CupertinoIcons.camera_fill,
            size: 17,
            color: Color(0xFF72C2FF),
          ),
        ),
        const SizedBox(width: 11),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OpenSimCam',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 2),
            Text(
              'Studio · Camera workspace',
              style: TextStyle(fontSize: 11, color: Color(0xFFA7ADBE)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInspector() {
    return SingleChildScrollView(child: _buildInspectorContents());
  }

  Widget _buildInspectorContents() => Column(
    children: [
      _buildSettingsContents(),
      const SizedBox(height: 12),
      _buildSimulatorCameraBottomCard(),
    ],
  );

  Widget _buildSettingsContents() => Column(
    children: [
      _buildCameraSettingsCard(),
      const SizedBox(height: 12),
      _buildAdjustViewCard(),
      if (_currentSource == CameraSourceType.image ||
          _currentSource == CameraSourceType.video ||
          _currentSource == CameraSourceType.qrCode ||
          _currentSource == CameraSourceType.passthrough) ...[
        const SizedBox(height: 12),
        _buildContextualCard(),
      ],
    ],
  );

  Widget _buildWorkspacePreview() => LivePreviewPanel(
    frame: _previewFrameNotifier,
    source: _currentSource,
    isLive: _isSimCameraActive,
    previewCamera: _previewTarget,
    targetCamera: _targetCamera,
    zoom: _previewTarget == 'front' ? _frontFraming.zoom : _backFraming.zoom,
    onSwitchCamera: () =>
        _setPreviewCamera(_previewTarget == 'back' ? 'front' : 'back'),
  );

  // --- WIDGET BUILDERS ---

  Widget _buildCameraSettingsCard() {
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Camera Configuration',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: StudioColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),

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
                  DropdownMenuItem(
                    value: 'fit',
                    child: Text('Fit (Letterbox)'),
                  ),
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
    return GlassPanel(
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
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
                      color: isSelected
                          ? Colors.white
                          : const Color(0xFF94A3B8),
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
                        horizontal: 6,
                        vertical: 3,
                      ),
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

    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      radius: 14,
      child: content,
    );
  }

  // Bottom Card matching orange arrow in ui.webp
  Widget _buildSimulatorCameraBottomCard() {
    final simulator = _bootedSimulators.isEmpty
        ? null
        : _bootedSimulators.first;
    final runningApp = simulator?['runningAppBundle']?.toString();
    final appBundle = _connectedAppBundle ?? runningApp;

    return SimulatorCameraPanel(
      source: _currentSource,
      onSourceChanged: _activateSource,
      simulatorName: simulator?['name']?.toString(),
      isDiscovering: _isDiscoveringSimulators,
      appBundle: appBundle,
      isConnected: _connectedAppBundle != null,
      isCameraActive: _isSimCameraActive,
      activeCamera: _simActiveCamera,
      isSettingUp: _isSimulatorSetupRunning,
      setupComplete:
          _simulatorSetupComplete || simulator?['isInjected'] == true,
      setupMessage: _simulatorSetupMessage,
      setupError: _simulatorSetupError,
      onStartSetup: _startSimulatorSetup,
    );
  }

  Widget _buildSettingRow({required String label, required Widget control}) {
    return SettingRow(label: label, control: control);
  }
}
