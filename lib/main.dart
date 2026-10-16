import 'package:flutter/material.dart';

import 'screens/studio_screen.dart';
import 'theme/studio_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenSCApp());
}

class OpenSCApp extends StatelessWidget {
  const OpenSCApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenSC (Open Source Simulator Cam)',
    debugShowCheckedModeBanner: false,
    theme: StudioTheme.dark,
    home: const OpenSCStudioHome(),
  );
}
