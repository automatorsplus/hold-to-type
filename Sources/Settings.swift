import Foundation

/// Preferences live in UserDefaults (domain local.holdtotype), so they can also be set with `defaults write`.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var hotkey: Hotkey {
        get { defaults.string(forKey: "hotkey").flatMap(Hotkey.init(rawValue:)) ?? .key(.rightOption) }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var insertMethod: InsertMethod {
        get { defaults.string(forKey: "insertMethod").flatMap(InsertMethod.init(rawValue:)) ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: "insertMethod") }
    }

    /// Whisper language code ("en", "de", ...) or "auto".
    static var language: String {
        get { defaults.string(forKey: "language") ?? "en" }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Optional vocabulary hint passed to Whisper as its initial prompt (names, jargon, spelling).
    static var vocabulary: String? {
        defaults.string(forKey: "vocabulary")
    }

    static var modelPath: String {
        if let custom = defaults.string(forKey: "modelPath"), !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        let candidates = [
            "~/.cache/whisper-models/ggml-large-v3-turbo.bin",
            "~/.cache/whisper/ggml-large-v3-turbo.bin",
        ].map { ($0 as NSString).expandingTildeInPath }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }
}
