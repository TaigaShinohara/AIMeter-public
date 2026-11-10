import Foundation

/// Distribution-specific identities and Widget storage. Both the host and its
/// extension must provide the same values in their own Info.plist files.
public struct DistributionConfiguration: Equatable {
    public enum Mode: Equatable {
        case direct
        case appStore
    }

    public enum ConfigurationError: Error, Equatable {
        case invalidDistribution
        case missingValue(String)
        case invalidValue(String)
        case conflictsWithDirectDistribution(String)
        case missingAppGroupContainer
    }

    public let mode: Mode
    public let appGroupIdentifier: String?
    public let keychainService: String
    public let widgetKind: String
    public let urlScheme: String

    /// Missing distribution metadata preserves the existing direct build.
    /// Invalid Store metadata fails closed rather than selecting direct storage.
    public init(infoDictionary: [String: Any], requireAppStore: Bool = false) throws {
        let distribution = infoDictionary["AIMeterDistribution"]
        if distribution == nil {
            guard !requireAppStore else { throw ConfigurationError.invalidDistribution }
            mode = .direct
            appGroupIdentifier = nil
            keychainService = "com.local.AIMeter"
            widgetKind = "com.local.AIMeter.widget"
            urlScheme = "aimeter"
            return
        }
        guard let value = distribution as? String, value == "app-store" else {
            throw ConfigurationError.invalidDistribution
        }

        func required(_ key: String, distinctFrom directValue: String? = nil) throws -> String {
            guard let value = infoDictionary[key] as? String,
                  !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ConfigurationError.missingValue(key)
            }
            guard key == "AIMeterURLScheme" ? value.lowercased() != directValue?.lowercased() : value != directValue else {
                throw ConfigurationError.conflictsWithDirectDistribution(key)
            }
            return value
        }

        func validIdentifier(_ value: String) -> Bool {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
            }
        }

        func validated(_ key: String, distinctFrom directValue: String? = nil,
                       accepts: (String) -> Bool) throws -> String {
            let value = try required(key, distinctFrom: directValue)
            guard accepts(value) else { throw ConfigurationError.invalidValue(key) }
            return value
        }

        mode = .appStore
        appGroupIdentifier = try validated("AIMeterAppGroupIdentifier") { value in
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, validIdentifier(value), let prefix = parts.first else { return false }
            let teamCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return prefix == "group" || (prefix.count == 10 && prefix.unicodeScalars.allSatisfy { teamCharacters.contains($0) })
        }
        keychainService = try validated("AIMeterKeychainService", distinctFrom: "com.local.AIMeter", accepts: validIdentifier)
        widgetKind = try validated("AIMeterWidgetKind", distinctFrom: "com.local.AIMeter.widget", accepts: validIdentifier)
        urlScheme = try validated("AIMeterURLScheme", distinctFrom: "aimeter") { value in
            let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            let rest = letters.union(CharacterSet(charactersIn: "0123456789+-."))
            guard let first = value.unicodeScalars.first, letters.contains(first) else { return false }
            return value.unicodeScalars.dropFirst().allSatisfy { rest.contains($0) }
        }
    }

    public static func current(bundle: Bundle = .main) throws -> DistributionConfiguration {
        #if AIMETER_APP_STORE
        try DistributionConfiguration(infoDictionary: bundle.infoDictionary ?? [:], requireAppStore: true)
        #else
        try DistributionConfiguration(infoDictionary: bundle.infoDictionary ?? [:])
        #endif
    }

    /// `groupContainer` is supplied by the caller after resolving the declared
    /// App Group. Keeping resolution separate makes failure and paths testable.
    public func widgetSnapshotURL(home: URL, groupContainer: URL?) throws -> URL {
        switch mode {
        case .direct:
            return home.appendingPathComponent(".ai_meter_widget.json")
        case .appStore:
            guard let groupContainer else { throw ConfigurationError.missingAppGroupContainer }
            return groupContainer.appendingPathComponent(".ai_meter_widget.json")
        }
    }
}
