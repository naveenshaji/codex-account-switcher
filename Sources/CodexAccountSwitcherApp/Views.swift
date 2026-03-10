import SwiftUI
import Observation

@main
struct CodexAccountSwitcherApp: App {
    @State private var appState = AppState()
    @State private var updaterManager = UpdaterManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: appState, updaterManager: updaterManager)
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
    @Bindable var updaterManager: UpdaterManager
    @State private var showRestartHint = false
    @State private var isCodexRunning = ProcessActions.isCodexDesktopRunning()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex Accounts")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                HStack(spacing: 10) {
                    if appState.isGraphMode {
                        GraphMetricToggle(selection: $appState.selectedGraphMetric)
                            .frame(width: 74)

                        Picker("Range", selection: $appState.selectedHistoryRange) {
                            ForEach(UsageHistoryRange.allCases) { range in
                                Text(range.label).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 62)
                    }

                    HoverIconButton(
                        systemImage: "chart.xyaxis.line",
                        helpText: appState.isGraphMode ? "Show usage bars" : "Show history graph",
                        isSelected: appState.isGraphMode
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.isGraphMode.toggle()
                        }
                    }

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

            if appState.shouldShowOnboarding {
                FirstRunOnboardingCard(
                    isAddingAccount: appState.isAddingOAuthProfile,
                    onAddAccount: {
                        Task {
                            _ = await appState.addProfileViaOAuth()
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.dismissOnboarding()
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if appState.sortedProfiles.isEmpty {
                if !appState.shouldShowOnboarding {
                    Text("No saved accounts yet. Use Add Account below.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
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

                if updaterManager.isAvailable {
                    Divider()
                        .padding(.vertical, 6)

                    MenuToggleRowButton(
                        title: "Check for Updates Automatically",
                        isOn: updaterManager.automaticallyChecksForUpdates
                    ) {
                        updaterManager.setAutomaticallyChecksForUpdates(!updaterManager.automaticallyChecksForUpdates)
                    }

                    if updaterManager.allowsAutomaticUpdates {
                        MenuToggleRowButton(
                            title: "Install Updates Automatically",
                            isOn: updaterManager.automaticallyDownloadsUpdates,
                            isDisabled: !updaterManager.automaticallyChecksForUpdates
                        ) {
                            updaterManager.setAutomaticallyDownloadsUpdates(!updaterManager.automaticallyDownloadsUpdates)
                        }
                    }

                    MenuActionRowButton(
                        title: "Check for Updates...",
                        systemImage: "arrow.down.circle",
                        isDisabled: !updaterManager.canCheckForUpdates
                    ) {
                        updaterManager.checkForUpdates()
                    }
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
            updaterManager.refreshState()
        }
        .onDisappear {
            showRestartHint = false
            appState.clearTransientErrors()
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
        let history = appState.historySeries(for: profile.id, metric: appState.selectedGraphMetric)
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

            AccountUsageDetailView(
                usage: usage,
                history: history,
                isGraphMode: appState.isGraphMode,
                historyRange: appState.selectedHistoryRange
            )

            if let actionError = appState.actionErrorByProfileID[profile.id] {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let usageError = appState.usageErrorByProfileID[profile.id] {
                Text(usageError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
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
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark" : "minus")
                    .font(.system(size: 11, weight: .semibold))
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

private struct FirstRunOnboardingCard: View {
    let isAddingAccount: Bool
    let onAddAccount: () -> Void
    let onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome")
                .font(.subheadline.weight(.semibold))

            Text("Add your accounts, switch the active one from the list, then restart Codex or open a new CLI session when you change accounts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: onAddAccount) {
                    HStack(spacing: 6) {
                        Image(systemName: isAddingAccount ? "hourglass" : "person.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isAddingAccount ? "Connecting..." : "Add First Account")
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.accentColor.opacity(0.18))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAddingAccount)

                Button("Skip") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(isHovered ? 0.14 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct HoverIconButton: View {
    let systemImage: String
    let helpText: String
    var isLoading = false
    var isSelected = false
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
                        .fill((isHovered || isSelected) ? Color.secondary.opacity(isSelected ? 0.24 : 0.18) : Color.clear)
                )
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
    }
}

private struct GraphMetricToggle: View {
    @Binding var selection: UsageGraphMetric
    @State private var hoveredMetric: UsageGraphMetric?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageGraphMetric.allCases) { metric in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = metric
                    }
                } label: {
                    Text(metric.label)
                        .font(.caption2.weight(selection == metric ? .semibold : .regular))
                        .foregroundStyle(selection == metric ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    selection == metric
                                    ? Color.secondary.opacity(0.24)
                                    : (hoveredMetric == metric ? Color.secondary.opacity(0.12) : Color.clear)
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredMetric = isHovering ? metric : nil
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
        .help("Graph metric")
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

private struct AccountUsageDetailView: View {
    let usage: UsageSnapshot?
    let history: [UsageSeriesPoint]
    let isGraphMode: Bool
    let historyRange: UsageHistoryRange

    var body: some View {
        ZStack {
            if isGraphMode {
                UsageHistoryGraphView(points: history, range: historyRange)
                    .padding(.bottom, -10)
                    .transition(.opacity)
            } else {
                UsageBarsView(usage: usage)
                    .transition(.opacity)
            }
        }
        .frame(height: 42)
        .animation(.easeInOut(duration: 0.18), value: isGraphMode)
    }
}

private struct UsageHistoryGraphView: View {
    let points: [UsageSeriesPoint]
    let range: UsageHistoryRange
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverLocation: CGPoint?
    @State private var didInitialAutoScroll = false

    private enum BarKind {
        case actual
        case gap
        case prediction
        case empty
    }

    private struct RenderedBar: Identifiable {
        let id: Int
        let timestamp: Date
        let remainingPercent: Double?
        let kind: BarKind
        let isResetPoint: Bool
        let predictedLimitDate: Date?
    }

    var body: some View {
        GeometryReader { geo in
            let viewportSize = geo.size
            let graphContentWidth = max(viewportSize.width, viewportSize.width * 1.9)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    let renderSize = CGSize(width: graphContentWidth, height: viewportSize.height)
                    let renderedBars = renderedBars(in: renderSize)
                    let hovered = hoveredBar(at: hoverLocation, in: renderedBars, size: renderSize)
                    let predictionStartIndex = renderedBars.firstIndex(where: { $0.kind == .prediction })

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.secondary.opacity(0.08))

                        if renderedBars.contains(where: { $0.kind != .empty }) {
                            Canvas { context, size in
                                let count = max(renderedBars.count, 1)
                                let step = size.width / CGFloat(count)
                                let barWidth = max(1, min(2, step * 0.55))
                                let topPadding: CGFloat = 2
                                let bottomPadding: CGFloat = 0
                                let drawableHeight = max(size.height - topPadding - bottomPadding, 1)

                                for (index, bar) in renderedBars.enumerated() {
                                    guard bar.kind != .empty, let remainingPercent = bar.remainingPercent else {
                                        continue
                                    }

                                    let ratio = CGFloat(min(max(remainingPercent, 0), 100) / 100)
                                    let barHeight = max(1, ratio * drawableHeight)
                                    let x = (CGFloat(index) + 0.5) * step
                                    let y = topPadding + (drawableHeight - barHeight)
                                    let rect = CGRect(x: x - (barWidth / 2), y: y, width: barWidth, height: barHeight)
                                    let color: Color
                                    switch bar.kind {
                                    case .actual:
                                        color = usageColor(forRemaining: remainingPercent)
                                    case .gap:
                                        color = .secondary.opacity(0.35)
                                    case .prediction:
                                        color = usageColor(forRemaining: remainingPercent).opacity(0.55)
                                    case .empty:
                                        color = .clear
                                    }
                                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))

                                    if bar.kind == .actual && bar.isResetPoint {
                                        let markerWidth = max(3, barWidth + 1)
                                        let markerRect = CGRect(
                                            x: x - (markerWidth / 2),
                                            y: max(1, y - 2),
                                            width: markerWidth,
                                            height: 2
                                        )
                                        context.fill(
                                            Path(roundedRect: markerRect, cornerRadius: 1),
                                            with: .color(.orange.opacity(0.95))
                                        )
                                    }
                                }
                            }

                            if let predictionStartIndex {
                                let count = max(renderedBars.count, 1)
                                let step = renderSize.width / CGFloat(count)
                                let boundaryX = CGFloat(predictionStartIndex) * step
                                Path { path in
                                    path.move(to: CGPoint(x: boundaryX, y: 0))
                                    path.addLine(to: CGPoint(x: boundaryX, y: renderSize.height))
                                }
                                .stroke(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            }
                        } else {
                            Text("Collecting history…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }

                        if let hovered {
                            let title = hoveredTitle(for: hovered.bar)
                            let timestampText = tooltipTimeString(from: hovered.bar.timestamp)
                            let tooltipWidth = min(
                                tooltipWidth(forTitle: title, timestampText: timestampText),
                                max(96, renderSize.width - 8)
                            )
                            let tooltipHeight: CGFloat = 24
                            Path { path in
                                path.move(to: CGPoint(x: hovered.x, y: 0))
                                path.addLine(to: CGPoint(x: hovered.x, y: renderSize.height))
                            }
                            .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                            GraphTooltipView(
                                title: title,
                                timestampText: timestampText
                            )
                            .frame(width: tooltipWidth)
                            .position(
                                x: tooltipX(for: hovered.x, width: renderSize.width, tooltipWidth: tooltipWidth),
                                y: tooltipY(height: renderSize.height, tooltipHeight: tooltipHeight)
                            )
                        }
                    }
                    .frame(width: renderSize.width, height: renderSize.height)
                    .clipShape(Rectangle())
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverLocation = location
                        case .ended:
                            hoverLocation = nil
                        }
                    }
                    .id("history-graph-content")
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    guard !didInitialAutoScroll else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("history-graph-content", anchor: .trailing)
                        didInitialAutoScroll = true
                    }
                }
                .onChange(of: range) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("history-graph-content", anchor: .trailing)
                    }
                }
            }
        }
    }

    private func renderedBars(in size: CGSize) -> [RenderedBar] {
        let totalCount = idealBarCount(for: size.width)
        guard totalCount > 0 else { return [] }

        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        let totalDuration = max(range.duration, 1)
        let forecastDuration = predictionHorizon(for: range)
        let combinedDuration = totalDuration + forecastDuration

        var forecastCount = Int(round(Double(totalCount) * (forecastDuration / combinedDuration)))
        forecastCount = max(2, min(forecastCount, totalCount - 1))
        let historicalCount = max(totalCount - forecastCount, 1)
        let sortedPoints = points.sorted(by: { $0.timestamp < $1.timestamp })

        var sampledByIndex: [Int: UsageSeriesPoint] = [:]
        for sample in sortedPoints {
            guard sample.timestamp >= start, sample.timestamp <= end else { continue }
            let progress = sample.timestamp.timeIntervalSince(start) / totalDuration
            var index = Int(floor(progress * Double(historicalCount)))
            index = min(max(index, 0), historicalCount - 1)
            if let existing = sampledByIndex[index] {
                if sample.timestamp > existing.timestamp {
                    sampledByIndex[index] = sample
                }
            } else {
                sampledByIndex[index] = sample
            }
        }

        let actualHistoricalPoints = sampledByIndex.values.sorted(by: { $0.timestamp < $1.timestamp })
        let predictionModel = predictionModel(from: actualHistoricalPoints)
        let predictedLimitDate = computePredictedLimitDate(from: predictionModel)

        if sampledByIndex.isEmpty {
            return (0..<totalCount).map { index in
                if index < historicalCount {
                    let timestamp = start.addingTimeInterval((Double(index) + 0.5) * totalDuration / Double(historicalCount))
                    return RenderedBar(
                        id: index,
                        timestamp: timestamp,
                        remainingPercent: nil,
                        kind: .empty,
                        isResetPoint: false,
                        predictedLimitDate: nil
                    )
                } else {
                    let forecastIndex = index - historicalCount
                    let timestamp = end.addingTimeInterval((Double(forecastIndex) + 1) * forecastDuration / Double(max(forecastCount, 1)))
                    return RenderedBar(
                        id: index,
                        timestamp: timestamp,
                        remainingPercent: nil,
                        kind: .empty,
                        isResetPoint: false,
                        predictedLimitDate: nil
                    )
                }
            }
        }

        var nearestLeft: [Int?] = Array(repeating: nil, count: historicalCount)
        var lastSeen: Int?
        for index in 0..<historicalCount {
            if sampledByIndex[index] != nil {
                lastSeen = index
            }
            nearestLeft[index] = lastSeen
        }

        var nearestRight: [Int?] = Array(repeating: nil, count: historicalCount)
        var nextSeen: Int?
        for index in stride(from: historicalCount - 1, through: 0, by: -1) {
            if sampledByIndex[index] != nil {
                nextSeen = index
            }
            nearestRight[index] = nextSeen
        }

        let historicalBars: [RenderedBar] = (0..<historicalCount).map { index in
            let timestamp = start.addingTimeInterval((Double(index) + 0.5) * totalDuration / Double(historicalCount))

            if let sample = sampledByIndex[index] {
                return RenderedBar(
                    id: index,
                    timestamp: sample.timestamp,
                    remainingPercent: min(max(sample.remainingPercent, 0), 100),
                    kind: .actual,
                    isResetPoint: sample.isResetPoint,
                    predictedLimitDate: nil
                )
            }

            guard
                let leftIndex = nearestLeft[index],
                let rightIndex = nearestRight[index],
                leftIndex != rightIndex,
                let leftSample = sampledByIndex[leftIndex],
                let rightSample = sampledByIndex[rightIndex]
            else {
                return RenderedBar(
                    id: index,
                    timestamp: timestamp,
                    remainingPercent: nil,
                    kind: .empty,
                    isResetPoint: false,
                    predictedLimitDate: nil
                )
            }

            let distance = Double(rightIndex - leftIndex)
            let progress = distance > 0 ? Double(index - leftIndex) / distance : 0
            let interpolated = leftSample.remainingPercent + (rightSample.remainingPercent - leftSample.remainingPercent) * progress
            return RenderedBar(
                id: index,
                timestamp: timestamp,
                remainingPercent: min(max(interpolated, 0), 100),
                kind: .gap,
                isResetPoint: false,
                predictedLimitDate: nil
            )
        }

        let forecastBars: [RenderedBar] = (0..<forecastCount).map { forecastIndex in
            let absoluteIndex = historicalCount + forecastIndex
            let timestamp = end.addingTimeInterval((Double(forecastIndex) + 1) * forecastDuration / Double(max(forecastCount, 1)))

            guard let predictionModel else {
                return RenderedBar(
                    id: absoluteIndex,
                    timestamp: timestamp,
                    remainingPercent: nil,
                    kind: .empty,
                    isResetPoint: false,
                    predictedLimitDate: nil
                )
            }

            let dt = timestamp.timeIntervalSince(predictionModel.anchorTimestamp)
            let projected = predictionModel.anchorRemaining + (predictionModel.slopePerSecond * dt)
            return RenderedBar(
                id: absoluteIndex,
                timestamp: timestamp,
                remainingPercent: min(max(projected, 0), 100),
                kind: .prediction,
                isResetPoint: false,
                predictedLimitDate: predictedLimitDate
            )
        }

        return historicalBars + forecastBars
    }

    private func hoveredBar(
        at location: CGPoint?,
        in bars: [RenderedBar],
        size: CGSize
    ) -> (bar: RenderedBar, x: CGFloat)? {
        guard let location, !bars.isEmpty else { return nil }
        let step = size.width / CGFloat(max(bars.count, 1))
        guard step > 0 else { return nil }
        let index = min(max(Int(floor(location.x / step)), 0), bars.count - 1)
        let bar = bars[index]
        guard bar.kind != .empty else { return nil }
        let x = (CGFloat(index) + 0.5) * step
        return (bar, x)
    }

    private func idealBarCount(for width: CGFloat) -> Int {
        let estimate = Int(floor(width / 4.0))
        return min(max(estimate, 24), 110)
    }

    private func hoveredTitle(for bar: RenderedBar) -> String {
        if bar.kind == .gap {
            return "No data"
        }
        if bar.kind == .prediction {
            let predicted = "Predicted \(Int((bar.remainingPercent ?? 0).rounded()))%"
            if let predictedLimitDate = bar.predictedLimitDate,
               let eta = shortEta(to: predictedLimitDate, from: Date()) {
                return "\(predicted) • 0% in \(eta)"
            }
            return predicted
        }
        let percent = "\(Int((bar.remainingPercent ?? 0).rounded()))%"
        return bar.isResetPoint ? "Reset detected • \(percent)" : percent
    }

    private func usageColor(forRemaining remaining: Double) -> Color {
        if colorScheme == .dark {
            switch remaining {
            case ..<20:
                return Color(red: 1.0, green: 0.33, blue: 0.33)
            case ..<40:
                return Color(red: 0.97, green: 0.79, blue: 0.20)
            default:
                return Color(red: 0.24, green: 0.86, blue: 0.46)
            }
        }

        switch remaining {
        case ..<20:
            return Color(red: 0.78, green: 0.16, blue: 0.16)
        case ..<40:
            return Color(red: 0.75, green: 0.52, blue: 0.02)
        default:
            return Color(red: 0.08, green: 0.56, blue: 0.24)
        }
    }

    private struct PredictionModel {
        let anchorTimestamp: Date
        let anchorRemaining: Double
        let slopePerSecond: Double
    }

    private func predictionModel(from actualPoints: [UsageSeriesPoint]) -> PredictionModel? {
        guard actualPoints.count >= 2, let anchor = actualPoints.last else {
            return nil
        }

        let lookback: TimeInterval
        switch range {
        case .h1, .h5:
            lookback = 90 * 60
        case .h12, .h24:
            lookback = 6 * 60 * 60
        case .d7, .d30:
            lookback = 24 * 60 * 60
        }

        let recent = actualPoints.filter {
            anchor.timestamp.timeIntervalSince($0.timestamp) <= lookback
        }

        guard recent.count >= 2 else {
            return PredictionModel(
                anchorTimestamp: anchor.timestamp,
                anchorRemaining: anchor.remainingPercent,
                slopePerSecond: 0
            )
        }

        var negativeSlopes: [Double] = []
        for index in 1..<recent.count {
            let previous = recent[index - 1]
            let current = recent[index]
            if current.isResetPoint { continue }
            let dt = current.timestamp.timeIntervalSince(previous.timestamp)
            guard dt > 0 else { continue }
            let slope = (current.remainingPercent - previous.remainingPercent) / dt
            if slope < 0 {
                negativeSlopes.append(slope)
            }
        }

        let slopePerSecond: Double
        if negativeSlopes.isEmpty {
            slopePerSecond = 0
        } else {
            let mean = negativeSlopes.reduce(0, +) / Double(negativeSlopes.count)
            let maxDropPerHour = -30.0 / 3600.0
            slopePerSecond = max(mean, maxDropPerHour)
        }

        return PredictionModel(
            anchorTimestamp: anchor.timestamp,
            anchorRemaining: anchor.remainingPercent,
            slopePerSecond: slopePerSecond
        )
    }

    private func predictionHorizon(for range: UsageHistoryRange) -> TimeInterval {
        switch range {
        case .h1:
            return 30 * 60
        case .h5:
            return 2 * 60 * 60
        case .h12:
            return 4 * 60 * 60
        case .h24:
            return 8 * 60 * 60
        case .d7:
            return 2 * 24 * 60 * 60
        case .d30:
            return 7 * 24 * 60 * 60
        }
    }

    private func tooltipX(for x: CGFloat, width: CGFloat, tooltipWidth: CGFloat) -> CGFloat {
        let half = tooltipWidth / 2
        let minX = half + 4
        let maxX = max(width - half - 4, minX)
        return min(max(x, minX), maxX)
    }

    private func tooltipY(height: CGFloat, tooltipHeight: CGFloat) -> CGFloat {
        let minY = (tooltipHeight / 2) + 3
        let maxY = max(height - (tooltipHeight / 2) - 2, minY)
        let preferredY = minY
        return min(preferredY, maxY)
    }

    private func tooltipWidth(forTitle title: String, timestampText: String) -> CGFloat {
        let titleWidth = CGFloat(title.count) * 6.6
        let timeWidth = CGFloat(timestampText.count) * 5.8
        let estimated = titleWidth + timeWidth + 36
        return min(max(estimated, 108), 320)
    }

    private func tooltipTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private func computePredictedLimitDate(from model: PredictionModel?) -> Date? {
        guard let model, model.slopePerSecond < 0, model.anchorRemaining > 0 else {
            return nil
        }
        let secondsToZero = model.anchorRemaining / abs(model.slopePerSecond)
        guard secondsToZero.isFinite, secondsToZero > 0 else {
            return nil
        }
        return model.anchorTimestamp.addingTimeInterval(secondsToZero)
    }

    private func shortEta(to target: Date, from reference: Date) -> String? {
        let interval = target.timeIntervalSince(reference)
        guard interval > 60 else { return "1m" }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: interval)
    }
}

private struct GraphTooltipView: View {
    let title: String
    let timestampText: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
            Text(timestampText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
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
