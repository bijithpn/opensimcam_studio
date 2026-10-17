import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../models/camera_framing.dart';
import '../models/camera_source_type.dart';
import '../theme/studio_theme.dart';
import '../widgets/floating_toolbar.dart';
import '../widgets/main_settings_panel.dart';
import '../widgets/simulator_camera_panel.dart';
import '../widgets/viewfinder_dialog.dart';

class OpenSCStudioHome extends StatefulWidget {
  const OpenSCStudioHome({super.key});

  @override
  State<OpenSCStudioHome> createState() => _OpenSCStudioHomeState();
}

class _OpenSCStudioHomeState extends State<OpenSCStudioHome> {
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
  int _selectedToolbarTab = 0;

  CameraFraming get _activeFraming {
    if (_targetCamera == 'front') return _frontFraming;
    return _backFraming;
  }

  StreamSubscription? _previewSubscription;
  final ValueNotifier<Uint8List?> _previewFrameNotifier =
      ValueNotifier<Uint8List?>(null);

  List<Map<String, dynamic>> _bootedSimulators = [];
  String? _connectedAppBundle;
  List<Map<String, String>> _availableCameras = [];
  String? _selectedCameraId;
  bool _hasScreenCapturePermission = true;
  bool _isDiscoveringSimulators = true;
  bool _isSimulatorSetupRunning = false;
  bool _isFetchingSimulators = false;
  bool _simulatorSetupComplete = false;
  String? _simulatorSetupMessage;
  String? _simulatorSetupError;

  // Custom paths
  String? _customImagePath;
  String? _customVideoPath;
  String _selectedBundledVideoAsset = 'assets/demo_video.mp4';
  List<String> _bundledVideoAssets = const ['assets/demo_video.mp4'];
  Future<void>? _bundledVideoAssetsLoad;
  final TextEditingController _qrController = TextEditingController(
    text: 'https://github.com',
  );

  @override
  void initState() {
    super.initState();
    _initMethodChannelHandler();
    _initPreviewStream();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_fetchCameras());
      unawaited(_fetchSimulators());
      unawaited(_loadBundledVideoAssets());
      unawaited(_activateSource(_currentSource));
    });
  }

  @override
  void dispose() {
    _controlChannel.setMethodCallHandler(null);
    _previewSubscription?.cancel();
    _previewFrameNotifier.dispose();
    _qrController.dispose();
    super.dispose();
  }

  void _initMethodChannelHandler() {
    _controlChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onTrayStartSetup':
          unawaited(_startSimulatorSetup());
          break;
        case 'onTrayOpenSimulator':
          unawaited(_openSimulator());
          break;
        case 'onTrayRefresh':
          unawaited(_fetchCameras());
          unawaited(_fetchSimulators());
          break;
        case 'onTraySourceChanged':
          final sourceName = (call.arguments as Map?)?['source']?.toString();
          if (sourceName != null) {
            final source = CameraSourceType.values.firstWhere(
              (item) => item.name == sourceName,
              orElse: () => _currentSource,
            );
            unawaited(_activateSource(source));
          }
          break;
        case 'onTrayToggleMirror':
          final newMirror = !_activeFraming.mirror;
          setState(() {
            _activeFraming.mirror = newMirror;
            if (_targetCamera == 'both') {
              _frontFraming.mirror = newMirror;
              _backFraming.mirror = newMirror;
            }
          });
          unawaited(_updateTransformSettings());
          break;
        case 'onTraySwitchCamera':
          final target = (call.arguments as Map?)?['camera']?.toString();
          if (target != null && (target == 'front' || target == 'back')) {
            _selectTargetCamera(target);
          } else {
            final next = _previewTarget == 'front' ? 'back' : 'front';
            _selectTargetCamera(next);
          }
          break;
        case 'onSimulatorsUpdated':
          if (call.arguments is List) {
            final list = (call.arguments as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            if (mounted) {
              setState(() {
                _bootedSimulators = list;
              });
              _updateAutomaticSetupStatus(list);
            }
          }
          break;
        case 'onClientConnected':
          if (call.arguments is Map) {
            final args = call.arguments as Map;
            if (mounted) {
              setState(() {
                _connectedAppBundle = args['bundleId']?.toString();
                _simulatorSetupComplete = true;
                _simulatorSetupMessage = null;
                _simulatorSetupError = null;
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
    unawaited(
      _controlChannel.invokeMethod<bool>('flutterReady').catchError((error) {
        debugPrint('Tray bridge readiness handshake failed: $error');
        return false;
      }),
    );
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
    if (_isFetchingSimulators) return;
    _isFetchingSimulators = true;
    try {
      final sims = await _controlChannel.invokeListMethod<Map>(
        'getBootedSimulators',
      );
      if (sims != null && mounted) {
        final simulators = sims
            .map((s) => Map<String, dynamic>.from(s))
            .toList();
        setState(() {
          _isDiscoveringSimulators = false;
          _bootedSimulators = simulators;
          if (_bootedSimulators.isEmpty) {
            if (_connectedAppBundle != null) {
              _connectedAppBundle = null;
              _isSimCameraActive = false;
            }
          }
        });
        _updateAutomaticSetupStatus(simulators);
      } else if (mounted && _isDiscoveringSimulators) {
        setState(() => _isDiscoveringSimulators = false);
      }
    } catch (e) {
      debugPrint('Error fetching simulators: $e');
      if (mounted && _isDiscoveringSimulators) {
        setState(() => _isDiscoveringSimulators = false);
      }
    } finally {
      _isFetchingSimulators = false;
    }
  }

  Future<void> _loadBundledVideoAssets() {
    return _bundledVideoAssetsLoad ??= _discoverBundledVideoAssets();
  }

  Future<void> _discoverBundledVideoAssets() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest.listAssets().where((asset) {
        final extension = asset.split('.').last.toLowerCase();
        return asset.startsWith('assets/') &&
            const {'mp4', 'mov', 'm4v'}.contains(extension);
      }).toList()..sort();
      if (!assets.contains(_selectedBundledVideoAsset)) {
        assets.insert(0, _selectedBundledVideoAsset);
      }
      if (mounted) setState(() => _bundledVideoAssets = assets);
    } catch (error) {
      debugPrint('Could not list bundled videos: $error');
    }
  }

  void _updateAutomaticSetupStatus(List<Map<String, dynamic>> simulators) {
    Map<String, dynamic>? simulator;
    for (final candidate in simulators) {
      if (candidate['runningAppBundle'] != null) {
        simulator = candidate;
        break;
      }
    }
    if (simulator == null || _connectedAppBundle != null || !mounted) return;
    final bundle = simulator['runningAppBundle']?.toString();
    if (bundle == null || bundle.isEmpty || simulator['isInjected'] != true) {
      return;
    }
    const message =
        'Camera loader is ready. If this app was already open before setup, relaunch the app once to load the camera plugin. Keep Simulator running.';
    if (_simulatorSetupMessage == message) return;
    final isInjected = simulator['isInjected'] == true;
    setState(() {
      _simulatorSetupMessage = message;
      _simulatorSetupError = null;
      _simulatorSetupComplete = isInjected;
    });
  }

  void _setTraySetupRunning(bool isRunning) {
    _controlChannel.invokeMethod('setTraySetupState', {'isRunning': isRunning});
  }

  void _setTraySetupError(String? message) {
    _controlChannel.invokeMethod('setTraySetupError', {'message': message});
  }

  Future<void> _openSimulator() async {
    try {
      await _controlChannel.invokeMethod<bool>('openSimulator');
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not open Simulator.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open Simulator: $error')),
      );
    }
  }

  Future<void> _activateSource(CameraSourceType source) async {
    setState(() => _currentSource = source);
    try {
      await _controlChannel.invokeMethod('updateTraySource', {
        'source': source.name,
      });
      switch (source) {
        case CameraSourceType.passthrough:
          final hasPerm =
              await _controlChannel.invokeMethod<bool>(
                'checkScreenCapturePermission',
              ) ??
              false;
          setState(() => _hasScreenCapturePermission = hasPerm);
          if (!hasPerm) {
            final requested =
                await _controlChannel.invokeMethod<bool>(
                  'requestScreenCapturePermission',
                ) ??
                false;
            final granted =
                requested ||
                (await _controlChannel.invokeMethod<bool>(
                      'checkScreenCapturePermission',
                    ) ??
                    false);
            if (mounted) setState(() => _hasScreenCapturePermission = granted);
            if (!granted) return;
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
          var demoPath = await _controlChannel.invokeMethod<String>(
            'getBundledVideoPath',
            {'asset': _selectedBundledVideoAsset},
          );
          if (demoPath == null || demoPath.isEmpty) {
            final tempDir = Directory.systemTemp;
            final filename = _selectedBundledVideoAsset.split('/').last;
            demoPath = '${tempDir.path}/opensc_$filename';
            final file = File(demoPath);
            if (!await file.exists()) {
              final byteData = await rootBundle.load(
                _selectedBundledVideoAsset,
              );
              await file.writeAsBytes(byteData.buffer.asUint8List());
            }
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
    _setTraySetupRunning(true);

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
      _setTraySetupError(null);

      final appBundle =
          _connectedAppBundle ?? simulator['runningAppBundle']?.toString();
      if (!mounted) return;
      setState(() {
        _simulatorSetupComplete = true;
        _simulatorSetupMessage = appBundle == null || appBundle.isEmpty
            ? 'Setup is ready. Launch an app in the simulator to connect.'
            : _connectedAppBundle == appBundle
            ? 'Setup is ready. The current camera connection was left running.'
            : 'Setup is ready. If ${appBundle.split('.').last} was already open, relaunch that app once to load the camera plugin. Keep Simulator running.';
      });
    } on PlatformException catch (error) {
      debugPrint('Simulator setup failed: ${error.code} ${error.message}');
      _setTraySetupError(error.message ?? 'Simulator setup failed.');
      if (!mounted) return;
      setState(() {
        _simulatorSetupError = error.message ?? 'Simulator setup failed.';
      });
    } catch (error) {
      debugPrint('Simulator setup failed: $error');
      _setTraySetupError('Simulator setup failed: $error');
      if (!mounted) return;
      setState(() => _simulatorSetupError = 'Simulator setup failed.');
    } finally {
      if (mounted) setState(() => _isSimulatorSetupRunning = false);
      _setTraySetupRunning(false);
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

  Future<void> _closeWindow() async {
    try {
      await _controlChannel.invokeMethod('closeWindow');
    } catch (e) {
      debugPrint('Failed to close window: $e');
    }
  }

  Future<void> _startDraggingWindow() async {
    try {
      await _controlChannel.invokeMethod('dragWindow');
    } catch (e) {
      debugPrint('Failed to drag window: $e');
    }
  }

  Widget _buildWindowHeaderBar() {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xF216171D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: StudioColors.border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _TrafficLightButton(
            color: const Color(0xFFFF5F56),
            hoverColor: const Color(0xFFFF3B30),
            icon: CupertinoIcons.xmark,
            tooltip: 'Close window',
            onTap: _closeWindow,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _startDraggingWindow(),
              child: Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _startDraggingWindow(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.move,
                  size: 11,
                  color: Colors.white.withValues(alpha: 0.38),
                ),
                const SizedBox(width: 4),
                Text(
                  'DRAG',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Colors.white.withValues(alpha: 0.38),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final simulator = _bootedSimulators.isEmpty
        ? null
        : _bootedSimulators.first;
    final runningApp = simulator?['runningAppBundle']?.toString();
    final appBundle = _connectedAppBundle ?? runningApp;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => _startDraggingWindow(),
          child: Center(
            child: ScrollConfiguration(
              behavior: const ScrollBehavior().copyWith(scrollbars: false),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 356),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Window Top Control & Drag Bar
                      _buildWindowHeaderBar(),
                      const SizedBox(height: 12),

                      // Top Tool Tab Bar (matching image.png)
                      FloatingToolbar(
                        selectedIndex: _selectedToolbarTab,
                        onTabSelected: (index) {
                          setState(() => _selectedToolbarTab = index);
                        },
                      ),
                      const SizedBox(height: 16),

                      // Main Floating Settings Panel
                      _buildMainSettingsPanel(),
                      const SizedBox(height: 14),

                      // Simulator Camera Panel (matching bottom card in image.png)
                      _buildSimulatorCameraBottomCard(simulator, appBundle),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainSettingsPanel() => MainSettingsPanel(
    currentSource: _currentSource,
    targetCamera: _targetCamera,
    activeFraming: _activeFraming,
    isSimCameraActive: _isSimCameraActive,
    simActiveCamera: _simActiveCamera,
    availableCameras: _availableCameras,
    selectedCameraId: _selectedCameraId,
    onCameraSelected: (id) {
      setState(() => _selectedCameraId = id);
      _activateSource(CameraSourceType.webcam);
    },
    onFitModeChanged: _setFitMode,
    onTargetCameraSelected: _selectTargetCamera,
    onZoomChanged: (val) {
      setState(() => _activeFraming.zoom = val);
      _updateTransformSettings();
    },
    onOffsetXChanged: (val) {
      setState(() => _activeFraming.offsetX = val);
      _updateTransformSettings();
    },
    onOffsetYChanged: (val) {
      setState(() => _activeFraming.offsetY = val);
      _updateTransformSettings();
    },
    onRotationChanged: (deg) {
      setState(() => _activeFraming.rotation = deg);
      _updateTransformSettings();
    },
    onMirrorChanged: (val) {
      setState(() {
        _activeFraming.mirror = val;
        if (_targetCamera == 'both') {
          _frontFraming.mirror = val;
          _backFraming.mirror = val;
        }
      });
      _updateTransformSettings();
    },
    onResetTransform: _resetTransform,
    bundledVideoAssets: _bundledVideoAssets,
    selectedBundledVideoAsset: _selectedBundledVideoAsset,
    onBundledVideoSelected: (asset) {
      setState(() => _selectedBundledVideoAsset = asset);
      unawaited(_activateSource(CameraSourceType.demoVideo));
    },
    customImagePath: _customImagePath,
    onPickImage: _pickImageFile,
    customVideoPath: _customVideoPath,
    onPickVideo: _pickVideoFile,
    qrController: _qrController,
    onApplyQr: () => _activateSource(CameraSourceType.qrCode),
    hasScreenCapturePermission: _hasScreenCapturePermission,
    onRequestScreenCapturePermission: () async {
      await _controlChannel.invokeMethod('openSystemPreferencesScreenCapture');
    },
    selectedTab: _selectedToolbarTab,
    onOpenSimulator: _openSimulator,
    onStartSetup: _startSimulatorSetup,
    onOpenViewfinder: () {
      showCurrentViewfinder(
        context: context,
        frame: _previewFrameNotifier,
        camera: _previewTarget,
        zoom: _previewTarget == 'front'
            ? _frontFraming.zoom
            : _backFraming.zoom,
      );
    },
  );

  Widget _buildSimulatorCameraBottomCard(
    Map<String, dynamic>? simulator,
    String? appBundle,
  ) => SimulatorCameraPanel(
    source: _currentSource,
    onSourceChanged: _activateSource,
    simulatorName: simulator?['name']?.toString(),
    isDiscovering: _isDiscoveringSimulators,
    appBundle: appBundle,
    isConnected: _connectedAppBundle != null,
    isCameraActive: _isSimCameraActive,
    activeCamera: _simActiveCamera,
    isSettingUp: _isSimulatorSetupRunning,
    setupComplete: _simulatorSetupComplete || simulator?['isInjected'] == true,
    setupMessage: _simulatorSetupMessage,
    setupError: _simulatorSetupError,
    onStartSetup: _startSimulatorSetup,
    onOpenSimulator: _openSimulator,
  );
}

class _TrafficLightButton extends StatefulWidget {
  const _TrafficLightButton({
    required this.color,
    required this.hoverColor,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final Color hoverColor;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_TrafficLightButton> createState() => _TrafficLightButtonState();
}

class _TrafficLightButtonState extends State<_TrafficLightButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 22,
            height: 22,
            child: Center(
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: _isHovered ? widget.hoverColor : widget.color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(
                        alpha: _isHovered ? 0.6 : 0.3,
                      ),
                      blurRadius: _isHovered ? 4 : 2,
                    ),
                  ],
                ),
                child: Center(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _isHovered ? 1.0 : 0.0,
                    child: Icon(
                      widget.icon,
                      size: 8,
                      color: const Color(0xDD000000),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
