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
    @State private var hoverLocation: CGPoint?

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
    }

    var body: some View {
        GeometryReader { geo in
            let renderedBars = renderedBars(in: geo.size)
            let hovered = hoveredBar(at: hoverLocation, in: renderedBars, size: geo.size)
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
                                color = .green
                            case .gap:
                                color = .secondary.opacity(0.35)
                            case .prediction:
                                color = .green.opacity(0.5)
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
                        let step = geo.size.width / CGFloat(count)
                        let boundaryX = CGFloat(predictionStartIndex) * step
                        Path { path in
                            path.move(to: CGPoint(x: boundaryX, y: 0))
                            path.addLine(to: CGPoint(x: boundaryX, y: geo.size.height))
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
                    Path { path in
                        path.move(to: CGPoint(x: hovered.x, y: 0))
                        path.addLine(to: CGPoint(x: hovered.x, y: geo.size.height))
                    }
                    .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    GraphTooltipView(
                        title: hoveredTitle(for: hovered.bar),
                        timestamp: hovered.bar.timestamp
                    )
                    .position(x: tooltipX(for: hovered.x, width: geo.size.width), y: 8)
                }
            }
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
        }
    }

    private func renderedBars(in size: CGSize) -> [RenderedBar] {
        let totalCount = idealBarCount(for: size.width)
        guard totalCount > 0 else { return [] }

        let forecastCount = max(4, min(18, Int(Double(totalCount) * 0.18)))
        let historicalCount = max(totalCount - forecastCount, 1)

        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        let totalDuration = max(range.duration, 1)
        let forecastDuration = predictionHorizon(for: range)
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

        if sampledByIndex.isEmpty {
            return (0..<totalCount).map { index in
                if index < historicalCount {
                    let timestamp = start.addingTimeInterval((Double(index) + 0.5) * totalDuration / Double(historicalCount))
                    return RenderedBar(id: index, timestamp: timestamp, remainingPercent: nil, kind: .empty, isResetPoint: false)
                } else {
                    let forecastIndex = index - historicalCount
                    let timestamp = end.addingTimeInterval((Double(forecastIndex) + 1) * forecastDuration / Double(max(forecastCount, 1)))
                    return RenderedBar(id: index, timestamp: timestamp, remainingPercent: nil, kind: .empty, isResetPoint: false)
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
                    isResetPoint: sample.isResetPoint
                )
            }

            guard
                let leftIndex = nearestLeft[index],
                let rightIndex = nearestRight[index],
                leftIndex != rightIndex,
                let leftSample = sampledByIndex[leftIndex],
                let rightSample = sampledByIndex[rightIndex]
            else {
                return RenderedBar(id: index, timestamp: timestamp, remainingPercent: nil, kind: .empty, isResetPoint: false)
            }

            let distance = Double(rightIndex - leftIndex)
            let progress = distance > 0 ? Double(index - leftIndex) / distance : 0
            let interpolated = leftSample.remainingPercent + (rightSample.remainingPercent - leftSample.remainingPercent) * progress
            return RenderedBar(
                id: index,
                timestamp: timestamp,
                remainingPercent: min(max(interpolated, 0), 100),
                kind: .gap,
                isResetPoint: false
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
                    isResetPoint: false
                )
            }

            let dt = timestamp.timeIntervalSince(predictionModel.anchorTimestamp)
            let projected = predictionModel.anchorRemaining + (predictionModel.slopePerSecond * dt)
            return RenderedBar(
                id: absoluteIndex,
                timestamp: timestamp,
                remainingPercent: min(max(projected, 0), 100),
                kind: .prediction,
                isResetPoint: false
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
            return "Predicted \(Int((bar.remainingPercent ?? 0).rounded()))%"
        }
        let percent = "\(Int((bar.remainingPercent ?? 0).rounded()))%"
        return bar.isResetPoint ? "Reset detected • \(percent)" : percent
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
            return 15 * 60
        case .h5:
            return 45 * 60
        case .h12:
            return 90 * 60
        case .h24:
            return 3 * 60 * 60
        case .d7:
            return 12 * 60 * 60
        case .d30:
            return 24 * 60 * 60
        }
    }

    private func tooltipX(for x: CGFloat, width: CGFloat) -> CGFloat {
        let minX: CGFloat = 52
        let maxX = max(width - 52, minX)
        return min(max(x, minX), maxX)
    }
}

private struct GraphTooltipView: View {
    let title: String
    let timestamp: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
            Text(timeString(from: timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
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
