/// Bounds end-to-end video latency by allowing at most two unacknowledged frames.
@MainActor
final class FramePacer {
    private var enabled = false
    private var pending = [UInt64]()
    private var waiting: CheckedContinuation<Void, Error>?

    func configure() {
        enabled = true
        pending.removeAll()
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }

    func waitForCapacity() async throws {
        try Task.checkCancellation()
        if enabled && pending.count >= 2 {
            try await withCheckedThrowingContinuation { waiting = $0 }
        }
        try Task.checkCancellation()
    }

    func sent(_ sequence: UInt64) {
        if enabled { pending.append(sequence) }
    }

    func acknowledge(_ sequence: UInt64) {
        guard pending.contains(sequence) else { return }
        pending.removeAll { $0 <= sequence }
        if pending.count < 2 {
            let continuation = waiting
            waiting = nil
            continuation?.resume()
        }
    }

    func stop() {
        enabled = false
        pending.removeAll()
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: CancellationError())
    }
}
