# AI Glass

Claude Code · Codex · Gemini 사용량을 liquid glass 플로팅 HUD와 메뉴바 대시보드로 보여주는 macOS 앱.

## 실행

```bash
swift run AIGlass                 # 개발 실행 (메뉴바 + 플로팅 HUD)
swift run AIGlass --check-claude  # Claude 한도 API 연결 진단
swift test                        # 단위 테스트
```

요구사항: macOS 26+, Claude Code / Codex / Gemini CLI 중 1개 이상 사용 이력.

### .app 번들로 설치

알림센터 · 로그인 시 자동 시작은 **.app 번들에서만** 동작한다 (`swift run`은 번들이 아니므로 no-op).

```bash
bash Scripts/make-app.sh          # release 빌드 → build/AIGlass.app 생성 (ad-hoc 코드사인)
open build/AIGlass.app            # 실행
cp -r build/AIGlass.app /Applications   # 설치 (선택)
```

## 설정

메뉴바 `✦` 우클릭 → **설정…** (또는 ⌘,):

- **경고/위험 임계값**: HUD·알림이 뜨는 사용률(%) 기준
- **HUD 표시**: 플로팅 알약 표시/숨김 (즉시 반영)
- **알림 보내기**: 이벤트 발생 시 알림센터 알림 (.app 전용)
- **로그인 시 시작**: 자동 시작 (.app 전용 — `swift run`에서는 비활성)
- **Gemini 일일 쿼터**: 요청 수 추정 기준 (재시작 후 적용)

전역 단축키 **⌘⇧U** — 어디서든 대시보드 팝오버 토글.

## 동작

- **플로팅 HUD**: 화면 우상단 liquid glass 알약. 실시간 토큰 소모 속도가 펄스 웨이브로 출렁이고, 이벤트(한도 임계값 도달·소진 임박·윈도우 리셋·토큰 급증) 시 카드로 모핑됐다가 6초 후 수축. 클릭하면 대시보드. 드래그로 이동(위치 기억).
- **메뉴바**: `✦ N%`(최고 사용률). 좌클릭 → 대시보드 팝오버 (개요/추이/프로젝트). 우클릭 → 대시보드·설정·HUD 표시·종료 메뉴.
- **소진 예측**: 사용률 시계열의 추세로 "이 속도면 N분 후 소진 (리셋 전)"을 추정해 개요 탭과 알림에 표시.
- **세션 리포트**: 윈도우 리셋 시 직전 세션 요약(토큰·주 프로젝트·추정 비용)을 카드/알림에 표시.
- **30일 추이**: 추이 탭의 7일/30일 토글. 30일은 SQLite(`~/Library/Application Support/AIGlass/stats.db`)에 영구 저장된 통계 기반.
- **갱신**: FSEvents로 로그 변경 즉시 + 30초 폴백 타이머. Claude 한도는 60초마다 API 폴링.

## 데이터 소스

- Claude: `~/.claude/projects/**/*.jsonl` + Keychain OAuth → 사용량 API (5h/주간 %, 최초 1회 Keychain 허용 필요)
- Codex: `~/.codex/sessions/**/*.jsonl` (rate limit 스냅샷 포함)
- Gemini: `~/.gemini/tmp/**/logs.json` (일일 요청 수 기반 추정, 토큰 데이터 없음)

모든 처리는 로컬. 외부 전송은 Anthropic 사용량 API 호출뿐. 텔레메트리 없음.

## 비용 추정 면책

표시되는 비용($)은 **API 단가 환산 추정치**일 뿐이며 **구독(정액) 실비가 아니다**. Claude Pro/Max, ChatGPT Plus 등 정액 구독 사용자의 실제 청구액과 무관하며, "이만큼을 API로 썼다면 얼마"라는 참고용 환산값이다. 단가는 공개 API 가격 기준 추정이고 시점에 따라 부정확할 수 있다.

## 알려진 제약 (MVP)

- 첫 실행 시 최근 8일 로그를 동기 파싱 — 로그가 많으면 시작에 수 초 소요
- Gemini는 토큰 수를 알 수 없어 요청 수 기반 추정치만 표시
- HUD 헤드라인 %는 세 서비스 윈도우의 최댓값이며 Gemini 추정치도 포함됨
- 비용($)은 API 환산 추정치 — 위 면책 참고
