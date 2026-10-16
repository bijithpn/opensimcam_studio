import 'package:flutter/material.dart';

import 'screens/studio_screen.dart';
import 'theme/studio_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenSimCamApp());
}

class OpenSimCamApp extends StatelessWidget {
  const OpenSimCamApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenSimCam Studio',
    debugShowCheckedModeBanner: false,
    theme: StudioTheme.dark,
    home: const OpenSimCamInspectorHome(),
  );
}
