import Foundation
import Observation

/// Everything the app keeps between launches: the queue, the saved presets, the download
/// archive and the managed yt-dlp/ffmpeg/deno binaries.
enum AppSupport {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VideoDart", isDirectory: true)
        // The app was called VideoDownloader until 0.3.0. Adopt the old folder wholesale
        // rather than start clean: it holds the queue, the saved presets and ~90 MB of
        // downloaded tools that would otherwise all be fetched again on first launch.
        let legacy = base.appendingPathComponent("VideoDownloader", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Creates the directory on first use, so callers never have to.
    static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

/// Downloads yt-dlp and ffmpeg into Application Support so a machine without Homebrew
/// still works. They live outside the app bundle deliberately: a binary inside a signed
/// bundle cannot be replaced without invalidating the signature, which would freeze
/// yt-dlp between app releases — exactly the staleness the banner warns about.
@MainActor @Observable
final class ToolInstaller {
    enum Phase: Equatable {
        case idle
        case working(label: String, fraction: Double)
        case failed(String)
        case done
    }

    var phase: Phase = .idle

    nonisolated static let binDirectory: URL = {
        let dir = AppSupport.directory.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static var managedYTDLP: String { binDirectory.appendingPathComponent("yt-dlp").path }
    nonisolated static var managedFFmpeg: String { binDirectory.appendingPathComponent("ffmpeg").path }
    nonisolated static var managedDeno: String { binDirectory.appendingPathComponent("deno").path }

    private static let ytdlpSource = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    // yt-dlp_macos is a universal binary, so one asset covers both Macs. ffmpeg is not:
    // the arch is baked in, and `#if arch` resolves per-slice in a universal build.
    #if arch(arm64)
    private static let ffmpegSource = URL(
        string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz")!
    private static let denoSource = URL(
        string: "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip")!
    #else
    private static let ffmpegSource = URL(
        string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64.gz")!
    private static let denoSource = URL(
        string: "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip")!
    #endif

    func install() async {
        do {
            if !FileManager.default.isExecutableFile(atPath: Self.managedYTDLP) {
                try await fetch(Self.ytdlpSource, to: Self.managedYTDLP,
                                label: "Downloading yt-dlp", gzipped: false)
            }
            if !FileManager.default.isExecutableFile(atPath: Self.managedFFmpeg) {
                try await fetch(Self.ffmpegSource, to: Self.managedFFmpeg,
                                label: "Downloading ffmpeg", gzipped: true)
            }
            // YouTube signs its formats behind a JS challenge. With no runtime present
            // yt-dlp reports "only images are available" — so this is not optional.
            if !FileManager.default.isExecutableFile(atPath: Self.managedDeno) {
                try await fetch(Self.denoSource, to: Self.managedDeno,
                                label: "Downloading JavaScript runtime", zipped: true)
            }
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Replaces the managed yt-dlp with the current release. ffmpeg is left alone —
    /// it is not the part that rots.
    func updateYTDLP() async {
        do {
            try? FileManager.default.removeItem(atPath: Self.managedYTDLP)
            try await fetch(Self.ytdlpSource, to: Self.managedYTDLP,
                            label: "Updating yt-dlp", gzipped: false)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func fetch(_ source: URL, to destination: String, label: String,
                       gzipped: Bool = false, zipped: Bool = false) async throws {
        phase = .working(label: label, fraction: 0)
        let reporter = ProgressReporter { fraction in
            Task { @MainActor [weak self] in self?.phase = .working(label: label, fraction: fraction) }
        }
        let (temporary, response) = try await URLSession.shared.download(from: source, delegate: reporter)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
            throw YTError(message: "\(label) failed: server returned an error.")
        }

        try? FileManager.default.removeItem(atPath: destination)
        if zipped {
            try unzip(temporary, to: destination)
        } else if gzipped {
            try expand(temporary, to: destination)
        } else {
            try FileManager.default.moveItem(at: temporary, to: URL(fileURLWithPath: destination))
        }
        // Both upstream binaries already carry an ad-hoc signature, which Apple Silicon
        // requires; nothing here re-signs them, so no Command Line Tools dependency.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
    }

    /// deno ships as a zip holding one binary.
    private func unzip(_ archive: URL, to destination: String) throws {
        let staging = URL(fileURLWithPath: destination + ".unzip", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-q", "-o", archive.path, "-d", staging.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw YTError(message: "Could not expand the JavaScript runtime download.")
        }
        let name = URL(fileURLWithPath: destination).lastPathComponent
        let unpacked = try FileManager.default
            .contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent == name } ?? staging.appendingPathComponent(name)
        try FileManager.default.moveItem(at: unpacked, to: URL(fileURLWithPath: destination))
    }

    private func expand(_ archive: URL, to destination: String) throws {
        guard FileManager.default.createFile(atPath: destination, contents: nil) else {
            throw YTError(message: "Could not write to \(destination).")
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
        defer { try? output.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        task.arguments = ["-c", archive.path]
        task.standardOutput = output
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw YTError(message: "Could not expand the ffmpeg download.")
        }
    }
}

/// URLSession hands progress to a delegate; the async download API accepts one directly.
private final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by the protocol; the async API returns the file itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
