import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'submission_progress.dart';
import 'verification_api.dart';

/// POC 측정용 인증 1회 기록. docs/POC_TEST_PLAN.md의 측정 항목을 채우는 데 쓴다.
///
/// 시각의 출처가 다르다는 점에 주의한다.
/// - SDK 시작·종료: 기기 시계
/// - 접수·결정: 서버가 상태를 갱신한 시각(서버 시계). 기록이 없으면 앱이 처음 확인한 시각
class Measurement {
  const Measurement({
    required this.id,
    required this.vendorData,
    required this.sdkStartedAt,
    required this.sdkFinishedAt,
    required this.sdkOutcome,
    this.sessionId,
    this.kind,
    this.receivedAt,
    this.decidedAt,
    this.finalState,
  });

  final String id;
  final String vendorData;
  final String? sessionId;

  /// 'verification'(풀 인증) 또는 'authentication'(셀피 재인증). 세션 URL을 붙여넣었으면 null.
  final String? kind;
  final DateTime sdkStartedAt;
  final DateTime sdkFinishedAt;
  final SdkOutcome sdkOutcome;
  final DateTime? receivedAt;
  final DateTime? decidedAt;
  final VerificationState? finalState;

  /// SDK 화면을 연 뒤 제출(또는 취소·오류)로 돌아오기까지.
  Duration get sdkDuration => sdkFinishedAt.difference(sdkStartedAt);

  /// SDK 시작부터 Veriff 접수가 서버에 기록되기까지. 기기·서버 시계 차이만큼 오차가 있다.
  /// submitted 이벤트는 SDK 화면이 닫히기 전에 오므로 SDK 종료가 아니라 시작부터 잰다.
  Duration? get toReceipt => _nonNegative(receivedAt?.difference(sdkStartedAt));

  /// 접수 후 심사 결과가 나오기까지. 접수 시각을 모르면 SDK 종료부터 잰다.
  Duration? get toDecision =>
      _nonNegative(decidedAt?.difference(receivedAt ?? sdkFinishedAt));

  /// 서버 상태를 반영한 새 기록. 바뀐 것이 없으면 this를 그대로 돌려준다.
  Measurement applyStatus(VerificationStatus status) {
    final at = status.updatedAt ?? DateTime.now();
    var receivedAt = this.receivedAt;
    var decidedAt = this.decidedAt;
    var finalState = this.finalState;

    // 접수 시각은 submitted를 직접 본 경우에만 기록한다. 처음 본 상태가 review나
    // 최종 결과면 그 updatedAt은 검토·결정 시각이지 접수 시각이 아니다.
    if (receivedAt == null && status.state == VerificationState.submitted) {
      receivedAt = at;
    }
    if (decidedAt == null && status.state.isFinal) {
      decidedAt = at;
      finalState = status.state;
    }

    if (receivedAt == this.receivedAt && decidedAt == this.decidedAt) {
      return this;
    }
    return Measurement(
      id: id,
      vendorData: vendorData,
      sessionId: sessionId,
      kind: kind,
      sdkStartedAt: sdkStartedAt,
      sdkFinishedAt: sdkFinishedAt,
      sdkOutcome: sdkOutcome,
      receivedAt: receivedAt,
      decidedAt: decidedAt,
      finalState: finalState,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'vendorData': vendorData,
    'sessionId': sessionId,
    'kind': kind,
    'sdkStartedAt': sdkStartedAt.toIso8601String(),
    'sdkFinishedAt': sdkFinishedAt.toIso8601String(),
    'sdkOutcome': sdkOutcome.name,
    'receivedAt': receivedAt?.toIso8601String(),
    'decidedAt': decidedAt?.toIso8601String(),
    'finalState': finalState?.wireName,
  };

  static Measurement? fromJson(Map<String, dynamic> json) {
    final startedAt = _date(json['sdkStartedAt']);
    final finishedAt = _date(json['sdkFinishedAt']);
    final outcome = SdkOutcome.values
        .where((o) => o.name == json['sdkOutcome'])
        .firstOrNull;
    final id = json['id'];
    final vendorData = json['vendorData'];
    if (startedAt == null ||
        finishedAt == null ||
        outcome == null ||
        id is! String ||
        vendorData is! String) {
      return null;
    }
    final sessionId = json['sessionId'];
    final kind = json['kind'];
    final finalState = json['finalState'];
    return Measurement(
      id: id,
      vendorData: vendorData,
      sessionId: sessionId is String ? sessionId : null,
      kind: kind is String ? kind : null,
      sdkStartedAt: startedAt,
      sdkFinishedAt: finishedAt,
      sdkOutcome: outcome,
      receivedAt: _date(json['receivedAt']),
      decidedAt: _date(json['decidedAt']),
      finalState: finalState is String
          ? VerificationState.parse(finalState)
          : null,
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static Duration? _nonNegative(Duration? d) =>
      d == null ? null : (d.isNegative ? Duration.zero : d);
}

/// "2분 13초"처럼 읽기 쉬운 길이. null이면 '-'.
String formatDuration(Duration? d) {
  if (d == null) return '-';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '$h시간 $m분';
  if (m > 0) return '$m분 $s초';
  return '$s초';
}

String kindLabel(String? kind) => switch (kind) {
  'verification' => '풀 인증',
  'authentication' => '셀피 재인증',
  _ => '세션 직접 입력',
};

String sdkOutcomeLabel(SdkOutcome outcome) => switch (outcome) {
  SdkOutcome.done => '제출',
  SdkOutcome.canceled => '취소',
  SdkOutcome.error => '오류',
};

/// 측정 기록을 POC 문서에 붙여넣을 Markdown 표로 만든다.
String measurementsToMarkdown(List<Measurement> measurements) {
  String two(int n) => n.toString().padLeft(2, '0');
  String time(DateTime t) {
    final l = t.toLocal();
    return '${l.month}/${l.day} ${two(l.hour)}:${two(l.minute)}';
  }

  final buffer = StringBuffer()
    ..writeln('| 시작 | 회원 | 종류 | SDK | SDK 진행 | 시작→접수 | 접수→결정 | 결과 |')
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final m in measurements) {
    final cells = [
      time(m.sdkStartedAt),
      m.vendorData,
      kindLabel(m.kind),
      sdkOutcomeLabel(m.sdkOutcome),
      formatDuration(m.sdkDuration),
      formatDuration(m.toReceipt),
      formatDuration(m.toDecision),
      m.finalState?.label ?? '대기',
    ];
    buffer.writeln('| ${cells.join(' | ')} |');
  }
  return buffer.toString();
}

/// 측정 기록 저장소. 앱을 다시 켜도 남고, 나중에 도착한 결정도 이어서 반영할 수 있다.
class MeasurementStore {
  static const _key = 'measurements.v1';
  static const maxEntries = 50;

  Future<List<Measurement>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) ?Measurement.fromJson(item),
      ];
    } catch (_) {
      // 저장 형식이 깨졌으면 측정 기록만 포기하고 앱은 계속 쓴다.
      return [];
    }
  }

  /// 저장에 실패해도 화면의 기록은 그대로 두고 앱은 계속 쓴다 (측정은 부가 기능).
  Future<void> save(List<Measurement> measurements) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trimmed = measurements.take(maxEntries).toList();
      await prefs.setString(
        _key,
        jsonEncode([for (final m in trimmed) m.toJson()]),
      );
    } catch (_) {}
  }
}
