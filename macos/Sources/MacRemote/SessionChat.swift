import Foundation

struct ChatEvent: Encodable {
    enum Kind: String, Encodable { case state, message }
    let type: Kind
    let generation: Int
    var enabled: Bool? = nil
    var text: String? = nil
    var fromHost: Bool? = nil
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let fromHost: Bool

    static func cleaned(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf16.count <= 250 ? text : nil
    }
}
