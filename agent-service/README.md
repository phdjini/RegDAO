# RegDAO 피어리뷰 AI 에이전트 서비스

정책제안 게시판의 근거(RE)에 대한 형식검증(FCC)을 수행하고, 검증된 RE 수가 회부 임계값(θ_PR)에 도달한 안건에 대해 논문 피어리뷰와 같은 절차(에디터 배정 →
리뷰어 모집 → 비공개 질의응답 → 최종 발행)를 자동으로 진행하는 오프체인 서비스입니다.

## 이 서비스가 하는 일

1. **FCC 점검** (`processFCC.js`, `fcc.js`) — 대기 중인 RE마다 체크리스트 C1–C6을 판정해
   `ProposalBoard.recordFCC()`로 6비트 결과를 온체인에 기록합니다. C4(인신공격 여부)만 Claude API 분류기를
   쓰고 나머지는 결정적 규칙입니다. 분류기를 쓸 수 없으면 판정하지 않고 다음 실행으로 넘깁니다.
2. **정기 스캔** (`scanNewCases.js`) — 온체인에서 `referred`로 표시된(검증된 RE 수 ≥ θ_PR) 안건에
   `PeerReview.initiateCase()`를 호출하고, Claude API로 에디터를 매칭합니다. 두 에디터가 예치금을 걸고
   수락하면 Member-Gold 이상 회원 중에서 리뷰어를 초대합니다.
3. **이메일 발송** (`email.js`) — 위촉 대상에게 수락/거절 버튼이 담긴 메일을 보냅니다.
4. **응답 처리** (`server.js`) — 거절은 `PeerReview.declineInvite()`로 바로 기록합니다. 수락은 예치금(S_PPR)이
   필요하므로 본인이 대시보드에서 지갑으로 `acceptInvite`/`acceptEditorship`를 호출하도록 안내합니다.
5. **시간초과·no-show·정산** (`scheduler.js`) — 일정 시간(기본 48시간) 응답이 없으면 다음 후보에게
   재발송하고, 리뷰 마감이 지난 미제출 리뷰어를 no-show로 처리하며, 판정이 난 안건의 예치금을 `settle()`로 정산합니다.
6. **최종 발행**은 에디터(주에디터 또는 보조에디터)가 직접 `PeerReview.publishFinalProposal()`을
   호출합니다 — 투표 없이 즉시 온체인에 반영됩니다. (대시보드에서 지갑 연결 후 호출하거나,
   에디터용 스크립트를 별도로 만들어드릴 수 있습니다.)

## 왜 "AI 에이전트"인가

이 서비스가 하는 판단(누구를 에디터/리뷰어로 배정할지, 언제 재배정할지)은 모두
**Claude API 호출 결과**로 결정됩니다. 스마트컨트랙트는 그 판단의 실행 결과(누가 배정되었고
언제 수락/거절했는지)만 투명하게 기록할 뿐, 판단 자체는 하지 않습니다.

## 설치

```bash
cd agent-service
npm install
cp .env.example .env
```

`.env`를 채워주세요.
- `AGENT_PRIVATE_KEY`: 이 서비스 전용 지갑의 개인키. **BadgeSBT/DAOGovernance 배포자와는
  다른, 이 용도로만 쓰는 새 지갑을 권장**합니다. Sepolia ETH를 소량 충전해두세요
  (트랜잭션마다 가스비 필요).
- `BADGE_ADDRESS`, `PROPOSAL_BOARD_ADDRESS`, `MEMBER_PROFILE_ADDRESS`, `PEER_REVIEW_ADDRESS`:
  배포된 컨트랙트 주소
- `ANTHROPIC_API_KEY`: Claude API 키 (console.anthropic.com에서 발급)
- `SMTP_*`: 이메일 발송용 계정 (Gmail 앱 비밀번호, SendGrid, AWS SES 등 아무거나 가능)
- `PUBLIC_BASE_URL`: 이 서버가 외부에서 접근 가능한 주소 (배포 후 실제 도메인으로 교체 필요.
  로컬 테스트만 할 경우 ngrok 등으로 임시 공개 URL을 만들 수 있습니다)

## 사전 준비: 에이전트 지갑에 AGENT_ROLE 부여

`PeerReview` 컨트랙트 배포 시 admin(배포자)은 자동으로 에이전트 권한을 갖지만, 별도의
전용 에이전트 지갑을 쓰려면 admin 권한으로 아래처럼 등록해야 합니다.

```javascript
// hardhat console 등에서
const peerReview = await ethers.getContractAt("PeerReview", "0xPeerReview주소");
await peerReview.setAgent("0x에이전트지갑주소", true);
```

## 실행

**상시 서버로 실행** (이메일 응답 수신 + 매시 자동 스캔/에스컬레이션):
```bash
npm start
```

**수동으로 한 번만 실행**하고 싶을 때:
```bash
npm run scan       # 신규 안건 스캔 + 에디터/리뷰어 배정
npm run escalate    # 시간초과된 초대 재배정
```

외부 크론(예: 서버의 crontab, GitHub Actions 스케줄, Vercel Cron 등)으로 이 두 명령을
주기적으로 실행하는 방식도 가능합니다 — `server.js`를 상시 띄우지 않아도 됩니다.

## 회원이 프로필을 먼저 등록해야 매칭이 가능합니다

이 매칭은 `MemberProfile` 컨트랙트에 저장된 관심분야·소개를 기반으로 하므로, 회원들이
먼저 아래 함수를 호출해 프로필을 등록해야 에이전트가 후보로 인식할 수 있습니다.

```solidity
setProfile(string bio, string[] interests, string email)
```

(대시보드에 프로필 등록 폼을 추가해드릴 수도 있습니다 — 필요하시면 말씀해주세요.)

## 정성적 성과 주장(세미나 연사 초빙 등) 제출

회원이 직접 서버에 요청을 보내 성과 주장을 접수할 수 있습니다 (지갑 서명으로 신원 증명,
별도 로그인 불필요).

```bash
curl -X POST http://localhost:3001/claims/achievement \
  -H "Content-Type: application/json" \
  -d '{
    "address": "0x...",
    "description": "2026년 정기세미나에 OOO 해외 연사 초빙 성사",
    "signature": "지갑으로 서명한 값 (message = RegDAO 성과 주장 제출: <description>)"
  }'
```

이후 절차(에디터 배정 → 리뷰어 모집 → 발행)는 정책제안과 동일합니다.

## 제한사항 / 알아두실 점

- 이 서비스는 **지속적으로 켜져 있어야** 이메일 버튼 클릭이나 정기 스캔이 작동합니다.
  자체 서버(VPS, 클라우드 인스턴스 등)에 배포하셔야 합니다 — 이 대화 환경에서 계속
  실행해드릴 수는 없습니다.
- 비공개 질의응답(에디터·리뷰어 간 논의)은 **이메일로만** 이루어지도록 설계했습니다.
  블록체인은 기본적으로 공개 원장이라, 진짜 비공개 논의를 온체인에 남기려면 별도의
  암호화가 필요한데, 지금 단계에서는 이메일 스레드로 충분히 목적을 달성할 수 있어
  단순하게 설계했습니다.
- 리뷰 의견 자체(`reviewURI`)는 온체인에는 링크(포인터)만 남기고, 실제 내용은
  이메일이나 별도 문서 저장소에 보관하는 걸 권장합니다.
