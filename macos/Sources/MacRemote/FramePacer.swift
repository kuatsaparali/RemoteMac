/// Bounds the number of frames waiting for the browser on a slow connection.
@MainActor
final class FramePacer {
    private var limit: Int?
    private var pending = [UInt64]()
    private var waiting: CheckedContinuation<Void, Error>?

    func configure(video: Bool) {
        // At 60 fps, four frames cover about 67 ms of round-trip time.
        limit = video ? 4 : 2
        pending.removeAll()
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }

    func waitForCapacity() async throws {
        try Task.checkCancellation()
        if let limit, pending.count >= limit {
            try await withCheckedThrowingContinuation { waiting = $0 }
        }
        try Task.checkCancellation()
    }

    func sent(_ sequence: UInt64) {
        if limit != nil { pending.append(sequence) }
    }

    func acknowledge(_ sequence: UInt64) {
        guard let limit, pending.contains(sequence) else { return }
        pending.removeAll { $0 <= sequence }
        if pending.count < limit {
            let continuation = waiting
            waiting = nil
            continuation?.resume()
        }
    }

    func stop() {
        limit = nil
        pending.removeAll()
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: CancellationError())
    }
}
