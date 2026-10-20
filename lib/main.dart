import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:veriff_flutter/veriff_flutter.dart';

import 'verification_api.dart';

void main() {
  runApp(const VeriffExampleApp());
}

class VeriffExampleApp extends StatelessWidget {
  const VeriffExampleApp({super.key, this.api});

  /// 테스트에서 가짜 서버를 주입할 때 사용한다.
  final VerificationApi? api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rocket Now Partner 인증 POC',
      theme: ThemeData(
        // Rocket Now 브랜드 네이비 (앱 아이콘 로고 색)
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00479F)),
        useMaterial3: true,
      ),
      home: VerificationPage(api: api),
    );
  }
}

class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key, this.api});

  final VerificationApi? api;

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  static const String _defaultServerUrl = 'https://veriff.hoyuo.me';

  // 테스트용 회원 5명. id가 Veriff 세션의 vendorData로 전달되어
  // 풀 인증(등록)과 셀피 재인증을 같은 사람으로 묶는 열쇠가 된다.
  static const List<({String id, String firstName, String lastName})>
      _testUsers = [
    (id: 'user-test-001', firstName: 'Test', lastName: 'UserOne'),
    (id: 'user-test-002', firstName: 'Test', lastName: 'UserTwo'),
    (id: 'user-test-003', firstName: 'Test', lastName: 'UserThree'),
    (id: 'user-test-004', firstName: 'Test', lastName: 'UserFour'),
    (id: 'user-test-005', firstName: 'Test', lastName: 'UserFive'),
  ];

  // Veriff SDK 화면 언어. 실제 사용자는 일본 라이더이므로 일본어가 기본이다.
  static const List<({String code, String label})> _languages = [
    (code: 'ja', label: '日本語'),
    (code: 'ko', label: '한국어'),
    (code: 'en', label: 'English'),
  ];

  // 제출 후 심사 결과 자동 조회 간격과 최대 대기 시간.
  static const Duration _pollInterval = Duration(seconds: 5);
  static const Duration _pollTimeout = Duration(minutes: 3);

  late final TextEditingController _serverUrlController =
      TextEditingController(text: _defaultServerUrl);
  final TextEditingController _sessionUrlController = TextEditingController();

  String _selectedUserId = _testUsers.first.id;
  String _languageCode = _languages.first.code;

  bool _isBusy = false;
  String? _sessionId;
  String? _resultMessage;
  bool? _resultSuccess;

  VerificationStatus? _status;
  String? _statusError;
  bool _isLoadingStatus = false;
  Timer? _pollTimer;
  DateTime? _pollDeadline;
  DateTime? _pollStartedAt;
  // 자동 조회 대상 세션. 이전 세션의 최종 결과를 보고 조회를 멈추지 않기 위해 쓴다.
  String? _pollSessionId;
  // 상태 조회 요청 번호. 회원·서버가 바뀌거나 응답 순서가 뒤바뀌어도 최신 요청 결과만 반영한다.
  int _statusRequestSeq = 0;

  VerificationApi? _serverApi;
  String? _serverApiUrl;

  /// 서버 URL이 바뀔 때만 클라이언트를 새로 만든다.
  VerificationApi get _api {
    if (widget.api != null) return widget.api!;
    final url = _serverUrlController.text.trim();
    if (_serverApi == null || _serverApiUrl != url) {
      _serverApi?.close();
      _serverApi = VerificationApi(url);
      _serverApiUrl = url;
    }
    return _serverApi!;
  }

  ({String id, String firstName, String lastName}) get _selectedUser =>
      _testUsers.firstWhere((u) => u.id == _selectedUserId);

  bool get _isPolling => _pollTimer != null;

  @override
  void initState() {
    super.initState();
    // initState 안에서는 setState를 부를 수 없으므로 첫 프레임 이후에 조회한다.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _serverApi?.close();
    _serverUrlController.dispose();
    _sessionUrlController.dispose();
    super.dispose();
  }

  void _showResult(String message, {required bool success}) {
    if (!mounted) return;
    setState(() {
      _resultMessage = message;
      _resultSuccess = success;
    });
  }

  /// 선택된 회원의 최신 인증 상태를 서버에서 가져온다.
  Future<void> _refreshStatus() async {
    final seq = ++_statusRequestSeq;
    setState(() => _isLoadingStatus = true);
    try {
      final status = await _api.fetchStatus(_selectedUserId);
      // 그사이 회원·서버가 바뀌었거나 더 새 요청이 있으면 이 결과는 버린다.
      if (!mounted || seq != _statusRequestSeq) return;
      setState(() {
        _status = status;
        _statusError = null;
      });
      if (_isPolling && _isPolledSessionFinal(status)) _stopPolling();
    } on ApiException catch (e) {
      if (!mounted || seq != _statusRequestSeq) return;
      setState(() => _statusError = e.message);
    } finally {
      if (mounted && seq == _statusRequestSeq) {
        setState(() => _isLoadingStatus = false);
      }
    }
  }

  /// 자동 조회 중인 세션의 최종 결과인지.
  /// 웹훅이 오기 전에는 이전 세션(예: 지난 풀 인증 승인)이 최신으로 보일 수 있다.
  bool _isPolledSessionFinal(VerificationStatus status) {
    if (!status.state.isFinal) return false;
    if (_pollSessionId != null) return status.sessionId == _pollSessionId;
    // 세션 URL을 직접 붙여넣어 세션 ID를 모르면, 조회 시작 이후 갱신된 결과만 인정한다.
    final updatedAt = status.updatedAt;
    return updatedAt != null && updatedAt.isAfter(_pollStartedAt!);
  }

  /// 제출 직후부터 최종 결과가 나올 때까지 주기적으로 상태를 조회한다.
  void _startPolling() {
    _stopPolling();
    if (!mounted) return;
    _pollSessionId = _sessionId;
    _pollStartedAt = DateTime.now();
    _pollDeadline = _pollStartedAt!.add(_pollTimeout);
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (DateTime.now().isAfter(_pollDeadline!)) {
        _stopPolling();
        return;
      }
      // 이전 요청이 아직 끝나지 않았으면 이번 차례는 건너뛴다.
      if (!_isLoadingStatus) _refreshStatus();
    });
    setState(() {});
    _refreshStatus();
  }

  void _stopPolling() {
    if (_pollTimer == null) return;
    _pollTimer!.cancel();
    if (mounted) setState(() => _pollTimer = null);
  }

  Future<void> _requestSession(
      Future<({String sessionId, String sessionUrl})> Function() create) async {
    setState(() {
      _isBusy = true;
      _resultMessage = null;
    });

    try {
      final session = await create();
      if (!mounted) return;
      setState(() {
        _sessionId = session.sessionId;
        _sessionUrlController.text = session.sessionUrl;
      });
      _showResult('세션이 생성되었습니다.\nID: $_sessionId', success: true);
    } on ApiException catch (e) {
      _showResult(e.message, success: false);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// 풀 인증(신분증 + 셀피) 세션. 승인되면 vendorData 기준으로 얼굴이 등록된다.
  Future<void> _createSessionFromServer() {
    final user = _selectedUser;
    return _requestSession(() => _api.createVerification(
          vendorData: user.id,
          firstName: user.firstName,
          lastName: user.lastName,
        ));
  }

  /// 셀피 재인증 세션. 같은 vendorData로 등록된 얼굴과 대조한다.
  /// 서버에 Biometric Authentication 연동이 준비되어 있어야 한다.
  Future<void> _createAuthSessionFromServer() {
    return _requestSession(() => _api.createAuthentication(_selectedUserId));
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
      // Rocket Now Partner 브랜딩: 앱 아이콘에서 추출한 브랜드 색상.
      // 화면 구성은 Veriff 고정이지만 색·로고·버튼 모양은 우리 브랜드로 입힌다.
      final branding = Branding(
        logo: const AssetImage('assets/rocketnow_partner_logo.png'),
        primary: '#00479F',        // 메인 버튼 (브랜드 네이비)
        onPrimary: '#FFFFFF',
        background: '#FFFFFF',
        onBackground: '#1A1A1A',
        secondary: '#168350',      // 일러스트·불릿 (Partner 그린)
        onSecondary: '#FFFFFF',
        success: '#168350',
        error: '#FF5132',          // 브랜드 오렌지
        buttonRadius: 12,
      );
      final Result result = await Veriff().start(
        Configuration(
          sessionUrl,
          branding: branding,
          languageLocale: _languageCode,
        ),
      );
      switch (result.status) {
        case Status.done:
          _showResult(
            '인증을 제출했습니다.\n심사 결과를 자동으로 확인합니다 (최대 3분).',
            success: true,
          );
          _startPolling();
        case Status.canceled:
          _showResult('사용자가 인증을 취소했습니다.', success: false);
        case Status.error:
          _showResult('오류가 발생했습니다: ${result.error}', success: false);
      }
    } on PlatformException catch (e) {
      _showResult('SDK 실행 실패: ${e.message}', success: false);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _onUserChanged(String? value) {
    if (value == null) return;
    _stopPolling();
    // 회원이 바뀌면 이전 회원의 세션 정보를 초기화한다.
    setState(() {
      _selectedUserId = value;
      _sessionId = null;
      _sessionUrlController.clear();
      _resultMessage = null;
      _status = null;
      _statusError = null;
    });
    _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 풀 인증 승인 이력이 없다고 서버가 확실히 알려준 경우에만 재인증을 막는다.
    final canReauthenticate = _status?.enrolled != false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rocket Now Partner 인증'),
        backgroundColor: colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('1단계 · 세션 준비', style: textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  labelText: '백엔드 서버 URL',
                  helperText: '세션 생성과 결과 조회를 담당하는 백엔드 주소',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                onSubmitted: (_) => _refreshStatus(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selectedUserId,
                decoration: const InputDecoration(
                  labelText: '테스트 회원 선택 (vendorData)',
                  helperText: '풀 인증과 셀피 재인증을 같은 사람으로 묶는 식별자',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final user in _testUsers)
                    DropdownMenuItem(
                      value: user.id,
                      child: Text('${user.id} (${user.lastName})'),
                    ),
                ],
                onChanged: _isBusy ? null : _onUserChanged,
              ),
              const SizedBox(height: 12),
              _StatusCard(
                status: _status,
                error: _statusError,
                isLoading: _isLoadingStatus,
                isPolling: _isPolling,
                onRefresh: _isLoadingStatus ? null : _refreshStatus,
                onStopPolling: _stopPolling,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _createSessionFromServer,
                icon: const Icon(Icons.cloud_download),
                label: const Text('풀 인증 세션 생성 (신분증 + 셀피)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isBusy || !canReauthenticate
                    ? null
                    : _createAuthSessionFromServer,
                icon: const Icon(Icons.face),
                label: const Text('재인증 세션 생성 (셀피만)'),
              ),
              if (!canReauthenticate)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '풀 인증이 승인된 회원만 셀피 재인증을 할 수 있습니다.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
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
              Text('2단계 · 인증 진행', style: textTheme.titleMedium),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  for (final language in _languages)
                    ButtonSegment(
                      value: language.code,
                      label: Text(language.label),
                    ),
                ],
                selected: {_languageCode},
                onSelectionChanged: _isBusy
                    ? null
                    : (selection) =>
                        setState(() => _languageCode = selection.first),
              ),
              const SizedBox(height: 4),
              Text(
                'Veriff 인증 화면에 표시할 언어',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
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

/// 선택된 회원의 인증 상태 요약. 승인 여부와 사유만 보여주고 개인정보는 다루지 않는다.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.error,
    required this.isLoading,
    required this.isPolling,
    required this.onRefresh,
    required this.onStopPolling,
  });

  final VerificationStatus? status;
  final String? error;
  final bool isLoading;
  final bool isPolling;
  final VoidCallback? onRefresh;
  final VoidCallback onStopPolling;

  ({IconData icon, Color color}) _visual(VerificationState state) {
    return switch (state) {
      VerificationState.approved => (
          icon: Icons.verified,
          color: const Color(0xFF168350)
        ),
      VerificationState.declined => (
          icon: Icons.cancel,
          color: const Color(0xFFFF5132)
        ),
      VerificationState.resubmissionRequested => (
          icon: Icons.replay,
          color: Colors.orange.shade800
        ),
      VerificationState.submitted ||
      VerificationState.review ||
      VerificationState.started ||
      VerificationState.created =>
        (icon: Icons.hourglass_top, color: const Color(0xFF00479F)),
      _ => (icon: Icons.help_outline, color: Colors.grey.shade700),
    };
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final mutedStyle = textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final status = this.status;

    final Widget body;
    if (error != null) {
      body = Text(error!, style: TextStyle(color: Colors.red.shade700));
    } else if (status == null) {
      body = const Text('상태를 불러오는 중...');
    } else {
      final visual = _visual(status.state);
      final kindLabel = switch (status.kind) {
        'verification' => '풀 인증',
        'authentication' => '셀피 재인증',
        _ => null,
      };
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(visual.icon, color: visual.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  [?kindLabel, status.state.label].join(' · '),
                  style: textTheme.titleSmall?.copyWith(color: visual.color),
                ),
              ),
            ],
          ),
          if (status.reason != null) ...[
            const SizedBox(height: 6),
            Text('사유: ${status.reason}'),
          ],
          const SizedBox(height: 6),
          Text(
            [
              if (status.enrolled != null)
                status.enrolled! ? '얼굴 등록됨 (재인증 가능)' : '얼굴 미등록',
              if (status.updatedAt != null)
                '갱신 ${_formatTime(status.updatedAt!.toLocal())}',
              if (status.legacy) '구버전 서버 응답',
            ].join(' · '),
            style: mutedStyle,
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('현재 인증 상태', style: textTheme.labelLarge)),
                if (isPolling)
                  TextButton(
                    onPressed: onStopPolling,
                    child: const Text('자동 조회 중지'),
                  ),
                IconButton(
                  tooltip: '새로고침',
                  onPressed: onRefresh,
                  icon: isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            body,
            if (isPolling) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.month}/${time.day} ${two(time.hour)}:${two(time.minute)}';
  }
}
