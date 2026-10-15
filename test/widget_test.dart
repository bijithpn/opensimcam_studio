import 'package:flutter_test/flutter_test.dart';
import 'package:opensimcam_studio/main.dart';

void main() {
  testWidgets('OpenSimCamApp loads smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenSimCamApp());
    expect(find.text('OpenSimCam'), findsOneWidget);
  });
}
