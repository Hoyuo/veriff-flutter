const crypto = require('node:crypto');
const express = require('express');

const PORT = Number(process.env.PORT) || 3000;
const VERIFF_BASE_URL = process.env.VERIFF_BASE_URL || 'https://stationapi.veriff.com';
const API_KEY = process.env.VERIFF_API_KEY;
const SHARED_SECRET = process.env.VERIFF_SHARED_SECRET;

const app = express();
// HMAC 서명은 가공 전 원문 바이트로 계산해야 하므로 raw body를 보관한다.
app.use(express.json({ verify: (req, _res, buf) => { req.rawBody = buf; } }));

// 로컬 테스트용 인메모리 저장소. 서버를 재시작하면 사라진다.
const decisions = new Map(); // sessionId -> decision webhook payload
const events = new Map();    // sessionId -> [event webhook payloads]

function verifyHmacSignature(req) {
  if (!SHARED_SECRET) {
    console.warn('[webhook] VERIFF_SHARED_SECRET 미설정 — 서명 검증을 건너뜁니다 (로컬 테스트 전용).');
    return true;
  }
  const signature = req.get('x-hmac-signature');
  if (!signature || !req.rawBody) return false;
  const digest = crypto
    .createHmac('sha256', SHARED_SECRET)
    .update(req.rawBody)
    .digest('hex');
  try {
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(digest));
  } catch {
    return false;
  }
}

function extractSessionId(payload) {
  return payload?.verification?.id ?? payload?.sessionId ?? payload?.id ?? null;
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, apiKeyConfigured: Boolean(API_KEY) });
});

// 앱이 호출: Veriff 세션을 생성하고 sessionUrl을 돌려준다.
app.post('/verification', async (req, res) => {
  if (!API_KEY) {
    return res.status(500).json({
      error: 'VERIFF_API_KEY가 설정되지 않았습니다. server/.env 파일을 확인하세요.',
    });
  }

  const { firstName = 'John', lastName = 'Smith' } = req.body ?? {};

  try {
    const veriffRes = await fetch(`${VERIFF_BASE_URL}/v1/sessions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-AUTH-CLIENT': API_KEY,
      },
      body: JSON.stringify({
        verification: {
          person: { firstName, lastName },
        },
      }),
    });

    const body = await veriffRes.json();
    if (!veriffRes.ok) {
      console.error('[session] Veriff API 오류:', veriffRes.status, body);
      return res.status(veriffRes.status).json({ error: 'Veriff 세션 생성 실패', detail: body });
    }

    const sessionId = body.verification.id;
    const sessionUrl = body.verification.url;
    console.log(`[session] 생성됨 id=${sessionId}`);
    return res.json({ sessionId, sessionUrl });
  } catch (err) {
    console.error('[session] 요청 실패:', err);
    return res.status(502).json({ error: 'Veriff API 호출에 실패했습니다.', detail: String(err) });
  }
});

// Veriff가 호출: 최종 심사 결과(승인/거절) 웹훅.
app.post('/webhooks/decision', (req, res) => {
  if (!verifyHmacSignature(req)) {
    console.warn('[webhook] decision 서명 검증 실패 — 요청 거부');
    return res.status(401).json({ error: 'invalid signature' });
  }
  const sessionId = extractSessionId(req.body);
  console.log(`[webhook] decision 수신 id=${sessionId} status=${req.body?.verification?.status}`);
  if (sessionId) decisions.set(sessionId, req.body);
  return res.sendStatus(200);
});

// Veriff가 호출: 진행 상황 이벤트 웹훅 (started, submitted 등).
app.post('/webhooks/event', (req, res) => {
  if (!verifyHmacSignature(req)) {
    console.warn('[webhook] event 서명 검증 실패 — 요청 거부');
    return res.status(401).json({ error: 'invalid signature' });
  }
  const sessionId = extractSessionId(req.body);
  console.log(`[webhook] event 수신 id=${sessionId} action=${req.body?.action}`);
  if (sessionId) {
    if (!events.has(sessionId)) events.set(sessionId, []);
    events.get(sessionId).push(req.body);
  }
  return res.sendStatus(200);
});

// 앱이 호출: 웹훅으로 수신한 심사 결과를 조회한다.
app.get('/verification/:sessionId/decision', (req, res) => {
  const decision = decisions.get(req.params.sessionId);
  if (!decision) {
    return res.status(404).json({ error: '아직 심사 결과가 도착하지 않았습니다.' });
  }
  return res.json(decision);
});

app.get('/verification/:sessionId/events', (req, res) => {
  res.json(events.get(req.params.sessionId) ?? []);
});

app.listen(PORT, () => {
  console.log(`Veriff 예제 서버 실행 중: http://localhost:${PORT}`);
  console.log(`  - API key 설정됨: ${Boolean(API_KEY)}`);
  console.log(`  - 웹훅 서명 검증: ${SHARED_SECRET ? '활성화' : '비활성화 (VERIFF_SHARED_SECRET 미설정)'}`);
  console.log('  - 웹훅을 받으려면 ngrok 등으로 외부 노출 후 Veriff Station에 URL을 등록하세요.');
});
