import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veriff_example/submission_progress.dart';
import 'package:veriff_example/verification_api.dart';
import 'package:veriff_flutter/veriff_flutter.dart' as veriff;

Future<void> _pump(
  WidgetTester tester, {
  bool sessionCreated = true,
  SdkOutcome? sdkOutcome,
  veriff.Error? sdkError,
  VerificationState? serverState,
  bool isPolling = false,
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SubmissionProgress(
        sessionCreated: sessionCreated,
        sdkOutcome: sdkOutcome,
        sdkError: sdkError,
        serverState: serverState,
        isPolling: isPolling,
      ),
    ),
  ));
}

void main() {
  testWidgets('세션만 만든 상태', (tester) async {
    await _pump(tester, serverState: VerificationState.created);

    expect(find.text('세션 생성 완료'), findsOneWidget);
    expect(find.text('인증 시작을 눌러 촬영하세요'), findsOneWidget);
    expect(find.text('제출 후 서버에서 확인'), findsOneWidget);
  });

  testWidgets('SDK 제출 직후에는 접수 확인 중', (tester) async {
    await _pump(tester,
        sdkOutcome: SdkOutcome.done,
        serverState: VerificationState.started,
        isPolling: true);

    expect(find.text('촬영과 제출을 마쳤습니다'), findsOneWidget);
    expect(find.text('Veriff 접수를 확인하는 중...'), findsOneWidget);
  });

  testWidgets('서버가 submitted를 받으면 접수 완료, 심사 대기', (tester) async {
    await _pump(tester,
        sdkOutcome: SdkOutcome.done,
        serverState: VerificationState.submitted,
        isPolling: true);

    expect(find.text('Veriff가 제출을 접수했습니다'), findsOneWidget);
    expect(find.text('심사 결과를 기다리는 중...'), findsOneWidget);
  });

  testWidgets('자동 조회가 끝났는데 접수가 안 되면 경고', (tester) async {
    await _pump(tester,
        sdkOutcome: SdkOutcome.done, serverState: VerificationState.started);

    expect(find.textContaining('접수 확인이 안 됩니다'), findsOneWidget);
  });

  testWidgets('승인까지 완료', (tester) async {
    await _pump(tester,
        sdkOutcome: SdkOutcome.done, serverState: VerificationState.approved);

    expect(find.text('승인되었습니다'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
  });

  testWidgets('SDK 결과가 없어도 서버가 접수했으면 제출 완료로 본다', (tester) async {
    await _pump(tester, serverState: VerificationState.submitted);

    expect(find.text('촬영과 제출을 마쳤습니다'), findsOneWidget);
    expect(find.text('Veriff가 제출을 접수했습니다'), findsOneWidget);
  });

  testWidgets('취소와 오류 안내', (tester) async {
    await _pump(tester, sdkOutcome: SdkOutcome.canceled);
    expect(find.textContaining('제출 전에 취소했습니다'), findsOneWidget);

    await _pump(tester,
        sdkOutcome: SdkOutcome.error, sdkError: veriff.Error.cameraUnavailable);
    expect(find.textContaining('카메라 권한이 없습니다'), findsOneWidget);
  });

  testWidgets('자동 조회가 끝난 심사 대기는 스피너 없이 대기 표시', (tester) async {
    await _pump(tester,
        sdkOutcome: SdkOutcome.done, serverState: VerificationState.submitted);

    expect(find.text('심사 중입니다. 잠시 후 새로고침하세요.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('제출 없이 만료된 세션은 접수·제출 단계를 실패로 표시', (tester) async {
    await _pump(tester, serverState: VerificationState.expired);

    expect(find.text('제출하지 않은 채 세션이 종료되었습니다'), findsOneWidget);
    expect(find.text('접수되지 않은 채 세션이 종료되었습니다'), findsOneWidget);
    expect(find.text('세션이 만료되었습니다'), findsOneWidget);
    expect(find.textContaining('웹훅 설정'), findsNothing);
  });

  test('모든 SDK 오류 코드에 안내 문구가 있다', () {
    for (final error in [...veriff.Error.values, null]) {
      expect(sdkErrorMessage(error), isNotEmpty);
    }
  });
}
