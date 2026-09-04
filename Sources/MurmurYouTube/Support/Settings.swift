import Foundation
import Observation

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Which mini-pill layout the HUD uses (wave only / last word / tail / word+timer).
    var hudStyle: HUDStyle {
        didSet { defaults.set(hudStyle.rawValue, forKey: Keys.hudStyle) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let hudStyle = "hudStyle"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.f19.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .f19
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        hudStyle = HUDStyle(rawValue: defaults.string(forKey: Keys.hudStyle) ?? "") ?? .wordTimer
    }
}
