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
    @State private var key = ""
    @State private var copied = false
    @State private var ownServer = false
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
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .padding(27)
        .frame(width: 536)
        .onAppear { host.refreshPermissions() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { host.refreshPermissions() }
        }
        .onChange(of: host.phase) { _ in copied = false }
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
                Text("Удалённый доступ к этому Mac").font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Разрешения macOS").font(.headline)
                VStack(spacing: 0) {
                    permission("Запись экрана", icon: "rectangle.inset.filled", allowed: host.screenAllowed,
                               help: "Показывает основной экран", action: host.grantScreenPermission)
                    Divider().padding(.leading, 42)
                    permission("Универсальный доступ", icon: "cursorarrow.rays", allowed: host.inputAllowed,
                               help: "Разрешает управление мышью и клавиатурой", action: host.grantInputPermission)
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                if !ready {
                    Text("После выдачи разрешений вернитесь сюда. Если статус не обновится, перезапустите MacRemote.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Подключение через интернет").font(.headline)
                Text("Создайте ссылку и откройте её на другом устройстве. Запрос доступа нужно подтвердить на этом Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Использовать свой сервер", isOn: $ownServer)
                    .font(.callout)
                if ownServer {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Адрес").foregroundStyle(.secondary)
                        TextField("https://…", text: $address)
                            .accessibilityLabel("Адрес сервера")
                    }
                    GridRow {
                        Text("Ключ").foregroundStyle(.secondary)
                        SecureField("Из окна запущенного сервера", text: $key)
                            .accessibilityLabel("Ключ сервера")
                    }
                }
                .controlSize(.large)
                } else {
                    Text("Временное подключение создаётся через Cloudflare. Ссылка действует, пока открыт сеанс.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Создать ссылку") {
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
                Text(title).font(.callout.weight(.medium))
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed {
                Label("Включено", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Разрешить") { action() }
                    .accessibilityLabel("Разрешить: " + title)
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
                    Text(sessionStatus.title).font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(sessionStatus.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                if host.phase == .request {
                    Button("Отклонить") { host.reject() }
                        .keyboardShortcut(.cancelAction)
                    Button("Разрешить доступ") { host.approve() }
                        .buttonStyle(.borderedProminent)
                } else if let link = host.invitation {
                    Button("Отменить ссылку") { host.stop() }
                        .keyboardShortcut(.cancelAction)
                    Button(copied ? "Ссылка скопирована" : "Скопировать ссылку") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copied = pasteboard.setString(link.absoluteString, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(host.phase == .active ? "Завершить сеанс" : "Отмена", role: .destructive) {
                        host.stop(host.phase == .active ? "Сеанс завершён." : nil)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.large)
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
            return ("person.crop.circle.badge.questionmark", "Запрос на удалённый доступ", "Если вы ждёте это подключение, разрешите просмотр экрана и управление этим Mac.")
        case .starting:
            return ("display", "Настройка сеанса", "Подождите несколько секунд.")
        case .active:
            return ("record.circle", "Доступ открыт", "Другой участник видит основной экран и может управлять мышью и клавиатурой.")
        }
    }
}
