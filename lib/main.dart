import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:veriff_flutter/veriff_flutter.dart';

void main() {
  runApp(const VeriffExampleApp());
}

class VeriffExampleApp extends StatelessWidget {
  const VeriffExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Veriff Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF004D40)),
        useMaterial3: true,
      ),
      home: const VerificationPage(),
    );
  }
}

class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  // Android 에뮬레이터에서 호스트 머신의 localhost는 10.0.2.2로 접근한다.
  static final String _defaultServerUrl =
      !kIsWeb && Platform.isAndroid
          ? 'http://10.0.2.2:3000'
          : 'http://localhost:3000';

  late final TextEditingController _serverUrlController =
      TextEditingController(text: _defaultServerUrl);
  final TextEditingController _sessionUrlController = TextEditingController();

  bool _isBusy = false;
  String? _sessionId;
  String? _resultMessage;
  bool? _resultSuccess;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _sessionUrlController.dispose();
    super.dispose();
  }

  String get _serverUrl {
    final url = _serverUrlController.text.trim();
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  void _showResult(String message, {required bool success}) {
    setState(() {
      _resultMessage = message;
      _resultSuccess = success;
    });
  }

  /// 백엔드 서버에 세션 생성을 요청하고 세션 URL을 받아온다.
  Future<void> _createSessionFromServer() async {
    setState(() {
      _isBusy = true;
      _resultMessage = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/verification'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'firstName': 'John', 'lastName': 'Smith'}),
          )
          .timeout(const Duration(seconds: 15));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        _showResult('세션 생성 실패 (${response.statusCode}): ${body['error']}',
            success: false);
        return;
      }

      setState(() {
        _sessionId = body['sessionId'] as String?;
        _sessionUrlController.text = body['sessionUrl'] as String;
      });
      _showResult('세션이 생성되었습니다.\nID: $_sessionId', success: true);
    } catch (e) {
      _showResult('서버 연결 실패: $e\n서버가 실행 중인지 확인하세요 (server/ 디렉터리에서 npm start).',
          success: false);
    } finally {
      setState(() => _isBusy = false);
    }
  }

  /// 세션 URL로 Veriff SDK 인증 플로우를 시작한다.
  Future<void> _startVerification() async {
    final sessionUrl = _sessionUrlController.text.trim();
    if (sessionUrl.isEmpty) {
      _showResult('세션 URL을 입력하거나 서버에서 세션을 생성하세요.', success: false);
      return;
    }

    setState(() {
      _isBusy = true;
      _resultMessage = null;
    });

    try {
      final Result result = await Veriff().start(Configuration(sessionUrl));
      switch (result.status) {
        case Status.done:
          _showResult(
            '인증 세션이 완료되었습니다.\n최종 승인/거절 결과는 심사 후 웹훅으로 서버에 전달됩니다.',
            success: true,
          );
        case Status.canceled:
          _showResult('사용자가 인증을 취소했습니다.', success: false);
        case Status.error:
          _showResult('오류가 발생했습니다: ${result.error}', success: false);
      }
    } on PlatformException catch (e) {
      _showResult('SDK 실행 실패: ${e.message}', success: false);
    } finally {
      setState(() => _isBusy = false);
    }
  }

  /// 서버가 웹훅으로 수신한 심사 결과를 조회한다.
  Future<void> _fetchDecision() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;

    setState(() => _isBusy = true);
    try {
      final response = await http
          .get(Uri.parse('$_serverUrl/verification/$sessionId/decision'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 404) {
        _showResult('아직 심사 결과가 도착하지 않았습니다.\n잠시 후 다시 조회해보세요.',
            success: false);
        return;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final verification = body['verification'] as Map<String, dynamic>?;
      _showResult(
        '심사 결과: ${verification?['status'] ?? '알 수 없음'}\n'
        '사유: ${verification?['reason'] ?? '없음'}',
        success: verification?['status'] == 'approved',
      );
    } catch (e) {
      _showResult('결과 조회 실패: $e', success: false);
    } finally {
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Veriff 신원 인증 예제'),
        backgroundColor: colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('1단계 · 세션 준비',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  labelText: '백엔드 서버 URL',
                  helperText: 'Android 에뮬레이터는 10.0.2.2, iOS 시뮬레이터는 localhost',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _createSessionFromServer,
                icon: const Icon(Icons.cloud_download),
                label: const Text('서버에서 세션 생성'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _sessionUrlController,
                decoration: const InputDecoration(
                  labelText: '세션 URL (직접 붙여넣기도 가능)',
                  hintText: 'https://alchemy.veriff.com/v/...',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 24),
              Text('2단계 · 인증 진행',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isBusy ? null : _startVerification,
                icon: _isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_user),
                label: Text(_isBusy ? '진행 중...' : '인증 시작'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              if (_sessionId != null) ...[
                const SizedBox(height: 24),
                Text('3단계 · 심사 결과 확인',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _fetchDecision,
                  icon: const Icon(Icons.fact_check),
                  label: const Text('심사 결과 조회'),
                ),
              ],
              const SizedBox(height: 24),
              if (_resultMessage != null)
                Card(
                  color: _resultSuccess == true
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          _resultSuccess == true
                              ? Icons.check_circle
                              : Icons.error_outline,
                          color: _resultSuccess == true
                              ? Colors.green
                              : Colors.red,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _resultMessage!,
                            style: const TextStyle(height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
