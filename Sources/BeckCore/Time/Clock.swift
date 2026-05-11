import Foundation

public protocol BeckClock: AnyObject, Sendable {
    func now() -> TimeInterval
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelToken
}

public final class CancelToken: @unchecked Sendable {
    private let cancelImpl: () -> Void
    private var cancelled = false
    public init(_ cancel: @escaping () -> Void) { self.cancelImpl = cancel }
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        cancelImpl()
    }
}

public final class RealClock: BeckClock, @unchecked Sendable {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue = .main) { self.queue = queue }

    public func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    public func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelToken {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return CancelToken { item.cancel() }
    }
}

public final class TestClock: BeckClock, @unchecked Sendable {
    private struct Pending {
        let id: Int
        let deadline: TimeInterval
        let block: () -> Void
    }

    private var current: TimeInterval = 0
    private var pending: [Pending] = []
    private var nextID = 0

    public init(start: TimeInterval = 0) {
        self.current = start
    }

    public func now() -> TimeInterval { current }

    public func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancelToken {
        nextID += 1
        let id = nextID
        let p = Pending(id: id, deadline: current + delay, block: block)
        pending.append(p)
        return CancelToken { [weak self] in
            self?.pending.removeAll { $0.id == id }
        }
    }

    public func advance(by delta: TimeInterval) {
        let target = current + delta
        while true {
            let due = pending.filter { $0.deadline <= target }.sorted { $0.deadline < $1.deadline }
            guard let next = due.first else { break }
            current = next.deadline
            pending.removeAll { $0.id == next.id }
            next.block()
        }
        current = target
    }
}
