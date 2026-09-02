//  Log.swift
//  Privacy-safe operational logging for Embers.
//
//  Release diagnostics intentionally contain only fixed, allowlisted event names. User
//  content, stable identifiers, paths, and underlying error text never reach the unified
//  log, stdout, stderr, or a persistent local trace. Keep rich developer inspection in
//  tests and the debugger rather than creating a second, durable record of a person's data.
//
//  Filter the unified log with:
//      log stream --predicate 'subsystem == "dev.embers"' --info --debug

import Foundation
import OSLog

struct EmbersLog {
    private let logger: Logger
    init(_ category: String) {
        self.logger = Logger(subsystem: "dev.embers", category: category)
    }

    // The type deliberately accepts only StaticString. Dynamic values are often names,
    // transcript fragments, graph IDs, file paths, or NSError text; adding an overload for
    // String would make a future privacy regression far too easy.
    func debug(_ event: StaticString)  { logger.debug("\(event)") }
    func info(_ event: StaticString)   { logger.info("\(event)") }
    func notice(_ event: StaticString) { logger.notice("\(event)") }
    func error(_ event: StaticString)  { logger.error("\(event)") }
}

enum Log {
    static let app    = EmbersLog("app")
    static let graph  = EmbersLog("graph")
    static let speech = EmbersLog("speech")
    static let peek   = EmbersLog("peek")
    static let walk   = EmbersLog("walk")
}
