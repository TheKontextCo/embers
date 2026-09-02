import SwiftUI

struct IndexingTrailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleNodeCount: Int

    private let activity: ProviderActivityPresentation?
    private let graph = IndexingTrailGraph.graph

    init(activity: ProviderActivityPresentation? = nil, initialNodeCount: Int = 1) {
        self.activity = activity
        _visibleNodeCount = State(initialValue: initialNodeCount)
    }

    var body: some View {
        HStack(spacing: 26) {
            VStack(alignment: .leading, spacing: 0) {
                Text(activityLabel)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.35)
                    .foregroundStyle(Style.emberHi)

                Text(activityHeadline)
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                Text(activityDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(Style.inkMut)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .frame(width: 205, alignment: .leading)

            TrailGraphPanel(
                graph: graph,
                visibleNodeCount: visibleNodeCount
            )
            .frame(width: 390, height: 268)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Label(activityFootnote, systemImage: "lock.fill")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Style.inkDim)
                .symbolRenderingMode(.hierarchical)
                .padding(.trailing, 24)
                .padding(.bottom, 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activityLabel). \(activityHeadline.replacingOccurrences(of: "\n", with: " ")) \(activityFootnote).")
        .task(id: reduceMotion) {
            if reduceMotion {
                visibleNodeCount = min(24, graph.nodes.count)
                return
            }

            visibleNodeCount = 1
            for count in 2 ... graph.nodes.count {
                let delay = count < 16 ? 330 : 650
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                visibleNodeCount = count
            }
        }
    }

    private var activityLabel: String {
        guard let activity else { return "INDEXING LOCALLY" }
        switch activity.phase {
        case .connecting: return "CONNECTING \(activity.providerName.uppercased())"
        case .discovering: return "DISCOVERING \(activity.providerName.uppercased())"
        case .indexing:
            return activity.isLocal
                ? "INDEXING LOCALLY"
                : "INDEXING \(activity.providerName.uppercased())"
        case .idle, .ready, .stale, .failed: return "PREPARING CONTEXT"
        }
    }

    private var activityHeadline: String {
        guard let activity else { return "Your workspace\nis taking shape." }
        switch activity.phase {
        case .connecting: return "Connecting your\ncontext source."
        case .discovering: return "Finding your\ncontext sources."
        case .indexing: return "Your workspace\nis taking shape."
        case .idle, .ready, .stale, .failed: return "Preparing your\nworkspace."
        }
    }

    private var activityDetail: String {
        guard let activity else {
            return "Embers is reading your folder and building a private graph on this Mac."
        }
        switch activity.phase {
        case .connecting:
            return "Embers is completing the secure handoff to \(activity.providerName)."
        case .discovering:
            return "Embers is finding the context sources available from \(activity.providerName)."
        case .indexing:
            return activity.isLocal
                ? "Embers is reading your folder and building a private graph on this Mac."
                : "Embers is validating \(activity.providerName) and building its local graph."
        case .idle, .ready, .stale, .failed:
            return "Embers is preparing a validated context graph."
        }
    }

    private var activityFootnote: String {
        activity?.isLocal == true
            ? "Everything stays on this Mac"
            : "Validated locally before replacing your workspace"
    }
}

private struct TrailGraphPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let graph: IndexingTrailGraph
    let visibleNodeCount: Int

    private var visibleNodes: ArraySlice<IndexingTrailNode> {
        graph.nodes.prefix(visibleNodeCount)
    }

    private var visibleEdges: [IndexingTrailEdge] {
        let ids = Set(visibleNodes.map(\.id))
        return graph.edges.filter { ids.contains($0.startID) && ids.contains($0.endID) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DottedGraphBackground()

            GeometryReader { proxy in
                let frame = CGRect(
                    x: 20,
                    y: 34,
                    width: proxy.size.width - 40,
                    height: proxy.size.height - 52
                )
                let points = Dictionary(
                    uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.point(in: frame)) }
                )

                ZStack {
                    ForEach(visibleEdges) { edge in
                        if let start = points[edge.startID], let end = points[edge.endID] {
                            TrailGraphEdgeView(start: start, end: end, isSecondary: edge.isSecondary)
                        }
                    }

                    ForEach(visibleNodes) { node in
                        TrailGraphNodeView(
                            node: node,
                            isFrontier: node.id == visibleNodes.last?.id
                        )
                        .position(points[node.id] ?? .zero)
                    }
                }
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(Style.ember2)
                    .frame(width: 5, height: 5)
                    .shadow(color: Style.emberGlow.opacity(0.5), radius: 5)
                    .phaseAnimator(reduceMotion ? [false] : [false, true]) { content, bright in
                        content
                            .opacity(bright ? 1 : 0.45)
                            .scaleEffect(bright ? 1 : 0.82)
                    } animation: { _ in
                        .easeInOut(duration: 0.85)
                    }

                Text("GRAPH GROWING")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.top, 14)
            .padding(.leading, 16)
        }
        .background(Color.black.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055))
        }
        .accessibilityHidden(true)
    }
}

private struct TrailGraphNodeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    let node: IndexingTrailNode
    let isFrontier: Bool

    var body: some View {
        ZStack {
            if isFrontier && !reduceMotion {
                Circle()
                    .stroke(Style.ember2.opacity(0.32), lineWidth: 0.8)
                    .frame(width: node.size + 9, height: node.size + 9)
                    .phaseAnimator([false, true]) { content, expanded in
                        content
                            .scaleEffect(expanded ? 1.7 : 0.82)
                            .opacity(expanded ? 0 : 0.62)
                    } animation: { _ in
                        .easeOut(duration: 0.9)
                    }
            }

            RoundedRectangle(cornerRadius: node.isRoot ? node.size / 2 : 3.5, style: .continuous)
                .fill(node.fill)
                .overlay {
                    RoundedRectangle(cornerRadius: node.isRoot ? node.size / 2 : 3.5, style: .continuous)
                        .strokeBorder(node.stroke, lineWidth: 0.8)
                }
                .shadow(
                    color: node.isRoot ? Style.emberGlow.opacity(0.34) : Style.emberGlow.opacity(0.1),
                    radius: node.isRoot ? 9 : 5
                )
                .frame(width: node.size, height: node.size)
        }
        .scaleEffect(isVisible || reduceMotion ? 1 : 0.72)
        .opacity(isVisible || reduceMotion ? 1 : 0)
        .onAppear {
            guard !reduceMotion else {
                isVisible = true
                return
            }
            withAnimation(.spring(duration: 0.42, bounce: 0.18)) {
                isVisible = true
            }
        }
    }
}

private struct TrailGraphEdgeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    let start: CGPoint
    let end: CGPoint
    let isSecondary: Bool

    private var delta: CGVector {
        CGVector(dx: end.x - start.x, dy: end.y - start.y)
    }

    var body: some View {
        let length = hypot(delta.dx, delta.dy)
        let angle = Angle(radians: atan2(delta.dy, delta.dx))

        Capsule()
            .fill(
                LinearGradient(
                    colors: isSecondary
                        ? [Color.white.opacity(0.09), Color.white.opacity(0.18)]
                        : [Style.ember2.opacity(0.28), Color.white.opacity(0.14)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: length, height: 0.8)
            .scaleEffect(x: isVisible || reduceMotion ? 1 : 0.02, y: 1, anchor: .leading)
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .rotationEffect(angle)
            .position(x: start.x + delta.dx / 2, y: start.y + delta.dy / 2)
            .onAppear {
                guard !reduceMotion else {
                    isVisible = true
                    return
                }
                withAnimation(.smooth(duration: 0.46)) {
                    isVisible = true
                }
            }
    }
}

private struct DottedGraphBackground: View {
    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1, height: 1))
            for x in stride(from: 18.0, through: size.width, by: 18) {
                for y in stride(from: 18.0, through: size.height, by: 18) {
                    context.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.fill(dot, with: .color(.white.opacity(0.025)))
                    }
                }
            }
        }
        .background {
            RadialGradient(
                colors: [Style.ember2.opacity(0.07), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 150
            )
        }
    }
}

struct IndexingTrailGraph: Equatable {
    let nodes: [IndexingTrailNode]
    let edges: [IndexingTrailEdge]

    static let graph: IndexingTrailGraph = makeGraph()

    private static func makeGraph() -> IndexingTrailGraph {
        var nodes: [IndexingTrailNode] = [
            .init(id: 0, parentID: nil, x: 0.02, y: 0.50, size: 12, isSecondary: false),
            .init(id: 1, parentID: 0, x: 0.16, y: 0.35, size: 8, isSecondary: false),
            .init(id: 2, parentID: 0, x: 0.17, y: 0.65, size: 8, isSecondary: true),
            .init(id: 3, parentID: 1, x: 0.31, y: 0.20, size: 9, isSecondary: false),
            .init(id: 4, parentID: 1, x: 0.33, y: 0.48, size: 7, isSecondary: false),
            .init(id: 5, parentID: 2, x: 0.33, y: 0.82, size: 8, isSecondary: true),
            .init(id: 6, parentID: 3, x: 0.50, y: 0.08, size: 7, isSecondary: true),
            .init(id: 7, parentID: 3, x: 0.51, y: 0.34, size: 9, isSecondary: false),
            .init(id: 8, parentID: 4, x: 0.50, y: 0.64, size: 7, isSecondary: false),
            .init(id: 9, parentID: 5, x: 0.65, y: 0.86, size: 8, isSecondary: true),
            .init(id: 10, parentID: 6, x: 0.70, y: 0.20, size: 8, isSecondary: false),
            .init(id: 11, parentID: 7, x: 0.75, y: 0.54, size: 7, isSecondary: true),
            .init(id: 12, parentID: 10, x: 0.88, y: 0.07, size: 7, isSecondary: false),
            .init(id: 13, parentID: 10, x: 0.93, y: 0.38, size: 8, isSecondary: false),
            .init(id: 14, parentID: 9, x: 0.90, y: 0.82, size: 7, isSecondary: true),
        ]

        var random = IndexingTrailRandom(seed: 0xE3B3_45A1)
        for id in 15 ..< 72 {
            var candidates = Array(nodes.suffix(12))
            if candidates.allSatisfy({ $0.x > 0.84 }) {
                candidates = nodes.filter { $0.x > 0.35 && $0.x < 0.78 }
            }

            var parent = candidates[Int(random.next() * Double(candidates.count)) % candidates.count]
            if parent.x > 0.88,
               let replacement = nodes.reversed().first(where: { $0.x < 0.76 }) {
                parent = replacement
            }

            let horizontal = 0.09 + random.next() * 0.09
            let vertical = (random.next() - 0.5) * 0.42
            var x = min(0.96, parent.x + horizontal)
            var y = min(0.92, max(0.08, parent.y + vertical))

            for attempt in 0 ..< 6 {
                let collides = nodes.contains { node in
                    hypot(node.x - x, node.y - y) < 0.045
                }
                guard collides else { break }
                y = min(0.92, max(0.08, y + (attempt.isMultiple(of: 2) ? 0.07 : -0.1)))
                if attempt == 4 { x = min(0.96, x + 0.04) }
            }

            nodes.append(
                .init(
                    id: id,
                    parentID: parent.id,
                    x: x,
                    y: y,
                    size: 6 + random.next() * 3,
                    isSecondary: random.next() > 0.72
                )
            )
        }

        var edges = nodes.compactMap { node -> IndexingTrailEdge? in
            guard let parentID = node.parentID else { return nil }
            return .init(id: node.id, startID: parentID, endID: node.id, isSecondary: node.isSecondary)
        }

        let crossLinks = [(2, 4), (4, 7), (5, 8), (7, 10), (8, 11), (10, 13)]
        edges.append(contentsOf: crossLinks.enumerated().map { offset, pair in
            .init(id: 1_000 + offset, startID: pair.0, endID: pair.1, isSecondary: true)
        })

        for id in stride(from: 18, to: nodes.count, by: 5) {
            edges.append(
                .init(id: 2_000 + id, startID: max(0, id - 3), endID: id, isSecondary: true)
            )
        }

        return .init(nodes: nodes, edges: edges)
    }
}

struct IndexingTrailNode: Identifiable, Equatable {
    let id: Int
    let parentID: Int?
    let x: Double
    let y: Double
    let size: CGFloat
    let isSecondary: Bool

    var isRoot: Bool { parentID == nil }

    var fill: Color {
        if isRoot { return Style.ember2 }
        return isSecondary ? Color(red: 0.14, green: 0.145, blue: 0.165) : Color(red: 0.12, green: 0.09, blue: 0.075)
    }

    var stroke: Color {
        if isRoot { return Color(red: 1, green: 0.78, blue: 0.52) }
        return isSecondary ? Color.white.opacity(0.34) : Color(red: 1, green: 0.68, blue: 0.39).opacity(0.64)
    }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * x,
            y: rect.minY + rect.height * y
        )
    }
}

struct IndexingTrailEdge: Identifiable, Equatable {
    let id: Int
    let startID: Int
    let endID: Int
    let isSecondary: Bool
}

private struct IndexingTrailRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
