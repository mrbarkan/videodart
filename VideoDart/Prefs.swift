import Foundation

/// Thin wrapper over UserDefaults so SettingsView (@AppStorage) and the argument
/// builder read the same keys. ponytail: no observable settings object, defaults are read on demand.
enum Prefs {
    enum Key {
        static let downloadDir = "downloadDir"
        static let filenameTemplate = "filenameTemplate"
        static let maxConcurrent = "maxConcurrent"
        static let embedMetadata = "embedMetadata"
        static let embedThumbnail = "embedThumbnail"
        static let cookieSource = "cookieSource"
        static let cookieProfile = "cookieProfile"
        static let cookieFile = "cookieFile"
        static let ytdlpPath = "ytdlpPath"
        static let subLangs = "subLangs"
        static let rateLimit = "rateLimit"
        static let useArchive = "useArchive"
        static let watchClipboard = "watchClipboard"
        /// Empty writes the converted file beside its source, which is what a
        /// converter is expected to do; a path overrides that for every job.
        static let convertDir = "convertDir"
        static let convertPreset = "convertPreset"
    }

    static let browsers = ["safari", "chrome", "brave", "firefox", "edge", "chromium", "vivaldi", "opera"]

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.downloadDir: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                ?? NSHomeDirectory() + "/Downloads",
            Key.filenameTemplate: "%(title)s [%(id)s].%(ext)s",
            Key.maxConcurrent: 2,
            Key.embedMetadata: true,
            Key.embedThumbnail: true,
            Key.cookieSource: "none",
            Key.cookieProfile: "",
            Key.cookieFile: "",
            Key.ytdlpPath: "",
            Key.subLangs: "en",
            Key.rateLimit: "",
            Key.useArchive: false,
            Key.watchClipboard: true,
            Key.convertDir: "",
            Key.convertPreset: "",
        ])
    }

    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func int(_ k: String) -> Int { UserDefaults.standard.integer(forKey: k) }
}
