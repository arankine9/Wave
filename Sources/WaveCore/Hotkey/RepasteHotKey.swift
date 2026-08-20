#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey — Ctrl+Cmd+V by default — via
/// Carbon's `RegisterEventHotKey`, and calls `onPressed` whenever it fires,
/// in whatever app is frontmost.
///
/// Why Carbon and not a CGEventTap (like `FnKeyMonitor`) or an NSEvent global
/// monitor:
///   - `RegisterEventHotKey` *consumes* the chord — the focused app never sees
///     Ctrl+Cmd+V, so we don't fight whatever that app binds it to.
///   - It does the chord matching for us; no risk of accidentally swallowing
///     unrelated keystrokes the way a broad keyDown tap could.
///   - It needs no special permission. (The paste it ultimately triggers needs
///     Accessibility, same as ordinary dictation paste — but registration does
///     not, so the hotkey can be installed eagerly at launch.)
///
/// Carbon's hotkey handler is invoked on the main run loop. `onPressed` is
/// declared `@Sendable` to mirror `FnKeyMonitor`; the wrapper itself is only
/// ever touched from the main thread.
public final class RepasteHotKey {
    // Four-char code 'Wave' (0x57 'W', 0x61 'a', 0x76 'v', 0x65 'e'),
    // identifying our hotkey registration. We register exactly one, so the
    // handler doesn't need to disambiguate by id.
    private static let signature: OSType = 0x5761_7665

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public var onPressed: (@Sendable () -> Void)?

    public init() {}

    /// Install the application-level event handler and register Ctrl+Cmd+V.
    /// Idempotent — a second call while already registered is a no-op.
    ///
    /// Returns `true` only if both the handler installed and the hotkey
    /// registered. Registration fails (e.g. `eventHotKeyExistsErr`) when
    /// another running app already owns Ctrl+Cmd+V globally; the caller should
    /// surface that rather than letting the shortcut silently do nothing.
    @discardableResult
    public func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let monitor = Unmanaged<RepasteHotKey>.fromOpaque(userData).takeUnretainedValue()
                monitor.onPressed?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        // kVK_ANSI_V is virtual keycode 9 — the same 'v' the paster posts.
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | controlKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        return installStatus == noErr && registerStatus == noErr && hotKeyRef != nil
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        hotKeyRef = nil
        handlerRef = nil
    }
}
#endif
