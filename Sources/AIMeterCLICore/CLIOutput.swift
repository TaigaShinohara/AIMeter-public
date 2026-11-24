import Foundation

/// The CLI's own version. The GUI app's version lives in the app bundle and
/// is not duplicated here; `status` labels this value as the CLI version.
public let aimeterCLIVersion = "0.2.0"

/// Version of the CLI input/output schema (`meta.schema_version`).
public let aimeterCLISchemaVersion = 1

/// A command failure with a stable machine-readable code and the unified
/// exit code. Codes are string constants and never change meaning.
public struct CLIError: Error, Equatable {
    public var code: String
    public var message: String
    public var exitCode: Int32
    public var retryable: Bool
    public var details: JSONValue?

    public init(code: String, message: String, exitCode: Int32, retryable: Bool = false, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
        self.retryable = retryable
        self.details = details
    }

    public static func invalidArgument(_ message: String, details: JSONValue? = nil) -> CLIError {
        CLIError(code: "invalid_argument", message: message, exitCode: 1, details: details)
    }

    public static func unknownCommand(_ name: String) -> CLIError {
        CLIError(
            code: "unknown_command",
            message: "未知のコマンドです: \(name)",
            exitCode: 1,
            details: .object([("known_commands", .array(CLICommand.allCases.map { .string($0.rawValue) }))])
        )
    }

    public static func unsupportedFlag(_ flag: String, command: String) -> CLIError {
        CLIError(
            code: "unsupported_flag",
            message: "\(flag) は読み取り専用コマンド \(command) では未対応です。書き込み系フラグは update コマンドでのみ使えます。",
            exitCode: 1,
            details: .object([("flag", .string(flag)), ("command", .string(command))])
        )
    }

    public static func idempotencyConflict(key: String, recordedServiceID: String, recordedEnabled: Bool) -> CLIError {
        CLIError(
            code: "idempotency_conflict",
            message: "冪等キー \(key) は別の変更（\(recordedServiceID) を \(recordedEnabled ? "有効化" : "無効化")）に使用済みです。別のキーを指定してください。",
            exitCode: 1,
            details: .object([
                ("idempotency_key", .string(key)),
                ("recorded_service_id", .string(recordedServiceID)),
                ("recorded_enabled", .bool(recordedEnabled))
            ])
        )
    }

    public static func notFound(_ message: String, details: JSONValue? = nil) -> CLIError {
        CLIError(code: "not_found", message: message, exitCode: 4, details: details)
    }

    public static func permissionDenied(_ message: String, details: JSONValue? = nil) -> CLIError {
        CLIError(code: "permission_denied", message: message, exitCode: 3, details: details)
    }

    public static func appFailure(_ message: String, code: String = "internal_error", details: JSONValue? = nil) -> CLIError {
        CLIError(code: code, message: message, exitCode: 2, details: details)
    }
}

/// Builds the unified envelopes from the CLI contract:
/// success `{"ok": true, "data": ..., "meta": {...}}` and
/// failure `{"ok": false, "error": {...}, "meta": {...}}`.
public enum CLIEnvelope {
    public static func success(data: JSONValue, command: String, requestID: String = UUID().uuidString) -> JSONValue {
        .object([
            ("ok", .bool(true)),
            ("data", data),
            ("meta", meta(command: command, requestID: requestID))
        ])
    }

    public static func failure(error: CLIError, command: String?, requestID: String = UUID().uuidString) -> JSONValue {
        var errorPairs: [(String, JSONValue)] = [
            ("code", .string(error.code)),
            ("message", .string(error.message)),
            ("retryable", .bool(error.retryable))
        ]
        if let details = error.details {
            errorPairs.append(("details", details))
        }
        return .object([
            ("ok", .bool(false)),
            ("error", .object(errorPairs)),
            ("meta", meta(command: command, requestID: requestID))
        ])
    }

    private static func meta(command: String?, requestID: String) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("schema_version", .int(aimeterCLISchemaVersion)),
            ("request_id", .string(requestID)),
            ("cli_version", .string(aimeterCLIVersion))
        ]
        if let command {
            pairs.append(("command", .string(command)))
        }
        return .object(pairs)
    }
}
