# 온보딩 투트랙 재설계 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 온보딩 초반에 "HUD 메인 / 메뉴바 메인" 트랙을 고르게 하고, 트랙에 따라 웨이브·메뉴바 단계 순서를 바꾸며 `hudVisible`을 설정한다.

**Architecture:** `Sources/AIGlass/UI/OnboardingView.swift` 단일 파일. `@State track` 추가, step 6→7단계, 1단계에 트랙 선택 삽입, 2·3단계를 `@ViewBuilder`로 트랙 분기. 기존 `waveStyleStep`/`menubarStep` 재사용. SwiftUI 뷰라 단위 테스트 없음 — 빌드 + 수동 검증.

**Tech Stack:** Swift 6, SwiftUI, AppKit. 스펙: `docs/superpowers/specs/2026-06-13-onboarding-two-track-design.md`.

---

### Task 1: 트랙 enum + 상태 + 단계 분기 골격

**Files:** Modify `Sources/AIGlass/UI/OnboardingView.swift`

- [ ] **Step 1: 트랙 타입·상태·stepCount**

`struct OnboardingView` 상단에 추가/수정:

```swift
    @State private var step = 0
    @State private var track: OnboardingTrack?   // nil = 미선택 (트랙 단계 이전)
    private let stepCount = 7                      // 6 → 7
```

파일 내(타입 밖 또는 안)에 enum 정의:

```swift
enum OnboardingTrack { case hud, menubar }
```

- [ ] **Step 2: body의 switch step 재배치**

```swift
            Group {
                switch step {
                case 0: welcomeStep
                case 1: trackStep
                case 2: step2()
                case 3: step3()
                case 4: agentsStep
                case 5: funStep
                default: keychainStep
                }
            }
```

`@ViewBuilder` 헬퍼 2개 추가:

```swift
    @ViewBuilder private func step2() -> some View {
        if track == .menubar { menubarStep } else { waveStyleStep }
    }
    @ViewBuilder private func step3() -> some View {
        if track == .menubar { waveStyleStep } else { menubarStep }
    }
```

- [ ] **Step 3: 트랙 미선택 시 "다음" 잠금**

네비게이션 바의 "다음" 버튼이 step 1에서 track==nil이면 비활성. 기존:

```swift
                if step < stepCount - 1 {
                    Button("다음") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
```

을 다음으로:

```swift
                if step < stepCount - 1 {
                    Button("다음") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && track == nil)
```

- [ ] **Step 4: 빌드 (트랙 화면은 다음 태스크)**

Run: `swift build 2>&1 | tail -3`
Expected: `trackStep`이 아직 없어 컴파일 실패 — "cannot find 'trackStep'". Task 2에서 해소. (이 단계 단독 커밋 안 함)

### Task 2: 트랙 선택 화면

**Files:** Modify `Sources/AIGlass/UI/OnboardingView.swift`

- [ ] **Step 1: trackStep + trackCard 추가**

`// MARK: - 공통` 앞에 추가:

```swift
    // MARK: - 1.5 트랙 선택

    private var trackStep: some View {
        VStack(spacing: 16) {
            stepHeader("어떻게 보고 싶으세요?",
                       "느낌 가는 쪽으로 고르세요 — 설정에서 언제든 바꿀 수 있어요.")
            VStack(spacing: 12) {
                trackCard(
                    .hud, title: "HUD 알약", icon: "rectangle.on.rectangle.angled",
                    points: ["원하는 곳에 배치", "세련된 liquid glass 스타일", "마우스 호버로 사용량 빠르게 확인"],
                    warning: nil)
                trackCard(
                    .menubar, title: "메뉴바", icon: "menubar.rectangle",
                    points: ["깔끔하게 메뉴바 안에", "다른 화면 방해 없음", "단축키로 사용량 확인"],
                    warning: "HUD 알약은 표시되지 않아요")
            }
            Spacer()
        }
    }

    /// 트랙 카드 — 탭하면 트랙 선택 + hudVisible 적용 + 다음 단계로 자동 진행.
    private func trackCard(_ t: OnboardingTrack, title: String, icon: String,
                           points: [String], warning: String?) -> some View {
        let selected = track == t
        return Button {
            track = t
            settings.hudVisible = (t == .hud)
            withAnimation { step += 1 }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    ForEach(points, id: \.self) { p in
                        Label(p, systemImage: "checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 2: 빌드**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/AIGlass/UI/OnboardingView.swift
git commit -m "feat: 온보딩 트랙 선택 단계 (HUD/메뉴바) + 단계 분기"
```

(Co-Authored-By 푸터 금지.)

### Task 3: 웨이브 단계 적응형 카피

**Files:** Modify `Sources/AIGlass/UI/OnboardingView.swift`

- [ ] **Step 1: waveStyleStep 부제 동적화**

`waveStyleStep`의 `stepHeader(...)` 줄을 교체:

```swift
            stepHeader("웨이브 스타일", waveStyleSubtitle)
```

그리고 `waveStyleStep` 아래에 계산 프로퍼티 추가:

```swift
    private var waveStyleSubtitle: String {
        if track == .menubar {
            return settings.menubarMode == .wavePill
                ? "메뉴바 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
                : "웨이브 스타일은 이렇게 다양해요 — 기본(펄스 바)으로 둬도 되고, 마음에 드는 걸 골라보세요."
        }
        return "HUD 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
    }
```

- [ ] **Step 2: 빌드 + 커밋**

Run: `swift build 2>&1 | tail -1` → Build complete.

```bash
git add Sources/AIGlass/UI/OnboardingView.swift
git commit -m "feat: 온보딩 웨이브 단계 적응형 카피 (트랙·메뉴바 모드 반영)"
```

### Task 4: 빌드 + 수동 검증

- [ ] **Step 1: 번들 빌드 + 온보딩 리셋 실행**

```bash
bash Scripts/make-app.sh
pkill -f "AIGlass" 2>/dev/null; sleep 1
defaults delete io.taeng.aiglass aiglass.onboardingCompleted 2>/dev/null
open build/AIGlass.app
```

- [ ] **Step 2: 검증 체크리스트** (screencapture로 단계별 확인)

1. 1단계 = 트랙 선택, 두 카드 + "나중에 바꿀 수 있어요" 부제, 메뉴바 카드에 "HUD 알약은 표시되지 않아요" 경고.
2. HUD 카드 탭 → 자동으로 2단계(웨이브). 이후 3단계 메뉴바. HUD 알약 화면에 떠 있음(hudVisible=true).
3. 1단계로 돌아와 메뉴바 카드 탭 → 2단계 메뉴바 정보 → 3단계 웨이브. HUD 알약 사라짐(hudVisible=false).
4. 메뉴바 트랙 + 텍스트 모드 선택 후 웨이브 단계 부제 = "다양해요…".
5. 메뉴바 트랙 + 미니 알약 선택 후 웨이브 단계 부제 = "메뉴바 알약의 움직임…".
6. 완료("시작하기") 후 hudVisible·menubarMode·waveStyle이 선택대로 적용.
7. 진행 점 7개.

- [ ] **Step 3: README 업데이트 (온보딩 설명)**

README의 온보딩 항목을 트랙 선택 반영해 갱신:

```markdown
- **온보딩**: 첫 실행 시 HUD/메뉴바 사용 방식을 고르고, 웨이브 스타일·메뉴바 모드·에이전트를 라이브 프리뷰로 선택
```

```bash
git add README.md
git commit -m "docs: 온보딩 투트랙 README 반영"
```

## 검증 요약
- 자동: 코어 변경 없음 — 기존 175 테스트 그대로 통과 확인(`swift test`).
- 수동: Task 4 체크리스트 7항목.
- 리스크: 트랙 카드 탭 시 hudVisible 실시간 반영 — SettingsView의 동일 토글이 이미 동작하므로 배선 존재. 검증 2·3에서 확인.
