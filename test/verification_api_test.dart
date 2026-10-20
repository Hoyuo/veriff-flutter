import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veriff_example/verification_api.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

// Express가 없는 라우트에 돌려주는 기본 404 응답.
http.Response _expressNotFound(String path) =>
    http.Response('<pre>Cannot GET $path</pre>', 404);

void main() {
  group('fetchStatus (신버전 서버)', () {
    test('/status 응답을 그대로 파싱한다', () async {
      final api = VerificationApi('https://example.test/',
          client: MockClient((request) async {
        expect(request.url.toString(),
            'https://example.test/users/user-test-001/status');
        return _json({
          'vendorData': 'user-test-001',
          'kind': 'verification',
          'sessionId': 's-1',
          'state': 'resubmission_requested',
          'approved': false,
          'reason': 'Document not fully visible',
          'updatedAt': '2026-10-21T01:02:03Z',
          'enrolled': false,
        });
      }));

      final status = await api.fetchStatus('user-test-001');

      expect(status.state, VerificationState.resubmissionRequested);
      expect(status.state.isFinal, isTrue);
      expect(status.reason, 'Document not fully visible');
      expect(status.enrolled, isFalse);
      expect(status.kind, 'verification');
      expect(status.updatedAt, DateTime.utc(2026, 10, 21, 1, 2, 3));
      expect(status.legacy, isFalse);
    });

    test('이력이 없으면 state none', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((_) async => _json({
                'vendorData': 'user-test-002',
                'state': 'none',
                'approved': false,
                'enrolled': false,
              })));

      final status = await api.fetchStatus('user-test-002');

      expect(status.state, VerificationState.none);
      expect(status.state.isFinal, isFalse);
    });

    test('모르는 state는 unknown으로 처리한다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((_) async =>
              _json({'vendorData': 'u', 'state': 'something_new'})));

      expect((await api.fetchStatus('u')).state, VerificationState.unknown);
    });
  });

  group('fetchStatus (구버전 서버 대체 경로)', () {
    test('/status 라우트가 없으면 /decision 결과를 사용한다', () async {
      final requested = <String>[];
      final api = VerificationApi('https://example.test',
          client: MockClient((request) async {
        requested.add(request.url.path);
        if (request.url.path.endsWith('/status')) {
          return _expressNotFound(request.url.path);
        }
        return _json({
          'vendorData': 'user-test-001',
          'sessionId': 's-1',
          'approved': true,
          'status': 'approved',
          'decisionAt': '2026-10-21T00:00:00Z',
        });
      }));

      final status = await api.fetchStatus('user-test-001');

      expect(requested, [
        '/users/user-test-001/status',
        '/users/user-test-001/decision',
      ]);
      expect(status.state, VerificationState.approved);
      expect(status.legacy, isTrue);
      expect(status.enrolled, isNull);
    });

    test('구버전 서버에 결과가 없으면 state none', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((request) async {
        if (request.url.path.endsWith('/status')) {
          return _expressNotFound(request.url.path);
        }
        return _json({'error': '이 회원의 심사 결과가 아직 없습니다.'}, 404);
      }));

      final status = await api.fetchStatus('user-test-001');

      expect(status.state, VerificationState.none);
      expect(status.legacy, isTrue);
    });

    test('웹훅 원본 형태의 오래된 응답도 처리한다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((request) async {
        if (request.url.path.endsWith('/status')) {
          return _expressNotFound(request.url.path);
        }
        return _json({
          'verification': {'status': 'declined'},
        });
      }));

      expect((await api.fetchStatus('u')).state, VerificationState.declined);
    });
  });

  group('오류 처리', () {
    test('필드 타입이 달라도 예외 없이 null로 처리한다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((_) async => _json({
                'state': 'approved',
                'enrolled': 1,
                'updatedAt': 1729000000,
                'sessionId': 42,
              })));

      final status = await api.fetchStatus('user-test-001');

      expect(status.vendorData, 'user-test-001');
      expect(status.state, VerificationState.approved);
      expect(status.enrolled, isNull);
      expect(status.updatedAt, isNull);
      expect(status.sessionId, isNull);
    });

    test('인증 백엔드가 아닌 주소는 이력 없음 대신 오류를 낸다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient(
              (request) async => _expressNotFound(request.url.path)));

      expect(() => api.fetchStatus('u'), throwsA(isA<ApiException>()));
    });

    test('세션 응답에 필드가 없으면 ApiException', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((_) async => _json({'sessionId': 's-1'})));

      expect(() => api.createAuthentication('u'), throwsA(isA<ApiException>()));
    });

    test('JSON 오류 응답은 서버 메시지를 전달한다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient(
              (_) async => _json({'error': 'VERIFF_AUTH_API_KEY 미설정'}, 501)));

      expect(
        () => api.createAuthentication('user-test-001'),
        throwsA(isA<ApiException>().having(
            (e) => e.message, 'message', '세션 생성 실패 (501): VERIFF_AUTH_API_KEY 미설정')),
      );
    });

    test('HTML 오류 페이지(예: Cloudflare 502)도 예외로 감싼다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient(
              (_) async => http.Response('<html>Bad gateway</html>', 502)));

      expect(() => api.fetchStatus('u'), throwsA(isA<ApiException>()));
    });

    test('네트워크 실패는 ApiException으로 바뀐다', () async {
      final api = VerificationApi('https://example.test',
          client: MockClient((_) async => throw http.ClientException('offline')));

      expect(
        () => api.createVerification(
            vendorData: 'u', firstName: 'a', lastName: 'b'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  test('createVerification은 vendorData와 이름을 보낸다', () async {
    late Map<String, dynamic> sent;
    final api = VerificationApi('https://example.test',
        client: MockClient((request) async {
      expect(request.url.path, '/verification');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return _json({'sessionId': 's-9', 'sessionUrl': 'https://alchemy/v/9'});
    }));

    final session = await api.createVerification(
        vendorData: 'user-test-003', firstName: 'Test', lastName: 'UserThree');

    expect(sent, {
      'firstName': 'Test',
      'lastName': 'UserThree',
      'vendorData': 'user-test-003',
    });
    expect(session.sessionId, 's-9');
    expect(session.sessionUrl, 'https://alchemy/v/9');
  });
}
