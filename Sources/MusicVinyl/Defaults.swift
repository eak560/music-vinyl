import Foundation

/// Thin wrapper over `UserDefaults` so model properties can persist themselves
/// without pulling in `@AppStorage`, which only works inside a `View`.
enum Defaults {
    static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func set(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
