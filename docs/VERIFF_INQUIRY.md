# Veriff 문의 사항

Veriff 담당자(account manager / support)에게 보낼 질문입니다. 아래 영문 초안을 그대로 보내거나 고쳐서 쓰세요.

## 요약 (한국어)

1. Biometric Authentication(셀피 재인증) 활성화 요청, 소요 기간과 비용
2. 테스트 integration에서 결정(decision)이 자동으로 나오는지, 수동 처리가 필요한지
3. 일본 신분증(운전면허증, 마이넘버카드, 재류카드) 지원 범위와 추출 필드
4. 재류카드의 체류자격·취업 제한 정보 추출 가능 여부
5. 건당 가격(풀 인증 / 재인증), 데이터 보존·저장 지역·삭제 정책(APPI)
6. 커스텀 인트로 화면 활성화 가능 여부

## Email draft (English)

```
Subject: Biometric Authentication activation and Japan KYC questions

Hello,

We are evaluating Veriff for rider onboarding and periodic re-verification in a
food delivery app in Japan. Our current integration uses the Flutter SDK
(veriff_flutter 7.2.0) with sessions created server-side and decision/event
webhooks. We would appreciate help with the following:

1. Biometric Authentication
   - Please enable Biometric Authentication for our account (selfie-only
     re-verification against the face enrolled in an approved IDV session,
     linked by vendorData).
   - What is the lead time and the pricing per authentication?
   - Does it use a separate integration (API key and shared secret)?

2. Test integration behaviour
   - Our test session (id: 9757e420-9844-4dac-acbc-19533c11acca) has been in
     "submitted" since 2026-10-20 15:04 UTC and no decision webhook has arrived.
     Are decisions generated automatically for test integrations, or do we need
     to set them manually in Station?

3. Japanese documents
   - Which Japanese documents are supported (driver's licence, My Number card,
     residence card)?
   - For residence cards, can you return the status of residence and work
     restriction fields in the decision webhook?

4. Data handling
   - Data retention period, storage region, and deletion request process
     (we need to comply with Japan's APPI).

5. Other
   - Pricing per full IDV session and any minimum commitment.
   - Can the custom intro screen (useCustomIntroScreen) be enabled for us?

Thank you.
```
