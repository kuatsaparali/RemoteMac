import AppKit
import ApplicationServices
import Foundation

@MainActor
final class HostSession: ObservableObject {
    enum Phase { case idle, connecting, sharingLink, request, starting, active }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var screenAllowed = false
    @Published private(set) var inputAllowed = false
    @Published private(set) var invitation: URL?
    @Published private(set) var notice: String?

    private let network = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var captureStarter: Task<Void, Never>?
    private var timeLimit: Task<Void, Never>?
    private var cipher: SessionCipher?
    private var capture: ScreenFeed?
    private var input: RemoteInput?

    func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        inputAllowed = AXIsProcessTrusted()
    }

    func grantScreenPermission() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
        refreshPermissions()
    }

    func grantInputPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings("Privacy_Accessibility")
        }
        refreshPermissions()
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    func start(address: String, hostKey: String) {
        guard phase == .idle else { return }
        do {
            refreshPermissions()
            guard screenAllowed, inputAllowed else { throw SessionError.permissions }
            let key = hostKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
                throw SessionError.invalidKey
            }

            var addressParts = try Self.addressParts(address)
            let room = try Data.secureRandom(count: 16).base64url
            let cipher = try SessionCipher()
            addressParts.fragment = room + "." + cipher.secret.base64url
            guard let link = addressParts.url else { throw SessionError.invalidAddress }
            addressParts.fragment = nil
            addressParts.path = "/ws"
            addressParts.scheme = addressParts.scheme == "https" ? "wss" : "ws"
            guard let endpoint = addressParts.url else { throw SessionError.invalidAddress }

            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            let socket = network.webSocketTask(with: request)
            socket.maximumMessageSize = 2048
            self.socket = socket
            self.cipher = cipher
            notice = nil
            phase = .connecting
            socket.resume()

            receiver = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(["type": "host", "room": room, "ticket": cipher.ticket, "key": key], on: socket)
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard self.socket === socket else { return }
                        self.handle(message, invitation: link)
                    }
                } catch {
                    guard self.socket === socket else { return }
                    self.stop("Связь с сервером потеряна. Проверьте адрес и создайте новую ссылку.")
                }
            }
            timeLimit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.socket === socket, self.phase == .connecting else { return }
                self.stop("Сервер не ответил. Проверьте адрес и повторите.")
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func approve() {
        guard phase == .request, let socket else { return }
        refreshPermissions()
        guard screenAllowed, inputAllowed else {
            stop(SessionError.permissions.localizedDescription)
            return
        }
        phase = .starting
        captureStarter = Task { [weak self] in
            guard let self else { return }
            var pending: ScreenFeed?
            do {
                let capture = try await ScreenFeed()
                pending = capture
                try Task.checkCancellation()
                try await capture.start()
                try Task.checkCancellation()
                try await self.send(["type": "approve"], on: socket)
                try Task.checkCancellation()
                guard self.socket === socket else {
                    await capture.stop()
                    return
                }
                self.capture = capture
                pending = nil
                self.input = RemoteInput(displayID: capture.displayID)
                self.phase = .active
                self.startSending(capture, on: socket)
            } catch {
                if let pending { await pending.stop() }
                guard self.socket === socket else { return }
                self.stop("Не удалось начать показ экрана. " + error.localizedDescription)
            }
        }
    }

    func reject() {
        guard phase == .request, let socket else { return }
        phase = .starting
        captureStarter = Task { [weak self] in
            guard let self else { return }
            try? await self.send(["type": "reject"], on: socket)
            guard self.socket === socket else { return }
            self.stop("Запрос отклонён. Можно создать новую ссылку.")
        }
    }

    func stop(_ reason: String? = nil) {
        guard phase != .idle else { return }
        let feed = capture
        capture = nil
        let closing = socket
        socket = nil
        receiver?.cancel()
        sender?.cancel()
        captureStarter?.cancel()
        timeLimit?.cancel()
        receiver = nil
        sender = nil
        captureStarter = nil
        timeLimit = nil
        closing?.cancel(with: .normalClosure, reason: nil)
        input?.release()
        input = nil
        cipher = nil
        invitation = nil
        phase = .idle
        notice = reason
        if let feed { Task { await feed.stop() } }
    }

    private func startSending(_ capture: ScreenFeed, on socket: URLSessionWebSocketTask) {
        sender = Task { [weak self] in
            do {
                for try await jpeg in capture.frames {
                    guard let self, self.socket === socket, let packet = try self.cipher?.frame(jpeg) else { return }
                    try await socket.send(.data(packet))
                }
                guard let self, self.socket === socket else { return }
                self.stop("Показ экрана завершён.")
            } catch {
                guard let self, self.socket === socket else { return }
                self.stop("Показ экрана прерван. Создайте новую ссылку.")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, invitation link: URL) {
        switch message {
        case .string(let text):
            guard let message = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return }
            switch message["type"] {
            case "ready" where phase == .connecting:
                invitation = link
                phase = .sharingLink
                timeLimit?.cancel()
                timeLimit = nil
            case "request" where phase == .sharingLink:
                invitation = nil
                phase = .request
                NSApp.requestUserAttention(.informationalRequest)
            case "denied":
                stop(SessionError.protocolError.localizedDescription)
            case "expired":
                stop("Время на подтверждение истекло. Создайте новую ссылку.")
            case "ended":
                stop("Сеанс завершён. Можно создать новую ссылку.")
            case "rejected":
                stop("Запрос отклонён. Можно создать новую ссылку.")
            default:
                break
            }
        case .data(let data):
            guard phase == .active, let command = cipher?.command(data) else { return }
            input?.apply(command)
        @unknown default:
            break
        }
    }

    private func send(_ fields: [String: String], on socket: URLSessionWebSocketTask) async throws {
        let encoded = try JSONEncoder().encode(fields)
        try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
    }

    private static func addressParts(_ address: String) throws -> URLComponents {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw SessionError.invalidAddress }
        let loopback = ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased())
        parts.scheme = parts.scheme?.lowercased()
        guard parts.scheme == "https" || (parts.scheme == "http" && loopback) else {
            throw SessionError.invalidAddress
        }
        parts.path = "/"
        return parts
    }
}
