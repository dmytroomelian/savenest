import AppKit
import SwiftUI

struct AutomationSettingsView: View {
    @ObservedObject var controller: AutomationController
    @ObservedObject var account: AccountController
    @State private var selectedClientID: String?
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text("AI connections").font(.system(size: 20, weight: .semibold))
                    Text("PRO").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.sage)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.sage.opacity(0.1), in: Capsule())
                }
                Text("Your saved links, ready for your AI.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(AutomationClientKind.allCases, id: \.rawValue) { kind in connectionCard(kind) }
            }
            if let message = controller.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Text(controller.adapterURL == nil ? "Coming soon with Pro." : "Connect to share saved links and notes.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted)
                Spacer()
                Button("How it works") { showingDetails = true }.buttonStyle(.link).font(.system(size: 11))
            }
        }
        .sheet(isPresented: Binding(get: { selectedClientID != nil }, set: { if !$0 { selectedClientID = nil } })) {
            if let id = selectedClientID, controller.clients.contains(where: { $0.id == id }) {
                AutomationConnectionDetails(controller: controller, clientID: id) { selectedClientID = nil }
            }
        }
        .sheet(isPresented: $showingDetails) { information }
    }

    private func connectionCard(_ kind: AutomationClientKind) -> some View {
        let client = controller.connection(for: kind)
        let configured = client?.configuredAt != nil && client?.userID == account.account?.user.id
        let connecting = controller.connectingClient == kind
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: symbol(kind)).font(.system(size: 21, weight: .medium))
                    .foregroundStyle(kind == .codex ? Color.ink : Color(red: 0.72, green: 0.39, blue: 0.27))
                    .frame(width: 40, height: 40)
                    .background(Color.line.opacity(0.28), in: RoundedRectangle(cornerRadius: 11))
                Text(kind.rawValue).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(description(kind)).font(.system(size: 12)).foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let client, configured {
                    Label(controller.enabled ? (controller.activeClients.contains(client.id) ? "Connected" : "Ready") : "Paused",
                          systemImage: controller.enabled ? "checkmark.circle.fill" : "pause.circle")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted)
                    Spacer(minLength: 0)
                    Button("Manage") { selectedClientID = client.id }.buttonStyle(QuietButton())
                } else {
                    Button(connecting ? "Connecting…" : "Connect") { Task { await controller.connect(kind) } }
                        .buttonStyle(SageButton())
                        .disabled(controller.connectingClient != nil || controller.adapterURL == nil)
                        .accessibilityLabel("Connect \(kind.rawValue)")
                    Spacer(minLength: 0)
                    if let client {
                        Button { selectedClientID = client.id } label: { Image(systemName: "ellipsis") }
                            .buttonStyle(.plain).help("Manage connection")
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).nestSurface()
    }

    private func symbol(_ kind: AutomationClientKind) -> String {
        switch kind { case .codex: "terminal"; case .claudeDesktop: "sun.max"; case .claudeCode: "chevron.left.forwardslash.chevron.right" }
    }
    private func description(_ kind: AutomationClientKind) -> String {
        switch kind {
        case .codex: "Bring saved research into Codex."
        case .claudeDesktop: "Find and use your links in Claude."
        case .claudeCode: "Keep research close while you code."
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("About AI connections").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { showingDetails = false }.buttonStyle(QuietButton())
            }
            Text("Connect once. SaveNest sets up the app for you with read-only access to your saved links and quick notes. Use Manage to allow more actions or disconnect.")
            Text("Selected link details and notes reach your AI provider. Article text and external Obsidian files stay out of this connection.")
            Text("Keep SaveNest running on this Mac. Pro is verified online. Browser actions need macOS permission, and AI-client costs are separate.")
            if !controller.clients.isEmpty {
                Toggle("Allow AI connections", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
                ForEach(controller.clients) { client in
                    HStack {
                        Text(client.name)
                        Spacer()
                        Button("Disconnect") { controller.revoke(client) }.buttonStyle(.link)
                    }
                }
            }
            Link("Full guide ↗", destination: URL(string: "https://github.com/dmytroomelian/savenest/blob/main/docs/mcp.md")!)
        }
        .font(.system(size: 12)).foregroundStyle(Color.muted)
        .padding(26).frame(width: 480).background(Color.paper).nestAppearance()
    }
}

private struct AutomationConnectionDetails: View {
    @ObservedObject var controller: AutomationController
    let clientID: String
    var done: () -> Void
    @State private var showAdvanced = false
    @State private var showActivity = false
    @State private var copied = false

    var body: some View {
        if let client = controller.clients.first(where: { $0.id == clientID }) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(client.name).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Done", action: done).buttonStyle(QuietButton())
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("What this app can do").font(.system(size: 13, weight: .semibold))
                        ForEach(AutomationPermission.allCases) { permission in
                            Toggle(permission.title, isOn: Binding(get: {
                                controller.clients.first(where: { $0.id == clientID })?.permissions.contains(permission) == true
                            }, set: { controller.setPermission(permission, allowed: $0, clientID: clientID) }))
                        }
                        Text("Closing tabs may lose unsaved work. History and closing stay off until you enable them.")
                            .font(.system(size: 11)).foregroundStyle(Color.muted)
                        if !controller.enabled {
                            Button("Resume connections") { controller.setEnabled(true) }.buttonStyle(QuietButton())
                        }
                        DisclosureGroup("Advanced setup", isExpanded: $showAdvanced) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Saving needs library reading. Save-and-close also needs tab reading and saving. Enable history in SaveNest before allowing it here.")
                                HStack {
                                    Button(copied ? "Copied" : "Copy configuration") {
                                        if let text = controller.configuration(client, format: client.name) {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(text, forType: .string); copied = true
                                        }
                                    }.disabled(controller.adapterURL == nil)
                                    Button("Test access") { Task { await controller.testConnection(client) } }
                                }
                                if let kind = AutomationClientKind(rawValue: client.name) {
                                    Button("Repair setup") { Task { await controller.connect(kind) } }
                                        .disabled(controller.connectingClient != nil || controller.adapterURL == nil)
                                }
                            }.font(.system(size: 11)).foregroundStyle(Color.muted).padding(.top, 8)
                        }
                        DisclosureGroup("Recent actions", isExpanded: $showActivity) {
                            VStack(alignment: .leading, spacing: 7) {
                                let actions = controller.activity.filter { $0.hasPrefix(client.name + " ·") }
                                if actions.isEmpty { Text("No actions this session.") }
                                ForEach(Array(actions.enumerated()), id: \.offset) { _, value in Text(value) }
                            }.font(.system(size: 11)).foregroundStyle(Color.muted).padding(.top, 8)
                        }
                        if let message = controller.message {
                            Text(message).font(.system(size: 11)).foregroundStyle(Color.muted).textSelection(.enabled)
                        }
                    }.padding(.trailing, 8)
                }
                Button("Disconnect", role: .destructive) { controller.revoke(client); done() }.buttonStyle(.link)
            }
            .font(.system(size: 12)).padding(26).frame(width: 480, height: 530)
            .background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
        }
    }
}
