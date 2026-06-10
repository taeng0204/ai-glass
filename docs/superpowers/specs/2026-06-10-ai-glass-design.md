# AI Glass — 설계 문서

날짜: 2026-06-10
상태: 사용자 승인 대기

## 개요

Claude Code · Codex · Gemini 세 AI 코딩 에이전트의 구독 플랜 사용량을 추적하는 macOS 네이티브 앱.
두 개의 얼굴을 가진다:

1. **플로팅 HUD** — 화면 오른쪽 최상단에 상시 떠있는 liquid glass "펄스 웨이브" 알약. 실시간 토큰 소모 속도가 파형으로 출렁이고, 이벤트 발생 시 glass 카드로 모핑되어 내용을 보여준 뒤 자동 수축.
2. **메뉴바 팝오버** — NSStatusItem 클릭 시 열리는 대시보드. 탭(개요/추이/모델별)으로 풀 통계 접근.

핵심 가치: **진짜 liquid glass의 아름다움**. macOS 26+의 네이티브 글래스 머티리얼(`glassEffect`, `NSGlassEffectView`)을 사용하며, 웹 기술 모사를 배제한다.

## 결정 사항 (브레인스토밍 확정)

| 항목 | 결정 |
|---|---|
| 팝오버 정보 밀도 | **B 대시보드** (게이지 + 주간 한도 + 오늘 토큰/비용/세션) + 탭으로 풀 통계(C) 접근 |
| HUD 동작 | **상시 표시** (Dynamic Island 스타일) — 이벤트 시 카드로 모핑 후 자동 수축 |
| 알약 디자인 | **펄스 웨이브** — Siri 웨이브폼처럼 burn rate가 실시간 파형으로 표현, "작업 중일 때 살아있는 느낌" |
| 과금 전제 | 셋 다 구독 플랜 (Claude Pro/Max, ChatGPT Plus/Pro, Google AI Pro) → 한도 윈도우 % 추적이 1순위 |
| 기술 스택 | **순수 Swift/SwiftUI 네이티브** (대안이었던 Tauri, ccusage 위임은 기각) |

## 아키텍처

단일 SwiftUI 앱 (LSUIElement=true, Dock 아이콘 없음). 데이터 흐름은 단방향:

```
로컬 로그/API → Collectors → UsageStore(@Observable) → UI (HUD · 팝오버 · 설정)
                                    ↓
                               EventEngine → HUDEvent → HUD 모핑
```

외부 네트워크는 Anthropic OAuth 사용량 API 폴링 단 하나. 텔레메트리 없음, 모든 데이터 로컬.

## 컴포넌트

### 수집 계층

- **FileWatcher**: FSEvents로 `~/.claude`, `~/.codex`, `~/.gemini` 로그 디렉토리 감시. 파일 변경 즉시 해당 Collector를 트리거. 로그 쓰기 활동 자체가 펄스 웨이브 진폭의 신호원.
- **UsageCollector 프로토콜**: `serviceID`, `fetchLimits()`, `parseNewEntries()` — 서비스별 구현 3개.
  - **ClaudeCollector**: macOS Keychain의 Claude Code OAuth 토큰 → Anthropic 사용량 API 60초 폴링(정확한 5h/주간 %) + `~/.claude/projects/**/*.jsonl` 증분 파싱(토큰·모델·비용).
  - **CodexCollector**: `~/.codex/sessions/**/*.jsonl` 증분 파싱 — 이벤트에 포함된 rate limit 스냅샷(primary/secondary 윈도우 %)과 토큰 카운트.
  - **GeminiCollector**: `~/.gemini/tmp/**/logs.json` 파싱 — 토큰 카운트, 일일 요청 쿼터 기반 % 추정. 쿼터 기준값은 설정에서 플랜 선택(기본: Google AI Pro의 일일 요청 한도), 구현 시 실제 로그로 검증.
- 증분 파싱: 파일별 오프셋을 기억하여 새 줄만 읽음. 전체 재파싱은 시작 시 1회.

### 상태/두뇌

- **UsageStore** (`@Observable`, 단일 진실 공급원):
  - 서비스별 `LimitWindow` (사용률 %, 리셋 시각, 윈도우 종류)
  - 토큰/비용 시계열 (모델별 분해 포함)
  - burn rate (최근 10분 이동평균 vs 7일 기저선)
  - 일별 집계는 SQLite(`~/Library/Application Support/AIGlass/stats.db`)에 캐시 — 재시작 후 7일 차트 즉시 표시
- **EventEngine** — UsageStore 변화를 구독하는 규칙 엔진. HUDEvent 발행 조건:
  1. **토큰 급증**: burn rate가 기저선의 N배 초과 (기본 3배, 설정 가능)
  2. **한도 임박**: 어떤 윈도우든 70% / 90% 교차 시 (설정 가능)
  3. **윈도우 리셋**: 새 5h 세션/일일 쿼터 시작 감지 — 지난 세션 요약(토큰·비용) 포함
  - 동일 이벤트 중복 발행 방지(쿨다운), 이벤트 우선순위: 한도 임박 > 리셋 > 급증

### UI 계층

- **FloatingHUD**: non-activating `NSPanel` (`.statusBar` 레벨, `canJoinAllSpaces` + `fullScreenAuxiliary`) — 포커스를 뺏지 않고 모든 Spaces·전체화면 위에 표시.
  - 평소: 펄스 웨이브 알약 (파형 7-bar, 전체 사용률 %). 에이전트 활동 없으면 파형이 잔잔해짐.
  - "전체 사용률 %" 정의: 세 서비스의 현재 윈도우 사용률 중 **최댓값** (가장 긴급한 한도). 색상도 이 값 기준(녹/황/적).
  - 이벤트: 알약 → 이벤트 카드로 glass 모핑 (제목, 게이지, 부가 정보) → 6초 후 자동 수축 (호버 시 유지).
  - 클릭: 메뉴바 팝오버 열기. 드래그로 위치 조정 가능(우상단 기본).
- **MenuBar 팝오버**: 대시보드 탭 3개
  - **개요**: 서비스별 게이지 바(5h % + 주간 % + 리셋 카운트다운), 오늘의 토큰/비용/세션 요약 카드
  - **추이**: 7일(추후 30일) 토큰/비용 차트 — Swift Charts
  - **모델별**: 모델 비중 분해 (Opus/Sonnet, GPT 계열, Gemini 계열)
- **Settings**: 이벤트 임계값, HUD 표시 토글·위치 리셋, 서비스별 표시 on/off, 로그인 시 시작.

## 에러 처리

- 서비스별 독립 degrade: 한 서비스의 수집 실패가 다른 서비스·앱 전체에 영향 없음.
- Claude OAuth 토큰 만료/부재: 해당 게이지 `–` + "Claude Code에 재로그인 필요" 안내.
- 로그 포맷 변화(파싱 실패): 해당 서비스 "통계 일시 중단" 표시, 디버그 로그 기록.
- API 일시 실패: 마지막 값 유지 + stale(흐림) 표시, 지수 백오프 재시도.
- 로그 디렉토리 부재(미설치 도구): 해당 서비스 자동 숨김.

## 테스트

- **파서 단위 테스트**: 실제 로그 샘플을 fixture로 고정 (Claude JSONL, Codex JSONL, Gemini logs.json). 포맷 변형·손상 라인 내성 포함.
- **EventEngine 규칙 테스트**: 임계 교차, 쿨다운, 우선순위.
- **UsageStore 집계 테스트**: 시계열 집계, burn rate 계산, SQLite 캐시 왕복.
- UI: SwiftUI 프리뷰 + 수동 검증.

## 비범위 (YAGNI)

- 멀티 계정/프로필, 클라우드 동기화, 리더보드 등 소셜 기능
- Claude/Codex/Gemini 외 서비스 (Copilot, Cursor 등) — 구조상 Collector 추가로 확장 가능하게만 설계
- API 종량제 비용 추적 모드
- Windows/리눅스 지원, Mac App Store 배포 (개인용 빌드)
