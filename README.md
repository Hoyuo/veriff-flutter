# Veriff Flutter 예제 앱

[Veriff](https://www.veriff.com/) 신원 인증 SDK([veriff_flutter](https://pub.dev/packages/veriff_flutter))를 Flutter 앱에 통합한 기본 예제입니다.

## 동작 방식

1. Veriff Station(대시보드) 또는 [Sessions API](https://devdocs.veriff.com/)로 인증 세션을 생성합니다.
2. 발급받은 세션 URL을 앱의 입력란에 붙여넣습니다.
3. **인증 시작** 버튼을 누르면 Veriff SDK 화면이 열리고, 완료/취소/오류 결과가 앱에 표시됩니다.
4. 최종 인증 결과(승인/거절)는 앱이 아니라 Veriff 서버의 **웹훅**으로 전달됩니다.

## 로컬 테스트 백엔드 (server/)

API key를 앱에 두지 않기 위한 Node(Express) 예제 서버입니다. 세션 생성과 웹훅 수신을 담당합니다.

```bash
cd server
npm install
cp .env.example .env   # VERIFF_API_KEY, VERIFF_SHARED_SECRET 입력
npm start              # http://localhost:3000
```

엔드포인트:

| 메서드/경로 | 호출 주체 | 역할 |
|---|---|---|
| `POST /verification` | 앱 | Veriff 세션 생성 후 `sessionId`, `sessionUrl` 반환 |
| `POST /webhooks/decision` | Veriff | 최종 심사 결과 수신 (HMAC 서명 검증) |
| `POST /webhooks/event` | Veriff | 진행 이벤트 수신 (HMAC 서명 검증) |
| `GET /verification/:id/decision` | 앱 | 웹훅으로 받은 심사 결과 조회 |

앱은 기본적으로 이 서버를 바라봅니다 (Android 에뮬레이터 `http://10.0.2.2:3000`, iOS 시뮬레이터 `http://localhost:3000`). 서버 없이 쓰려면 세션 URL을 직접 붙여넣어도 됩니다:

```bash
curl -X POST https://stationapi.veriff.com/v1/sessions \
  -H 'Content-Type: application/json' \
  -H 'X-AUTH-CLIENT: <YOUR_API_KEY>' \
  -d '{"verification": {"person": {"firstName": "John", "lastName": "Smith"}}}'
```

### 웹훅 받기

Veriff가 로컬 서버에 접근할 수 있도록 터널링이 필요합니다:

```bash
ngrok http 3000
```

발급된 URL을 Veriff Station > Integrations > Webhook 설정에 등록하세요 (decision: `https://<ngrok-url>/webhooks/decision`, event: `https://<ngrok-url>/webhooks/event`).

## 플랫폼 요구사항

| 플랫폼 | 최소 버전 | 설정 위치 |
|---|---|---|
| Android | 8.0 (API 26) | `android/app/build.gradle.kts`의 `minSdk = 26` |
| iOS | 15.0 | `project.pbxproj`의 deployment target 15.0, `Info.plist`에 카메라/마이크/사진 권한 문구 추가됨 |

## 실행

```bash
flutter pub get
flutter run
```

iOS는 첫 실행 전 `cd ios && pod install`이 필요할 수 있습니다.
