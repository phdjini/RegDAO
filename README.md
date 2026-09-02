# 민관협의체 DAO — 평판 배지 기반 거버넌스 시스템

Polygon PoS **Amoy 테스트넷(Chain ID 80002)** 배포를 목표로 설계한 Web3 거버넌스 시스템입니다.
민간·공공 부문이 함께 참여하는 협의체를 퍼블릭 블록체인 위에서 운영하기 위해, "누가 발언·투표할
자격이 있는가"를 **양도 불가능한 평판 배지(Soulbound Token)**로 온체인에 기록합니다.

## 핵심 아이디어

| 요구사항 | 구현 |
|---|---|
| 의사결정·투표·발언을 위한 배지 | `BadgeSBT.sol` — ERC-721 기반 양도불가 배지, 레벨 1~4 |
| 지지를 받으면 올라가는 민팅 알고리즘 | `endorse()` — 기존 Lv2+ 멤버의 고유 지지가 임계값에 도달하면 자동 레벨업 |
| 어뷰징에 대한 슬래싱 페널티 | `slash()` — 거버넌스 투표로 통과된 제안만 실행 가능, 레벨 강등 또는 배지 완전 소각 |
| 퍼블릭 체인에서 자유로운 참여 | Polygon PoS Amoy (EVM 호환, 낮은 가스비, 공개 네트워크) |

## 컨트랙트 구성

### 1. `BadgeSBT.sol` — 평판 배지 (Soulbound)
- **레벨 체계**: Lv1 Observer(참관) → Lv2 Member(정회원, 제안·지지 가능) → Lv3 Council(협의회) → Lv4 Elder(원로)
- **발급**: `REGISTRAR_ROLE`(운영기관, 민+관 심사 주체)만 신규 회원에게 Lv1 배지 발급 (`mint`)
- **창립 부트스트랩**: `mintAt(address, level)` — DAO 출범 시 검증된 창립 대표단을 Lv2 이상으로 직접 지정 (최초 지지자가 있어야 endorse 생태계가 굴러가기 때문)
- **지지 기반 레벨업**: Lv2 이상만 타인을 지지(`endorse`) 가능. 같은 레벨에서 중복 지지 불가, 자기 자신 지지 불가, 지지자별 쿨다운(기본 1시간)으로 담합/스팸 방지. 임계값(기본 Lv1→2: 3명, Lv2→3: 5명, Lv3→4: 8명) 도달 시 자동 레벨업
- **슬래싱**: `GOVERNANCE_ROLE`(=DAOGovernance 컨트랙트)만 호출 가능. 레벨을 강등시키고, 0 이하가 되면 배지 완전 소각(자격 박탈)
- **전송 금지**: `_update` 오버라이드로 mint/burn 외 모든 전송을 revert (Soulbound)

### 2. `DAOGovernance.sol` — 제안·투표·집행
- **제안권**: 배지 Lv2 이상만 제안 가능
- **제안 종류**:
  - `GENERAL`: 임의의 컨트랙트 호출(예산 집행, 규정 개정 등)
  - `SLASH`: 특정 멤버에 대한 슬래싱(강등폭 지정) — 어뷰징 신고 시 사용
- **투표권**: 배지 레벨 = 투표 파워 (Lv1=1표 ~ Lv4=4표)
- **투표 기간**: 기본 3일, 정족수(기본 10 파워) 및 찬성 우세 시 `SUCCEEDED` → `execute()`로 집행
- **집행**: SLASH 제안이 통과되면 `BadgeSBT.slash()`를 자동 호출

## 왜 이렇게 설계했는가

1. **양도불가(SBT)** — 배지가 거래 가능한 NFT라면 "신뢰"를 사고팔 수 있게 되어 협의체의 정당성이 훼손됩니다. 평판은 본인에게 귀속되어야 합니다.
2. **동료 지지 기반 레벨업** — 중앙기관이 일방적으로 등급을 매기지 않고, 이미 신뢰를 획득한 회원들의 동의를 거치도록 하여 민관 양쪽의 실질적 참여도를 반영합니다.
3. **투표를 통한 슬래싱** — 한 사람(관리자)이 임의로 자격을 박탈하지 못하도록, 슬래싱도 반드시 거버넌스 투표를 거치게 했습니다. 권력 남용 방지책입니다.
4. **레벨 기반 차등 투표권** — 1인 1표가 아니라 신뢰 축적도에 비례한 투표권을 부여해, 어뷰징 계정을 대량 생성해도(Lv1은 제안권조차 없음) 영향력을 행사하기 어렵게 설계했습니다.

## 로컬에서 테스트하기

```bash
npm install
npx hardhat test
```

`test/dao.test.js`에 발급 → 지지 → 자동 레벨업 → 중복지지 방지 → 슬래싱 제안/투표/집행 →
soulbound 검증까지의 전체 시나리오가 포함되어 있습니다.

> 참고: 본 샌드박스 환경은 네트워크 접근이 제한되어 있어 `solc` 컴파일러를 npm 패키지(js 버전)로
> 직접 호출해 문법 오류가 없음을 확인했습니다(`node verify_compile.js`). 실제 `npx hardhat test`
> 실행과 배포는 네트워크 제한이 없는 본인 PC에서 진행해 주세요.

## Amoy 테스트넷 배포 방법

1. `.env` 파일 생성 (`.env.example` 참고)
   ```
   PRIVATE_KEY=0x본인지갑개인키
   AMOY_RPC_URL=https://rpc-amoy.polygon.technology/
   ```
2. 배포용 지갑에 테스트 POL 충전 (Alchemy/QuickNode/Chainlink Amoy 파우셋 이용)
3. 배포 실행
   ```bash
   npx hardhat run scripts/deploy.js --network amoy
   ```
4. 배포 완료 후 출력되는 `BadgeSBT`, `DAOGovernance` 주소를 `amoy.polygonscan.com`에서 확인

## 운영 시나리오 예시

1. 운영기관이 창립 민·관 대표단 5~10인을 `mintAt()`으로 Lv2~3 배지 발급하며 DAO 출범
2. 신규 참여 희망 기관/개인은 심사 후 `mint()`으로 Lv1 배지 발급받아 참관 자격 획득
3. 활동과 신뢰가 쌓이면 기존 회원들의 `endorse()`를 받아 Lv2(정회원)로 자동 승격, 이때부터 제안·투표·타인 지지 가능
4. 봇/사재기/담합 등 어뷰징이 포착되면 누구든 `proposeSlash()`로 슬래싱 제안 → 커뮤니티 투표 →
   가결 시 자동으로 레벨 강등 또는 자격 박탈

## v2 — 온체인 정관 (Charter)

기존 v1(BadgeSBT + DAOGovernance)에 **정관 컨트랙트(Charter.sol)**를 추가해, 정족수·투표기간·가입 요건·슬래싱 사유·레벨업 경로를 온체인에 명문화했습니다.

### 핵심 설계

- **이중 정족수 체계**: 일반 안건(`quorumNormal`, 기본 5)과 정관 개정(`quorumAmendment`, 기본 12, 더 엄격)을 분리. 정관 개정은 Council(Lv3) 이상만 제안 가능하고 투표기간도 더 깁니다(기본 7일 vs 3일).
- **정관 개정도 반드시 투표를 거침**: `Charter`의 모든 파라미터·조항 변경 함수는 `onlyGovernance`로 제한되어 있어, DAOGovernance를 통해 통과된 `CHARTER_AMENDMENT` 제안만 실행할 수 있습니다. 관리자가 임의로 바꿀 수 없습니다 (단, `setGovernance()` 호출 전 최초 부트스트랩 단계에서만 admin이 초기값을 조정 가능).
- **정성적 레벨업 경로**: 지지(endorse) 기반 자동 승급 외에, "해외 유력 인사 초빙", "산업 발전 기고문 발표", "게시판 제안으로 지지 획득" 같은 정성적 기여는 `ACHIEVEMENT` 유형 제안으로 발의 → 투표 → 통과 시 `BadgeSBT.levelUpByGovernance()`가 호출되어 레벨이 상승합니다.
- **개정 이력 투명성**: 모든 정관 변경은 `Amendment` 구조체로 온체인에 기록되어(`amendmentHistory`), 어떤 제안(#번호)이 어떤 항목을 어떻게 바꿨는지 누구나 조회할 수 있습니다.

### 배포 (v2, Charter 포함)

`scripts/deploy.js`가 Charter → BadgeSBT → DAOGovernance 순서로 배포하고 권한을 자동 연결합니다.

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

⚠️ `Charter.setGovernance()` 호출 이후에는 정관 파라미터를 admin이 직접 바꿀 수 없습니다. 테스트용으로 짧은 투표기간이 필요하면 배포 스크립트 실행 전에 `deploy.js`의 `setGovernance()` 호출 이전 구간에서 admin이 `setQuorumNormal`, `setVotingPeriodNormal` 등을 먼저 호출하도록 커스터마이징하세요.

### 대시보드에서 정관 확인·개정하기

`dashboard/index.html`의 **정관** 탭에서:
- 현재 정족수/투표기간, 창립 조항, 가입 요건, 슬래싱 사유, 레벨업 경로 전체 열람
- 개정 이력 테이블 확인
- Council(Lv3) 이상 지갑으로 정관 개정 제안 직접 제출
- 정성적 기여에 대한 성과 인증 제안 제출

상단 설정란에 **Charter 컨트랙트 주소**를 추가로 입력해야 이 탭이 활성화됩니다.



- 제안 생성 시점의 **투표력 스냅샷** 적용 (현재는 실시간 레벨 참조라 투표 도중 레벨 변동 영향 가능)
- 슬래싱 시 **경제적 담보(스테이킹) 몰수**까지 결합해 금전적 억지력 추가
- 오프체인 신원증명(DID/KYC)과 연동해 `REGISTRAR_ROLE`의 최초 심사 자동화
- Timelock 컨트랙트를 거쳐 `GENERAL` 제안 집행에 유예기간 부여
