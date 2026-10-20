# Rocket Now Partner · Veriff KYC POC

Rocket Now Partner(일본 배달 라이더 앱)에 [Veriff](https://www.veriff.com/) 신원 인증을 도입하기 위한 POC입니다.
Flutter 앱([veriff_flutter](https://pub.dev/packages/veriff_flutter) 7.2.0)과 Node(Express) 백엔드로 구성됩니다.

- **풀 인증**: 라이더 온보딩 시 신분증 + 셀피. 승인되면 회원 ID(`vendorData`) 기준으로 얼굴이 등록됩니다.
- **셀피 재인증**: 이후 주기적으로 셀피만 찍어 등록된 얼굴과 대조합니다 (Veriff Biometric Authentication, 별도 활성화 필요).
- **개인정보 방침**: 앱에는 승인 여부·상태·사유만 내려보내고, 신분증에서 추출된 정보(웹훅 원본)는 서버에만 보관합니다.

POC 진행 방법과 측정 항목은 [docs/POC_TEST_PLAN.md](docs/POC_TEST_PLAN.md), Veriff에 확인할 사항은 [docs/VERIFF_INQUIRY.md](docs/VERIFF_INQUIRY.md)를 보세요.

## 동작 흐름

```
앱 ──POST /verification (vendorData)──▶ 서버 ──▶ Veriff Sessions API
앱 ◀──────── sessionUrl ──────────────── 서버
앱 ── Veriff SDK로 촬영·제출 ──▶ Veriff
                                 Veriff ──웹훅(event/decision, HMAC 서명)──▶ 서버 (SQLite 저장)
앱 ──GET /users/:vendorData/status (5초 간격 자동 조회)──▶ 서버
```

## 앱 (lib/)

| 파일 | 역할 |
|---|---|
| `lib/main.dart` | 화면. 테스트 회원 선택, 세션 생성, SDK 실행, 상태 카드 |
| `lib/verification_api.dart` | 서버 API 클라이언트와 상태 모델(`VerificationState`) |

- 기본 서버는 `https://veriff.hoyuo.me`이며 화면에서 바꿀 수 있습니다.
- 테스트 회원 `user-test-001`~`005`가 `vendorData`로 쓰입니다.
- Veriff 화면 언어는 기본 일본어(`ja`)이며 한국어·영어로 바꿀 수 있습니다 (`Configuration.languageLocale`).
- 브랜딩: 네이비 `#00479F`, 그린 `#168350`, 오렌지 `#FF5132`, 로고 `assets/rocketnow_partner_logo.png`.
- 인증을 제출하면 최종 결과가 나올 때까지 최대 3분간 5초마다 상태를 조회합니다.
- 풀 인증 승인 이력이 없는 회원(`enrolled: false`)은 셀피 재인증 버튼이 비활성화됩니다.
- `/status`가 없는 구버전 서버에 연결하면 `/users/:vendorData/decision`으로 대체 조회합니다.

## 서버 API

배포 서버(`https://veriff.hoyuo.me`, Docker, Cloudflare 뒤)가 기준입니다.
이 리포의 `server/`는 로컬 테스트용 참고 구현이며 배포본보다 기능이 적습니다 (SQLite 저장, `/status` 없음).

| 메서드/경로 | 호출 주체 | 역할 |
|---|---|---|
| `POST /verification` | 앱 | 풀 인증 세션 생성 → `{sessionId, sessionUrl}` |
| `POST /authentication` | 앱 | 셀피 재인증 세션 생성 (`VERIFF_AUTH_API_KEY` 없으면 501) |
| `GET /users/:vendorData/status` | 앱 | 최신 상태 (아래 형식) |
| `GET /users/:vendorData/decision` | 앱 | 구버전 호환용 결과 조회 |
| `POST /webhooks/decision` | Veriff | 최종 결과 수신 (HMAC 서명 검증) |
| `POST /webhooks/event` | Veriff | 진행 이벤트 수신 (started, submitted 등) |
| `GET /health` | 운영 | 키 설정 여부, 저장소, 마지막 웹훅 시각, 서명 실패 수 |

`GET /users/:vendorData/status` 응답:

```json
{
  "vendorData": "user-test-001",
  "kind": "verification",
  "sessionId": "9757e420-…",
  "state": "submitted",
  "approved": false,
  "reason": null,
  "updatedAt": "2026-10-20T15:04:06.021Z",
  "enrolled": false
}
```

`state` 값: `none` · `created` · `started` · `submitted` · `review` · `approved` · `declined` · `resubmission_requested` · `expired` · `abandoned`

### 로컬 서버로 테스트

```bash
cd server
npm install
cp .env.example .env   # VERIFF_API_KEY, VERIFF_SHARED_SECRET 입력
npm start              # http://localhost:3000
```

앱의 서버 URL에 `http://localhost:3000`(iOS 시뮬레이터) 또는 `http://10.0.2.2:3000`(Android 에뮬레이터)을 입력합니다.
앱은 HTTPS만 허용하므로 이때는 Android `usesCleartextTraffic`, iOS `NSAllowsLocalNetworking` 예외를 다시 추가해야 합니다.
웹훅을 받으려면 `ngrok http 3000` 등으로 외부에 노출하고 Veriff Station > Integrations > Webhook에 URL을 등록하세요.

## 플랫폼 요구사항

| 항목 | 버전 |
|---|---|
| Flutter / Dart | 3.47 이상 / 3.13 이상 (`pubspec.yaml`의 `sdk: ^3.13.0`) |
| Android | 8.0 (API 26) 이상, `minSdk = 26` |
| iOS | 15.0 이상, 카메라·마이크·사진 권한 문구는 `Info.plist`에 있음 |

## 실행과 테스트

```bash
flutter pub get
flutter run            # 실기기 권장 (카메라 필요)
flutter test           # API 클라이언트·화면 테스트 (가짜 서버 사용)
```

iOS는 첫 실행 전 `cd ios && pod install`이 필요할 수 있습니다.
