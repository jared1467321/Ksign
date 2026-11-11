import Foundation

/// A bounded mailbox between workers and presentation. A busy UI retains one
/// newest value, rather than one queued closure for every byte/progress event.
final class LatestValueDelivery<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let merge: ((Value, Value) -> Value)?
    private let receive: (Value) -> Void
    private var pending: Value?
    private var scheduled = false
    private var generation: UInt64 = 0
    private var active = true

    init(interval: TimeInterval = 0.2, queue: DispatchQueue = .main,
         merge: ((Value, Value) -> Value)? = nil, receive: @escaping (Value) -> Void) {
        self.interval = interval
        self.queue = queue
        self.merge = merge
        self.receive = receive
    }

    func submit(_ value: Value, immediately: Bool = false) {
        lock.lock()
        if let pending, let merge {
            self.pending = merge(pending, value)
        } else {
            pending = value
        }
        if active && (!scheduled || immediately) {
            scheduleLocked(after: immediately ? 0 : interval)
        }
        lock.unlock()
    }

    func setActive(_ active: Bool) {
        lock.lock()
        self.active = active
        generation &+= 1
        scheduled = false
        if active, pending != nil { scheduleLocked(after: 0) }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        pending = nil
        generation &+= 1
        scheduled = false
        lock.unlock()
    }

    private func scheduleLocked(after delay: TimeInterval) {
        scheduled = true
        generation &+= 1
        let token = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.deliver(token) }
    }

    private func deliver(_ token: UInt64) {
        lock.lock()
        guard token == generation, active else { lock.unlock(); return }
        let value = pending
        pending = nil
        lock.unlock()
        if let value { receive(value) }
        lock.lock()
        if token == generation {
            scheduled = false
            if active, pending != nil { scheduleLocked(after: interval) }
        }
        lock.unlock()
    }
}
