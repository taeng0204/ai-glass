import SwiftUI
import AIGlassCore

/// 이벤트별 커스텀 알림 메시지 편집 시트.
/// 11종 이벤트를 DisclosureGroup으로 펼쳐 모드(추가/고정)·메시지 목록을 편집한다.
/// 저장은 AppSettings.customMessages(단일 JSON). 완료 시 빈 줄을 정리한다.
struct CustomMessagesEditor: View {
    @Bindable var settings: AppSettings
    /// 미리보기 — 실제 HUD 카드로 잠깐 띄운다(기록·사운드 없음). App이 flashHUD에 연결.
    var onPreview: (HUDEvent) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("커스텀 알림 메시지").font(.headline)
                Spacer()
                Button("완료") { cleanup(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    legend
                    ForEach(CustomizableEvent.allCases) { event in
                        eventRow(event)
                        Divider()
                    }
                }
                .padding()
            }
        }
        .frame(width: 580, height: 620)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("사용 가능한 변수").font(.caption.bold())
            Text("{AGENT} 서비스명 · {USAGE} 사용률% · {TOKENS} 토큰 수 · {RESET} 리셋까지 시간")
                .font(.caption).foregroundStyle(.secondary)
            Text("의미 없는 자리는 자동으로 비워집니다. 모드가 '추가'면 기존 멘트와 섞여 무작위로, '고정'이면 내 메시지만 표시돼요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func eventRow(_ event: CustomizableEvent) -> some View {
        let cfg = config(event)
        // 배지는 사용자가 직접 저장한 경우만(seed는 표시용이라 제외).
        let customized = (settings.customMessages[event.rawValue]?.messages
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? false
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cfg.messages.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        TextField("예: BAAAM! {AGENT} {USAGE} 찍었다", text: messageBinding(event, i))
                            .textFieldStyle(.roundedBorder)
                        Button { removeMessage(event, i) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Button { addMessage(event) } label: {
                        Label("메시지 추가", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { preview(event) } label: {
                        Label("미리보기", systemImage: "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .font(.callout)

                if !event.recommendedVariables.isEmpty {
                    Text("권장 변수: \(event.recommendedVariables.joined(separator: " "))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Text(event.label)
                Spacer()
                if customized {
                    Text("내 메시지").font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: - config get/set

    /// 편집기에 채울 기본 멘트(seed) — REAL 상태에 맞춰: ON이면 감성 풀, OFF면 기본 제목.
    /// 화면·미리보기·실제 발화(미편집)가 모두 일관되게 보이도록 한다.
    private func seed(_ e: CustomizableEvent) -> [String] {
        settings.realMode ? RealModeMessages.pool(for: e.sampleKind) : [e.sampleDefaultTitle]
    }

    /// 저장된 커스텀이 있으면 그것, 없으면 seed(표시용). 사용자가 편집해야 비로소 저장된다.
    private func config(_ e: CustomizableEvent) -> CustomMessageConfig {
        settings.customMessages[e.rawValue] ?? CustomMessageConfig(messages: seed(e))
    }

    /// config를 변형해 다시 저장(seed 기반에서 시작 — 첫 편집 시 seed가 보존됨).
    /// 메시지 목록이 완전히 비면(0줄) 항목을 제거해 기본으로 되돌린다.
    private func update(_ e: CustomizableEvent, _ transform: (inout CustomMessageConfig) -> Void) {
        var dict = settings.customMessages
        var cfg = dict[e.rawValue] ?? CustomMessageConfig(messages: seed(e))
        transform(&cfg)
        if cfg.messages.isEmpty {
            dict.removeValue(forKey: e.rawValue)
        } else {
            dict[e.rawValue] = cfg
        }
        settings.customMessages = dict
    }

    private func messageBinding(_ e: CustomizableEvent, _ i: Int) -> Binding<String> {
        Binding(
            get: { let m = config(e).messages; return i < m.count ? m[i] : "" },
            set: { v in update(e) { if i < $0.messages.count { $0.messages[i] = v } } })
    }

    private func addMessage(_ e: CustomizableEvent) {
        update(e) { $0.messages.append("") }
    }

    /// 현재 편집 중인 설정으로 샘플 HUD 카드를 띄운다 (커스텀이 비면 기본/REAL 멘트로 보임).
    private func preview(_ e: CustomizableEvent) {
        let kind = e.sampleKind
        let title = RealModeMessages.resolve(kind: kind, defaultTitle: e.sampleDefaultTitle,
                                             realMode: settings.realMode,
                                             custom: config(e),
                                             context: e.sampleContext)
        onPreview(HUDEvent(kind: kind, title: title, subtitle: e.sampleSubtitle, percent: nil))
    }

    private func removeMessage(_ e: CustomizableEvent, _ i: Int) {
        update(e) { if i < $0.messages.count { $0.messages.remove(at: i) } }
    }

    /// 완료 시 모든 이벤트의 공백 줄을 제거하고, 빈 config 키를 정리한다.
    private func cleanup() {
        var dict = settings.customMessages
        for key in Array(dict.keys) {
            dict[key]?.messages.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if dict[key]?.messages.isEmpty ?? true {
                dict.removeValue(forKey: key)
            }
        }
        settings.customMessages = dict
    }
}
