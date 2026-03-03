import SwiftUI
import Observation

@main
struct CodexAccountSwitcherApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: appState)
                .frame(minWidth: 340)
                .padding(.vertical, 8)
                .task {
                    await appState.refreshUsageForAllProfiles()
                }
        } label: {
            MenuBarStatusIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary, lineWidth: 1.6)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .black))
        }
        .frame(width: 18, height: 18)
    }
}

struct MenuContentView: View {
    @Bindable var appState: AppState
    @State private var showRestartHint = false
    @State private var isCodexRunning = ProcessActions.isCodexDesktopRunning()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex Accounts")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                HStack(spacing: 10) {
                    HoverIconButton(
                        systemImage: "arrow.clockwise",
                        helpText: "Refresh usage",
                        isLoading: appState.isRefreshingUsage,
                        isDisabled: appState.isRefreshingUsage
                    ) {
                        Task { await appState.refreshUsageForAllProfiles() }
                    }
                }
            }

            if appState.sortedProfiles.isEmpty {
                Text("No saved accounts yet. Use Add Account below.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(appState.sortedProfiles) { profile in
                    profileMenuRow(profile)
                    Divider()
                }
            }

            VStack(spacing: 2) {
                MenuActionRowButton(
                    title: isCodexRunning ? "Restart Codex App" : "Start Codex App",
                    systemImage: isCodexRunning ? "arrow.clockwise" : "play.fill"
                ) {
                    _ = ProcessActions.restartCodexDesktopApp()
                    refreshCodexRunningState(afterDelay: 0.8)
                }

                MenuActionRowButton(title: "New CLI Session", systemImage: "terminal") {
                    _ = ProcessActions.openNewCodexCLITerminal()
                }

                Divider()
                    .padding(.vertical, 6)

                MenuActionRowButton(
                    title: appState.isAddingOAuthProfile ? "Adding Account..." : "Add Account",
                    systemImage: "person.badge.plus",
                    isDisabled: appState.isAddingOAuthProfile
                ) {
                    Task { await appState.addProfileViaOAuth() }
                }

                MenuToggleRowButton(
                    title: "Open Automatically at Startup",
                    isOn: appState.openAtLoginEnabled
                ) {
                    appState.setOpenAtLoginEnabled(!appState.openAtLoginEnabled)
                }
            }

            if showRestartHint {
                Text("Restart Codex app and open a new CLI session to apply the new active account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.2), value: showRestartHint)
        .onAppear {
            refreshCodexRunningState()
            appState.refreshOpenAtLoginState()
        }
        .onDisappear {
            showRestartHint = false
        }
    }

    private func refreshCodexRunningState(afterDelay seconds: Double = 0) {
        Task { @MainActor in
            if seconds > 0 {
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            isCodexRunning = ProcessActions.isCodexDesktopRunning()
        }
    }

    @ViewBuilder
    private func profileMenuRow(_ profile: CodexAuthProfile) -> some View {
        let isActive = appState.activeProfileID == profile.id
        let usage = appState.usageByProfileID[profile.id]
        let plan = profile.planType?.trimmedNilIfEmpty ?? usage?.planType?.trimmedNilIfEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 7) {
                    Menu {
                        Button("Remove Account", role: .destructive) {
                            appState.deleteProfile(id: profile.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(profile.displayEmail)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .opacity(isActive ? 1.0 : 0.85)
                                .lineLimit(1)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)

                    if let plan {
                        SubscriptionBadge(plan: plan)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    ActiveAccountButton(
                        isActive: isActive,
                        isDisabled: appState.isSwitching,
                        onActivate: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if appState.setActiveProfile(id: profile.id) {
                                    showRestartHint = true
                                }
                            }
                        }
                    )
                }
            }

            UsageBarsView(usage: usage)
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

private struct ActiveAccountButton: View {
    let isActive: Bool
    let isDisabled: Bool
    let onActivate: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !isActive else { return }
            onActivate()
        } label: {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? .green : .secondary)
                .frame(width: 20, height: 20)
                .scaleEffect(isHovered && !isActive ? 1.08 : 1.0)
                .background(
                    Circle()
                        .fill(isHovered ? Color.secondary.opacity(0.18) : Color.clear)
                        .frame(width: 22, height: 22)
                )
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isActive)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isActive ? "Active account" : "Set as active account")
    }
}

private struct MenuActionRowButton: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(isDisabled ? .tertiary : .secondary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((isHovered && !isDisabled) ? Color.secondary.opacity(0.14) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct MenuToggleRowButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark" : "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.secondary.opacity(0.14) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct HoverIconButton: View {
    let systemImage: String
    let helpText: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 12, height: 12)
                }
            }
                .foregroundStyle(isDisabled ? .tertiary : .secondary)
                .padding(6)
                .background(
                    Circle()
                        .fill(isHovered ? Color.secondary.opacity(0.18) : Color.clear)
                )
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
    }
}

private struct SubscriptionBadge: View {
    let plan: String

    var body: some View {
        Text(plan.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.12), in: Capsule())
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
