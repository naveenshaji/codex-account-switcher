import AppKit
import SwiftUI
import Observation

private let manageWindowIdentifier = NSUserInterfaceItemIdentifier("manage-accounts-window")

@main
struct CodexAccountSwitcherApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Codex", systemImage: "person.2.circle") {
            MenuContentView(appState: appState)
                .frame(minWidth: 340)
                .padding(.vertical, 8)
                .task {
                    await appState.refreshUsageForAllProfiles()
                }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Codex Account Switcher", id: "manage-accounts") {
            ManageAccountsView(appState: appState)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 860, height: 620)
    }
}

struct MenuContentView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex Accounts")
                    .font(.headline)
                Spacer()
                Button("Manage") {
                    openManageWindow()
                }
                .buttonStyle(.link)
            }

            if appState.sortedProfiles.isEmpty {
                Text("No saved accounts yet. Open Manage to add or import one.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(appState.sortedProfiles) { profile in
                    profileMenuRow(profile)
                    Divider()
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await appState.refreshUsageForAllProfiles() }
                } label: {
                    Text(appState.isRefreshingUsage ? "Refreshing..." : "Refresh Usage")
                }
                .disabled(appState.isRefreshingUsage)

                Button("Restart Codex App") {
                    _ = ProcessActions.restartCodexDesktopApp()
                }

                Button("New CLI Session") {
                    _ = ProcessActions.openNewCodexCLITerminal()
                }
            }

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
    }

    private func openManageWindow() {
        openWindow(id: "manage-accounts")
        Task { @MainActor in
            for _ in 0..<12 {
                if let window = NSApp.windows.first(where: { $0.identifier == manageWindowIdentifier }) {
                    window.collectionBehavior.insert(.moveToActiveSpace)
                    window.level = .normal
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    return
                }
                try? await Task.sleep(nanoseconds: 75_000_000)
            }

            NSApplication.shared.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    }

    @ViewBuilder
    private func profileMenuRow(_ profile: CodexAuthProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                    Text(profile.accountID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.activeProfileID == profile.id {
                    Text("Active")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2), in: Capsule())
                } else {
                    Button("Switch") {
                        appState.setActiveProfile(id: profile.id)
                    }
                    .disabled(appState.isSwitching)
                }
            }

            UsageBarsView(usage: appState.usageByProfileID[profile.id])
        }
    }
}

struct ManageAccountsView: View {
    @Bindable var appState: AppState

    @State private var showingAddSheet = false
    @State private var selectedProfileID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Saved Accounts")
                        .font(.headline)
                    Spacer()
                    Button("Add") {
                        showingAddSheet = true
                    }
                }

                List(selection: $selectedProfileID) {
                    ForEach(appState.sortedProfiles) { profile in
                        let isActive = appState.activeProfileID == profile.id
                        AccountRowView(
                            profile: profile,
                            isActive: isActive,
                            usage: appState.usageByProfileID[profile.id]
                        )
                        .tag(profile.id)
                        .contextMenu {
                            if !isActive {
                                Button("Set Active") {
                                    appState.setActiveProfile(id: profile.id)
                                }
                            }
                            Button("Delete", role: .destructive) {
                                appState.deleteProfile(id: profile.id)
                            }
                        }
                    }
                }
                .frame(minWidth: 420)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Actions")
                    .font(.headline)

                Button(appState.isAddingOAuthProfile ? "Waiting for OAuth login..." : "Add account via ChatGPT OAuth") {
                    Task {
                        await appState.addProfileViaOAuth()
                    }
                }
                .disabled(appState.isAddingOAuthProfile)

                Button("Import current ~/.codex/auth.json") {
                    appState.importCurrentAuthAsProfile()
                }

                Button(appState.isRefreshingUsage ? "Refreshing usage..." : "Refresh usage for all accounts") {
                    Task { await appState.refreshUsageForAllProfiles() }
                }
                .disabled(appState.isRefreshingUsage)

                if let selectedProfileID,
                   appState.profiles.contains(where: { $0.id == selectedProfileID }) {
                    if appState.activeProfileID == selectedProfileID {
                        Text("Selected account is Active")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.2), in: Capsule())
                    } else {
                        Button("Set selected account active") {
                            appState.setActiveProfile(id: selectedProfileID)
                        }
                    }

                    Button("Delete selected account", role: .destructive) {
                        appState.deleteProfile(id: selectedProfileID)
                    }
                }

                Divider()

                Button("Restart Codex desktop app") {
                    _ = ProcessActions.restartCodexDesktopApp()
                }

                Button("Open new Codex CLI terminal") {
                    _ = ProcessActions.openNewCodexCLITerminal()
                }

                Divider()

                Text("Switching accounts updates `~/.codex/auth.json`. Start a new CLI session and restart Codex app to use the switched account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                if let error = appState.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(minWidth: 320)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddProfileSheet { profile in
                appState.addProfile(profile)
            }
        }
        .background(WindowAccessor { window in
            window.identifier = manageWindowIdentifier
            window.collectionBehavior.insert(.moveToActiveSpace)
        })
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

struct AccountRowView: View {
    let profile: CodexAuthProfile
    let isActive: Bool
    let usage: UsageSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.body.weight(.semibold))
                    Text(profile.accountID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.2), in: Capsule())
                }
            }

            if let plan = profile.planType?.trimmedNilIfEmpty ?? usage?.planType?.trimmedNilIfEmpty {
                Text(plan.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            UsageBarsView(usage: usage)
        }
        .padding(.vertical, 4)
    }
}

struct UsageBarsView: View {
    let usage: UsageSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            usageRow(title: "5h", window: usage?.fiveHourWindow)
            usageRow(title: "Weekly", window: usage?.weeklyWindow)
        }
    }

    @ViewBuilder
    private func usageRow(title: String, window: UsageWindow?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            if let window {
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let fill = width * (window.normalizedRemainingPercent / 100)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(barColor(forRemaining: window.normalizedRemainingPercent))
                            .frame(width: fill)
                    }
                }
                .frame(height: 9)

                Text("\(Int(window.normalizedRemainingPercent.rounded()))% left")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)

                Text(resetText(for: window))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 18)
    }

    private func barColor(forRemaining percent: Double) -> Color {
        switch percent {
        case ..<20:
            return .red
        case ..<40:
            return .yellow
        default:
            return .green
        }
    }

    private func resetText(for window: UsageWindow) -> String {
        guard let resetsAt = window.resetsAt else {
            return ""
        }

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return "resets \(relative.localizedString(for: resetsAt, relativeTo: Date()))"
    }
}

struct AddProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var planType = ""
    @State private var accountID = ""
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var idToken = ""

    let onSave: (CodexAuthProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account")
                .font(.headline)

            Group {
                TextField("Display name", text: $name)
                TextField("Email (optional)", text: $email)
                TextField("Plan type (optional, e.g. plus/pro/team)", text: $planType)
                TextField("ChatGPT Account ID", text: $accountID)
            }

            Group {
                SecureField("Access token", text: $accessToken)
                SecureField("Refresh token (optional)", text: $refreshToken)
                SecureField("ID token (optional)", text: $idToken)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    let profile = CodexAuthProfile(
                        name: name,
                        email: email,
                        planType: planType,
                        accountID: accountID,
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        idToken: idToken
                    )
                    onSave(profile)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
