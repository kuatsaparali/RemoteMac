import Foundation

@MainActor
final class DesktopRuntime {
    struct Endpoint {
        let address: String
        let localAddress: String
        let hostKey: String
    }

    private struct Event: Decodable {
        let type: String
        let address: String?
        let localAddress: String?
        let message: String?
    }

    private enum RuntimeError: LocalizedError {
        case missingFiles, failed(String)

        var errorDescription: String? {
            switch self {
            case .missingFiles: return "В сборке отсутствуют файлы подключения. Установите приложение из GitHub Releases."
            case .failed(let message): return message
            }
        }
    }

    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var reader: Task<Void, Never>?
    private var pending: CheckedContinuation<Endpoint, Error>?
    private var finishOutput: (() -> Void)?

    func start(resources: URL? = Bundle.main.resourceURL) async throws -> Endpoint {
        stop()
        guard let resources else { throw RuntimeError.missingFiles }
        let helpers = resources.deletingLastPathComponent().appendingPathComponent("Helpers")
        let executable = helpers.appendingPathComponent("node")
        let tunnel = helpers.appendingPathComponent("cloudflared")
        let entry = resources.appendingPathComponent("relay/desktop.mjs")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path), files.isExecutableFile(atPath: tunnel.path),
              files.fileExists(atPath: entry.path) else { throw RuntimeError.missingFiles }

        let key = try Data.secureRandom(count: 32).base64url
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [entry.path]
        process.currentDirectoryURL = resources
        // Avoid inheriting NODE_OPTIONS or a user's shell startup configuration.
        process.environment = [
            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "MACREMOTE_HOST_KEY": key, "MACREMOTE_CLOUDFLARED": tunnel.path
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let chunks = AsyncStream<Data> { continuation in
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { continuation.finish() }
                else { continuation.yield(data) }
            }
            process.terminationHandler = { _ in continuation.finish() }
            finishOutput = { continuation.finish() }
        }
        self.process = process
        self.input = input
        self.output = output

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            do {
                try process.run()
            } catch {
                pending = nil
                stop()
                continuation.resume(throwing: error)
                return
            }
            // Only the parent's write handle keeps stdin alive after launch.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            reader = Task { [weak self] in
                var buffer = Data()
                for await chunk in chunks {
                    guard !Task.isCancelled, let self, self.process === process else { return }
                    buffer.append(chunk)
                    guard buffer.count < 64 * 1024 else {
                        self.fail("Сервис подключения вернул неверный ответ.")
                        return
                    }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let event = try? JSONDecoder().decode(Event.self, from: line) else { continue }
                        if event.type == "ready", let address = event.address, let local = event.localAddress,
                           URL(string: address)?.scheme == "https", URL(string: local)?.host == "127.0.0.1" {
                            let waiting = self.pending
                            self.pending = nil
                            waiting?.resume(returning: Endpoint(address: address, localAddress: local, hostKey: key))
                        } else if event.type == "error" {
                            self.fail(event.message ?? "Подключение прервалось. Повторите попытку.")
                            return
                        }
                    }
                }
                guard !Task.isCancelled, let self, self.process === process else { return }
                self.fail("Сервис подключения остановился. Создайте новую ссылку.")
            }
        }
    }

    func stop() {
        let waiting = pending
        pending = nil
        waiting?.resume(throwing: CancellationError())
        reader?.cancel()
        reader = nil
        finishOutput?()
        finishOutput = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        output = nil
        // EOF makes the supervisor close its relay and tunnel, even if the app crashes.
        try? input?.fileHandleForWriting.close()
        input = nil
        process?.terminationHandler = nil
        process = nil
    }

    private func fail(_ message: String) {
        let wasStarting = pending != nil
        let waiting = pending
        pending = nil
        stop()
        waiting?.resume(throwing: RuntimeError.failed(message))
        if !wasStarting { onFailure?(message) }
    }
}
