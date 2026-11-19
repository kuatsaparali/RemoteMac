import SwiftUI

@MainActor
struct HostChatView: View {
    @ObservedObject var host: HostSession
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Чат"), systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                Toggle(L10n.text("Чат в сеансе"), isOn: Binding(get: { host.chatEnabled }, set: { host.setChatEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(12)

            if host.chatEnabled {
                Divider()
                conversation
                Divider()
                composer
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                if host.chatMessages.isEmpty {
                    Text(L10n.text("Здесь появятся сообщения."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 58)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(host.chatMessages) { message in
                            HStack {
                                if message.fromHost { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.text(message.fromHost ? "Вы" : "Зритель"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(message.text).font(.callout).textSelection(.enabled)
                                }
                                .padding(8)
                                .background(message.fromHost ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 8))
                                if !message.fromHost { Spacer(minLength: 40) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
            }
            .frame(height: 150)
            .onChange(of: host.chatMessages.last?.id) { id in
                if let id { reader.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = host.chatMessages.last?.id { reader.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField(L10n.text("Сообщение…"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button(L10n.text("Отправить")) { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ChatMessage.cleaned(draft) == nil)
            }
            if draft.utf16.count > 250 {
                Text(L10n.text("До 250 символов")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func send() {
        if host.sendChat(draft) { draft = "" }
    }
}
