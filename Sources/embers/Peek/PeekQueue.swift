//  PeekQueue.swift
//  The signature embers interaction. Speech matches push discovered context names that
//  drop down from the notch as one fused black slab. Rules:
//    • up to 3 concurrent slots, divided equally by the view layer (33/33/33)
//    • each peek lives 30s on an independent, cancellable timer
//    • a match for an already-showing target refreshes its 30s timer (no duplicate)
//    • a 4th distinct match evicts the oldest (FIFO)

import SwiftUI

enum MatchReference: Equatable { case node(String) }

struct MatchTarget: Equatable {
    let phrase: String
    let ref: MatchReference
    let title: String
    /// Present only when this target is one choice in a compiler-declared shared concept.
    /// The selected node remains in `ref`; this stable ID lets a later preference layer learn
    /// which candidate the user chose without changing routing identity.
    let conceptID: String?

    init(phrase: String, ref: MatchReference, title: String, conceptID: String? = nil) {
        self.phrase = phrase
        self.ref = ref
        self.title = title
        self.conceptID = conceptID
    }
}

let maxPeeks = 3

struct Peek: Identifiable, Equatable {
    let id: String              // stable per target → enables refresh instead of dup
    let target: MatchTarget
    let title: String           // short label rendered in the slab
    var bornAt: Date

    static func == (l: Peek, r: Peek) -> Bool { l.id == r.id && l.bornAt == r.bornAt }
}

@MainActor
final class PeekQueue: ObservableObject {
    private static let lifetime: Duration = .seconds(30)
    @Published private(set) var peeks: [Peek] = []   // front = oldest

    private var timers: [String: Task<Void, Never>] = [:]

    init() {}

    /// A speech match arrived. Insert (or refresh) and enforce the 3-slot FIFO window.
    func push(_ target: MatchTarget) {
        let peek = resolve(target)

        if let idx = peeks.firstIndex(where: { $0.id == peek.id }) {
            peeks[idx].bornAt = .now
            arm(peek.id)
            return
        }

        withAnimation(NotchViewModel.peekLayout) {
            peeks.append(peek)
            if peeks.count > maxPeeks {
                let evicted = peeks.removeFirst()      // FIFO
                timers[evicted.id]?.cancel()
                timers[evicted.id] = nil
            }
        }
        arm(peek.id)
    }

    var visibleNodeIDs: Set<String> {
        Set(peeks.compactMap { peek in
            guard case .node(let id) = peek.target.ref else { return nil }
            return id
        })
    }

    var visibleConceptCandidates: [String: Set<String>] {
        peeks.reduce(into: [:]) { result, peek in
            guard let conceptID = peek.target.conceptID,
                  case .node(let nodeID) = peek.target.ref else { return }
            result[conceptID, default: []].insert(nodeID)
        }
    }

    /// Replace the visible candidate set for one shared concept without disturbing peeks from
    /// other concepts or unique matches.
    func replaceConcept(_ conceptID: String, with targets: [MatchTarget]) {
        let existingIDs = peeks.compactMap { peek -> String? in
            peek.target.conceptID == conceptID ? peek.id : nil
        }
        existingIDs.forEach { id in
            timers[id]?.cancel()
            timers[id] = nil
        }
        withAnimation(NotchViewModel.peekLayout) {
            peeks.removeAll { $0.target.conceptID == conceptID }
        }
        targets.forEach(push)
    }

    func removeConcept(_ conceptID: String) {
        replaceConcept(conceptID, with: [])
    }

    func remove(_ id: String) {
        timers[id]?.cancel()
        timers[id] = nil
        withAnimation(NotchViewModel.peekLayout) {
            peeks.removeAll { $0.id == id }
        }
    }

    func clear() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        withAnimation(NotchViewModel.peekLayout) { peeks.removeAll() }
    }

    // MARK: - Lifetime
    private func arm(_ id: String) {
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }

    // MARK: - Resolve a match target into a renderable peek
    private func resolve(_ target: MatchTarget) -> Peek {
        switch target.ref {
        case .node(let id):
            let identity = target.conceptID.map { "c:\($0):n:\(id)" } ?? "n:\(id)"
            return Peek(id: identity, target: target, title: target.title, bornAt: .now)
        }
    }

}
