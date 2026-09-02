//  LastSeen.swift
//  The per-anchor "last peeked" watermark that powers changed-since-last-peek. Persisted in
//  UserDefaults in the app; an in-memory variant backs the tests.

import Foundation

protocol LastSeenStore: AnyObject {
    func lastSeen(_ anchorID: String) -> Date?
    func markSeen(_ anchorID: String, at date: Date)
}

extension LastSeenStore {
    func markSeen(_ anchorID: String) { markSeen(anchorID, at: Date()) }
}

final class InMemoryLastSeen: LastSeenStore {
    private var map: [String: Date] = [:]
    init(_ seed: [String: Date] = [:]) { map = seed }
    func lastSeen(_ anchorID: String) -> Date? { map[anchorID] }
    func markSeen(_ anchorID: String, at date: Date) { map[anchorID] = date }
}

final class UserDefaultsLastSeen: LastSeenStore {
    private let defaults: UserDefaults
    private let prefix = "lastSeen."
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    func lastSeen(_ anchorID: String) -> Date? {
        let t = defaults.double(forKey: prefix + anchorID)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func markSeen(_ anchorID: String, at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: prefix + anchorID)
    }
}
