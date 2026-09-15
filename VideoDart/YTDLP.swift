import Foundation

enum YTEvent: Sendable {
    case progress(percent: Double, speed: String, eta: String, size: String)
    case file(String)
    case log(String)
    case exited(Int32)
}

struct MediaInfo: Sendable {
    struct Entry: Sendable, Identifiable, Hashable {
        var id: String
        var url: String
        var title: String
        var duration: Double?
        var thumbnail: String?
        var uploader: String
    }
    var isPlaylist: Bool
    var title: String
    var entries: [Entry]
}

struct YTError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum YTDLP {

    // MARK: - Locating the binary

    static var executablePath: String {
        // Only honour the override while it actually resolves. A stale path used to win
        // over every working copy, so a good install still left the app dead.
        let custom = Prefs.string(Prefs.Key.ytdlpPath)
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) { return custom }
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp",
                  ToolInstaller.managedYTDLP]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/opt/homebrew/bin/yt-dlp"
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executablePath) }

    /// yt-dlp alone is not enough: merging video with audio, extracting audio and
    /// embedding metadata, thumbnails or subtitles all shell out to ffmpeg.
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
         ToolInstaller.managedFFmpeg]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isFFmpegInstalled: Bool { ffmpegPath != nil }

    /// YouTube's format URLs are behind a JS challenge; without a runtime yt-dlp can
    /// only see thumbnails. deno is yt-dlp's recommended one.
    static var jsRuntimePath: String? {
        ["/opt/homebrew/bin/deno", "/usr/local/bin/deno", ToolInstaller.managedDeno]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isJSRuntimeInstalled: Bool { jsRuntimePath != nil }

    static let archiveURL = AppSupport.file("archive.txt")

    /// yt-dlp ships dated releases (2026.08.19). A stale copy is the single most common
    /// cause of YouTube extraction failures, so the age is worth surfacing.
    static func versionAge(_ version: String) -> Int? {
        let trimmed = version.split(separator: ".").prefix(3).joined(separator: ".")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy.MM.dd"
        guard let released = formatter.date(from: trimmed) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.day], from: released, to: Date()).day
    }

    /// GUI apps inherit a bare PATH, so yt-dlp would not find ffmpeg. Hand it one that works.
    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(ToolInstaller.binDirectory.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["NO_COLOR"] = "1"
        return env
    }

    // MARK: - Arguments

    static func cookieArguments() -> [String] {
        let source = Prefs.string(Prefs.Key.cookieSource)
        switch source {
        case "", "none":
            return []
        case "file":
            let f = Prefs.string(Prefs.Key.cookieFile)
            return f.isEmpty ? [] : ["--cookies", f]
        default:
            let profile = Prefs.string(Prefs.Key.cookieProfile)
            return ["--cookies-from-browser", profile.isEmpty ? source : "\(source):\(profile)"]
        }
    }

    static func arguments(for job: DownloadJob) -> [String] {
        var a = [
            "--newline", "--no-playlist", "--no-simulate", "--no-quiet",
            "--ignore-config",
            "--progress-template",
            "download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"
            + "|%(progress._downloaded_bytes_str)s|%(progress._total_bytes_str,progress._total_bytes_estimate_str)s",
            "--print", "after_move:FILE|%(filepath)s",
            "-P", job.destination,
            "-o", Prefs.string(Prefs.Key.filenameTemplate),
            "--continue", "-N", "4",
        ]
        if Prefs.bool(Prefs.Key.useArchive) { a += ["--download-archive", archiveURL.path] }
        // PATH alone is not enough when ffmpeg lives in Application Support.
        if let ffmpeg = ffmpegPath { a += ["--ffmpeg-location", ffmpeg] }
        if let deno = jsRuntimePath, deno == ToolInstaller.managedDeno {
            a += ["--js-runtimes", "deno:\(deno)"]
        }
        a += cookieArguments()

        let limit = Prefs.string(Prefs.Key.rateLimit)
        if !limit.isEmpty { a += ["--limit-rate", limit] }

        switch job.kind {
        case .audio:
            a += ["-f", "bestaudio/best", "-x"]
            if job.container != "original" {
                a += ["--audio-format", job.container, "--audio-quality", "0"]
            }
        case .video:
            let f = job.quality == "best" ? "bestvideo" : "bestvideo[height<=?\(job.quality)]/bestvideo"
            a += ["-f", f]
            if job.container != "original" { a += ["--remux-video", job.container] }
        case .videoAudio:
            let f = job.quality == "best"
                ? "bestvideo+bestaudio/best"
                : "bestvideo[height<=?\(job.quality)]+bestaudio/best[height<=?\(job.quality)]/best"
            a += ["-f", f]
            if job.container != "original" { a += ["--merge-output-format", job.container] }
        }

        if Prefs.bool(Prefs.Key.embedMetadata) { a.append("--embed-metadata") }
        if Prefs.bool(Prefs.Key.embedThumbnail) { a.append("--embed-thumbnail") }

        switch job.subs {
        case .off:
            break
        case .embed:
            a += ["--write-subs", "--write-auto-subs", "--sub-langs", job.subLangs,
                  "--embed-subs", "--compat-options", "no-keep-subs"]
        case .sidecar:
            a += ["--write-subs", "--write-auto-subs", "--sub-langs", job.subLangs,
                  "--convert-subs", "srt"]
        }

        a.append(job.url)
        return a
    }

    // MARK: - Probing

    /// One shot metadata read. `--flat-playlist` keeps playlists fast; a single video still
    /// comes back fully populated.
    static func probe(_ url: String) async throws -> MediaInfo {
        var args = ["--dump-single-json", "--flat-playlist", "--ignore-config", url]
        args.insert(contentsOf: cookieArguments(), at: 0)
        let (out, err, status) = try await capture(args)
        guard status == 0, let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw YTError(message: cleanError(err.isEmpty ? out : err))
        }
        return parse(json, requestedURL: url)
    }

    /// The generic extractor names a video after its file, so titles arrive as
    /// "Clip_02.mp4". Drop a trailing media extension; leave everything else alone.
    static func displayTitle(_ raw: String) -> String {
        let media = ["mp4", "mkv", "webm", "mov", "m4v", "mp3", "m4a", "flac", "opus", "wav"]
        guard let dot = raw.lastIndex(of: "."),
              media.contains(String(raw[raw.index(after: dot)...]).lowercased()),
              raw.distance(from: raw.startIndex, to: dot) > 0
        else { return raw }
        return String(raw[..<dot])
    }

    private static func parse(_ json: [String: Any], requestedURL: String) -> MediaInfo {
        func entry(_ d: [String: Any], fallbackURL: String?) -> MediaInfo.Entry {
            let id = d["id"] as? String ?? UUID().uuidString
            let thumbs = d["thumbnails"] as? [[String: Any]]
            return MediaInfo.Entry(
                id: id,
                url: d["webpage_url"] as? String ?? d["url"] as? String ?? fallbackURL ?? id,
                title: displayTitle(d["title"] as? String ?? "Untitled"),
                duration: d["duration"] as? Double,
                thumbnail: d["thumbnail"] as? String ?? thumbs?.last?["url"] as? String,
                uploader: d["uploader"] as? String ?? d["channel"] as? String ?? ""
            )
        }

        if (json["_type"] as? String) == "playlist", let raw = json["entries"] as? [[String: Any]] {
            return MediaInfo(
                isPlaylist: true,
                title: json["title"] as? String ?? "Playlist",
                entries: raw.map { entry($0, fallbackURL: nil) }
            )
        }
        let single = entry(json, fallbackURL: requestedURL)
        return MediaInfo(isPlaylist: false, title: single.title, entries: [single])
    }

    static func version() async -> String {
        guard isInstalled else { return "not found" }
        return (try? await capture(["--version"]).0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "?"
    }

    private static func capture(_ args: [String]) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executablePath)
                p.arguments = args
                p.environment = environment
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(throwing: YTError(message: "Could not run \(executablePath): \(error.localizedDescription)"))
                    return
                }
                let o = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let e = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                p.waitUntilExit()
                cont.resume(returning: (String(decoding: o, as: UTF8.self),
                                        String(decoding: e, as: UTF8.self),
                                        p.terminationStatus))
            }
        }
    }

    /// yt-dlp errors arrive as one long line of message + CLI hints + wiki links.
    /// Keep the sentences a human needs; the app handles the cookie flags itself.
    static func cleanError(_ raw: String) -> String {
        var line = String(raw.split(separator: "\n").last(where: { $0.contains("ERROR") })
            ?? raw.split(separator: "\n").last ?? "Unknown error")
        line = line.replacingOccurrences(of: "ERROR: ", with: "")
        // Cut sentence-wise, not at the hint token: Instagram phrases it mid-sentence
        // ("…if it is not, then use --cookies…"), so cutting at the token leaves a
        // dangling clause. Matching literals also missed yt-dlp's lowercase "use --"
        // and its double-spaced "See  https", which is how a 550-character wall of
        // CLI boilerplate used to reach the user.
        let machineTalk = #"(?i)(--\w|https?://|please report|also see|yt-dlp -U)"#
        let sentences = line.components(separatedBy: ". ")
        let kept = sentences.prefix { $0.range(of: machineTalk, options: .regularExpression) == nil }
        // Re-terminate only when something was dropped, so a message that never had a
        // full stop ("Unable to download webpage: HTTP Error 404") does not gain one.
        if !kept.isEmpty, kept.count < sentences.count { line = kept.joined(separator: ". ") + "." }
        // "[youtube] P1-Era4suVg: Sign in…" -> "Sign in…". Two separate strips: the
        // extractor tag always, then the video id only when it is a spaceless token,
        // so "Unable to download webpage: HTTP Error 404" keeps its colon.
        for pattern in [#"^\[[^\]]+\]\s*"#, #"^\S{1,40}:\s+"#] {
            if let r = line.range(of: pattern, options: .regularExpression) {
                line = String(line[r.upperBound...])
            }
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Errors a browser sign-in would fix. A regex rather than a list of literals because
    /// every site spells it differently — YouTube says "Sign in", Instagram says both
    /// "log in" and "logged-in", and a missed spelling means the sheet offers the user
    /// no way out of a wall they could clear by picking a browser. "registered users" is
    /// the default wording of yt-dlp's raise_login_required, so it covers many extractors.
    static func isAuthError(_ message: String) -> Bool {
        message.range(
            of: #"(?i)(sign ?in|log ?in|logged.?in|registered users|confirm your age|cookies|private video|members.only|not a bot)"#,
            options: .regularExpression) != nil
    }

    // MARK: - Streaming a download

    /// Starts yt-dlp and returns the live process plus a stream of parsed events.
    /// The caller owns the process (for pause/cancel) and must drain the stream.
    static func start(_ job: DownloadJob) throws -> (Process, AsyncStream<YTEvent>) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = arguments(for: job)
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let (stream, cont) = AsyncStream<YTEvent>.makeStream(bufferingPolicy: .unbounded)
        LineReader.attach(out.fileHandleForReading, cont) { event(from: $0) }
        LineReader.attach(err.fileHandleForReading, cont) { event(from: $0) }

        p.terminationHandler = { proc in
            for h in [out.fileHandleForReading, err.fileHandleForReading] {
                h.readabilityHandler = nil
                if let rest = try? h.readToEnd(), !rest.isEmpty {
                    for line in String(decoding: rest, as: UTF8.self).split(whereSeparator: \.isNewline) {
                        cont.yield(event(from: String(line)))
                    }
                }
            }
            cont.yield(.exited(proc.terminationStatus))
            cont.finish()
        }

        do { try p.run() } catch {
            cont.finish()
            throw YTError(message: "Could not run \(executablePath): \(error.localizedDescription)")
        }
        return (p, stream)
    }

    static func event(from line: String) -> YTEvent {
        if line.hasPrefix("PROG|") {
            let f = line.dropFirst(5).components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // yt-dlp writes unknown fields as "NA" or "N/A" depending on the formatter;
            // both must be swallowed rather than shown to the user.
            func field(_ i: Int) -> String {
                guard f.indices.contains(i), !["NA", "N/A", "none", ""].contains(f[i]) else { return "" }
                return f[i]
            }
            let pct = Double(field(0).replacingOccurrences(of: "%", with: "")) ?? 0
            let (got, total) = (field(3), field(4))
            let size = switch (got.isEmpty, total.isEmpty) {
            case (false, false): "\(got) of \(total)"
            case (false, true): got
            case (true, false): total
            case (true, true): ""
            }
            return .progress(percent: pct / 100, speed: field(1), eta: field(2), size: size)
        }
        if line.hasPrefix("FILE|") { return .file(String(line.dropFirst(5))) }
        return .log(line)
    }
}

/// Turns a pipe into whole lines. Shared by `YTDLP.start` and `FFmpeg.start`: both read a
/// child process that writes progress a line at a time, and a chunk boundary landing
/// mid-line is the kind of bug that only shows up under load.
///
/// ponytail: unchecked Sendable is safe here — a FileHandle calls its readability handler
/// serially, so only one thread ever touches the box.
enum LineReader {
    private final class Box: @unchecked Sendable {
        var buffer = Data()
    }

    /// `parse` returning nil drops the line — ffmpeg's `-progress` output is mostly keys
    /// that mean nothing until the block terminator arrives.
    static func attach<E: Sendable>(_ handle: FileHandle,
                                    _ cont: AsyncStream<E>.Continuation,
                                    _ parse: @escaping @Sendable (String) -> E?) {
        let box = Box()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { fh.readabilityHandler = nil; return }
            box.buffer.append(chunk)
            // yt-dlp uses \n with --newline, but postprocessors still emit \r.
            while let i = box.buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: box.buffer[..<i], as: UTF8.self)
                box.buffer.removeSubrange(...i)
                if !line.isEmpty, let event = parse(line) { cont.yield(event) }
            }
        }
    }
}
