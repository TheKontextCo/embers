import Foundation

/// The bundle is assembled outside Xcode, so keep localization lookup explicit and
/// testable rather than relying on a generated catalog accessor.
enum L10n {
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let mainValue = localizedString(key, in: .main)
        let format: String
        if mainValue != key {
            format = mainValue
        } else {
#if SWIFT_PACKAGE
            format = localizedString(key, in: .module)
#else
            format = key
#endif
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: .current, arguments: arguments)
    }

    private static func localizedString(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
