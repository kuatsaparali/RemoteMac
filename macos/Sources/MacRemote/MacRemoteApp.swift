import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MacRemote", id: "host") {
            HostView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
struct HostView: View {
    @StateObject private var host = HostSession()
    @AppStorage("relayAddress") private var address = "http://localhost:8787"
    @AppStorage("appLanguage") private var language = AppLanguage.preferred.rawValue
    @State private var key = ""
    @State private var copied = false
    @State private var ownServer = false
    @State private var chatOpen = false
    @State private var chatDraft = ""
    @State private var chatReadCount = 0
    @Environment(\.scenePhase) private var scenePhase

    private var ready: Bool { host.screenAllowed && host.inputAllowed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 25)

            if host.phase == .idle {
                setup
            } else {
                session
            }

            if let notice = host.notice {
                Label(notice.text, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .padding(27)
        .frame(width: 536)
        .environment(\.locale, Locale(identifier: language))
        .onAppear { host.refreshPermissions() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { host.refreshPermissions() }
        }
        .onChange(of: host.phase) { phase in
            copied = false
            if phase != .active {
                chatOpen = false
                chatDraft = ""
                chatReadCount = 0
            }
        }
        .onChange(of: chatOpen) { open in
            if open { chatReadCount = host.chatReceivedCount }
        }
        .onChange(of: host.chatReceivedCount) { count in
            if chatOpen { chatReadCount = count }
        }
        .onChange(of: host.chatEnabled) { enabled in
            if !enabled { chatOpen = false }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
            host.stop("Сеанс закрыт после блокировки или смены пользователя.")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            host.stop("Сеанс закрыт при переходе экрана в режим сна.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            if host.phase == .active { host.stop("Параметры экрана изменились. Создайте новую ссылку.") }
        }
        .onDisappear { host.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            host.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "display")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 47, height: 47)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacRemote").font(.system(size: 25, weight: .semibold))
                Text(L10n.text("Удалённый доступ к этому Mac")).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Picker("Язык / Language", selection: $language) {
                Text("Русский").tag(AppLanguage.russian.rawValue)
                Text("English").tag(AppLanguage.english.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 156)
            .accessibilityLabel("Язык / Language")
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("Разрешения macOS")).font(.headline)
                VStack(spacing: 0) {
                    permission("Запись экрана", icon: "rectangle.inset.filled", allowed: host.screenAllowed,
                               help: "Показывает основной экран", action: host.grantScreenPermission)
                    Divider().padding(.leading, 42)
                    permission("Универсальный доступ", icon: "cursorarrow.rays", allowed: host.inputAllowed,
                               help: "Разрешает управление мышью и клавиатурой", action: host.grantInputPermission)
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                if !ready {
                    Text(L10n.text("После выдачи разрешений вернитесь сюда. Если статус не обновится, перезапустите MacRemote."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("Подключение через интернет")).font(.headline)
                Text(L10n.text("Создайте ссылку и откройте её на другом устройстве. Запрос доступа нужно подтвердить на этом Mac."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.text("Использовать свой сервер"), isOn: $ownServer)
                    .font(.callout)
                if ownServer {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(L10n.text("Адрес")).foregroundStyle(.secondary)
                        TextField("https://…", text: $address)
                            .accessibilityLabel(L10n.text("Адрес сервера"))
                    }
                    GridRow {
                        Text(L10n.text("Ключ")).foregroundStyle(.secondary)
                        SecureField(L10n.text("Из окна запущенного сервера"), text: $key)
                            .accessibilityLabel(L10n.text("Ключ сервера"))
                    }
                }
                .controlSize(.large)
                } else {
                    Text(L10n.text("Временное подключение создаётся через Cloudflare. Ссылка действует, пока открыт сеанс."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(L10n.text("Чат в сеансе"), isOn: Binding(get: { host.chatEnabled }, set: { host.setChatEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            HStack {
                Spacer()
                Button(L10n.text("Создать ссылку")) {
                    if ownServer { host.start(address: address, hostKey: key) }
                    else { host.startInternet() }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || (ownServer && key.isEmpty))
            }
            .padding(.top, 3)
        }
    }

    private func permission(_ title: String, icon: String, allowed: Bool, help: String,
                            action: @escaping @MainActor () -> Void) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).font(.callout.weight(.medium))
                Text(L10n.text(help)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed {
                Label(L10n.text("Включено"), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(L10n.text("Разрешить")) { action() }
                    .accessibilityLabel(L10n.text("Разрешить") + " " + L10n.text(title))
            }
        }
        .padding(11)
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sessionStatus.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(host.phase == .active ? Color.green : Color.accentColor)
                    .frame(width: 27)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(sessionStatus.title)).font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.text(sessionStatus.detail)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if host.phase == .active && host.chatAvailable { chatControls }
                Spacer()
                if host.phase == .request {
                    Button(L10n.text("Отклонить")) { host.reject() }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.text("Разрешить доступ")) { host.approve() }
                        .buttonStyle(.borderedProminent)
                } else if let link = host.invitation {
                    Button(L10n.text("Отменить ссылку")) { host.stop() }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.text(copied ? "Ссылка скопирована" : "Скопировать ссылку")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copied = pasteboard.setString(link.absoluteString, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.text(host.phase == .active ? "Завершить сеанс" : "Отмена"), role: .destructive) {
                        host.stop(host.phase == .active ? "Сеанс завершён." : nil)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.large)
        }
    }

    private var chatControls: some View {
        HStack(spacing: 10) {
            Button { chatOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Label(L10n.text("Чат"), systemImage: "bubble.left.and.bubble.right")
                    if host.chatEnabled && host.chatReceivedCount > chatReadCount {
                        Text(min(60, host.chatReceivedCount - chatReadCount).formatted())
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                    }
                }
            }
            .disabled(!host.chatEnabled)
            .popover(isPresented: $chatOpen, arrowEdge: .bottom) {
                HostChatView(host: host, draft: $chatDraft) { chatOpen = false }
                    .environment(\.locale, Locale(identifier: language))
            }
            Toggle(L10n.text("Чат в сеансе"), isOn: Binding(get: { host.chatEnabled }, set: { host.setChatEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(L10n.text("Чат в сеансе"))
        }
    }

    private var sessionStatus: (icon: String, title: String, detail: String) {
        switch host.phase {
        case .preparing:
            return ("network", "Создаём интернет-подключение", "Это может занять до 90 секунд. После подключения появится ссылка-приглашение.")
        case .idle, .connecting:
            return ("network", "Подключение к серверу", "Ссылка появится после подключения.")
        case .sharingLink:
            return ("link", "Ссылка готова", "Откройте её на другом устройстве. Вы сможете подтвердить или отклонить запрос на этом Mac.")
        case .request:
            return ("person.crop.circle.badge.questionmark", "Запрос на удалённый доступ", "Если вы ждёте это подключение, разрешите просмотр экрана, передачу звука и управление этим Mac.")
        case .starting:
            return ("display", "Настройка сеанса", "Подождите несколько секунд.")
        case .active:
            return ("record.circle", "Доступ открыт", "Другой участник может видеть экран, слышать звук Mac и управлять мышью и клавиатурой.")
        }
    }
}
