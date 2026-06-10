# AI Glass

Claude Code · Codex · Gemini 사용량을 liquid glass 플로팅 HUD와 메뉴바 대시보드로 보여주는 macOS 앱.

## 실행

```bash
swift run AIGlass                 # 앱 실행 (메뉴바 + 플로팅 HUD)
swift run AIGlass --check-claude  # Claude 한도 API 연결 진단
swift test                        # 단위 테스트
```

요구사항: macOS 26+, Claude Code / Codex / Gemini CLI 중 1개 이상 사용 이력.

## 동작

- **플로팅 HUD**: 화면 우상단 liquid glass 알약. 실시간 토큰 소모 속도가 펄스 웨이브로 출렁이고, 이벤트(한도 70/90% 도달·윈도우 리셋·토큰 급증) 시 카드로 모핑됐다가 6초 후 수축. 클릭하면 대시보드. 드래그로 이동 가능.
- **메뉴바**: `✦ N%`(최고 사용률). 클릭 → 대시보드 팝오버 (개요/추이/모델별 탭).
- **갱신**: FSEvents로 로그 변경 즉시 + 30초 폴백 타이머. Claude 한도는 60초마다 API 폴링.

## 데이터 소스

- Claude: `~/.claude/projects/**/*.jsonl` + Keychain OAuth → 사용량 API (5h/주간 %, 최초 1회 Keychain 허용 필요)
- Codex: `~/.codex/sessions/**/*.jsonl` (rate limit 스냅샷 포함)
- Gemini: `~/.gemini/tmp/**/logs.json` (일일 요청 수 기반 추정, 토큰 데이터 없음)

모든 처리는 로컬. 외부 전송은 Anthropic 사용량 API 호출뿐. 텔레메트리 없음.

## 알려진 제약 (MVP)

- 첫 실행 시 최근 8일 로그를 동기 파싱 — 로그가 많으면 시작에 수 초 소요
- 비용($) 추적, 설정 UI, SQLite 캐시는 미구현 (스펙상 의도적 연기)
- Gemini는 토큰 수를 알 수 없어 요청 수 기반 추정치만 표시
- HUD 헤드라인 %는 세 서비스 윈도우의 최댓값이며 Gemini 추정치도 포함됨
