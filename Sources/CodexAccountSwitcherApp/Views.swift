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
    @State private var showRestartHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex Accounts")
                    .font(.headline)
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        Task { await appState.refreshUsageForAllProfiles() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh usage")
                    .disabled(appState.isRefreshingUsage)

                    Button {
                        openManageWindow()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Manage accounts")
                }
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
                Button("Restart Codex App") {
                    _ = ProcessActions.restartCodexDesktopApp()
                }

                Button("New CLI Session") {
                    _ = ProcessActions.openNewCodexCLITerminal()
                }
            }

            if showRestartHint {
                Text("Restart Codex app and open a new CLI session to apply the new active account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .onDisappear {
            showRestartHint = false
        }
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
        let isActive = appState.activeProfileID == profile.id

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.displayEmail)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                ActiveAccountButton(
                    isActive: isActive,
                    isDisabled: appState.isSwitching,
                    onActivate: {
                        if appState.setActiveProfile(id: profile.id) {
                            showRestartHint = true
                        }
                    }
                )
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
                        AccountRowView(
                            profile: profile,
                            isActive: appState.activeProfileID == profile.id,
                            usage: appState.usageByProfileID[profile.id],
                            onSetActive: {
                                _ = appState.setActiveProfile(id: profile.id)
                            }
                        )
                        .tag(profile.id)
                        .contextMenu {
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
    let onSetActive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.displayEmail)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                ActiveAccountButton(
                    isActive: isActive,
                    isDisabled: false,
                    onActivate: onSetActive
                )
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

private struct ActiveAccountButton: View {
    let isActive: Bool
    let isDisabled: Bool
    let onActivate: () -> Void

    var body: some View {
        Button {
            guard !isActive else { return }
            onActivate()
        } label: {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? .green : .secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isActive)
        .help(isActive ? "Active account" : "Set as active account")
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
                SegmentedUsageBar(
                    percent: window.normalizedRemainingPercent,
                    color: barColor(forRemaining: window.normalizedRemainingPercent)
                )
                .frame(height: 12)

                Text("\(Int(window.normalizedRemainingPercent.rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)

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

        let interval = max(0, resetsAt.timeIntervalSinceNow)
        if interval < 60 {
            return "1m"
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: interval) ?? ""
    }
}

private struct SegmentedUsageBar: View {
    let percent: Double
    let color: Color

    private let segments = 20

    private var filledSegments: Int {
        let clamped = min(max(percent, 0), 100)
        return Int((clamped / 5).rounded())
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index < filledSegments ? color : .secondary.opacity(0.16))
            }
        }
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
