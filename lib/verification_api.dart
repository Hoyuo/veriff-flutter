import 'dart:convert';

import 'package:http/http.dart' as http;

/// 회원의 인증 진행 단계. 서버 `GET /users/:vendorData/status`의 `state` 값과 대응한다.
enum VerificationState {
  none('none', '인증 이력 없음'),
  created('created', '세션 생성됨 (아직 시작 안 함)'),
  started('started', '인증 진행 중'),
  submitted('submitted', '제출 완료 · 심사 대기'),
  review('review', '수동 검토 중'),
  approved('approved', '승인'),
  declined('declined', '거절'),
  resubmissionRequested('resubmission_requested', '재제출 요청'),
  expired('expired', '세션 만료'),
  abandoned('abandoned', '중단됨'),
  unknown('unknown', '알 수 없음');

  const VerificationState(this.wireName, this.label);

  final String wireName;
  final String label;

  static VerificationState parse(String? value) => VerificationState.values
      .firstWhere((s) => s.wireName == value, orElse: () => unknown);

  /// 더 이상 상태가 바뀌지 않는 최종 결과인지. 자동 조회(polling) 종료 조건으로 쓴다.
  bool get isFinal => const {
        approved,
        declined,
        resubmissionRequested,
        expired,
        abandoned,
      }.contains(this);
}

/// 앱에 노출해도 되는 최소한의 인증 상태. 신분증에서 추출된 개인정보는 포함하지 않는다.
class VerificationStatus {
  const VerificationStatus({
    required this.vendorData,
    required this.state,
    this.kind,
    this.sessionId,
    this.reason,
    this.updatedAt,
    this.enrolled,
    this.legacy = false,
  });

  final String vendorData;
  final VerificationState state;

  /// 'verification'(풀 인증) 또는 'authentication'(셀피 재인증).
  final String? kind;
  final String? sessionId;

  /// 거절·재제출 사유 (예: 서류 일부가 가려짐). 개인정보가 아닌 사유 문구만 온다.
  final String? reason;
  final DateTime? updatedAt;

  /// 풀 인증 승인 이력이 있어 셀피 재인증이 가능한지. 구버전 서버는 알 수 없어 null.
  final bool? enrolled;

  /// 구버전 서버(`/decision` 엔드포인트)로 조회한 결과인지.
  final bool legacy;

  bool get approved => state == VerificationState.approved;

  /// 서버가 필드를 빼거나 타입을 바꿔 보내도 예외 대신 null로 처리한다.
  factory VerificationStatus.fromJson(
      String vendorData, Map<String, dynamic> json) {
    return VerificationStatus(
      vendorData: _string(json['vendorData']) ?? vendorData,
      state: VerificationState.parse(_string(json['state'])),
      kind: _string(json['kind']),
      sessionId: _string(json['sessionId']),
      reason: _string(json['reason']),
      updatedAt: _dateTime(json['updatedAt']),
      enrolled: _bool(json['enrolled']),
    );
  }

  /// 구버전 서버의 `{vendorData, sessionId, approved, status, decisionAt}` 응답을 변환한다.
  factory VerificationStatus.fromLegacyJson(
      String vendorData, Map<String, dynamic> json) {
    // 더 오래된 서버는 웹훅 원본({verification: {status}})을 그대로 돌려줬다.
    final verification = json['verification'];
    final status = _string(json['status']) ??
        (verification is Map ? _string(verification['status']) : null);
    return VerificationStatus(
      vendorData: vendorData,
      state: json['approved'] == true
          ? VerificationState.approved
          : VerificationState.parse(status),
      sessionId: _string(json['sessionId']),
      updatedAt: _dateTime(json['decisionAt']),
      legacy: true,
    );
  }

  static String? _string(Object? value) => value is String ? value : null;

  static bool? _bool(Object? value) => value is bool ? value : null;

  static DateTime? _dateTime(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 백엔드 서버(server/) 호출. Veriff API key는 서버에만 있고 앱은 이 서버만 바라본다.
class VerificationApi {
  VerificationApi(String baseUrl, {http.Client? client})
      : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  void close() => _client.close();

  /// 풀 인증(신분증 + 셀피) 세션 생성. 승인되면 [vendorData] 기준으로 얼굴이 등록된다.
  Future<({String sessionId, String sessionUrl})> createVerification({
    required String vendorData,
    required String firstName,
    required String lastName,
  }) {
    return _createSession('/verification', {
      'firstName': firstName,
      'lastName': lastName,
      'vendorData': vendorData,
    });
  }

  /// 셀피 재인증 세션 생성. 같은 [vendorData]로 등록된 얼굴과 대조한다.
  Future<({String sessionId, String sessionUrl})> createAuthentication(
      String vendorData) {
    return _createSession('/authentication', {'vendorData': vendorData});
  }

  /// 회원의 최신 인증 상태를 조회한다.
  /// 신버전 서버의 `/status`가 없으면 구버전 `/decision`으로 대체한다.
  Future<VerificationStatus> fetchStatus(String vendorData) async {
    final id = Uri.encodeComponent(vendorData);
    final response = await _get('/users/$id/status');
    final body = _tryDecode(response.body);

    if (response.statusCode == 200 && body != null) {
      return VerificationStatus.fromJson(vendorData, body);
    }
    // 신버전 서버는 이력이 없어도 200(state: none)을 준다.
    // JSON이 아닌 404는 라우트 자체가 없는 구버전 서버라는 뜻이다.
    if (response.statusCode == 404 && body == null) {
      return _fetchLegacyDecision(vendorData);
    }
    throw ApiException(_errorMessage('상태 조회 실패', response, body));
  }

  Future<VerificationStatus> _fetchLegacyDecision(String vendorData) async {
    final id = Uri.encodeComponent(vendorData);
    final response = await _get('/users/$id/decision');
    final body = _tryDecode(response.body);

    if (response.statusCode == 404 && body == null) {
      throw ApiException('인증 백엔드가 아닌 주소입니다. 서버 URL을 확인하세요. ($baseUrl)');
    }
    if (response.statusCode == 404) {
      return VerificationStatus(
        vendorData: vendorData,
        state: VerificationState.none,
        legacy: true,
      );
    }
    if (response.statusCode == 200 && body != null) {
      return VerificationStatus.fromLegacyJson(vendorData, body);
    }
    throw ApiException(_errorMessage('결과 조회 실패', response, body));
  }

  Future<({String sessionId, String sessionUrl})> _createSession(
      String path, Map<String, dynamic> payload) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
    } catch (e) {
      throw ApiException('서버 연결 실패: $e');
    }

    final body = _tryDecode(response.body);
    if (response.statusCode != 200 || body == null) {
      throw ApiException(_errorMessage('세션 생성 실패', response, body));
    }
    final sessionId = body['sessionId'];
    final sessionUrl = body['sessionUrl'];
    if (sessionId is! String || sessionUrl is! String) {
      throw ApiException('세션 생성 실패: 서버 응답에 sessionId/sessionUrl이 없습니다.');
    }
    return (sessionId: sessionId, sessionUrl: sessionUrl);
  }

  Future<http.Response> _get(String path) async {
    try {
      return await _client.get(Uri.parse('$baseUrl$path')).timeout(_timeout);
    } catch (e) {
      throw ApiException('서버 연결 실패: $e');
    }
  }

  static Map<String, dynamic>? _tryDecode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String _errorMessage(
      String prefix, http.Response response, Map<String, dynamic>? body) {
    final detail = body?['error'] ?? '응답 형식이 올바르지 않습니다';
    return '$prefix (${response.statusCode}): $detail';
  }
}
