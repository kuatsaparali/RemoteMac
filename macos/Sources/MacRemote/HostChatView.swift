import SwiftUI

@MainActor
struct HostChatView: View {
    @ObservedObject var host: HostSession
    @Binding var draft: String
    let collapse: () -> Void
    @State private var activity = 0
    @State private var composerEngaged = false
    @FocusState private var composerFocused: Bool

    private var composing: Bool { composerFocused && composerEngaged }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Чат"), systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                Button(L10n.text("Свернуть"), action: collapse)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()
            conversation
            Divider()
            composer
        }
        .frame(width: 344)
        .simultaneousGesture(TapGesture().onEnded { activity += 1 })
        .onChange(of: composerFocused) { focused in
            if !focused { composerEngaged = false }
            activity += 1
        }
        .onChange(of: draft) { _ in
            if composerFocused { composerEngaged = true }
            activity += 1
        }
        .onChange(of: host.chatMessages.last?.id) { _ in activity += 1 }
        .task(id: activity) {
            // AppKit can focus the field on open before the user interacts with it.
            guard !composing else { return }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            if !composing { collapse() }
        }
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                Group {
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
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ChatScrollOffset.self,
                                               value: geometry.frame(in: .named("chatHistory")).minY)
                    }
                }
            }
            .coordinateSpace(name: "chatHistory")
            .onPreferenceChange(ChatScrollOffset.self) { _ in activity += 1 }
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
                    .focused($composerFocused)
                    .simultaneousGesture(TapGesture().onEnded {
                        composerEngaged = true
                        activity += 1
                    })
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

private struct ChatScrollOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
