# 온보딩 투트랙 재설계 — Design Spec

**작성일:** 2026-06-13
**관련:** GitHub 이슈 #1 (메뉴바 미니 알약), 그 후속 UX 통합

## 배경 / 문제

메뉴바 미니 알약(`MenubarMode.wavePill`)과 "알림 전용 HUD"(HUD를 꺼도 이벤트 카드가 그 자리에 잠깐 뜨는 `flashHUD`)가 추가되면서, 이제 사용자는 두 가지 사용 방식 중 하나를 택할 수 있다:

- **HUD를 메인으로** — 떠다니는 liquid glass 알약을 주로 본다.
- **메뉴바를 메인으로** — 메뉴바 안에서 본다. HUD는 끈다.

이 둘은 사실상 **상호 배타적**으로 쓰인다(둘 다 동시에 띄우는 경우는 드물다). 그러나 현재 온보딩은 선형 6단계(환영 → 웨이브 → 메뉴바 → 에이전트 → 재미 → 키체인)로, 두 방식을 구분 없이 모두 설정하게 한다. 사용자가 자기 사용 방식을 처음에 정하고 그에 맞는 흐름만 타도록 온보딩을 **투트랙**으로 재설계한다.

## 목표

- 온보딩 초반에 "HUD 메인 / 메뉴바 메인" 트랙을 고르게 한다.
- 트랙에 따라 같은 두 설정(`waveStyle`, `menubarMode`)을 **순서만 바꿔** 고르게 하고, 트랙이 `hudVisible`을 결정한다.
- 트랙 선택은 "느낌 가는 쪽으로, 설정에서 언제든 바꿀 수 있다"는 점을 알려 부담을 없앤다.

## 비목표 (YAGNI)

- 트랙을 영속 설정으로 저장하지 않는다. 트랙은 `hudVisible` + `menubarMode` 조합으로 환원되며, 그 둘은 설정 창에서 이미 각각 변경 가능하다. 온보딩 중 분기용 `@State`로만 둔다.
- 단계 배열을 트랙별로 동적 생성하지 않는다(7단계 고정이므로 과설계). `step` 정수 인덱스를 유지하고 2·3단계 내용만 분기한다.
- 설정 창(SettingsView)은 이 작업에서 바꾸지 않는다. (HUD on/off·메뉴바 모드 토글은 이미 존재)

## 아키텍처 / 접근

**파일:** `Sources/AIGlass/UI/OnboardingView.swift` 한 곳만 수정. 기존 `waveStyleStep`·`menubarStep` 컴포넌트를 양 트랙이 재사용한다.

- `@State private var track: OnboardingTrack?` 추가 (nil = 미선택). 트랙 선택 단계에서 채워진다.
- `enum OnboardingTrack { case hud, menubar }` — OnboardingView 내부 또는 파일 내 정의(영속화 없음).
- `stepCount`를 6 → 7로.
- `step == 1`에 트랙 선택 화면(`trackStep`)을 끼운다. 이후 단계 인덱스가 한 칸씩 밀린다.

### 단계 구조 (7단계)

| step | HUD 트랙 | 메뉴바 트랙 |
|------|---------|------------|
| 0 | welcomeStep (그대로) | welcomeStep |
| 1 | **trackStep** [신규] | trackStep |
| 2 | waveStyleStep | menubarStep |
| 3 | menubarStep | waveStyleStep |
| 4 | agentsStep (그대로) | agentsStep |
| 5 | funStep (그대로) | funStep |
| 6 | keychainStep (그대로) | keychainStep |

`body`의 `switch step`에서 2·3단계만 `track`에 따라 `@ViewBuilder` 헬퍼로 분기(AnyView 회피):

```swift
@ViewBuilder private func step2() -> some View {
    if track == .menubar { menubarStep } else { waveStyleStep }
}
@ViewBuilder private func step3() -> some View {
    if track == .menubar { waveStyleStep } else { menubarStep }
}
// body: case 2: step2(); case 3: step3()
```

### 트랙 선택 단계 (`trackStep`, step 1)

- 헤더: "어떻게 보고 싶으세요?"
- 부제: "느낌 가는 쪽으로 고르세요 — 설정에서 언제든 바꿀 수 있어요."
- 카드 2개 (세로 배치, 탭하면 즉시 선택 + 설정 적용):

  **HUD 알약** (아이콘/미니 프리뷰 + 장점 목록)
  - 원하는 곳에 배치
  - 세련된 liquid glass 스타일
  - 마우스 호버로 사용량 빠르게 확인

  **메뉴바** (아이콘/미니 알약 프리뷰 + 장점 목록)
  - 깔끔하게 메뉴바 안에
  - 다른 화면 방해 없음
  - 단축키로 사용량 확인
  - ⚠️ **HUD 알약은 표시되지 않아요** (시각적으로 강조 — 색/굵기)

- 선택된 카드는 기존 행 선택 스타일(accent 테두리 + 체크)과 동일하게 표시.

### 설정 매핑 (트랙 탭 즉시 적용)

```swift
// 카드 탭 핸들러
track = .hud
settings.hudVisible = true
// 또는
track = .menubar
settings.hudVisible = false
```

- `menubarMode`·`waveStyle`은 트랙 탭 시 **건드리지 않는다**(현재값에서 시작). 각자의 단계에서 사용자가 선택.
- 주의: `hudVisible` 변경은 `AppSettings`의 didSet을 통해 HUD 패널 가시성에 반영되어야 한다. 온보딩 중 실시간 반영되는지 확인(이미 SettingsView에서 동일 토글이 동작하므로 배선 존재).

### 웨이브 단계 적응형 카피 (`waveStyleStep`)

현재 헤더는 고정 "웨이브 스타일 / HUD 알약의 움직임을 고르세요". 트랙·메뉴바 모드에 따라 부제를 바꾼다:

```swift
private var waveStyleSubtitle: String {
    if track == .menubar {
        return settings.menubarMode == .wavePill
            ? "메뉴바 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
            : "웨이브 스타일은 이렇게 다양해요 — 기본(펄스 바)으로 둬도 되고, 마음에 드는 걸 골라보세요."
    }
    return "HUD 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다." // HUD 트랙(현재 카피)
}
```

(헤더 제목 "웨이브 스타일"은 공통 유지.)

### 메뉴바 단계 카피 (`menubarStep`)

- 제목/부제는 현재대로("메뉴바 표시" / "메뉴바에 어떤 정보를 고정 표시할지 고르세요").
- HUD 트랙의 3단계에서도 동일 컴포넌트 사용(부가 옵션 성격이지만 별도 카피 불필요 — YAGNI).
- 5개 모드 모두 표시, 미니 알약은 이미 라이브 `WaveStylePreview` 프리뷰 적용됨(직전 작업).

## 데이터 흐름

```
welcome → trackStep
  ├─ [HUD 탭]    → hudVisible=true  → waveStyle 선택 → menubarMode 선택 → …
  └─ [메뉴바 탭] → hudVisible=false → menubarMode 선택 → waveStyle 선택 → …
                                       (적응형 카피)
```

트랙 미선택(`track == nil`) 상태에서 "다음"을 누르면 진행 불가하게 하거나(버튼 비활성), 트랙 카드 탭이 곧 선택이므로 탭하면 자동으로 다음 단계로 넘어가게 한다 — **카드 탭 = 선택 + 자동 진행(step += 1)** 으로 한다(웨이브/메뉴바 행은 탭해도 진행 안 하지만, 트랙은 단일 결정이므로 탭 즉시 진행이 자연스럽다). "이전"으로 돌아오면 재선택 가능.

## 엣지 케이스 / 에러 처리

- **트랙 미선택 방지:** step 1에서 트랙 카드를 탭하기 전엔 "다음" 버튼을 숨기거나(카드 탭이 진행을 담당), `track == nil`이면 step 2 진입을 막는다.
- **뒤로 갔다 트랙 변경:** step 1로 돌아와 다른 트랙을 고르면 `hudVisible`이 다시 설정되고 2·3단계 내용이 새 트랙 기준으로 바뀐다. `step` 인덱스는 동일하므로 추가 처리 불필요.
- **온보딩 도중 종료:** 기존과 동일(완료 전까지 `onboardingCompleted=false`). 트랙은 @State라 재진입 시 초기화되지만, 그때까진 이미 hudVisible 등이 적용된 상태 — 무해(다시 고르면 덮어씀).

## 테스트

- OnboardingView는 SwiftUI 뷰라 단위 테스트 대상이 아니다(기존 관례: 수동 검증). 코어 로직 변경 없음.
- **수동 검증(make-app → 실행, onboardingCompleted 리셋):**
  1. 트랙 선택 화면이 1단계에 등장, 두 카드 + "나중에 바꿀 수 있어요" 문구.
  2. HUD 트랙 → 2단계 웨이브 → 3단계 메뉴바. hudVisible=true 확인.
  3. 메뉴바 트랙 → 2단계 메뉴바 정보 → 3단계 웨이브. hudVisible=false 확인(HUD 알약 사라짐).
  4. 메뉴바 트랙 + 텍스트 모드 → 웨이브 단계 부제가 "다양해요…" 카피.
  5. 메뉴바 트랙 + 미니 알약 → 웨이브 단계 부제가 "메뉴바 알약의 움직임…".
  6. "이전"으로 트랙 재선택 시 분기 내용 갱신.
  7. 완료 후 실제 hudVisible·menubarMode·waveStyle이 선택대로 적용.

## 미해결 / 향후

- 트랙 선택 카드의 "라이브 프리뷰"를 얼마나 정교하게 할지는 구현 시 결정(HUD 카드는 WaveStylePreview, 메뉴바 카드는 미니 알약 형태 — 과하면 아이콘+텍스트로 단순화).
