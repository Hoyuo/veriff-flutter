import 'package:flutter/material.dart';
import 'package:veriff_flutter/veriff_flutter.dart' as veriff;

import 'verification_api.dart';

/// Veriff SDK 플로우가 앱에 돌려준 결과. 제출 성공(done)은 앱 쪽 신호일 뿐이고,
/// Veriff가 실제로 받았는지는 서버의 submitted 이벤트로 확인한다.
enum SdkOutcome { done, canceled, error }

/// SDK 오류 코드를 사용자에게 보여줄 안내 문구로 바꾼다.
String sdkErrorMessage(veriff.Error? error) {
  return switch (error) {
    veriff.Error.cameraUnavailable => '카메라 권한이 없습니다. 설정에서 카메라를 허용한 뒤 다시 시도하세요.',
    veriff.Error.microphoneUnavailable => '마이크 권한이 없습니다. 설정에서 마이크를 허용한 뒤 다시 시도하세요.',
    veriff.Error.networkError => '네트워크 오류로 제출하지 못했습니다. 연결 상태를 확인하고 다시 시도하세요.',
    veriff.Error.sessionError => '제출 전에 세션 오류가 발생했습니다. 세션이 만료됐을 수 있으니 새 세션을 만드세요.',
    veriff.Error.deprecatedSDKVersion => '지원이 종료된 SDK 버전입니다. 앱을 업데이트해야 합니다.',
    veriff.Error.setupError => 'SDK 설정 오류입니다. 세션 URL과 앱 설정을 확인하세요.',
    veriff.Error.nfcError => 'NFC 칩 읽기에 실패했습니다.',
    veriff.Error.unknown || veriff.Error.none || null => '알 수 없는 오류가 발생했습니다.',
  };
}

/// active는 앱이 지금 무언가를 기다리며 조회 중(스피너), waiting은 사용자 행동이나
/// 나중 확인을 기다리는 정지 상태다.
enum _StepStatus { pending, waiting, active, done, warning, failed }

/// 현재 세션의 제출 진행 단계: 세션 생성 → 촬영·제출 → Veriff 접수 → 심사 결과.
class SubmissionProgress extends StatelessWidget {
  const SubmissionProgress({
    super.key,
    required this.sessionCreated,
    required this.sdkOutcome,
    required this.sdkError,
    required this.serverState,
    required this.isPolling,
  });

  final bool sessionCreated;
  final SdkOutcome? sdkOutcome;
  final veriff.Error? sdkError;

  /// 이 세션에 대한 서버 상태. 다른(이전) 세션의 상태라면 null을 넘긴다.
  final VerificationState? serverState;
  final bool isPolling;

  // 제출되지 않은 채 끝난 세션.
  static const _closedWithoutSubmit = {
    VerificationState.expired,
    VerificationState.abandoned,
  };

  @override
  Widget build(BuildContext context) {
    final received = serverState?.isReceived ?? false;
    final closed = _closedWithoutSubmit.contains(serverState);

    final sessionStep = sessionCreated || sdkOutcome != null
        ? (_StepStatus.done, '세션 생성 완료')
        : (_StepStatus.active, '서버에서 세션을 생성하세요');

    final sdkStep = switch (sdkOutcome) {
      // 앱이 꺼졌다 켜진 경우 등 SDK 결과가 없어도 서버가 받았으면 제출된 것이다.
      _ when received => (_StepStatus.done, '촬영과 제출을 마쳤습니다'),
      SdkOutcome.done => (_StepStatus.done, '촬영과 제출을 마쳤습니다'),
      SdkOutcome.canceled =>
        (_StepStatus.warning, '제출 전에 취소했습니다. 인증 시작을 눌러 다시 진행하세요.'),
      SdkOutcome.error => (_StepStatus.failed, sdkErrorMessage(sdkError)),
      null when closed => (_StepStatus.failed, '제출하지 않은 채 세션이 종료되었습니다'),
      null => sessionCreated
          ? (_StepStatus.waiting, '인증 시작을 눌러 촬영하세요')
          : (_StepStatus.pending, '세션 생성 후 진행'),
    };

    final receiptStep = received
        ? (_StepStatus.done, 'Veriff가 제출을 접수했습니다')
        : closed
            ? (_StepStatus.failed, '접수되지 않은 채 세션이 종료되었습니다')
            : sdkOutcome == SdkOutcome.done
            ? isPolling
                ? (_StepStatus.active, 'Veriff 접수를 확인하는 중...')
                : (
                    _StepStatus.warning,
                    '접수 확인이 안 됩니다. 새로고침하거나 서버의 웹훅 설정을 확인하세요.'
                  )
            : (_StepStatus.pending, '제출 후 서버에서 확인');

    final decisionStep = switch (serverState) {
      VerificationState.approved => (_StepStatus.done, '승인되었습니다'),
      VerificationState.declined => (_StepStatus.failed, '거절되었습니다'),
      VerificationState.resubmissionRequested =>
        (_StepStatus.warning, '재제출이 필요합니다. 새 세션으로 다시 진행하세요.'),
      VerificationState.expired => (_StepStatus.failed, '세션이 만료되었습니다'),
      VerificationState.abandoned => (_StepStatus.failed, '인증이 중단되었습니다'),
      VerificationState.review => isPolling
          ? (_StepStatus.active, '수동 검토 중입니다')
          : (_StepStatus.waiting, '수동 검토 중입니다. 잠시 후 새로고침하세요.'),
      _ when received => isPolling
          ? (_StepStatus.active, '심사 결과를 기다리는 중...')
          : (_StepStatus.waiting, '심사 중입니다. 잠시 후 새로고침하세요.'),
      _ => (_StepStatus.pending, '접수 후 심사'),
    };

    final steps = [
      ('세션 준비', sessionStep),
      ('촬영·제출 (앱)', sdkStep),
      ('Veriff 접수 (서버 확인)', receiptStep),
      ('심사 결과', decisionStep),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('제출 진행 상황', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            for (final (index, (title, (status, detail))) in steps.indexed)
              _StepRow(
                title: title,
                detail: detail,
                status: status,
                isLast: index == steps.length - 1,
              ),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.title,
    required this.detail,
    required this.status,
    required this.isLast,
  });

  final String title;
  final String detail;
  final _StepStatus status;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = switch (status) {
      _StepStatus.done => const Color(0xFF168350),
      _StepStatus.failed => const Color(0xFFFF5132),
      _StepStatus.warning => Colors.orange.shade800,
      _StepStatus.active || _StepStatus.waiting => const Color(0xFF00479F),
      _StepStatus.pending => colorScheme.outline,
    };

    final Widget indicator = switch (status) {
      _StepStatus.active => SizedBox(
          width: 20,
          height: 20,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
        ),
      _StepStatus.waiting => Icon(Icons.hourglass_top, size: 20, color: color),
      _StepStatus.done => Icon(Icons.check_circle, size: 20, color: color),
      _StepStatus.failed => Icon(Icons.cancel, size: 20, color: color),
      _StepStatus.warning => Icon(Icons.error, size: 20, color: color),
      _StepStatus.pending =>
        Icon(Icons.radio_button_unchecked, size: 20, color: color),
    };

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              indicator,
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: status == _StepStatus.done
                        ? color
                        : colorScheme.outlineVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.titleSmall?.copyWith(
                      color: status == _StepStatus.pending
                          ? colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: textTheme.bodySmall?.copyWith(
                      color: status == _StepStatus.pending
                          ? colorScheme.onSurfaceVariant
                          : color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
