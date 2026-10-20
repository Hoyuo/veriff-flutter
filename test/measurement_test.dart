import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veriff_example/measurement.dart';
import 'package:veriff_example/measurement_log_card.dart';
import 'package:veriff_example/submission_progress.dart';
import 'package:veriff_example/verification_api.dart';

final _start = DateTime.utc(2026, 10, 21, 3, 0, 0);

Measurement _measurement({SdkOutcome outcome = SdkOutcome.done}) => Measurement(
  id: 's-1-1',
  vendorData: 'user-test-001',
  sessionId: 's-1',
  kind: 'verification',
  sdkStartedAt: _start,
  sdkFinishedAt: _start.add(const Duration(minutes: 2, seconds: 13)),
  sdkOutcome: outcome,
);

VerificationStatus _status(VerificationState state, DateTime? at) =>
    VerificationStatus(
      vendorData: 'user-test-001',
      sessionId: 's-1',
      state: state,
      updatedAt: at,
    );

void main() {
  group('Measurement.applyStatus', () {
    test('submitted → approved 순서로 접수·결정 시각을 기록한다', () {
      var m = _measurement();
      m = m.applyStatus(
        _status(
          VerificationState.submitted,
          _start.add(const Duration(minutes: 2, seconds: 17)),
        ),
      );
      m = m.applyStatus(
        _status(
          VerificationState.approved,
          _start.add(const Duration(minutes: 5, seconds: 37)),
        ),
      );

      expect(m.sdkDuration, const Duration(minutes: 2, seconds: 13));
      // 접수는 SDK 시작부터 잰다.
      expect(m.toReceipt, const Duration(minutes: 2, seconds: 17));
      expect(m.toDecision, const Duration(minutes: 3, seconds: 20));
      expect(m.finalState, VerificationState.approved);
    });

    test('처음 본 상태가 최종 결과면 접수 시각은 비워둔다', () {
      final m = _measurement().applyStatus(
        _status(
          VerificationState.declined,
          _start.add(const Duration(minutes: 10)),
        ),
      );

      expect(m.receivedAt, isNull);
      expect(m.toReceipt, isNull);
      // 접수 시각을 모르면 SDK 종료부터 잰다.
      expect(m.toDecision, const Duration(minutes: 7, seconds: 47));
    });

    test('처음 본 상태가 review면 그 시각을 접수 시각으로 쓰지 않는다', () {
      final m = _measurement().applyStatus(
        _status(
          VerificationState.review,
          _start.add(const Duration(minutes: 8)),
        ),
      );

      expect(m.receivedAt, isNull);
      expect(m.decidedAt, isNull);
    });

    test('같은 상태를 다시 받아도 첫 시각을 유지하고 같은 객체를 돌려준다', () {
      final first = _measurement().applyStatus(
        _status(
          VerificationState.submitted,
          _start.add(const Duration(minutes: 3)),
        ),
      );
      final again = first.applyStatus(
        _status(
          VerificationState.submitted,
          _start.add(const Duration(minutes: 9)),
        ),
      );

      expect(identical(first, again), isTrue);
    });

    test('서버 시계가 늦어 음수가 되면 0초로 표시한다', () {
      final m = _measurement().applyStatus(
        _status(
          VerificationState.submitted,
          _start.subtract(const Duration(seconds: 5)),
        ),
      );

      expect(m.toReceipt, Duration.zero);
    });
  });

  test('formatDuration', () {
    expect(formatDuration(null), '-');
    expect(formatDuration(const Duration(seconds: 45)), '45초');
    expect(formatDuration(const Duration(minutes: 2, seconds: 13)), '2분 13초');
    expect(
      formatDuration(const Duration(hours: 1, minutes: 3, seconds: 9)),
      '1시간 3분',
    );
  });

  test('Markdown 표로 내보낸다', () {
    final m = _measurement().applyStatus(
      _status(
        VerificationState.approved,
        _start.add(const Duration(minutes: 6)),
      ),
    );
    final lines = measurementsToMarkdown([m]).trim().split('\n');

    expect(lines, hasLength(3));
    expect(lines[0], startsWith('| 시작 | 회원 |'));
    expect(
      lines[2],
      contains('| user-test-001 | 풀 인증 | 제출 | 2분 13초 | - | 3분 47초 | 승인 |'),
    );
  });

  group('MeasurementStore', () {
    test('저장 후 다시 불러온다', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MeasurementStore();
      final m = _measurement().applyStatus(
        _status(
          VerificationState.submitted,
          _start.add(const Duration(minutes: 3)),
        ),
      );

      await store.save([m]);
      final loaded = await store.load();

      expect(loaded, hasLength(1));
      expect(loaded.single.id, m.id);
      expect(loaded.single.kind, 'verification');
      expect(loaded.single.sdkOutcome, SdkOutcome.done);
      expect(loaded.single.receivedAt, m.receivedAt);
    });

    test('깨진 항목은 건너뛰고 나머지는 살린다', () async {
      SharedPreferences.setMockInitialValues({
        'measurements.v1':
            '[{"id": 1}, {"id": "ok", "vendorData": "u",'
            ' "sdkStartedAt": "2026-10-21T03:00:00Z",'
            ' "sdkFinishedAt": "2026-10-21T03:01:00Z", "sdkOutcome": "canceled"}]',
      });

      final loaded = await MeasurementStore().load();

      expect(loaded.map((m) => m.id), ['ok']);
    });

    test('JSON 자체가 깨졌으면 빈 목록', () async {
      SharedPreferences.setMockInitialValues({'measurements.v1': 'not json'});

      expect(await MeasurementStore().load(), isEmpty);
    });

    test('최대 개수까지만 저장한다', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MeasurementStore();
      await store.save(
        List.filled(MeasurementStore.maxEntries + 5, _measurement()),
      );

      expect(await store.load(), hasLength(MeasurementStore.maxEntries));
    });
  });

  testWidgets('측정 기록 카드: 표시와 복사', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );

    final m = _measurement().applyStatus(
      _status(
        VerificationState.approved,
        _start.add(const Duration(minutes: 6)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeasurementLogCard(measurements: [m], onClear: () {}),
        ),
      ),
    );

    expect(find.text('측정 기록 (1)'), findsOneWidget);
    expect(find.text('user-test-001 · 풀 인증 · 승인'), findsOneWidget);
    expect(find.textContaining('SDK 2분 13초'), findsOneWidget);
    expect(find.textContaining('결정 +3분 47초'), findsOneWidget);

    await tester.tap(find.byTooltip('표로 복사'));
    await tester.pump();

    expect(copied, contains('| user-test-001 |'));
    expect(find.textContaining('1건을 표로 복사했습니다'), findsOneWidget);
  });

  testWidgets('측정 기록 삭제는 확인을 거친다', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeasurementLogCard(
            measurements: [_measurement()],
            onClear: () => cleared = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('기록 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(cleared, isFalse);

    await tester.tap(find.byTooltip('기록 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
  });
}
