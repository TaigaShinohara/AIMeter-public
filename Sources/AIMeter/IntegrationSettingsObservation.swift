import Foundation
import CoreFoundation

/// Revocation may originate from AppStorage or a direct defaults write. Keep
/// the synchronous permission boundary independent of MainActor notification
/// delivery, including rapid off -> on transitions.
final class IntegrationPermitSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: IntegrationPermit?

    func install(_ permit: IntegrationPermit) {
        lock.lock(); let previous = current; current = permit; lock.unlock()
        previous?.revoke()
    }

    func revoke() {
        lock.lock(); let previous = current; current = nil; lock.unlock()
        previous?.revoke()
    }
}

final class IntegrationSettingsObservation: NSObject {
    // Absence keeps the product's existing default. A malformed persisted value
    // is not permission to load credentials or start an integration.
    static func isEnabled(in defaults: UserDefaults, key: String) -> Bool {
        guard let value = defaults.object(forKey: key) else { return true }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    private let defaults: UserDefaults
    private let openAI: IntegrationPermitSlot
    private let gemini: IntegrationPermitSlot
    private let local: IntegrationPermitSlot?
    private let changed: (String, Bool?) -> Void
    private let keys = ["showOpenAISection", "showGeminiSection", "gcpProjectId"]

    init(defaults: UserDefaults, openAI: IntegrationPermitSlot, gemini: IntegrationPermitSlot,
         local: IntegrationPermitSlot? = nil,
         changed: @escaping (String, Bool?) -> Void) {
        self.defaults = defaults; self.openAI = openAI; self.gemini = gemini; self.local = local; self.changed = changed
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, options: [.old, .new], context: nil) }
    }

    deinit { for key in keys { defaults.removeObserver(self, forKeyPath: key) } }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath, keys.contains(keyPath) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context); return
        }
        if let old = change?[.oldKey] as? NSObject, let new = change?[.newKey] as? NSObject,
           CFGetTypeID(old) == CFGetTypeID(new), old.isEqual(new) { return }
        if keyPath == "showOpenAISection" { openAI.revoke() } else { gemini.revoke() }
        if keyPath != "gcpProjectId" { local?.revoke() }
        let enabled: Bool? = keyPath == "gcpProjectId" ? nil : Self.isEnabled(in: defaults, key: keyPath)
        changed(keyPath, enabled)
    }
}
