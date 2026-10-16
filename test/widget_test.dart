import 'package:flutter_test/flutter_test.dart';
import 'package:opensc/main.dart';

void main() {
  testWidgets('OpenSC app loads smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenSCApp());
    expect(find.text('OpenSC'), findsOneWidget);
  });
}
