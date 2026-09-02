import Foundation
import EmbersCore

/// A non-interactive row for a real change that has no current artifact to
/// open. Keeping this distinct from `ContextHit` prevents removed evidence or
/// structural provider events from masquerading as documents.
struct ContextChangeSummaryRow: Equatable, Identifiable {
    let kind: ContextChangeSummary.Kind
    let count: Int
    let systemImage: String
    let message: String

    var id: ContextChangeSummary.Kind { kind }
}

enum ContextChangeSummaryPresentation {
    /// Onboarding may demonstrate a current document through the existing hit
    /// presentation override. It never creates structural or removal notices.
    static func rows(
        from changeSet: ContextChangeSet,
        isOnboarding: Bool
    ) -> [ContextChangeSummaryRow] {
        _ = isOnboarding
        return changeSet.nonArtifactSummaries.map { summary in
            switch summary.kind {
            case .removedArtifacts:
                let noun = summary.count == 1 ? "document" : "documents"
                return .init(
                    kind: summary.kind,
                    count: summary.count,
                    systemImage: "minus.circle",
                    message: "\(summary.count) \(noun) removed from this context"
                )
            case .membershipChanged:
                return .init(
                    kind: summary.kind,
                    count: summary.count,
                    systemImage: "arrow.triangle.branch",
                    message: "Context membership changed"
                )
            }
        }
    }
}
