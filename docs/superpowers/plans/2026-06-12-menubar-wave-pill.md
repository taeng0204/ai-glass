# 메뉴바 미니 알약 (이슈 #1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HUD 웨이브 알약을 메뉴바 상태 아이템 안에 미니 버전으로 표시하는 5번째 메뉴바 모드 추가 + HUD 알약을 꺼도 이벤트 알림 카드는 기존 HUD 위치에 잠깐 떠오르게 (GitHub 이슈 #1 대응, 사용자 확정 방향: "알약 HUD는 없애되, 해당 위치에 알람 띄우기").

**Architecture:** 기존 `WavePill`(HUDView.swift)에 `compact`/`paused` 파라미터를 추가해 재사용하고, `NSStatusItem.button` 위에 클릭-통과 `NSHostingView`를 얹는다. 활동이 없으면 TimelineView를 멈춰 메뉴바 상시 애니메이션의 에너지 비용을 없앤다. 모드 전환은 기존 `updateStatusTitle()` 경로에 설치/제거 분기로 편승한다. HUD가 숨김 상태일 때 이벤트가 오면 HUD 패널을 임시로 띄워 카드만 보여주고(알약 미표시) 종료 후 다시 숨긴다.

**Tech Stack:** Swift 6 SPM, SwiftUI(TimelineView), AppKit(NSStatusItem + NSHostingView), Swift Testing.

**배경 (이슈 해석):** seongyongju님 요청 "I want to see the screen displayed in the HUD options in the menu bar" — 플로팅 HUD 알약을 끄고 싶지만 그 표시(웨이브+사용률)는 메뉴바에서 보고 싶다는 의도로 확인. 기존 메뉴바 모드는 텍스트 4종(todayTokens/burnRate/maxPercent/iconOnly)뿐.

**설계 결정:**
- 알약 내용 = 웨이브(설정된 WaveStyle 그대로) + 서비스 점 + % (카운트다운은 메뉴바 폭 절약을 위해 제외).
- 메뉴바 글로우(빨강 shadow)는 메뉴바에서 클리핑되므로 compact에서는 끔 — 위험도는 % 색으로 충분.
- 폭은 `WaveStyle.areaWidth + 52`로 고정 (% 자릿수 변화로 이웃 메뉴바 아이템이 밀리는 것 방지).
- idle(activityLevel·requestActivityLevel 모두 0)이면 `TimelineView paused` — 정지 프레임. store가 @Observable이라 다음 refresh(30s)에 활동이 생기면 자동 재개.
- 클릭은 기존 `statusItemClicked`(대시보드 토글) 유지 — 호스팅 뷰는 `hitTest → nil`로 통과.

**파일 구조:**
- `Sources/AIGlass/UI/HUDView.swift` — WavePill에 compact/paused 추가 (수정)
- `Sources/AIGlass/UI/MenubarPill.swift` — MenubarPillView + ClickThroughHostingView + 폭 헬퍼 (신규)
- `Sources/AIGlass/AppSettings.swift` — MenubarMode에 `.wavePill` 케이스 (수정)
- `Sources/AIGlass/UI/OnboardingView.swift` — 프리뷰 텍스트 케이스 (수정)
- `Sources/AIGlass/UI/SettingsView.swift` — waveStyle 변경 시 메뉴바 갱신 콜백 (수정)
- `Sources/AIGlass/App.swift` — 설치/제거 배선 (수정)
- `Tests/AIGlassCoreTests/MenubarPillTests.swift` — 폭 헬퍼 테스트 (신규)

---

### Task 1: WavePill에 compact / paused 파라미터

**Files:**
- Modify: `Sources/AIGlass/UI/HUDView.swift:182-298` (WavePill)

- [ ] **Step 1: 프로퍼티 추가**

`struct WavePill` 프로퍼티 블록(`var waveStyle: WaveStyle = .pulseBars` 아래)에 추가:

```swift
    /// 메뉴바 등 좁은 컨테이너용 — 패딩 최소화, 빨강 글로우 생략. 기본 false(HUD 원형 유지).
    var compact: Bool = false
    /// true면 TimelineView 정지 (idle 시 에너지 절약 — 메뉴바는 상시 노출).
    var paused: Bool = false
```

- [ ] **Step 2: body 반영**

`TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in` 줄을 다음으로 교체:

```swift
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
```

body 끝부분의 패딩/그림자(`.padding(.horizontal, 13)`, `.padding(.vertical, 8)`, `.shadow(...)`)를 다음으로 교체:

```swift
            .padding(.horizontal, compact ? 4 : 13)
            .padding(.vertical, compact ? 0 : 8)
            .shadow(color: .red.opacity(!compact && critical ? 0.55 * glow + 0.2 : 0),
                    radius: compact ? 0 : glowRadius)
```

- [ ] **Step 3: 빌드 + 전체 테스트로 회귀 없음 확인**

Run: `swift build && swift test 2>&1 | tail -1`
Expected: 빌드 성공, `✔ Test run with 174 tests ... passed` (기존 HUD는 기본값 compact=false/paused=false로 동작 불변)

- [ ] **Step 4: Commit**

```bash
git add Sources/AIGlass/UI/HUDView.swift
git commit -m "feat: WavePill compact·paused 파라미터 (메뉴바 재사용 준비)"
```

### Task 2: MenubarPill.swift — 뷰 + 클릭 통과 + 폭 헬퍼 (TDD)

**Files:**
- Create: `Sources/AIGlass/UI/MenubarPill.swift`
- Test: `Tests/AIGlassCoreTests/MenubarPillTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/AIGlassCoreTests/MenubarPillTests.swift` 생성 (테스트 타깃은 이미 앱 모듈을 import 가능 — AllocateBarsTests 참조):

```swift
import Testing
@testable import AIGlass

@MainActor @Test func menubarPillWidthAddsTextAreaToWaveWidth() {
    // 점(6) + 간격 + "100%"(11pt bold mono) + 좌우 패딩 = 52pt 고정 텍스트 영역.
    #expect(MenubarPill.width(for: .pulseBars) == WaveStyle.pulseBars.areaWidth + 52)
    #expect(MenubarPill.width(for: .orbGlow) == WaveStyle.orbGlow.areaWidth + 52)
    // orbGlow(20)는 pulseBars(36)보다 좁다 — 스타일별 폭 차이가 반영되는지.
    #expect(MenubarPill.width(for: .orbGlow) < MenubarPill.width(for: .pulseBars))
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter menubarPillWidth 2>&1 | tail -3`
Expected: FAIL — `cannot find 'MenubarPill' in scope` 컴파일 에러

- [ ] **Step 3: 구현**

`Sources/AIGlass/UI/MenubarPill.swift` 생성:

```swift
import SwiftUI
import AppKit
import AIGlassCore

/// 메뉴바 미니 알약 (이슈 #1) — HUD WavePill의 compact 변형을 NSStatusItem에 띄운다.
enum MenubarPill {
    /// 상태 아이템 고정 폭: 웨이브 영역 + 텍스트 영역(점 6 + 간격 + "100%" + 좌우 패딩) 52pt.
    /// % 자릿수가 변해도 폭이 출렁이지 않도록 고정한다 (이웃 메뉴바 아이템 점프 방지).
    static func width(for style: WaveStyle) -> CGFloat {
        style.areaWidth + 52
    }
}

/// 메뉴바 상태 아이템에 들어가는 미니 웨이브 알약 뷰.
/// idle(활동 0)이면 TimelineView를 멈춰 상시 애니메이션 비용을 없앤다 —
/// store가 @Observable이라 다음 데이터 갱신 때 body가 재평가되며 자동 재개된다.
struct MenubarPillView: View {
    let store: UsageStore
    let settings: AppSettings

    private var paused: Bool {
        let now = Date()
        return store.activityLevel(now: now) == 0 && store.requestActivityLevel(now: now) == 0
    }

    var body: some View {
        WavePill(store: store,
                 enabled: settings.enabledServices,
                 warn: settings.warnThreshold,
                 crit: settings.critThreshold,
                 showsPercent: true,
                 showsCountdown: false, // 메뉴바 폭 절약 — 카운트다운은 호버카드/대시보드에서
                 waveStyle: settings.waveStyle,
                 compact: true,
                 paused: paused)
            .frame(width: MenubarPill.width(for: settings.waveStyle), height: 22, alignment: .leading)
    }
}

/// 클릭을 NSStatusBarButton으로 통과시키는 호스팅 뷰 — 메뉴바 클릭 → 대시보드 토글 유지.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
```

주의: `store.activityLevel(now:)`/`requestActivityLevel(now:)`는 UsageStore의 기존 공개 메서드 (HUD WavePill body에서 동일하게 사용 중). `settings.warnThreshold`/`critThreshold`도 기존 프로퍼티 (App.swift:229 사용 예).

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter menubarPillWidth 2>&1 | tail -3`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AIGlass/UI/MenubarPill.swift Tests/AIGlassCoreTests/MenubarPillTests.swift
git commit -m "feat: MenubarPillView — 메뉴바 미니 알약 뷰 + 클릭 통과 호스팅"
```

### Task 3: MenubarMode .wavePill 케이스 + 선택 UI

**Files:**
- Modify: `Sources/AIGlass/AppSettings.swift:7-26` (MenubarMode)
- Modify: `Sources/AIGlass/UI/OnboardingView.swift:182-188` (menubarPreviewText)
- Modify: `Sources/AIGlass/UI/SettingsView.swift` (waveStyle 변경 콜백)

- [ ] **Step 1: 케이스 추가**

`AppSettings.swift`의 `enum MenubarMode`에서 `case iconOnly` 아래에 추가:

```swift
    /// HUD 웨이브 알약 미니 버전 (이슈 #1).
    case wavePill
```

`label` switch에 추가:

```swift
        case .wavePill: return "미니 알약 (웨이브)"
```

- [ ] **Step 2: 온보딩 프리뷰 텍스트**

`OnboardingView.swift`의 `menubarPreviewText` switch에 추가 (텍스트 근사 — 온보딩에 라이브 렌더까지는 YAGNI):

```swift
        case .wavePill: return "✦ ≋ 63%"
```

- [ ] **Step 3: SettingsView — 웨이브 스타일 변경 시 메뉴바 폭 갱신**

`SettingsView.swift`에서 waveStyle Picker를 찾아 (HUD 탭, `$settings.waveStyle` 바인딩) `.onChange` 추가. 기존 menubarMode Picker의 패턴과 동일:

```swift
                .onChange(of: settings.waveStyle) { _, _ in onMenubarModeChange() }
```

(wavePill 모드일 때 스타일별 areaWidth가 달라 상태 아이템 length 재계산 필요 — Task 4의 updateStatusTitle이 처리. 다른 모드에선 updateStatusTitle이 텍스트만 다시 쓰므로 무해.)

- [ ] **Step 4: 빌드 — switch 누락 컴파일 에러가 없는지**

Run: `swift build 2>&1 | tail -3`
Expected: App.swift의 `updateStatusTitle` switch가 비망라(non-exhaustive)라며 **컴파일 실패** — Task 4에서 해소하므로 이 시점에서는 에러 메시지가 `switch must be exhaustive`인 것만 확인.

- [ ] **Step 5: Commit은 Task 4와 묶는다** (빌드가 깨진 상태로 커밋하지 않음)

### Task 4: AppDelegate 설치/제거 배선

**Files:**
- Modify: `Sources/AIGlass/App.swift:205-249` (updateStatusTitle 주변)

- [ ] **Step 1: 호스팅 뷰 프로퍼티 추가**

`private var lastMenubarKey: String?` (App.swift:206) 아래에 추가:

```swift
    /// 메뉴바 미니 알약 호스팅 뷰 — wavePill 모드에서만 non-nil.
    private var menubarPillHost: NSView?
```

- [ ] **Step 2: updateStatusTitle에 분기 추가**

`updateStatusTitle()` 함수 본문 맨 앞 (`guard let button = statusItem?.button else { return }` 직후)에 추가:

```swift
        if settings.menubarMode == .wavePill {
            installMenubarPillIfNeeded(on: button)
            // 웨이브 스타일 변경으로 폭이 달라졌으면 갱신 (동일 값 set 생략 — 깜빡임 방지).
            let width = MenubarPill.width(for: settings.waveStyle) + 4
            if statusItem?.length != width { statusItem?.length = width }
            return
        }
        removeMenubarPillIfNeeded()
```

기존 `switch settings.menubarMode` 에 `.wavePill` 케이스는 위 early-return으로 도달 불가지만 망라성을 위해 추가:

```swift
        case .wavePill:
            break // 위 early-return에서 처리됨
```

- [ ] **Step 3: 설치/제거 메서드 추가**

`updateStatusTitle()` 아래 `setPlainTitle` 앞에 추가:

```swift
    /// wavePill 모드 진입 — 상태 버튼 위에 클릭-통과 호스팅 뷰를 얹는다 (멱등).
    private func installMenubarPillIfNeeded(on button: NSStatusBarButton) {
        guard menubarPillHost == nil else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "") // iconOnly 잔존 색 제거
        lastMenubarKey = "pill"
        let host = ClickThroughHostingView(
            rootView: MenubarPillView(store: store, settings: settings))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        ])
        menubarPillHost = host
    }

    /// wavePill 외 모드 — 호스팅 뷰 제거 + 가변 폭 복원 (멱등).
    private func removeMenubarPillIfNeeded() {
        guard let host = menubarPillHost else { return }
        host.removeFromSuperview()
        menubarPillHost = nil
        statusItem?.length = NSStatusItem.variableLength
        lastMenubarKey = nil // 텍스트 모드 타이틀 강제 재설정
    }
```

- [ ] **Step 4: 빌드 + 전체 테스트**

Run: `swift build && swift test 2>&1 | tail -1`
Expected: 빌드 성공, 175개 테스트 통과 (Task 2의 +1)

- [ ] **Step 5: Commit**

```bash
git add Sources/AIGlass/AppSettings.swift Sources/AIGlass/UI/OnboardingView.swift Sources/AIGlass/UI/SettingsView.swift Sources/AIGlass/App.swift
git commit -m "feat: 메뉴바 미니 알약 모드 (이슈 #1) — 설치/제거 배선 + 선택 UI"
```

### Task 5: 알림 전용 HUD — HUD 꺼짐 상태에서 이벤트 카드 플래시

**배경:** 현재 `HUDPanelController.setVisible(false)`(HUDPanel.swift:75)면 패널이 완전히 숨어 이벤트 카드(`HUDState.show` → EventCard 모핑)도 안 보인다. 메뉴바 알약으로 갈아탄 사용자는 HUD를 끄게 되는데, 그러면 한도 경고·세션 요약 카드를 잃는다. HUD가 꺼져 있어도 이벤트 동안만 패널을 띄워 카드를 보여준다.

**Files:**
- Modify: `Sources/AIGlass/UI/HUDView.swift:155-179` (body 분기)
- Modify: `Sources/AIGlass/App.swift:276-279` (showHUD) + onReplay 배선(App.swift:111)

- [ ] **Step 1: HUDView — HUD 꺼짐 시 알약/호버카드 미표시**

`HUDView.body`의 ZStack 분기를 다음으로 교체 (이벤트 카드는 항상, 알약·호버카드는 hudVisible일 때만 — 카드가 사라지는 0.5초 동안 알약이 비치는 것 방지):

```swift
        ZStack(alignment: .topTrailing) {
            if let event = state.currentEvent {
                EventCard(event: event, warn: settings.warnThreshold, crit: settings.critThreshold)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { tapped() }
            } else if !settings.hudVisible {
                // 알림 전용 모드 — 카드 dismiss 후 패널이 숨겨질 때까지 빈 상태 유지.
                Color.clear.frame(width: 1, height: 1)
            } else if state.showsHoverCard {
                HoverCard(store: store, enabled: enabled,
                          warn: settings.warnThreshold, crit: settings.critThreshold, onTap: tapped)
            } else {
                WavePill(store: store, enabled: enabled,
                         warn: settings.warnThreshold, crit: settings.critThreshold,
                         showsPercent: settings.hudShowsPercent,
                         showsCountdown: settings.hudShowsCountdown,
                         waveStyle: settings.waveStyle)
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { tapped() }
            }
        }
```

`.glassEffect`는 그대로 둔다 (1×1 투명 콘텐츠에는 사실상 보이지 않음 — 실기기 검증에서 잔상 확인, 거슬리면 `state.currentEvent != nil || settings.hudVisible` 조건부로 변경).

- [ ] **Step 2: AppDelegate — flashHUD 헬퍼 + showHUD/onReplay 경유**

`App.swift`의 `showHUD`를 다음으로 교체:

```swift
    /// HUD 알림 표시 + 기록(EventLog) 적재. 호버 리플레이는 이 경로를 쓰지 않는다(기록 금지).
    func showHUD(_ event: HUDEvent, duration: TimeInterval = 6) {
        flashHUD(event, duration: duration)
        eventLog.append(event)
    }

    /// HUD가 숨김 상태여도 이벤트 카드가 HUD 위치에 잠깐 떠오르게 한다 (기록 없음 — 리플레이 공용).
    func flashHUD(_ event: HUDEvent, duration: TimeInterval = 6) {
        hudState.show(event, duration: duration)
        guard !settings.hudVisible else { return }
        hudController?.setVisible(true)
        // 카드 dismiss 애니메이션(0.45s) 여유를 두고 숨김. 그 사이 새 이벤트가 오면 유지
        // (그 이벤트의 flashHUD가 자기 타이머로 다시 숨김).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.6) { [weak self] in
            guard let self, !self.settings.hudVisible,
                  self.hudState.currentEvent == nil else { return }
            self.hudController?.setVisible(false)
        }
    }
```

`applicationDidFinishLaunching`의 dashboardPanel 생성부(App.swift:111) `onReplay`를 flashHUD 경유로 교체:

```swift
            onReplay: { [weak self] event in self?.flashHUD(event, duration: 2.5) })
```

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `swift build && swift test 2>&1 | tail -1`
Expected: 빌드 성공, 175개 테스트 통과 (UI 동작은 Task 6에서 실기기 검증)

- [ ] **Step 4: Commit**

```bash
git add Sources/AIGlass/UI/HUDView.swift Sources/AIGlass/App.swift
git commit -m "feat: 알림 전용 HUD — HUD 꺼짐 상태에서도 이벤트 카드 플래시"
```

### Task 6: 실기기 검증 (스크린샷)

**Files:** 없음 (수동 검증 — 이 프로젝트의 UI 검증 관례)

- [ ] **Step 1: 번들 빌드 + 교체 실행**

```bash
bash Scripts/make-app.sh && pkill -f "AIGlass.app/Contents/MacOS"; sleep 1
rm -rf /Applications/AIGlass.app && cp -R build/AIGlass.app /Applications/ && open /Applications/AIGlass.app
```

- [ ] **Step 2: 검증 체크리스트** (각각 `screencapture -x`로 캡처해 확인)

1. 설정 → 표시 → 표시 모드 "미니 알약 (웨이브)" 선택 → 메뉴바에 웨이브+점+% 등장, 텍스트 모드 잔재 없음
2. 메뉴바 알약 클릭 → 대시보드 토글 (클릭 통과 동작)
3. 웨이브 스타일을 오브 글로우로 변경 → 메뉴바 폭이 좁아짐 (areaWidth 20 반영)
4. 다른 모드(오늘 누적 토큰)로 전환 → 알약 제거 + "✦ 612M" 텍스트 복귀
5. Claude Code로 토큰을 굴리면서 → 웨이브가 움직이는지 / 몇 분 방치 후(idle) 정지하는지
6. 라이트 모드 데스크톱에서 % 텍스트 가독성
7. HUD 알약을 끄고(설정) 메뉴바 알약만 쓰는 조합 — 이슈 #1의 핵심 시나리오
8. **HUD 꺼진 상태에서 알림 플래시**: 대시보드 기록 탭의 항목 hover(리플레이) → HUD 위치에 카드가 떠올랐다 사라지는지, 사라진 뒤 알약이 잔상으로 남지 않는지
9. HUD 꺼짐 + 실제 이벤트(한도 임계 등) 발생 시에도 8과 동일하게 동작하는지 (임계값을 일시적으로 낮춰 유발 가능)

- [ ] **Step 3: 발견된 폭/정렬 미세 조정**

52pt 텍스트 영역이 실기기에서 좁거나 넓으면 `MenubarPill.width(for:)` 상수와 테스트를 함께 조정 후 재검증.

- [ ] **Step 4: README 갱신 + Commit**

README.md 기능 목록의 메뉴바 항목에 미니 알약 모드 언급 추가:

```markdown
- **플로팅 HUD**: ... 드래그 이동, ⌘⇧E 고정 확장 — 또는 **메뉴바 미니 알약** 모드로 메뉴바 안에서 웨이브 표시
```

```bash
git add README.md
git commit -m "docs: 메뉴바 미니 알약 모드 README 반영"
```

### Task 7: 릴리스 + 이슈 답글

- [ ] **Step 1: 버전 범프 + 태그**

```bash
sed -i '' 's|<string>0\.11\.0</string>|<string>0.12.0</string>|g' Scripts/make-app.sh
git add Scripts/make-app.sh && git commit -m "chore: 버전 0.12.0"
git push origin main && git tag v0.12.0 && git push origin v0.12.0
```

GitHub Actions Release 워크플로 성공 확인:

```bash
gh run list --repo taeng0204/ai-glass --workflow Release --limit 1
```

- [ ] **Step 2: 이슈 #1 답글 + 클로즈** (게시 전 사용자에게 초안 확인)

```bash
gh issue comment 1 --repo taeng0204/ai-glass --body "Shipped in v0.12.0! 🎉

Settings → Display → menu bar mode now has a **Mini pill (wave)** option that renders the HUD wave pill right in the menu bar — wave animation, active-agent dot, and usage %. Clicking it still toggles the dashboard.

You can now hide the floating HUD entirely and keep the pill in the menu bar — limit warnings and session summaries will still pop up briefly at the HUD position when something happens.

Update via the in-app update badge or: \`curl -fsSL https://raw.githubusercontent.com/taeng0204/ai-glass/main/install.sh | bash\`"
gh issue close 1 --repo taeng0204/ai-glass
```

**사전 정리**: 이슈에 달린 "TL; DR" 자기 댓글은 게시 전 삭제 권장 — `gh api -X DELETE repos/taeng0204/ai-glass/issues/comments/<id>` (id는 `gh api repos/taeng0204/ai-glass/issues/1/comments --jq '.[].id'`).

---

## 검증 요약
- 자동: 기존 174 + 폭 헬퍼 1 = 175 테스트.
- 수동: Task 6 체크리스트 9항목 (클릭 통과·idle 정지·라이트 모드·알림 플래시 포함).
- 리스크 1: NSStatusItem 위 NSHostingView는 비표준 조합 — 클릭/레이아웃이 macOS 버전에 따라 어긋날 수 있어 Task 6을 통과 못 하면 폭 고정 + `button.image` 기반 오프스크린 렌더(30fps CADisplayLink 없이 1fps 스냅샷)로 폴백한다.
- 리스크 2: 알림 플래시의 setVisible(false) 타이밍 — 연속 이벤트 시 먼저 잡힌 타이머가 패널을 숨기지 않도록 `currentEvent == nil` 가드를 둠 (Task 5 Step 2). 드물게 깜빡이면 dismiss 시점에 HUDState가 콜백을 주는 방식으로 변경.
