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
        ["/opt/homebrew/bin/deno", "/usr/local/bin/deno", NSHomeDirectory() + "/.deno/bin/deno",
         ToolInstaller.managedDeno]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isJSRuntimeInstalled: Bool { jsRuntimePath != nil }

    static let archiveURL = AppSupport.file("archive.txt")
    /// The archive records a video's id whatever was fetched, so "Both, split" — two jobs,
    /// one id — finished whichever ran second as "Already downloaded", with no file.
    /// Audio keeps its own record.
    static let audioArchiveURL = AppSupport.file("archive-audio.txt")
    static func archive(for kind: MediaKind) -> URL { kind == .audio ? audioArchiveURL : archiveURL }

    static let defaultFilenameTemplate = "%(title)s [%(id)s].%(ext)s"

    /// yt-dlp's --limit-rate syntax ("500K", "2.5M"), forgiving of a space and lowercase.
    /// Anything else is dropped rather than passed on: a typo there failed every job.
    static func rateLimit(_ text: String) -> String? {
        let compact = text.replacingOccurrences(of: " ", with: "").uppercased()
        guard compact.range(of: #"^\d+(\.\d+)?[KMG]?$"#, options: .regularExpression) != nil,
              (Double(compact.trimmingCharacters(in: .letters)) ?? 0) > 0 else { return nil }
        return compact
    }

    /// yt-dlp ships dated releases (2026.08.19). A stale copy is the single most common
    /// cause of YouTube extraction failures — but age alone says nothing: yt-dlp can go
    /// weeks between releases, and the banner used to nag about a copy that was already
    /// the latest. So it compares against the newest release instead.
    static func isBehind(_ installed: String, latest: String) -> Bool {
        guard let have = releaseDate(installed), let want = releaseDate(latest) else { return false }
        return have.lexicographicallyPrecedes(want)
    }

    /// The first three components as numbers. A nightly's fourth is a build time, so a
    /// nightly from the same day as the stable release counts as current.
    private static func releaseDate(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    /// The newest release the copy in use can actually update to, asked at most once a
    /// day. A Homebrew copy is compared with Homebrew's formula, which trails GitHub by a
    /// day or two — measured against GitHub, the banner offered a `brew upgrade` that had
    /// nothing to install. Everything else updates from GitHub (the unauthenticated API
    /// allows 60 requests an hour). Offline, it falls back to the last answer, or nil,
    /// and the banner stays quiet rather than guess.
    static func latestRelease() async -> String? {
        let homebrew = isHomebrew
        // Keyed by source, so switching between copies never compares against the
        // other feed's cached answer.
        let key = Prefs.Key.ytdlpLatest + (homebrew ? ".brew" : "")
        let checkedKey = Prefs.Key.ytdlpLatestCheckedAt + (homebrew ? ".brew" : "")
        let defaults = UserDefaults.standard
        let cached = defaults.string(forKey: key)
        if cached != nil, Date().timeIntervalSince1970 - defaults.double(forKey: checkedKey) < 86_400 {
            return cached
        }

        var request = URLRequest(url: URL(string: homebrew
            ? "https://formulae.brew.sh/api/formula/yt-dlp.json"
            : "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        if !homebrew { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = homebrew ? formulaVersion(data) : releaseTag(data)
        else { return cached }
        defaults.set(latest, forKey: key)
        defaults.set(Date().timeIntervalSince1970, forKey: checkedKey)
        return latest
    }

    static func releaseTag(_ data: Data) -> String? {
        struct Release: Decodable { let tagName: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Release.self, from: data).tagName
    }

    static func formulaVersion(_ data: Data) -> String? {
        struct Formula: Decodable { struct Versions: Decodable { let stable: String }; let versions: Versions }
        return try? JSONDecoder().decode(Formula.self, from: data).versions.stable
    }

    private static var isHomebrew: Bool {
        URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path.contains("/Cellar/")
    }

    /// The command that updates the copy in use — nil for the app's own copy, which the
    /// banner updates in place. `brew upgrade` can't touch anything else, and `-U` can't
    /// touch a Homebrew install, so the banner must offer the one that works.
    static var updateCommand: String? {
        let path = executablePath
        if path == ToolInstaller.managedYTDLP { return nil }
        if isHomebrew { return "brew upgrade yt-dlp" }
        return "'\(path)' -U"
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
            // A cleared field stores "", and `-o ""` names nothing.
            "-o", Prefs.string(Prefs.Key.filenameTemplate).trimmingCharacters(in: .whitespaces).isEmpty
                ? defaultFilenameTemplate : Prefs.string(Prefs.Key.filenameTemplate),
            "--continue", "-N", "4",
        ]
        if Prefs.bool(Prefs.Key.useArchive) { a += ["--download-archive", archive(for: job.kind).path] }
        // PATH alone is not enough when ffmpeg lives in Application Support.
        if let ffmpeg = ffmpegPath { a += ["--ffmpeg-location", ffmpeg] }
        if let deno = jsRuntimePath, deno == ToolInstaller.managedDeno {
            a += ["--js-runtimes", "deno:\(deno)"]
        }
        a += cookieArguments()

        if let limit = rateLimit(Prefs.string(Prefs.Key.rateLimit)) { a += ["--limit-rate", limit] }

        // "MP4" should mean a file QuickTime plays. Left to its default ranking yt-dlp
        // picks AV1 or VP9 with Opus and copies them into the MP4 untouched. Resolution
        // still ranks first, so asking for 4K still gets 4K; at each size H.264 and AAC win.
        if job.kind != .audio, ["mp4", "mov"].contains(job.container) {
            a += ["-S", "res,vcodec:h264,acodec:m4a"]
        }

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
        // --no-playlist as the download has: a watch link copied from inside a playlist
        // or a YouTube Mix means that video. A plain playlist link is still a playlist.
        var args = ["--dump-single-json", "--flat-playlist", "--no-playlist", "--ignore-config", url]
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
                // Drain stderr alongside stdout: read one after the other, a full stderr
                // pipe stalls yt-dlp while stdout waits for an EOF that never comes.
                nonisolated(unsafe) var e = Data()
                let drained = DispatchGroup()
                DispatchQueue.global().async(group: drained) {
                    e = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                }
                let o = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                drained.wait()
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
        // The path yt-dlp quotes is the browser's folder plus the Profile setting, which is
        // easy to get wrong: Chrome's menu says "David", its folder says "Profile 1".
        if let r = line.range(of: #"could not find \w+ cookies database"#, options: .regularExpression) {
            let browser = line[r].split(separator: " ")[3].capitalized
            return "Couldn’t find \(browser)’s cookies. \(cookieSetupHint)"
        }
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

    private static let cookieSetupHint =
        "Check Profile in Settings ▸ Account — leave it blank for the browser’s default profile."

    /// The cookie source points nowhere. Settings fixes it; signing in again does not.
    static func isCookieSetupError(_ message: String) -> Bool {
        message.hasSuffix(cookieSetupHint)
    }

    /// Errors a browser sign-in would fix. A regex rather than a list of literals because
    /// every site spells it differently — YouTube says "Sign in", Instagram says both
    /// "log in" and "logged-in", and a missed spelling means the sheet offers the user
    /// no way out of a wall they could clear by picking a browser. "registered users" is
    /// the default wording of yt-dlp's raise_login_required, so it covers many extractors.
    static func isAuthError(_ message: String) -> Bool {
        !isCookieSetupError(message) && message.range(
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
        let drained = DispatchGroup()
        LineReader.attach(out.fileHandleForReading, cont, drained) { event(from: $0) }
        LineReader.attach(err.fileHandleForReading, cont, drained) { event(from: $0) }

        p.terminationHandler = { proc in
            LineReader.finish(drained, [out.fileHandleForReading, err.fileHandleForReading])
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
    ///
    /// Each reader leaves `drained` at EOF, after flushing a last line that had no newline.
    /// The exit event waits on that: it used to cut the readers off and read the rest
    /// itself, which raced a handler already running and could drop the `FILE|` line or
    /// deliver a progress tick after the exit.
    static func attach<E: Sendable>(_ handle: FileHandle,
                                    _ cont: AsyncStream<E>.Continuation,
                                    _ drained: DispatchGroup,
                                    _ parse: @escaping @Sendable (String) -> E?) {
        let box = Box()
        drained.enter()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else {
                fh.readabilityHandler = nil
                let last = String(decoding: box.buffer, as: UTF8.self)
                box.buffer.removeAll()
                if !last.isEmpty, let event = parse(last) { cont.yield(event) }
                drained.leave()
                return
            }
            box.buffer.append(chunk)
            // yt-dlp uses \n with --newline, but postprocessors still emit \r.
            while let i = box.buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: box.buffer[..<i], as: UTF8.self)
                box.buffer.removeSubrange(...i)
                if !line.isEmpty, let event = parse(line) { cont.yield(event) }
            }
        }
    }

    /// Called from a termination handler. A grandchild (yt-dlp's ffmpeg) can hold a pipe
    /// open past the exit, so the wait is bounded; past it the readers are cut off.
    static func finish(_ drained: DispatchGroup, _ handles: [FileHandle]) {
        if drained.wait(timeout: .now() + 5) == .timedOut {
            for h in handles { h.readabilityHandler = nil }
        }
    }
}
