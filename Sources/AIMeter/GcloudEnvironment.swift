import Foundation
import AIMeterCore
import Darwin

/// gcloud itself and its SDK dependencies remain trusted local software. Do not
/// inherit Python/loader injection variables or arbitrary credential overrides.
enum GcloudEnvironment {
    enum Failure: Error { case configuration }

    static func make(home: String, inherited: [String: String]) throws -> [String: String] {
        // Silently dropping an explicit credential source could switch to a
        // different (possibly broader) default account. Refuse that mode.
        for key in ["CLOUDSDK_AUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
                    "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "GOOGLE_APPLICATION_CREDENTIALS"] {
            if let value = inherited[key], !value.isEmpty { throw Failure.configuration }
        }
        var result = ["HOME": home, "CLOUDSDK_CORE_DISABLE_PROMPTS": "1",
                      "CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK": "1", "LANG": "en_US.UTF-8"]
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .compactMap { ExecutableTrust.directory(at: $0) }
        result["PATH"] = directories.joined(separator: ":")
        for key in ["USER", "LOGNAME"] {
            if let value = inherited[key], !value.utf8.contains(0) { result[key] = value }
        }
        // These selectors contain identity/configuration names, not secret
        // material. Preserve explicit selections rather than changing accounts.
        for key in ["CLOUDSDK_ACTIVE_CONFIG_NAME", "CLOUDSDK_CORE_ACCOUNT",
                    "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT",
                    "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT_DELEGATES"] {
            if let value = inherited[key] {
                guard value.utf8.count <= 1024, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
                    throw Failure.configuration
                }
                result[key] = value
            }
        }
        if let configuration = inherited["CLOUDSDK_CONFIG"] {
            guard let trusted = ExecutableTrust.directory(at: configuration) else { throw Failure.configuration }
            result["CLOUDSDK_CONFIG"] = trusted
        } else {
            result["CLOUDSDK_CONFIG"] = try defaultConfiguration(home: home)
        }
        if let python = inherited["CLOUDSDK_PYTHON"] {
            guard let trusted = ExecutableTrust.executable(at: python) else { throw Failure.configuration }
            result["CLOUDSDK_PYTHON"] = trusted
        }
        return result
    }

    private static func defaultConfiguration(home: String) throws -> String {
        // gcloud's macOS default is $HOME/.config/gcloud. Check that selected
        // directory too: an unset override must not bypass the ancestry checks.
        guard let trustedHome = ExecutableTrust.directory(at: home) else { throw Failure.configuration }
        var parent = URL(fileURLWithPath: trustedHome, isDirectory: true)
        let components = [".config", "gcloud"]
        for (index, component) in components.enumerated() {
            let candidate = parent.appendingPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(candidate.path, &info) == 0 {
                guard let trusted = ExecutableTrust.directory(at: candidate.path) else { throw Failure.configuration }
                parent = URL(fileURLWithPath: trusted, isDirectory: true)
            } else {
                // A first-time gcloud invocation may create its default path.
                // Only genuine absence beneath a checked, non-shared ancestor
                // is acceptable; dangling symlinks and other errors fail closed.
                guard errno == ENOENT else { throw Failure.configuration }
                return components[index...].reduce(parent) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }.path
            }
        }
        return parent.path
    }
}
