import AppKit
import Carbon.HIToolbox

/// 글로벌 단축키 (Carbon RegisterEventHotKey — 접근성 권한 불필요).
/// 기본 ⌘⇧U(대시보드 토글). keyCode/id를 주입하면 다른 키도 등록 가능 (예: ⌘⇧E).
/// Carbon hot-key 이벤트는 메인 스레드에서 디스패치된다.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void
    /// 이 인스턴스가 등록한 핫키 id. 핸들러가 자기 핫키 이벤트만 처리하도록 필터링에 사용.
    let registeredID: UInt32

    private static let signature = OSType(0x4147_4C53) // 'AGLS'

    init(keyCode: Int = kVK_ANSI_U, id: UInt32 = 1, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.registeredID = id

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // InstallEventHandler 콜백은 C 함수 — Unmanaged self 패턴 (DirectoryWatcher 참고).
        // 인스턴스마다 같은 타겟에 핸들러가 설치되므로, EventHotKeyID를 꺼내
        // 자기 id/signature와 일치할 때만 처리하고 아니면 eventNotHandledErr로
        // 체인을 통과시킨다 (안 그러면 나중 설치된 핸들러가 모든 핫키를 가로챔).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID) == noErr else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard hkID.signature == GlobalHotKey.signature, hkID.id == hotKey.registeredID else {
                    return OSStatus(eventNotHandledErr)
                }
                hotKey.onPress()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
