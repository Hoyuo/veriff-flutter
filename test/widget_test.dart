import 'package:flutter_test/flutter_test.dart';

import 'package:veriff_example/main.dart';

void main() {
  testWidgets('Verification page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const VeriffExampleApp());

    expect(find.text('Veriff 신원 인증 예제'), findsOneWidget);
    expect(find.text('인증 시작'), findsOneWidget);
  });
}
