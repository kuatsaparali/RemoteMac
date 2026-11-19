import CryptoKit
import Foundation
import Security

enum SessionError: LocalizedError {
    case random, invalidAddress, invalidKey, permissions, noDisplay, protocolError

    var errorDescription: String? {
        switch self {
        case .random: return "Не удалось создать ключ сеанса."
        case .invalidAddress: return "Укажите адрес HTTPS или http://localhost:8787."
        case .invalidKey: return "Скопируйте ключ из окна запущенного сервера."
        case .permissions: return "Включите доступ к экрану и управлению в настройках macOS."
        case .noDisplay: return "Основной экран недоступен."
        case .protocolError: return "Сервер отклонил запрос. Проверьте адрес и ключ."
        }
    }
}

extension Data {
    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func secureRandom(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else { throw SessionError.random }
        return data
    }
}

struct SessionCipher {
    let secret: Data
    private var sent: UInt64 = 0
    private var audioSent: UInt64 = 0
    private var chatSent: UInt64 = 0
    private var received: UInt64 = 0

    var lastFrameSequence: UInt64 { sent }

    init() throws { secret = try .secureRandom(count: 32) }

    var ticket: String { Data(SHA256.hash(data: secret)).base64url }

    mutating func frame(_ payload: Data) throws -> Data {
        sent += 1
        return try seal(payload, direction: 1, sequence: sent)
    }

    mutating func audio(_ payload: Data) throws -> Data {
        audioSent += 1
        return try seal(payload, direction: 3, sequence: audioSent)
    }

    mutating func chat(_ event: ChatEvent) throws -> Data {
        let payload = try JSONEncoder().encode(event)
        chatSent += 1
        return try seal(payload, direction: 4, sequence: chatSent)
    }

    private func seal(_ payload: Data, direction: UInt8, sequence: UInt64) throws -> Data {
        var sequence = sequence.bigEndian
        var nonce = Data([0, 0, 0, direction])
        Swift.withUnsafeBytes(of: &sequence) { nonce.append(contentsOf: $0) }
        let sealed = try AES.GCM.seal(payload, using: SymmetricKey(data: secret), nonce: AES.GCM.Nonce(data: nonce))
        var packet = nonce
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        return packet
    }

    mutating func command(_ packet: Data) -> RemoteCommand? {
        guard (29...2048).contains(packet.count), packet.prefix(4).elementsEqual([0, 0, 0, 2]) else {
            return nil
        }
        let sequence = packet.dropFirst(4).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard sequence > received,
              let box = try? AES.GCM.SealedBox(combined: packet),
              let data = try? AES.GCM.open(box, using: SymmetricKey(data: secret)) else { return nil }
        received = sequence
        return try? JSONDecoder().decode(RemoteCommand.self, from: data)
    }
}
