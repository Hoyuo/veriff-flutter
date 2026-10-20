import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veriff_example/main.dart';
import 'package:veriff_example/verification_api.dart';

VerificationApi _fakeApi(Map<String, Map<String, dynamic>> statusByUser) {
  return VerificationApi('https://example.test',
      client: MockClient((request) async {
    final userId = request.url.pathSegments[1];
    return http.Response(
      jsonEncode(statusByUser[userId] ??
          {'vendorData': userId, 'state': 'none', 'enrolled': false}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }));
}

Finder _reauthButton() =>
    find.widgetWithText(OutlinedButton, '재인증 세션 생성 (셀피만)');

void main() {
  testWidgets('Verification page renders', (WidgetTester tester) async {
    await tester.pumpWidget(VeriffExampleApp(api: _fakeApi({})));
    await tester.pumpAndSettle();

    expect(find.text('Rocket Now Partner 인증'), findsOneWidget);
    expect(find.text('인증 시작'), findsOneWidget);
    expect(find.text('日本語'), findsOneWidget);
  });

  testWidgets('미등록 회원은 재인증 버튼이 비활성화된다', (WidgetTester tester) async {
    await tester.pumpWidget(VeriffExampleApp(api: _fakeApi({})));
    await tester.pumpAndSettle();

    expect(find.text('인증 이력 없음'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_reauthButton()).onPressed, isNull);
    expect(find.text('풀 인증이 승인된 회원만 셀피 재인증을 할 수 있습니다.'),
        findsOneWidget);
  });

  testWidgets('승인된 회원은 상태와 재인증 버튼이 활성화된다', (WidgetTester tester) async {
    await tester.pumpWidget(VeriffExampleApp(
      api: _fakeApi({
        'user-test-001': {
          'vendorData': 'user-test-001',
          'kind': 'verification',
          'state': 'approved',
          'approved': true,
          'enrolled': true,
        },
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.text('풀 인증 · 승인'), findsOneWidget);
    expect(find.textContaining('얼굴 등록됨'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_reauthButton()).onPressed, isNotNull);
  });

  testWidgets('재제출 요청은 사유를 보여준다', (WidgetTester tester) async {
    await tester.pumpWidget(VeriffExampleApp(
      api: _fakeApi({
        'user-test-001': {
          'vendorData': 'user-test-001',
          'kind': 'verification',
          'state': 'resubmission_requested',
          'reason': 'Document not fully visible',
          'enrolled': false,
        },
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.text('풀 인증 · 재제출 요청'), findsOneWidget);
    expect(find.text('사유: Document not fully visible'), findsOneWidget);
  });
}
