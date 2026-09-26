import 'package:battery_insights_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home renders both tracking modes', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    expect(find.text('This app today'), findsOneWidget);
    expect(find.text('Checkout (tracked by route)'), findsOneWidget);
  });
}
