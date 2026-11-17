import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var available = false
    @Published private(set) var message = "Checking startup settings…"
    var hostRefresh: (() -> Void)?
    var hostSet: ((Bool) -> Void)?
    private let usesHost = ProcessInfo.processInfo.arguments.contains("--electron-bridge")

    func refresh() {
        if AppLaunch.isPreview {
            receive(enabled: false, available: false, message: "Startup settings are disabled in Preview.")
        } else if usesHost {
            hostRefresh?()
        } else {
            let status = SMAppService.mainApp.status
            receive(enabled: status == .enabled || status == .requiresApproval,
                    available: Bundle.main.bundleURL.pathExtension == "app",
                    message: status == .requiresApproval ? "Allow Savenest in System Settings → General → Login Items." : "Open Savenest automatically when you log in to your Mac.")
        }
    }

    func setEnabled(_ value: Bool) {
        guard available, !AppLaunch.isPreview else { return }
        if usesHost { available = false; hostSet?(value); return }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            message = "Could not change startup settings: \(error.localizedDescription)"
        }
    }

    func receive(enabled: Bool, available: Bool, message: String) {
        self.enabled = enabled
        self.available = available
        self.message = message
    }
}

struct LaunchAtLoginSettingsView: View {
    @ObservedObject var controller: LaunchAtLogin
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("STARTUP")
            Toggle("Launch at login", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
                .disabled(!controller.available)
            Text(controller.message).font(.system(size: 11)).foregroundStyle(Color.muted)
            Button("Open Login Items settings ↗") { SMAppService.openSystemSettingsLoginItems() }
                .buttonStyle(.link).font(.system(size: 11))
        }.padding(20).nestSurface()
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refresh() }
    }
}
