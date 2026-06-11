import AppKit
import Carbon.HIToolbox

/// 글로벌 단축키 ⌘⇧U (Carbon RegisterEventHotKey — 접근성 권한 불필요).
/// Carbon hot-key 이벤트는 메인 스레드에서 디스패치된다.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // InstallEventHandler 콜백은 C 함수 — Unmanaged self 패턴 (DirectoryWatcher 참고).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.onPress()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4147_4C53), id: 1) // 'AGLS'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_U),
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
