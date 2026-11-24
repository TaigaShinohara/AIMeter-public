import Foundation

public enum CLICommand: String, CaseIterable, Sendable {
    case status
    case list
    case get
    case history
    case doctor
}

public enum CLIOutputFormat: String, Equatable, Sendable {
    case json
    case human
}

/// Parsed command line. Malformed input throws `CLIError` (exit 1).
/// Write-oriented common flags (`--dry-run`, `--yes`, `--idempotency-key`)
/// are collected instead of thrown, so `--help` can still answer first; the
/// engine rejects them explicitly for these read-only commands rather than
/// silently ignoring them.
public struct CLIArguments: Equatable {
    public var command: CLICommand?
    public var commandName: String?
    public var positional: [String] = []
    public var format: CLIOutputFormat = .json
    public var wantsHelp = false
    public var dataDirectoryOverride: String?
    public var timeoutSeconds: Double?
    public var unsupportedFlags: [String] = []

    public static func parse(_ arguments: [String]) throws -> CLIArguments {
        var result = CLIArguments()
        var sawJSON = false
        var sawHuman = false
        var index = 0

        func value(after flag: String) throws -> String {
            let next = index + 1
            guard next < arguments.count, !arguments[next].hasPrefix("-") else {
                throw CLIError.invalidArgument("\(flag) には値が必要です。")
            }
            index = next
            return arguments[next]
        }

        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--help", "-h":
                result.wantsHelp = true
            case "--json":
                sawJSON = true
            case "--human":
                sawHuman = true
            case "--dry-run", "--yes":
                result.unsupportedFlags.append(token)
            case "--idempotency-key":
                _ = try value(after: token)
                result.unsupportedFlags.append(token)
            case "--timeout":
                let raw = try value(after: token)
                guard let seconds = Double(raw), seconds > 0, seconds.isFinite else {
                    throw CLIError.invalidArgument("--timeout には正の数（秒）を指定してください: \(raw)")
                }
                result.timeoutSeconds = seconds
            case "--data-dir":
                result.dataDirectoryOverride = try value(after: token)
            default:
                if token.hasPrefix("-") {
                    throw CLIError.invalidArgument("未知のフラグです: \(token)")
                }
                if result.commandName == nil {
                    result.commandName = token
                } else {
                    result.positional.append(token)
                }
            }
            index += 1
        }

        if sawJSON && sawHuman {
            throw CLIError.invalidArgument("--json と --human は同時に指定できません。出力形式はどちらか一方にしてください。")
        }
        result.format = sawHuman ? .human : .json
        if let name = result.commandName {
            result.command = CLICommand(rawValue: name)
        }
        return result
    }
}
