import Foundation
import AIMeterCore

/// Everything a command run needs from the outside world, injected so tests
/// can substitute a temporary data directory and a dedicated defaults suite.
public struct CLIEnvironment {
    /// Directory holding `.ai_meter_usage.json` and `.ai_meter_widget.json`.
    public var dataDirectory: URL
    /// The app's preferences domain (direct build: `com.local.AIMeter`).
    public var defaults: UserDefaults
    public var preferenceDomain: String
    public var timeZone: TimeZone

    public init(dataDirectory: URL, defaults: UserDefaults, preferenceDomain: String, timeZone: TimeZone = .current) {
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        self.preferenceDomain = preferenceDomain
        self.timeZone = timeZone
    }
}

public struct CLIResult: Equatable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Argument parsing, dispatch, and envelope rendering. Pure with respect to
/// the process: the executable's `main` only resolves the environment,
/// prints `output`, and exits with `exitCode`.
public enum CLIEngine {
    public static func run(arguments: [String], environment: CLIEnvironment) -> CLIResult {
        let parsed: CLIArguments
        do {
            parsed = try CLIArguments.parse(arguments)
        } catch let error as CLIError {
            return failure(error, format: .json, command: nil)
        } catch {
            return failure(.appFailure("引数の解析に失敗しました。"), format: .json, command: nil)
        }

        if parsed.wantsHelp {
            let text = parsed.command.map { CLIHelp.text(for: $0) } ?? CLIHelp.topLevel
            return CLIResult(exitCode: 0, output: text)
        }

        guard let commandName = parsed.commandName else {
            return failure(
                .invalidArgument("コマンドを指定してください。--help で使い方を表示します。"),
                format: parsed.format, command: nil
            )
        }
        guard let command = parsed.command else {
            return failure(.unknownCommand(commandName), format: parsed.format, command: commandName)
        }
        if command.isReadOnly, let flag = parsed.unsupportedFlags.first {
            return failure(.unsupportedFlag(flag, command: command.rawValue), format: parsed.format, command: command.rawValue)
        }
        if command != .update, parsed.enabledState != nil {
            return failure(
                .invalidArgument("--enabled / --disabled は update コマンド専用のフラグです。"),
                format: parsed.format, command: command.rawValue
            )
        }

        var environment = environment
        if let override = parsed.dataDirectoryOverride {
            environment.dataDirectory = URL(fileURLWithPath: override)
        }
        let context = CLIContext(environment: environment)

        do {
            let result: CLICommandResult
            switch command {
            case .status:
                result = try context.runStatus()
            case .list:
                result = context.runList()
            case .get:
                guard let serviceID = parsed.positional.first, parsed.positional.count == 1 else {
                    throw CLIError.invalidArgument("get にはサービス ID を 1 つだけ指定してください。例: AIMeterCLI get openai")
                }
                result = try context.runGet(serviceID: serviceID)
            case .history:
                result = context.runHistory()
            case .doctor:
                result = context.runDoctor()
            case .update:
                guard parsed.positional.count == 2, parsed.positional[0] == "service" else {
                    throw CLIError.invalidArgument("使い方: AIMeterCLI update service <サービスID> --enabled|--disabled")
                }
                guard let enabled = parsed.enabledState else {
                    throw CLIError.invalidArgument("update には --enabled か --disabled のどちらかが必要です。")
                }
                result = try context.runUpdateService(
                    serviceID: parsed.positional[1],
                    enabled: enabled,
                    dryRun: parsed.dryRun,
                    idempotencyKey: parsed.idempotencyKey
                )
            case .verify:
                guard parsed.positional.isEmpty else {
                    throw CLIError.invalidArgument("verify には引数はありません。")
                }
                result = try context.runVerify()
            }
            switch parsed.format {
            case .json:
                return CLIResult(
                    exitCode: result.exitCode,
                    output: CLIEnvelope.success(data: result.data, command: command.rawValue).serializedString()
                )
            case .human:
                return CLIResult(exitCode: result.exitCode, output: result.human)
            }
        } catch let error as CLIError {
            return failure(error, format: parsed.format, command: command.rawValue)
        } catch {
            return failure(
                .appFailure("予期しないエラーが発生しました: \(error.localizedDescription)"),
                format: parsed.format, command: command.rawValue
            )
        }
    }

    private static func failure(_ error: CLIError, format: CLIOutputFormat, command: String?) -> CLIResult {
        switch format {
        case .json:
            return CLIResult(
                exitCode: error.exitCode,
                output: CLIEnvelope.failure(error: error, command: command).serializedString()
            )
        case .human:
            return CLIResult(exitCode: error.exitCode, output: "エラー [\(error.code)]: \(error.message)")
        }
    }
}
