// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:subterraguard/main.dart';

void main() {
  testWidgets('SubterraGuard app loads in demo mode', (WidgetTester tester) async {
    await tester.pumpWidget(const SubterraGuardApp(firebaseAvailable: false));

    expect(find.text('SubterraGuard Demo Mode'), findsOneWidget);
    expect(find.text('Demo mode: no live Firebase data.'), findsOneWidget);
  });
}
