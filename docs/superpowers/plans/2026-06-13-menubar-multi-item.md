# 메뉴바 다중 항목 표시 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 메뉴바 표시를 단일 모드(배타 enum)에서 다중 항목(웨이브·토큰·속도·%) 동시 표시로 전환한다.

**Architecture:** `MenubarItem` enum + `AppSettings.menubarItems: Set` 도입(기존 `menubarMode`에서 1회 마이그레이션). NSStatusItem을 항상 호스팅뷰(`MenubarContentView`) 단일 경로로 렌더 — 켜진 항목을 고정 순서로 한 줄 조합, 빈 선택 시 ✦. 설정·온보딩 UI를 다중 토글로.

**Tech Stack:** Swift 6, SwiftUI, AppKit. 스펙: `docs/superpowers/specs/2026-06-13-menubar-multi-item-design.md`.

---

### Task 1: MenubarItem 모델 + 마이그레이션 (AppSettings, TDD)

**Files:**
- Modify: `Sources/AIGlass/AppSettings.swift`
- Test: `Tests/AIGlassCoreTests/MenubarItemTests.swift`

- [ ] **Step 1: 실패 테스트 작성**

`Tests/AIGlassCoreTests/MenubarItemTests.swift` 생성:

```swift
import Testing
@testable import AIGlass

@MainActor @Test func menubarMigrationMapsEachMode() {
    #expect(AppSettings.migratedItems(from: .todayTokens) == [.todayTokens])
    #expect(AppSettings.migratedItems(from: .burnRate) == [.burnRate])
    #expect(AppSettings.migratedItems(from: .maxPercent) == [.maxPercent])
    #expect(AppSettings.migratedItems(from: .wavePill) == [.wave])
    #expect(AppSettings.migratedItems(from: .iconOnly) == [])  // 빈 집합 = ✦ fallback
}

@MainActor @Test func menubarItemsOrderedFollowsCanonicalOrder() {
    // 입력 순서 무관, allCases 고정 순(wave→todayTokens→burnRate→maxPercent)으로 정렬.
    let set: Set<MenubarItem> = [.maxPercent, .wave, .todayTokens]
    #expect(MenubarItem.ordered(set) == [.wave, .todayTokens, .maxPercent])
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter menubar 2>&1 | tail -5`
Expected: 컴파일 실패 — `MenubarItem` 미정의.

- [ ] **Step 3: MenubarItem enum 추가**

`AppSettings.swift`에서 `enum MenubarMode` 정의 **아래**에 추가:

```swift
/// 메뉴바에 동시 표시할 수 있는 항목 (다중 선택). 고정 순서로 렌더된다.
enum MenubarItem: String, CaseIterable, Identifiable {
    case wave         // 미니 웨이브 알약
    case todayTokens  // 오늘 누적 토큰 "612M"
    case burnRate     // 소모 속도 "38K/m"
    case maxPercent   // 최고 사용률 "49%"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .wave: return "웨이브 알약"
        case .todayTokens: return "오늘 누적 토큰"
        case .burnRate: return "소모 속도 (t/min)"
        case .maxPercent: return "최고 사용률 %"
        }
    }

    /// 주어진 집합을 allCases 고정 순으로 정렬한 배열 (렌더 순서).
    static func ordered(_ items: Set<MenubarItem>) -> [MenubarItem] {
        allCases.filter { items.contains($0) }
    }
}
```

- [ ] **Step 4: AppSettings에 menubarItems + 마이그레이션**

`AppSettings.swift`의 `Key` enum에 추가 (다른 static let 옆):

```swift
        static let menubarItems = "aiglass.menubarItems"
```

프로퍼티 추가 (`menubarMode` 프로퍼티 아래):

```swift
    /// 메뉴바에 동시 표시할 항목 집합 (다중). 빈 집합이면 ✦ 아이콘만. 기본 [.todayTokens].
    var menubarItems: Set<MenubarItem> {
        didSet { defaults.set(menubarItems.map(\.rawValue).sorted(), forKey: Key.menubarItems) }
    }
```

마이그레이션 순수 함수 추가 (AppSettings 내, init 위나 아래):

```swift
    /// 구 단일 모드 → 신 항목 집합 1:1 변환.
    static func migratedItems(from mode: MenubarMode) -> Set<MenubarItem> {
        switch mode {
        case .todayTokens: return [.todayTokens]
        case .burnRate:    return [.burnRate]
        case .maxPercent:  return [.maxPercent]
        case .iconOnly:    return []        // 빈 집합 = ✦ fallback
        case .wavePill:    return [.wave]
        }
    }
```

`init()` 끝부분(`enabledServices = ...` 아래)에 마이그레이션 로직 추가:

```swift
        // 메뉴바 항목: 신 포맷 키가 있으면 그대로, 없으면 구 menubarMode에서 1회 마이그레이션.
        if let rawItems = defaults.stringArray(forKey: Key.menubarItems) {
            menubarItems = Set(rawItems.compactMap(MenubarItem.init(rawValue:)))
        } else {
            menubarItems = Self.migratedItems(from: menubarMode)
        }
```

(주의: `menubarMode`는 이 시점에 이미 init에서 로드됨 — line 163. 그 아래에 배치.)

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter menubar 2>&1 | tail -5`
Expected: PASS. 이어서 `swift test 2>&1 | tail -1` — 177개(175+2) 통과.

- [ ] **Step 6: Commit**

```bash
git add Sources/AIGlass/AppSettings.swift Tests/AIGlassCoreTests/MenubarItemTests.swift
git commit -m "feat: MenubarItem 모델 + menubarItems 집합 + 단일모드 마이그레이션"
```

(Co-Authored-By 푸터 금지.)

### Task 2: MenubarContentView — 다중 항목 렌더 뷰

**Files:**
- Modify: `Sources/AIGlass/UI/MenubarPill.swift`

- [ ] **Step 1: MenubarContentView 추가**

`MenubarPill.swift`의 `MenubarPillView` 아래에 추가. 토큰/속도 포맷은 AppDelegate의 static 헬퍼와 중복을 피해 여기 로컬 헬퍼로(App.swift의 `formatTokens`/`formatRate`는 private이므로 동일 로직 복제 — 작은 함수라 허용, 스펙의 "기존 포맷 재사용" 의도는 동일 출력):

```swift
/// 메뉴바 상태 아이템 콘텐츠 — 켜진 항목(MenubarItem)을 고정 순서로 한 줄에 조합한다.
/// store·settings를 @Observable로 관찰해 토큰/속도/% 값과 항목 집합 변화에 자동 반응.
struct MenubarContentView: View {
    let store: UsageStore
    let settings: AppSettings

    private var maxPercent: Double { store.maxUsedPercent(in: settings.enabledServices) }

    var body: some View {
        let items = MenubarItem.ordered(settings.menubarItems)
        HStack(spacing: 6) {
            if items.isEmpty {
                Text("✦")
                    .foregroundStyle(Theme.statusColor(percent: maxPercent,
                                                        warn: settings.warnThreshold,
                                                        crit: settings.critThreshold))
            } else {
                ForEach(Array(items.enumerated()), id: \.element) { idx, item in
                    if idx > 0 && item != .wave && items[idx - 1] != .wave {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    itemView(item)
                }
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .fixedSize()
    }

    @ViewBuilder
    private func itemView(_ item: MenubarItem) -> some View {
        switch item {
        case .wave:
            WavePill(store: store, enabled: settings.enabledServices,
                     warn: settings.warnThreshold, crit: settings.critThreshold,
                     showsPercent: false, showsCountdown: false,
                     waveStyle: settings.waveStyle, compact: true,
                     paused: store.activityLevel(now: Date()) == 0
                          && store.requestActivityLevel(now: Date()) == 0)
                .frame(height: 22)
        case .todayTokens:
            Text("✦ \(Self.formatTokens(store.todayTokens(now: Date())))")
                .foregroundStyle(.primary)
        case .burnRate:
            Text(Self.formatRate(store.tokensPerMinute(windowMinutes: 5, now: Date())))
                .foregroundStyle(.primary)
        case .maxPercent:
            Text(Theme.formatUsagePercent(maxPercent))
                .foregroundStyle(Theme.statusColor(percent: maxPercent,
                                                   warn: settings.warnThreshold,
                                                   crit: settings.critThreshold))
        }
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.0fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func formatRate(_ perMinute: Double) -> String {
        let n = Int(perMinute.rounded())
        switch n {
        case 1_000_000...: return String(format: "%.1fM/m", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK/m", Double(n) / 1_000)
        default: return "\(n)/m"
        }
    }
}
```

주의: `·` 구분은 인접 항목이 둘 다 텍스트일 때만(웨이브 앞뒤엔 안 붙임 — 웨이브 자체가 시각 구분). `todayTokens`의 `✦` 접두는 기존 단일 모드 외형 유지(아이콘+값). 단 토큰이 첫 항목이 아니고 웨이브가 앞이면 `✦`가 중복돼 보일 수 있으나, 웨이브+토큰 조합 시 `∿ ✦612M`은 허용 가능(아이콘이 토큰 라벨 역할). 실기기 확인 후 거슬리면 토큰의 `✦`를 첫 항목일 때만 붙이도록 조정.

- [ ] **Step 2: 빌드**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/AIGlass/UI/MenubarPill.swift
git commit -m "feat: MenubarContentView — 다중 항목 한 줄 조합 렌더"
```

### Task 3: AppDelegate — 단일 호스팅뷰 경로로 교체

**Files:**
- Modify: `Sources/AIGlass/App.swift`

- [ ] **Step 1: updateStatusTitle + 설치 헬퍼 교체**

기존 `updateStatusTitle()`(switch menubarMode 분기), `installMenubarPillIfNeeded`, `removeMenubarPillIfNeeded`, `setPlainTitle`, `statusNSColor`를 찾아 **다음으로 교체**(기존 5개 메서드 삭제 후 아래 2개로):

```swift
    /// 메뉴바 호스팅뷰 — 항목 집합/값 변화는 SwiftUI @Observable로 자동 반영.
    private var menubarHost: NSView?

    /// 상태 아이템에 다중 항목 콘텐츠 호스팅뷰를 1회 설치하고 폭을 콘텐츠에 맞춘다.
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if menubarHost == nil {
            button.title = ""
            let host = ClickThroughHostingView(
                rootView: MenubarContentView(store: store, settings: settings))
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: button.topAnchor),
                host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            ])
            menubarHost = host
        }
        statusItem?.length = NSStatusItem.variableLength
    }
```

`lastMenubarKey` 프로퍼티 선언도 제거(더 이상 안 씀). `static func formatTokens`/`formatRate`가 App.swift에서 더 이상 안 쓰이면(다른 호출처 확인) 남겨둬도 무방하나, 미사용 경고 시 제거.

- [ ] **Step 2: 빌드 — 미사용/누락 확인**

Run: `swift build 2>&1 | tail -8`
Expected: Build complete. 만약 `formatTokens`/`formatRate`/`statusNSColor` 미사용 경고나 다른 곳에서 `setPlainTitle` 호출 에러가 나면 해당 호출부 정리. (예상 호출부: `updateStatusTitle`만 — 교체로 해소.)

- [ ] **Step 3: 전체 테스트**

Run: `swift test 2>&1 | tail -1`
Expected: 177개 통과.

- [ ] **Step 4: Commit**

```bash
git add Sources/AIGlass/App.swift
git commit -m "refactor: 메뉴바를 단일 호스팅뷰 경로로 — 다중 항목 콘텐츠뷰 설치"
```

### Task 4: SettingsView — 다중 토글

**Files:**
- Modify: `Sources/AIGlass/UI/SettingsView.swift`

- [ ] **Step 1: 메뉴바 섹션 교체**

`displayTab`의 `Section("메뉴바") { ... }`(Picker 블록)을 교체:

```swift
            Section("메뉴바") {
                ForEach(MenubarItem.allCases) { item in
                    Toggle(item.label, isOn: menubarItemBinding(for: item))
                }
                Text("켤 항목을 고르세요 — 모두 끄면 ✦ 아이콘만 표시됩니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: settings.menubarItems) { _, _ in onMenubarModeChange() }
```

`enabledBinding(for:)` 헬퍼 아래에 추가:

```swift
    /// 메뉴바 항목 토글 바인딩 — 켜고 끔 자유(빈 집합 허용 = ✦ 아이콘).
    private func menubarItemBinding(for item: MenubarItem) -> Binding<Bool> {
        Binding(
            get: { settings.menubarItems.contains(item) },
            set: { on in
                if on { settings.menubarItems.insert(item) }
                else { settings.menubarItems.remove(item) }
            })
    }
```

- [ ] **Step 2: 빌드 + 커밋**

Run: `swift build 2>&1 | tail -1` → Build complete.

```bash
git add Sources/AIGlass/UI/SettingsView.swift
git commit -m "feat: 설정 메뉴바 섹션을 다중 항목 토글로"
```

### Task 5: OnboardingView — 메뉴바 다중 토글 + 적응형 카피

**Files:**
- Modify: `Sources/AIGlass/UI/OnboardingView.swift`

- [ ] **Step 1: menubarStep + menubarRow를 다중 토글로**

`menubarStep`의 `ForEach(MenubarMode.allCases) { menubarRow($0) }`을 항목 다중 선택으로 교체. 기존 `menubarRow(_ mode: MenubarMode)`와 `menubarPreviewText`를 삭제하고 다음으로 대체:

```swift
    private var menubarStep: some View {
        VStack(spacing: 16) {
            stepHeader("메뉴바 표시", "메뉴바에 표시할 항목을 고르세요. 여러 개 켤 수 있어요.")
            VStack(spacing: 10) {
                ForEach(MenubarItem.allCases) { item in
                    menubarItemRow(item)
                }
            }
            Spacer()
        }
    }

    private func menubarItemRow(_ item: MenubarItem) -> some View {
        let selected = settings.menubarItems.contains(item)
        return Button {
            if selected { settings.menubarItems.remove(item) }
            else { settings.menubarItems.insert(item) }
            onMenubarRefresh()
        } label: {
            HStack(spacing: 14) {
                Group {
                    if item == .wave {
                        WaveStylePreview(style: settings.waveStyle, chrome: false).fixedSize()
                    } else {
                        Text(menubarItemPreview(item))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 108, alignment: .leading)
                Text(item.label).font(.body).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func menubarItemPreview(_ item: MenubarItem) -> String {
        switch item {
        case .wave: return ""
        case .todayTokens: return "✦ 612M"
        case .burnRate: return "✦ 38K/m"
        case .maxPercent: return "✦ 49%"
        }
    }
```

- [ ] **Step 2: 웨이브 단계 적응형 카피의 wavePill 판정 갱신**

`waveStyleSubtitle`에서 `settings.menubarMode == .wavePill`을 `settings.menubarItems.contains(.wave)`로 교체:

```swift
    private var waveStyleSubtitle: String {
        if track == .menubar {
            return settings.menubarItems.contains(.wave)
                ? "메뉴바 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
                : "웨이브 스타일은 이렇게 다양해요 — 기본(펄스 바)으로 둬도 되고, 마음에 드는 걸 골라보세요."
        }
        return "HUD 알약의 움직임을 고르세요. 탭하면 바로 적용됩니다."
    }
```

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `swift build && swift test 2>&1 | tail -1`
Expected: Build complete, 177개 통과.

- [ ] **Step 4: Commit**

```bash
git add Sources/AIGlass/UI/OnboardingView.swift
git commit -m "feat: 온보딩 메뉴바 단계를 다중 항목 토글로 + 웨이브 판정 갱신"
```

### Task 6: 빌드 + 수동 검증 + 마무리

- [ ] **Step 1: 번들 빌드 + 실행**

```bash
bash Scripts/make-app.sh
pkill -9 -f "AIGlass.app/Contents/MacOS"; sleep 1
defaults write io.taeng.aiglass aiglass.onboardingCompleted -bool true
open build/AIGlass.app
```

- [ ] **Step 2: 검증 체크리스트** (설정 → 표시 → 메뉴바 토글 조합, 메뉴바 캡처)

1. 토큰만 → `✦ 612M`
2. 토큰+% → `✦ 612M · 49%`
3. 웨이브+토큰+% → `∿ ✦612M · 49%` (웨이브 앞, · 구분, 폭 자동)
4. 속도 추가 → `38K/m` 포함
5. 모두 끄기 → `✦` 아이콘만(위험도 색)
6. 웨이브 항목 idle 시 8fps 유지(CPU 최적화 반영), 활동 시 30fps
7. 토글 변경 즉시 메뉴바 반영(폭 포함)
8. 기존 사용자 마이그레이션: `defaults write ...menubarMode wavePill` 후 `menubarItems` 키 삭제 → 재실행 시 웨이브 항목으로 변환
9. 온보딩(메뉴바 트랙) 다중 토글 동작 + 웨이브 포함 시 웨이브 단계 카피

- [ ] **Step 3: `·` 구분/`✦` 중복 미세 조정** (검증에서 거슬리면)

웨이브+토큰 조합 시 토큰의 `✦` 접두가 중복돼 보이면, `itemView`의 todayTokens에서 `✦`를 첫 항목일 때만 붙이도록 조정(MenubarContentView body에서 index 전달). 거슬리지 않으면 그대로.

- [ ] **Step 4: README 갱신 + Commit**

README 기능 목록의 메뉴바 설명을 다중 항목으로 갱신:

```markdown
- **메뉴바**: 웨이브 알약·오늘 토큰·소모 속도·최고 사용률%를 원하는 만큼 골라 한 줄에 표시 (모두 끄면 ✦ 아이콘만)
```

```bash
git add README.md
git commit -m "docs: 메뉴바 다중 항목 표시 README 반영"
```

## 검증 요약
- 자동: 기존 175 + 마이그레이션/순서 2 = 177 테스트.
- 수동: Task 6 체크리스트 9항목 (조합 표시·빈 선택·마이그레이션·idle fps·온보딩).
- 리스크: 호스팅뷰 통일로 기존 텍스트 모드(button.title) 깜빡임 방지 로직 제거 — SwiftUI @Observable 재렌더가 깜빡임 없이 동작하는지 Task 6 step 7에서 확인. 문제 시 호스팅뷰 rootView를 값 변경 시에만 교체하는 방식 검토.
