import AppKit
import SwiftUI
import EmbersCore
import EmbersPluginKit

enum ContextActivityMotionPolicy {
    static func shouldAnimate(isAppOpen: Bool, reduceMotion: Bool) -> Bool {
        isAppOpen && !reduceMotion
    }
}

struct ContextProgressPresentation: Equatable {
    let valueLabel: String
    let fraction: CGFloat

    init(progress: VoiceRoutingCompilationProgress) {
        valueLabel = progress.percentageLabel
        fraction = CGFloat(progress.overallFraction)
    }
}

struct NotchProgressVisualState: Equatable {
    enum Tip: Equatable {
        case ember(progress: CGFloat)
        case success(progress: CGFloat)
    }

    let orangeRange: ClosedRange<CGFloat>?
    let greenRange: ClosedRange<CGFloat>?
    let tip: Tip?

    init(progress: CGFloat, completionSweep: CGFloat) {
        let progress = min(max(progress, 0), 1)
        if progress < 1 {
            orangeRange = progress > 0 ? 0...progress : nil
            greenRange = nil
            tip = .ember(progress: progress)
            return
        }

        let completionSweep = min(max(completionSweep, 0), 1)
        orangeRange = completionSweep < 1 ? completionSweep...1 : nil
        greenRange = completionSweep > 0 ? 0...completionSweep : nil
        tip = completionSweep < 1 ? .success(progress: completionSweep) : nil
    }
}

struct ContextActivityLayout {
    static let statusHeight: CGFloat = 13
    private static let statusClearance: CGFloat = 6
    private static let headerBottomClearance: CGFloat = 5

    let notchHeight: CGFloat

    var statusTop: CGFloat {
        notchHeight + Self.statusClearance
    }

    var headerHeight: CGFloat {
        max(46, statusTop + Self.statusHeight + Self.headerBottomClearance)
    }
}

struct NotchProgressPlacement {
    private static let strokeOutset: CGFloat = 1
    let physicalExclusionSize: CGSize

    var pathSize: CGSize {
        CGSize(
            width: physicalExclusionSize.width + Self.strokeOutset * 2,
            height: physicalExclusionSize.height + Self.strokeOutset
        )
    }

    var cornerRadius: CGFloat {
        NotchMetrics.closedRadii.bottom + Self.strokeOutset
    }
}

struct NotchProgressPerimeter {
    struct Segment: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    let width: CGFloat
    let height: CGFloat
    let inset: CGFloat
    let cornerRadius: CGFloat

    init(
        width: CGFloat,
        height: CGFloat,
        inset: CGFloat,
        cornerRadius: CGFloat = NotchMetrics.closedRadii.bottom
    ) {
        self.width = width
        self.height = height
        self.inset = inset
        self.cornerRadius = min(
            max(0, cornerRadius),
            max(0, height),
            max(0, (width - inset * 2) / 2)
        )
    }

    var leftVerticalCompletion: CGFloat { progress(atVertex: 1) }

    var leftEdgeCompletion: CGFloat {
        progress(atVertex: 1 + Self.cornerSamples)
    }

    var bottomStraightCompletion: CGFloat {
        progress(atVertex: 2 + Self.cornerSamples)
    }

    var bottomEdgeCompletion: CGFloat {
        progress(atVertex: 2 + Self.cornerSamples * 2)
    }

    func endpoint(at progress: CGFloat) -> CGPoint {
        let distance = completedDistance(at: progress)
        let points = vertices
        guard let first = points.first else { return .zero }
        guard distance > 0 else { return first }
        guard distance < totalLength else { return points.last ?? first }

        var traversed: CGFloat = 0
        for pair in zip(points, points.dropFirst()) {
            let length = segmentLength(from: pair.0, to: pair.1)
            if traversed + length >= distance {
                let fraction = length > 0 ? (distance - traversed) / length : 1
                return interpolate(from: pair.0, to: pair.1, fraction: fraction)
            }
            traversed += length
        }
        return points.last ?? first
    }

    func visibleSegments(at progress: CGFloat) -> [Segment] {
        var remaining = completedDistance(at: progress)
        guard remaining > 0 else { return [] }
        var segments: [Segment] = []

        for pair in zip(vertices, vertices.dropFirst()) where remaining > 0 {
            let length = segmentLength(from: pair.0, to: pair.1)
            let completed = min(remaining, length)
            guard completed > 0 else { continue }
            segments.append(.init(
                start: pair.0,
                end: interpolate(
                    from: pair.0,
                    to: pair.1,
                    fraction: length > 0 ? completed / length : 1
                )
            ))
            remaining -= completed
        }
        return segments
    }

    private static let cornerSamples = 12

    private var vertices: [CGPoint] {
        let leftX = inset
        let rightX = max(inset, width - inset)
        let curveY = height - cornerRadius
        var points = [
            CGPoint(x: leftX, y: 0),
            CGPoint(x: leftX, y: curveY),
        ]

        let leftCenter = CGPoint(x: leftX + cornerRadius, y: curveY)
        for step in 1...Self.cornerSamples {
            if step == Self.cornerSamples {
                points.append(CGPoint(x: leftX + cornerRadius, y: height))
            } else {
                let angle = .pi - CGFloat(step) / CGFloat(Self.cornerSamples) * (.pi / 2)
                points.append(CGPoint(
                    x: leftCenter.x + cos(angle) * cornerRadius,
                    y: leftCenter.y + sin(angle) * cornerRadius
                ))
            }
        }

        points.append(CGPoint(x: rightX - cornerRadius, y: height))
        let rightCenter = CGPoint(x: rightX - cornerRadius, y: curveY)
        for step in 1...Self.cornerSamples {
            if step == Self.cornerSamples {
                points.append(CGPoint(x: rightX, y: curveY))
            } else {
                let angle = .pi / 2 - CGFloat(step) / CGFloat(Self.cornerSamples) * (.pi / 2)
                points.append(CGPoint(
                    x: rightCenter.x + cos(angle) * cornerRadius,
                    y: rightCenter.y + sin(angle) * cornerRadius
                ))
            }
        }
        points.append(CGPoint(x: rightX, y: 0))
        return points
    }

    private var totalLength: CGFloat {
        zip(vertices, vertices.dropFirst()).reduce(0) {
            $0 + segmentLength(from: $1.0, to: $1.1)
        }
    }

    private func progress(atVertex index: Int) -> CGFloat {
        let points = vertices
        let boundedIndex = min(max(index, 0), points.count - 1)
        let distance = zip(points, points.dropFirst()).prefix(boundedIndex).reduce(CGFloat.zero) {
            $0 + segmentLength(from: $1.0, to: $1.1)
        }
        guard totalLength > 0 else { return 0 }
        return distance / totalLength
    }

    private func completedDistance(at progress: CGFloat) -> CGFloat {
        totalLength * min(max(progress, 0), 1)
    }

    private func segmentLength(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func interpolate(from start: CGPoint, to end: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }
}

enum DashboardContentState: Equatable {
    case providerActivity(ProviderActivityPresentation)
    case indexing
    case empty
    case workspace

    static func resolve(
        providerActivity: ProviderActivityPresentation?,
        hasSnapshot: Bool,
        indexingState: IndexingState
    ) -> DashboardContentState {
        if let providerActivity { return .providerActivity(providerActivity) }
        if !hasSnapshot, indexingState == .indexing { return .indexing }
        return hasSnapshot ? .workspace : .empty
    }

    var presentsIndexingTrail: Bool {
        switch self {
        case .providerActivity, .indexing: return true
        case .empty, .workspace: return false
        }
    }
}

struct DashboardView: View {
    @ObservedObject var vm: DashboardViewModel
    @ObservedObject private var context: ContextIndexController
    @ObservedObject private var voiceRoutingStatus: VoiceRoutingStatus
    let isPresented: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Namespace private var contextNavigation

    init(vm: DashboardViewModel, isPresented: Bool, notchWidth: CGFloat, notchHeight: CGFloat) {
        self._vm = ObservedObject(wrappedValue: vm)
        self._context = ObservedObject(wrappedValue: vm.context)
        self._voiceRoutingStatus = ObservedObject(wrappedValue: vm.voiceRoutingStatus)
        self.isPresented = isPresented
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                HStack(spacing: 8) {
                    Button {
                        Task { await vm.openList() }
                    } label: {
                        HStack(spacing: 7) {
                            Image(nsImage: NSApplication.shared.applicationIconImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text("Embers")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Embers home")

                    Spacer()

                    if !vm.recent.isEmpty {
                        Button {
                            if vm.tab == .recent { vm.showContext() }
                            else { vm.showRecent() }
                        } label: {
                            Image(systemName: vm.tab == .recent ? "clock.fill" : "clock")
                                .foregroundStyle(vm.tab == .recent ? Style.ember2 : Style.inkMut)
                                .frame(width: 30, height: 30)
                                .background(
                                    vm.tab == .recent ? Style.ember2.opacity(0.09) : .clear,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.selected != nil)
                        .opacity(vm.selected == nil ? 1 : 0.35)
                        .help(vm.tab == .recent ? "Show all contexts" : "Show recently opened files")
                    }

                    ListeningIndicator(speech: vm.speech, toggle: vm.toggleListening)
                    Button { vm.toggleSettings() } label: {
                        Image(systemName: "gearshape").foregroundStyle(Style.inkMut).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 30)
                .padding(.horizontal, 10)
                .padding(.top, 8)

                if let activityLabel = voiceRoutingStatus.state.contextLensActivityLabel {
                    if let progress = voiceRoutingStatus.state.compilationProgress {
                        let presentation = ContextProgressPresentation(progress: progress)
                        NotchProgressEdge(
                            progress: presentation.fraction,
                            width: notchWidth,
                            height: notchHeight
                        )
                    }

                    Group {
                        if let progress = voiceRoutingStatus.state.compilationProgress {
                            ContextProgressStatus(
                                label: activityLabel,
                                progress: progress
                            )
                        } else {
                            HStack(spacing: 6) {
                                ContextActivityIndicator(isAppOpen: isPresented)
                                Text(activityLabel)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Style.inkMut)
                            }
                            .fixedSize()
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(activityAccessibilityLabel)
                    .help("Making your notes easier to find. Everything stays on this Mac.")
                    .padding(.top, activityLayout.statusTop)
                    .transition(.opacity)
                }
            }
            .frame(height: headerHeight, alignment: .top)
            .opacity(isPresented ? 1 : 0)
            .animation(
                isPresented ? NotchViewModel.tabReveal : NotchViewModel.tabHide,
                value: isPresented
            )
            .animation(
                accessibilityReduceMotion ? nil : .smooth(duration: 0.2),
                value: voiceRoutingStatus.state.isWorking
            )
            Rectangle().fill(Style.hairline).frame(height: 1)
            content
                .animation(
                    accessibilityReduceMotion ? nil : .smooth(duration: 0.22),
                    value: context.activeProviderActivity
                )
        }
        .frame(width: NotchMetrics.openSize.width, height: NotchMetrics.openSize.height)
        .background(Style.panelFill)
        .overlay {
            if vm.showingSettings && !contentState.presentsIndexingTrail {
                SettingsView(vm: vm).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    @ViewBuilder private var content: some View {
        switch contentState {
        case .providerActivity(let activity):
            IndexingTrailView(activity: activity)
                .transition(.opacity)
        case .indexing:
            IndexingTrailView()
                .transition(.opacity)
        case .empty:
            EmptyContextView(
                state: context.state,
                trySample: { Task { try? await context.useSampleVault() } },
                chooseFolder: vm.chooseFolder
            )
        case .workspace:
            VStack(spacing: 0) {
                if context.isUsingSampleVault {
                    SampleVaultGuide(
                        selectedName: vm.selected.flatMap { selected in
                            vm.anchors.first(where: { $0.id == selected })?.name
                        },
                        chooseFolder: vm.chooseFolder
                    )
                    Rectangle().fill(Style.hairline).frame(height: 1)
                }
                ScrollView(showsIndicators: false) {
                    navigationContent
                    .padding(14)
                }
            }
        }
    }

    private var contentState: DashboardContentState {
        .resolve(
            providerActivity: context.activeProviderActivity,
            hasSnapshot: context.snapshot != nil,
            indexingState: context.state
        )
    }

    private var headerHeight: CGFloat {
        activityLayout.headerHeight
    }

    private var activityLayout: ContextActivityLayout {
        ContextActivityLayout(notchHeight: notchHeight)
    }

    private var activityAccessibilityLabel: String {
        if let progress = voiceRoutingStatus.state.compilationProgress {
            let presentation = ContextProgressPresentation(progress: progress)
            return "Preparing your notes. \(presentation.valueLabel) complete. Making them easier to find. Everything stays on this Mac."
        }
        return "Preparing your notes. Making them easier to find. Everything stays on this Mac."
    }

    @ViewBuilder private var navigationContent: some View {
        if let selected = vm.selected {
            SelectedContextView(
                id: selected,
                summary: vm.anchors.first(where: { $0.id == selected }),
                detail: vm.detail,
                vm: vm,
                namespace: contextNavigation,
                isSource: false,
                isOnboarding: context.isUsingSampleVault,
                reduceMotion: reduceNavigationMotion
            )
            .id(selected)
            .transition(selectedTransition)
        } else if vm.tab == .context || vm.recent.isEmpty {
            ContextGrid(
                vm: vm,
                namespace: contextNavigation,
                isSource: true,
                reduceMotion: reduceNavigationMotion
            )
                .transition(gridTransition)
        } else {
            RecentList(items: vm.recent, vm: vm)
                .transition(.opacity)
        }
    }

    private var reduceNavigationMotion: Bool {
        accessibilityReduceMotion || NotchViewModel.reduced
    }

    private var selectedTransition: AnyTransition {
        guard !reduceNavigationMotion else { return .opacity }
        switch vm.navigationMotion {
        case .traverse:
            return .asymmetric(
                insertion: .offset(x: 12).combined(with: .opacity),
                removal: .offset(x: -8).combined(with: .opacity)
            )
        case .drillIn, .back, .none:
            return .opacity
        }
    }

    private var gridTransition: AnyTransition {
        .opacity
    }
}

struct ContextProgressStatus: View {
    let label: String
    let progress: VoiceRoutingCompilationProgress
    private let progressFont = Font.system(size: 10.5, weight: .medium)
    private var presentation: ContextProgressPresentation {
        ContextProgressPresentation(progress: progress)
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(progressFont)
                .foregroundStyle(Style.inkMut)
                .lineLimit(1)
            Text(presentation.valueLabel)
                .font(progressFont)
                .monospacedDigit()
                .foregroundStyle(Style.inkMut.opacity(0.82))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Progress belongs to the hardware notch rather than becoming another dashboard divider.
/// It starts at the notch's top-left, descends, crosses the bottom, then rises to
/// the top-right. The three visible sides become one continuous measure of work.
private struct NotchProgressEdge: View {
    let progress: CGFloat
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionSweep: CGFloat = 0

    private var isComplete: Bool { progress >= 1 }

    var body: some View {
        let placement = NotchProgressPlacement(
            physicalExclusionSize: CGSize(width: width, height: height)
        )
        let perimeter = NotchProgressPerimeter(
            width: placement.pathSize.width,
            height: placement.pathSize.height,
            inset: 0,
            cornerRadius: placement.cornerRadius
        )
        let fullPath = Path { path in
            let segments = perimeter.visibleSegments(at: 1)
            if let first = segments.first {
                path.move(to: first.start)
            }
            for segment in segments {
                path.addLine(to: segment.end)
            }
        }

        let visualState = NotchProgressVisualState(
            progress: progress,
            completionSweep: completionSweep
        )

        ZStack {
            if let range = visualState.orangeRange {
                progressStroke(
                    path: fullPath,
                    range: range,
                    core: Style.emberGlow,
                    glow: Style.emberGlow
                )
            }
            if let range = visualState.greenRange {
                progressStroke(
                    path: fullPath,
                    range: range,
                    core: Style.green2,
                    glow: Style.listenGlow
                )
            }
            if let tip = visualState.tip {
                switch tip {
                case .ember(let progress):
                    NotchFuseTip(
                        point: perimeter.endpoint(at: progress),
                        color: Style.emberHi,
                        animated: !reduceMotion
                    )
                case .success(let progress):
                    NotchFuseTip(
                        point: perimeter.endpoint(at: progress),
                        color: Style.listenGlow,
                        animated: !reduceMotion
                    )
                }
            }
        }
            .frame(width: placement.pathSize.width, height: placement.pathSize.height)
            .animation(.linear(duration: 0.18), value: progress)
            .task(id: isComplete) {
                guard isComplete else {
                    completionSweep = 0
                    return
                }
                completionSweep = 0
                await Task.yield()
                let duration = ContextProgressCompletionTiming.sweepDuration(
                    reduceMotion: reduceMotion
                )
                guard duration > 0 else {
                    completionSweep = 1
                    return
                }
                withAnimation(.linear(duration: duration)) {
                    completionSweep = 1
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func progressStroke(
        path: Path,
        range: ClosedRange<CGFloat>,
        core: Color,
        glow: Color
    ) -> some View {
        path
            .trim(from: range.lowerBound, to: range.upperBound)
            .stroke(
                glow.opacity(0.24),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
            .blur(radius: 2.6)

        path
            .trim(from: range.lowerBound, to: range.upperBound)
            .stroke(
                core.opacity(0.9),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
    }
}

private struct NotchFuseTip: View {
    let point: CGPoint
    let color: Color
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animated)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let pulse = animated ? (sin(elapsed * .pi * 3.2) + 1) / 2 : 0.5

            ZStack {
                Circle()
                    .fill(color.opacity(0.2 + pulse * 0.12))
                    .frame(width: 7 + pulse * 1.5, height: 7 + pulse * 1.5)
                    .blur(radius: 2.2)
                Circle()
                    .fill(color)
                    .frame(width: 2.4, height: 2.4)
                Circle()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 0.9, height: 0.9)
            }
            .position(point)
        }
    }
}

private struct ContextActivityIndicator: View {
    let isAppOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldAnimate: Bool {
        ContextActivityMotionPolicy.shouldAnimate(
            isAppOpen: isAppOpen,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !shouldAnimate)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.45) / 1.45

            Canvas { context, size in
                if shouldAnimate {
                    let activeFraction = 0.62
                    let activeProgress = min(CGFloat(phase / activeFraction), 1)
                    let isActive = phase < activeFraction
                    let fadeIn = min(activeProgress / 0.2, 1)
                    let fadeOut = min((1 - activeProgress) / 0.28, 1)
                    let opacity = isActive ? max(0, min(fadeIn, fadeOut)) : 0
                    let radius = 1.15 + opacity * 0.35
                    let center = CGPoint(
                        x: size.width / 2,
                        y: 1.5 + activeProgress * 8
                    )
                    let glow = CGRect(
                        x: center.x - radius * 2,
                        y: center.y - radius * 2,
                        width: radius * 4,
                        height: radius * 4
                    )
                    context.fill(
                        Path(ellipseIn: glow),
                        with: .color(Style.emberGlow.opacity(Double(opacity) * 0.16))
                    )
                    let ember = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: ember),
                        with: .color(Style.emberHi.opacity(Double(opacity)))
                    )
                } else {
                    let ember = CGRect(
                        x: size.width / 2 - 1.2,
                        y: size.height / 2 - 1.2,
                        width: 2.4,
                        height: 2.4
                    )
                    context.fill(Path(ellipseIn: ember), with: .color(Style.emberGlow.opacity(0.62)))
                }
            }
        }
        .frame(width: 10, height: 12)
        .accessibilityHidden(true)
    }
}

private struct EmptyContextView: View {
    let state: IndexingState
    let trySample: () -> Void
    let chooseFolder: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Label("LOCAL-FIRST CONTEXT", systemImage: "lock.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.3)
                    .foregroundStyle(Style.emberHi)
                Text("See your work\nin context.")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                Text("Try a small Markdown vault first, or start with your own folder. No account or network required.")
                    .font(.system(size: 11))
                    .foregroundStyle(Style.inkMut)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 235, alignment: .leading)

            VStack(spacing: 10) {
                Button(action: trySample) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text("Try the sample vault")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Style.ember2)

                Button(action: chooseFolder) {
                    Text("Choose my folder…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("You can connect other sources later in Settings.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Style.inkDim)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 210)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .overlay(alignment: .bottom) {
            if case .failed(let message) = state {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SampleVaultGuide: View {
    let selectedName: String?
    let chooseFolder: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedName == nil ? "waveform" : "doc.text.magnifyingglass")
                .foregroundStyle(Style.ember2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("SAMPLE VAULT")
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Style.emberHi)
                Text(SampleVaultGuideCopy.instruction(selectedName: selectedName))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button("Use my folder…", action: chooseFolder)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Style.ember2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Style.ember2.opacity(0.055))
    }

}

enum SampleVaultGuideCopy {
    static func instruction(selectedName: String?) -> String {
        if let selectedName {
            return "\(selectedName) was assembled from the Markdown evidence below."
        }
        return "Say “San Francisco” to open the trip context."
    }
}

private struct ContextGrid: View {
    @ObservedObject var vm: DashboardViewModel
    let namespace: Namespace.ID
    let isSource: Bool
    let reduceMotion: Bool
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(vm.anchors) { anchor in
                Button { Task { await vm.select(anchor.id) } } label: {
                    ContextCard(anchor: anchor)
                        .contextGeometry(
                            id: contextCardID(anchor.id),
                            in: namespace,
                            isSource: isSource,
                            enabled: !reduceMotion
                        )
                }.buttonStyle(.plain)
            }
            ForEach(vm.unassignedArtifacts) { artifact in
                Button { vm.open(artifact) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(artifact.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text((artifact.metadata.kind ?? "document").uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(Style.emberHi)
                        }
                        Text("Not assigned to a context").font(.system(size: 10)).foregroundStyle(Style.inkDim)
                        HStack(spacing: 5) {
                            Image(systemName: artifact.metadata.kind == "task" ? "checkmark.square" : "doc.text")
                            Text("Open")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Style.ember2)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    .background(Style.cardFill, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Style.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ContextCard: View {
    let anchor: AnchorSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(anchor.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if let kind = anchor.kind {
                    Text(kind.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Style.emberHi)
                }
            }
            Text("\(anchor.documentCount) docs  ·  \(anchor.linkCount) links")
                .font(.system(size: 10))
                .foregroundStyle(Style.inkDim)
            if anchor.modifiedAt != .distantPast {
                Text(anchor.modifiedAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(Style.inkMut)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(Style.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Style.hairline))
    }
}

private struct RecentList: View {
    let items: [RecentArtifact]
    @ObservedObject var vm: DashboardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENTLY OPENED")
                .font(.system(size: 9.5, weight: .heavy))
                .tracking(1.3)
                .foregroundStyle(Style.inkDim)
                .padding(.horizontal, 2)
            ForEach(items) { item in
                Button { vm.open(item.artifact) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.artifact.mediaKind == .markdown ? "doc.text" : "doc").foregroundStyle(Style.ember2)
                        VStack(alignment: .leading, spacing: 3) { Text(item.artifact.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white); Text(item.artifact.relativePath).font(.system(size: 9.5)).foregroundStyle(Style.inkDim).lineLimit(1) }
                        Spacer(); Text(item.accessedAt, style: .relative).font(.system(size: 9)).foregroundStyle(Style.inkDim)
                    }.padding(11).background(Style.cardFill, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
        }
    }
}

private struct SelectedContextView: View {
    let id: String
    let summary: AnchorSummary?
    let detail: AnchorDetail?
    @ObservedObject var vm: DashboardViewModel
    let namespace: Namespace.ID
    let isSource: Bool
    let isOnboarding: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            contextHeader
                .contextGeometry(
                    id: contextCardID(id),
                    in: namespace,
                    isSource: isSource,
                    enabled: !reduceMotion
                )

            if let detail {
                AnchorDetailView(
                    detail: detail,
                    vm: vm,
                    isOnboarding: isOnboarding,
                    reduceMotion: reduceMotion,
                    emphasizedRevealNotBefore: vm.evidenceRevealNotBefore
                )
                    .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Style.ember2)
                    Text("Gathering direct evidence…")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Style.inkMut)
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 34)
                .transition(.opacity)
            }
        }
    }

    private var contextHeader: some View {
        HStack(spacing: 10) {
            Button { vm.back() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(Style.inkMut)
                        .frame(width: 22, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail?.anchor.canonicalName ?? summary?.name ?? "Context")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let kind = detail?.anchor.kind ?? summary?.kind {
                            Text(kind.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Style.ember2)
                        } else if let summary {
                            Text("\(summary.documentCount) docs  ·  \(summary.linkCount) links")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Style.inkDim)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to contexts")

            Button("Ignore this context") { vm.ignoreSelected() }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
                .opacity(detail == nil ? 0 : 1)
                .disabled(detail == nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(Style.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Style.hairline))
    }
}

private struct AnchorDetailView: View {
    let detail: AnchorDetail
    @ObservedObject var vm: DashboardViewModel
    let isOnboarding: Bool
    let reduceMotion: Bool
    let emphasizedRevealNotBefore: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            let changeSummaries = ContextChangeSummaryPresentation.rows(
                from: detail.changeSet,
                isOnboarding: isOnboarding
            )
            let changed = ChangedSinceLastPeekPresentation.hits(
                from: detail.hits,
                isOnboarding: isOnboarding,
                hasNonArtifactChanges: !changeSummaries.isEmpty
            )
            let hasChanges = !changed.isEmpty || !changeSummaries.isEmpty
            let changedCount = changed.count + changeSummaries.reduce(0) { $0 + $1.count }
            let documentsOrder = hasChanges ? 1 : 0
            let tasksOrder = documentsOrder + (detail.hits.isEmpty ? 0 : 1)
            let relatedOrder = tasksOrder + (detail.tasks.isEmpty ? 0 : 1)
            let insideOrder = relatedOrder + (detail.relatedAnchors.isEmpty ? 0 : 1)

            if hasChanges {
                section("CHANGED SINCE LAST PEEK", count: changedCount) {
                    changeSummaryRows(changeSummaries)
                    hitRows(changed)
                }
                    .evidenceReveal(order: 0, reduceMotion: reduceMotion, emphasizedNotBefore: emphasizedRevealNotBefore)
            }
            if !detail.hits.isEmpty {
                section("DIRECT DOCUMENTS", count: detail.hits.count) { hitRows(detail.hits) }
                    .evidenceReveal(order: documentsOrder, reduceMotion: reduceMotion, emphasizedNotBefore: emphasizedRevealNotBefore)
            }
            if !detail.tasks.isEmpty {
                section("TASKS", count: detail.tasks.count) {
                    if let error = vm.taskMutationError {
                        Text(error).font(.system(size: 9.5)).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(detail.tasks) { task in TaskCompletionRow(task: task, vm: vm) }
                }
                .evidenceReveal(order: tasksOrder, reduceMotion: reduceMotion, emphasizedNotBefore: emphasizedRevealNotBefore)
            }
            if !detail.relatedAnchors.isEmpty {
                section("RELATED", count: detail.relatedAnchors.count) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(detail.relatedAnchors) { related in
                                Button {
                                    Task { await vm.select(related.id) }
                                } label: {
                                    Text(related.name)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.bordered)
                                .help(relatedTooltip(related.relationKind))
                            }
                        }
                    }
                }
                .evidenceReveal(order: relatedOrder, reduceMotion: reduceMotion, emphasizedNotBefore: emphasizedRevealNotBefore)
            }
            if !detail.subcontexts.isEmpty {
                section("INSIDE \(detail.anchor.canonicalName.uppercased())", count: detail.subcontexts.count) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                        ForEach(detail.subcontexts) { child in
                            Button { Task { await vm.select(child.id) } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Style.ember2)
                                    Text(child.name)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(child.documentCount) \(child.documentCount == 1 ? "document" : "documents")")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Style.inkDim)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(Style.cardFill, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Style.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .evidenceReveal(order: insideOrder, reduceMotion: reduceMotion, emphasizedNotBefore: emphasizedRevealNotBefore)
            }
        }
    }

    private func hitRows(_ hits: [ContextHit]) -> some View {
        VStack(spacing: 0) { ForEach(hits) { hit in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(hit.artifact.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    ArtifactActionButtons(artifact: hit.artifact, vm: vm)
                }.font(.system(size: 9)).foregroundStyle(Style.ember2)
                Text(markdownSnippet(hit.snippet)).font(.system(size: 10.5)).foregroundStyle(Style.inkMut).lineLimit(3)
            }.padding(.vertical, 7)
        } }
    }

    private func changeSummaryRows(_ rows: [ContextChangeSummaryRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Style.ember2)
                    Text(row.message)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Style.inkMut)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func relatedTooltip(_ relationKind: String) -> String {
        relationKind
            .split(separator: "·")
            .map { relationship in
                switch relationship.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "mentions": "Mentioned by"
                case "links-to": "Linked to"
                case "contains-directly": "Contained directly"
                case "depends_on", "depends-on": "Depends on"
                case "contributes_to", "contributes-to": "Contributes to"
                case "supports": "Supports"
                case "related_to", "related-to", "related": "Related to"
                default:
                    relationship
                        .replacingOccurrences(of: "_", with: " ")
                        .replacingOccurrences(of: "-", with: " ")
                        .capitalized
                }
            }
            .joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text("\(title)  ·  \(count)").font(.system(size: 9, weight: .heavy)).tracking(1.1).foregroundStyle(Style.emberHi); content() }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Style.cardFill, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Style.hairline))
    }
}

private struct ArtifactActionButtons: View {
    let artifact: SourceArtifact
    @ObservedObject var vm: DashboardViewModel
    @State private var actions: [ArtifactAction] = []

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(action.title) {
                    Task { await vm.perform(action, for: artifact) }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: artifact.id) {
            actions = await vm.artifactActions(for: artifact)
        }
    }
}

private struct EvidenceRevealModifier: ViewModifier {
    let order: Int
    let reduceMotion: Bool
    let emphasizedNotBefore: Date?
    @State private var isVisible = false

    private var isEmphasized: Bool { emphasizedNotBefore != nil }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : (isEmphasized ? 8 : 4))
            .scaleEffect(isVisible || reduceMotion ? 1 : (isEmphasized ? 0.985 : 1))
            .task {
                if !reduceMotion {
                    let remainingMs = max(
                        0,
                        Int((emphasizedNotBefore?.timeIntervalSinceNow ?? 0) * 1_000)
                    )
                    let staggerMs = order * (isEmphasized ? 55 : 40)
                    let delayMs = remainingMs + staggerMs
                    do {
                        if delayMs > 0 {
                            try await Task.sleep(for: .milliseconds(delayMs))
                        }
                    } catch {
                        return
                    }
                }

                withAnimation(
                    isEmphasized
                        ? NotchViewModel.emphasizedEvidenceReveal
                        : NotchViewModel.evidenceReveal
                ) {
                    isVisible = true
                }
            }
    }
}

private func contextCardID(_ id: String) -> String {
    "context-card-\(id)"
}

private extension View {
    @ViewBuilder
    func contextGeometry(
        id: String,
        in namespace: Namespace.ID,
        isSource: Bool,
        enabled: Bool
    ) -> some View {
        if enabled {
            matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }

    func evidenceReveal(order: Int, reduceMotion: Bool, emphasizedNotBefore: Date?) -> some View {
        modifier(EvidenceRevealModifier(
            order: order,
            reduceMotion: reduceMotion,
            emphasizedNotBefore: emphasizedNotBefore
        ))
    }
}

enum ChangedSinceLastPeekPresentation {
    static func hits(
        from hits: [ContextHit],
        isOnboarding: Bool,
        hasNonArtifactChanges: Bool = false
    ) -> [ContextHit] {
        let actualChanges = hits.filter(\.changedSinceLastPeek)
        guard actualChanges.isEmpty, isOnboarding, !hasNonArtifactChanges else { return actualChanges }
        return Array(hits.prefix(1))
    }
}

private struct TaskCompletionRow: View {
    let task: AnchorTask
    @ObservedObject var vm: DashboardViewModel
    @State private var supportsCompletion = false

    private var isMutating: Bool { vm.mutatingTaskIDs.contains(task.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Button {
                Task { await vm.complete(task) }
            } label: {
                Group {
                    if isMutating { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "square") }
                }
                .frame(width: 14, height: 14)
                .foregroundStyle(Style.ember2)
            }
            .buttonStyle(.plain)
            .disabled(!supportsCompletion || isMutating)
            .help(supportsCompletion ? "Mark complete" : "This source is read-only")
            Text(task.text).font(.system(size: 11.5)).foregroundStyle(.white)
            Spacer()
            Text(task.artifactTitle).font(.system(size: 9)).foregroundStyle(Style.inkDim)
        }
        .padding(.vertical, 3)
        .task(id: task.id) { supportsCompletion = await vm.supportsCompletion(task) }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    init(spacing: CGFloat, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View { HStack(spacing: spacing) { content } }
}
