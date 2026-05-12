import Foundation

public enum HotkeyEvent: Sendable, Equatable {
    /// Fn-down arrived; pre-arm the STT session so audio capture starts
    /// instantly. May or may not be followed by `.startRecording`.
    case armRecording
    case startRecording(reason: Reason)
    case stopRecording
    /// The press cycle ended without ever becoming a hold or a lock. The
    /// orchestrator should tear down whatever it armed and discard audio.
    case disarmRecording

    public enum Reason: String, Sendable {
        case hold
        case locked
    }
}

/// Translates raw Fn key press/release events into dictation start/stop events,
/// implementing the project.md semantics:
///   - press-and-hold → dictate while held
///   - double-tap → lock-on (continues recording until next single tap)
///   - tap while locked → stop and unlock
public final class HotkeyController: @unchecked Sendable {
    private enum State {
        case idle
        case firstPressed                 // waiting hold-vs-tap
        case awaitingDoubleTap            // first tap done, waiting for second press
        case secondPressed                // second press, will lock on release
        case holdRecording                // dictating in hold mode
        case lockedRecording              // dictating in locked mode
        case lockedReleasing              // saw a press while locked, will stop on release
    }

    private let clock: BeckClock
    private let holdThreshold: TimeInterval
    private let doubleTapWindow: TimeInterval
    private var state: State = .idle
    private var pendingHoldTimer: CancelToken?
    private var pendingWindowTimer: CancelToken?

    public var onEvent: (@Sendable (HotkeyEvent) -> Void)?

    public init(
        clock: BeckClock,
        holdThresholdMs: Int = 250,
        doubleTapWindowMs: Int = 280
    ) {
        self.clock = clock
        self.holdThreshold = TimeInterval(holdThresholdMs) / 1000.0
        self.doubleTapWindow = TimeInterval(doubleTapWindowMs) / 1000.0
    }

    public func handlePressed() {
        switch state {
        case .idle:
            state = .firstPressed
            scheduleHoldCheck()
            // Pre-arm the STT session before we know whether this is a tap
            // or a hold. If it turns out to be a single tap, `.disarmRecording`
            // tears it back down (see windowExpired).
            emit(.armRecording)

        case .awaitingDoubleTap:
            cancelWindowTimer()
            state = .secondPressed
            scheduleHoldCheck()

        case .lockedRecording:
            state = .lockedReleasing

        case .firstPressed, .secondPressed, .holdRecording, .lockedReleasing:
            // Already mid-press; ignore re-press until release.
            break
        }
    }

    public func handleReleased() {
        switch state {
        case .firstPressed:
            cancelHoldTimer()
            state = .awaitingDoubleTap
            scheduleWindowExpiry()

        case .secondPressed:
            cancelHoldTimer()
            state = .lockedRecording
            emit(.startRecording(reason: .locked))

        case .holdRecording:
            state = .idle
            emit(.stopRecording)

        case .lockedReleasing:
            state = .idle
            emit(.stopRecording)

        case .idle, .awaitingDoubleTap, .lockedRecording:
            // Spurious release. Ignore.
            break
        }
    }

    public var isRecording: Bool {
        switch state {
        case .holdRecording, .lockedRecording, .lockedReleasing: return true
        default: return false
        }
    }

    private func scheduleHoldCheck() {
        cancelHoldTimer()
        pendingHoldTimer = clock.schedule(after: holdThreshold) { [weak self] in
            self?.holdTimerFired()
        }
    }

    private func cancelHoldTimer() {
        pendingHoldTimer?.cancel()
        pendingHoldTimer = nil
    }

    private func scheduleWindowExpiry() {
        cancelWindowTimer()
        pendingWindowTimer = clock.schedule(after: doubleTapWindow) { [weak self] in
            self?.windowExpired()
        }
    }

    private func cancelWindowTimer() {
        pendingWindowTimer?.cancel()
        pendingWindowTimer = nil
    }

    private func holdTimerFired() {
        switch state {
        case .firstPressed:
            state = .holdRecording
            emit(.startRecording(reason: .hold))
        case .secondPressed:
            // Second press held past threshold; treat as locked-on too.
            state = .lockedRecording
            emit(.startRecording(reason: .locked))
        default:
            break
        }
        pendingHoldTimer = nil
    }

    private func windowExpired() {
        if case .awaitingDoubleTap = state {
            state = .idle
            emit(.disarmRecording)
        }
        pendingWindowTimer = nil
    }

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
    }
}
