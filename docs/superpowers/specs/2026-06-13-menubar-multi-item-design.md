# 메뉴바 다중 항목 표시 — Design Spec

**작성일:** 2026-06-13
**관련:** 메뉴바 미니 알약(이슈 #1) 후속 — 사용자 의견 "토큰·속도 등을 병렬로 다 보이게"

## 배경 / 문제

현재 메뉴바는 `MenubarMode`(배타 enum) 중 **하나만** 고정 표시한다: 오늘 토큰 / 소모 속도 / 최고% / 아이콘 / 미니 알약. 사용자는 여러 정보(토큰·속도·% + 웨이브)를 **동시에** 메뉴바에서 보고 싶어 한다. HUD에 표시 항목 옵션(사용률%·카운트다운)이 있듯 메뉴바도 표시 항목을 자유 조합하게 한다.

## 목표

- 메뉴바 표시를 **단일 모드 → 다중 항목 선택**으로 전환.
- 항목: 웨이브 알약 / 오늘 토큰 / 소모 속도 / 최고 사용률%.
- 켜진 항목을 고정 순서로 한 줄에 조합 표시. 빈 선택 시 `✦` 아이콘만.
- 기존 사용자의 단일 모드 설정을 보존(마이그레이션).

## 비목표 (YAGNI)

- 에이전트별 % 병렬 표시(C63·X6·A100)는 범위 밖.
- 항목 순서 사용자 커스터마이즈는 범위 밖(고정 순서).
- 구분자·폰트 등 스타일 커스터마이즈 없음.

## 아키텍처

### 데이터 모델 (AppSettings.swift)

`enum MenubarMode`(배타)를 유지하되 **표시 항목 집합**을 새로 도입한다. 기존 `MenubarMode`는 마이그레이션 소스로만 쓰고, 런타임 상태는 `Set<MenubarItem>`.

```swift
/// 메뉴바에 동시 표시할 수 있는 항목 (다중 선택). 고정 순서로 렌더된다.
enum MenubarItem: String, CaseIterable, Identifiable {
    case wave        // 미니 웨이브 알약
    case todayTokens // 오늘 누적 토큰 "612M"
    case burnRate    // 소모 속도 "38K/m"
    case maxPercent  // 최고 사용률 "49%"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .wave: return "웨이브 알약"
        case .todayTokens: return "오늘 누적 토큰"
        case .burnRate: return "소모 속도 (t/min)"
        case .maxPercent: return "최고 사용률 %"
        }
    }
    /// 렌더 순서 인덱스 (웨이브 → 토큰 → 속도 → %).
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
```

AppSettings에 `menubarItems: Set<MenubarItem>` 프로퍼티 추가. UserDefaults에 rawValue 배열로 저장(`enabledServices` 패턴 재사용). 기본값: `[.todayTokens]`.

**마이그레이션**: 앱 첫 로드 시, `menubarItems` 키가 없고 기존 `menubarMode` 키가 있으면 1:1 변환 후 저장:
- todayTokens → `[.todayTokens]`
- burnRate → `[.burnRate]`
- maxPercent → `[.maxPercent]`
- wavePill → `[.wave]`
- iconOnly → `[]` (빈 집합 = ✦ 아이콘 fallback)

`menubarMode`는 변환 후에도 남겨두되 더 이상 읽지 않는다(롤백 안전). 마이그레이션은 AppSettings init에서 1회.

### 렌더링 (App.swift + 신규 MenubarContentView)

`NSStatusItem.button` 위에 **항상 클릭-통과 호스팅뷰**(`ClickThroughHostingView`, 기존)로 `MenubarContentView`를 띄운다. 텍스트만이든 웨이브 포함이든 단일 경로.

```swift
/// 메뉴바 상태 아이템 콘텐츠 — 켜진 항목을 고정 순서로 한 줄에 조합.
struct MenubarContentView: View {
    let store: UsageStore
    let settings: AppSettings
    /// refresh마다 +1 — 텍스트 값(토큰/속도/%) 재계산 트리거.
    let refreshTick: Int

    var body: some View {
        let items = MenubarItem.allCases.filter { settings.menubarItems.contains($0) }
        HStack(spacing: 6) {
            if items.isEmpty {
                Text("✦").foregroundStyle(iconColor) // 빈 선택 fallback
            } else {
                ForEach(items) { item in
                    itemView(item)
                }
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
    }
    // wave → WavePill(compact, paused: idle), 나머지 → Text(값) + 앞에 " · " 구분(첫 항목 제외)
}
```

- **웨이브 항목**: `WavePill(compact: true, paused: idleNow, ...)` (idle 8fps 최적화 그대로). showsPercent/countdown은 false(메뉴바엔 별도 % 항목이 담당).
- **텍스트 항목**: 값 문자열(기존 `formatTokens`/`formatRate`/`formatUsagePercent` 재사용). 항목 사이 `·` 구분.
- **값 갱신**: 텍스트는 `refreshTick`(refresh마다 증가하는 Int)에 의존해 재계산. store는 @Observable이지만 토큰/속도/%는 events·limits 변경 시 갱신되며, 명시적 tick으로 30초 주기 갱신 보장.
- **폭**: `statusItem.length = NSStatusItem.variableLength` (콘텐츠 자동). 웨이브 폭 고정 이슈 없음 — 호스팅뷰 intrinsic size.

### AppDelegate 변경 (App.swift)

기존 `updateStatusTitle()`의 분기(switch menubarMode + installMenubarPillIfNeeded/removeMenubarPillIfNeeded + setPlainTitle)를 **단일 경로로 교체**:

```swift
func updateStatusTitle() {
    guard let button = statusItem?.button else { return }
    installMenubarContentIfNeeded(on: button) // 호스팅뷰 1회 설치
    menubarRefreshTick += 1                    // 텍스트 값 갱신 트리거
    statusItem?.length = NSStatusItem.variableLength
}
```

- `installMenubarContentIfNeeded`: 호스팅뷰가 없으면 `ClickThroughHostingView(MenubarContentView(...))` 설치(엣지 고정 제약). menubarRefreshTick은 @State 대신 호스팅뷰 rootView 교체로 전달하거나, MenubarContentView가 settings·store를 @Observable로 관찰하므로 tick 없이도 갱신될 수 있음 — **구현 시 tick 불필요하면 생략**(토큰/속도는 events 변경 시 자동 갱신; 30초 정확성이 굳이 필요 없으면 @Observable만으로 충분).
- 기존 `installMenubarPillIfNeeded`/`removeMenubarPillIfNeeded`/`setPlainTitle`/`statusNSColor`/`lastMenubarKey`는 제거 또는 새 경로로 통합.
- `✦` 아이콘 색(위험도)은 MenubarContentView 내부에서 `store.maxUsedPercent` 기반 계산.

### 설정 UI (SettingsView.swift)

"메뉴바" 섹션의 Picker(단일) → **4개 Toggle**(다중):

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

웨이브 스타일 Picker의 `.onChange`(메뉴바 갱신)도 유지.

### 온보딩 (OnboardingView.swift)

기존 메뉴바 단계(`menubarStep`)는 `MenubarMode` 단일 선택이었다. 다중 항목으로 바꾸되, 온보딩에선 **간결성 위해 단일 대표 선택 유지 OR 다중 토글**:
- 메뉴바 트랙: 다중 토글로 변경(설정과 동일 컴포넌트 재사용 가능).
- 마이그레이션 매핑과 일관되게, 온보딩에서 고른 항목이 `menubarItems`에 반영.

*구현 시 온보딩 menubarStep을 다중 토글로 교체. 트랙 분기(투트랙)·웨이브 단계 적응형 카피는 유지(menubarItems에 .wave 포함 여부로 "미니 알약" 판정).*

## 데이터 흐름

```
설정 토글 변경 → settings.menubarItems 갱신 → onMenubarModeChange()
  → updateStatusTitle() → 호스팅뷰 rootView가 새 항목 집합 반영
refresh(30초)/이벤트 → store 갱신 → MenubarContentView 텍스트 값 재계산(@Observable)
웨이브 항목 → WavePill TimelineView (idle 8fps / active 30fps)
```

## 엣지 케이스

- **빈 선택**: `✦` 아이콘만(위험도 색). 토글 다 꺼도 허용(최소 강제 없음 — iconOnly 의도).
- **웨이브만 선택**: 기존 wavePill 모드와 동일 외형.
- **마이그레이션 충돌**: menubarItems 키 존재 시 마이그레이션 스킵(이미 신 포맷).
- **폭 변동**: variableLength라 항목 추가/제거 시 자동 조정. 텍스트 값 자릿수 변동(612M→1.2B)도 자동.

## 테스트

- **MenubarItem 마이그레이션** (단위): 기존 menubarMode 각 값 → 올바른 menubarItems 집합 변환. AppSettings는 UserDefaults 의존이라 테스트 가능한 순수 변환 함수로 분리: `static func migrate(mode: MenubarMode) -> Set<MenubarItem>`.
- **표시 문자열 조합** (단위): 켜진 항목 집합 → 렌더 순서·구분자 검증을 위한 순수 헬퍼 `menubarItemsOrdered(_:) -> [MenubarItem]`(allCases 필터).
- **수동 검증**: 항목 조합별 메뉴바 표시(웨이브+토큰+%, 텍스트만, 빈 선택 ✦), idle 시 웨이브 8fps 유지, 설정 토글 즉시 반영, 기존 설정 마이그레이션, 온보딩 다중 토글.

## 확정된 세부 결정

- **`menubarRefreshTick` 생략**: 토큰/속도/% 텍스트는 모두 `store.events`·`limits` 기반이고, refresh의 `addEvents`/`setLimits`가 `@Observable` 변경을 일으켜 `MenubarContentView`가 자동 재렌더된다. 별도 tick 불필요. `updateStatusTitle()`은 호스팅뷰 설치(멱등) + `length = variableLength`만 담당.
- **텍스트 항목 색**: 토큰·속도는 `.primary`, 최고 사용률% 항목은 `Theme.statusColor(percent:warn:crit:)`(위험도 색으로 가독성), 빈 선택 `✦`도 위험도 색. 웨이브 항목은 WavePill 자체 색.
