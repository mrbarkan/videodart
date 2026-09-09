import Foundation
import UniformTypeIdentifiers

enum FFEvent: Sendable {
    case duration(Double)                                    // from ffmpeg's own banner
    case progress(seconds: Double, speed: String, size: String)
    case log(String)
    case exited(Int32)
}

/// Runs the same ffmpeg the downloader already located and installs. Shaped like
/// `YTDLP`: an argument builder, plus a `start` that hands back the live process and a
/// stream of parsed events.
enum FFmpeg {

    static var executablePath: String? { YTDLP.ffmpegPath }
    static var isInstalled: Bool { executablePath != nil }

    /// What the resolved binary can actually encode. ffmpeg builds differ — the Homebrew
    /// 9.x here has no libvorbis, the bundled static 6.0 does — so the pickers are filtered
    /// against this rather than against the catalogue.
    ///
    /// Cached, but only once it has something: a `static let` computed while ffmpeg was
    /// still missing would pin the empty set for the life of the process, so installing
    /// from the banner would leave every codec menu blank until the next launch.
    /// ponytail: a blocking read costs one ~50 ms exec the first time the Convert window
    /// opens, which is cheaper than threading an async load through the view.
    @MainActor private static var encoderCache: Set<String> = []

    @MainActor static var supportedEncoders: Set<String> {
        if encoderCache.isEmpty { encoderCache = readEncoders() }
        return encoderCache
    }

    private static func readEncoders() -> Set<String> {
        guard let path = executablePath else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-encoders"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        // Rows look like " V....D libx264   libx264 H.264 ..." — the flags column first.
        return Set(String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 2, fields[0].count == 6,
                      let kind = fields[0].first, kind == "V" || kind == "A" else { return nil }
                return String(fields[1])
            })
    }

    /// GUI apps inherit a bare PATH; ffmpeg itself needs none of it, but keep the same
    /// environment the downloader uses so behaviour does not diverge between the two.
    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(ToolInstaller.binDirectory.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["NO_COLOR"] = "1"
        return env
    }

    // MARK: - Output naming

    /// Never returns the source path. Converting an MP4 to an MP4 in place would hand
    /// ffmpeg its own input as the output and truncate the original to nothing, so a
    /// collision — with the source or with any existing file — always gets a suffix.
    static func outputURL(for job: ConvertJob) -> URL {
        let directory = job.destinationDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? job.source.deletingLastPathComponent()
        let ext = job.preset.container == "original" ? job.source.pathExtension : job.preset.container
        let base = job.source.deletingPathExtension().lastPathComponent

        func candidate(_ name: String) -> URL {
            directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        func isFree(_ url: URL) -> Bool {
            url.standardizedFileURL.path.compare(job.source.standardizedFileURL.path,
                                                 options: .caseInsensitive) != .orderedSame
                && !FileManager.default.fileExists(atPath: url.path)
        }

        let plain = candidate(base)
        if isFree(plain) { return plain }
        let suffixed = candidate("\(base) (converted)")
        if isFree(suffixed) { return suffixed }
        for n in 2...999 {
            let numbered = candidate("\(base) (converted \(n))")
            if isFree(numbered) { return numbered }
        }
        return candidate("\(base) (converted \(UUID().uuidString.prefix(6)))")
    }

    // MARK: - Arguments

    static func arguments(for job: ConvertJob, output: URL) -> [String] {
        let preset = job.preset
        var a = ["-hide_banner",
                 // Without -nostdin ffmpeg grabs the shared terminal input and a GUI-spawned
                 // job can sit forever waiting on a keypress that will never come.
                 "-nostdin", "-y"]

        // -ss before -i seeks the input, which is fast; -t after it bounds the output, which
        // avoids -to's ambiguity about whether it counts from zero or from the seek point.
        if let start = Timecode.seconds(job.trimStart) { a += ["-ss", trimValue(start)] }
        a += ["-i", job.source.path]
        if let span = trimDuration(job) { a += ["-t", trimValue(span)] }

        a += ["-progress", "pipe:1", "-nostats"]

        if !preset.includeVideo {
            a.append("-vn")
        } else if preset.videoCodec == Encoders.copyID {
            a += ["-c:v", "copy"]
        } else {
            a += ["-c:v", preset.videoCodec]
            switch Encoders.video(preset.videoCodec)?.quality {
            case .crf: a += ["-crf", String(preset.crf)]
            case .bitrate: a += ["-b:v", preset.videoBitrate]
            case .prores: a += ["-profile:v", String(preset.proresProfile)]
            default: break
            }
            var filters: [String] = []
            if preset.maxHeight > 0 {
                // -2 keeps the aspect ratio and rounds to an even width, which every H.26x
                // encoder requires; min() means a 480p source is never blown up to 1080p.
                // The comma is escaped because ffmpeg reads a bare one as a filter separator.
                filters.append("scale=-2:min(ih\\,\(preset.maxHeight))")
            }
            if !filters.isEmpty { a += ["-vf", filters.joined(separator: ",")] }
            if preset.fps > 0 { a += ["-r", preset.formattedFPS] }
        }

        if !preset.includeAudio {
            a.append("-an")
        } else if preset.audioCodec == Encoders.copyID {
            a += ["-c:a", "copy"]
        } else {
            a += ["-c:a", preset.audioCodec]
            if Encoders.audio(preset.audioCodec)?.takesBitrate == true {
                a += ["-b:a", preset.audioBitrate]
            }
        }

        a += tokenize(preset.extraFlags)
        a.append(output.path)
        return a
    }

    /// The trimmed span, or nil when the job runs to the end of the source.
    static func trimDuration(_ job: ConvertJob) -> Double? {
        guard let end = Timecode.seconds(job.trimEnd) else { return nil }
        let start = Timecode.seconds(job.trimStart) ?? 0
        return end > start ? end - start : nil
    }

    /// ffmpeg wants a plain number of seconds; formatting keeps sub-second precision
    /// without ever reaching exponent notation.
    private static func trimValue(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    /// Splits the "extra flags" field the way a shell would, so a filter argument can be
    /// quoted: -vf "eq=contrast=1.2" arrives as two tokens, not three.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in text {
            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    // MARK: - Running

    static func start(_ job: ConvertJob, output: URL) throws -> (Process, AsyncStream<FFEvent>) {
        guard let path = executablePath else {
            throw YTError(message: "ffmpeg was not found.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments(for: job, output: output)
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let (stream, cont) = AsyncStream<FFEvent>.makeStream(bufferingPolicy: .unbounded)
        // -progress writes key=value blocks to stdout; the banner carrying Duration goes
        // to stderr. Two parsers, one line reader — the same one yt-dlp's output uses.
        let progress = ProgressAccumulator()
        LineReader.attach(out.fileHandleForReading, cont) { progress.consume($0) }
        LineReader.attach(err.fileHandleForReading, cont) { banner(from: $0) }

        p.terminationHandler = { proc in
            for h in [out.fileHandleForReading, err.fileHandleForReading] {
                h.readabilityHandler = nil
                if let rest = try? h.readToEnd(), !rest.isEmpty {
                    for line in String(decoding: rest, as: UTF8.self).split(whereSeparator: \.isNewline) {
                        if let event = banner(from: String(line)) { cont.yield(event) }
                    }
                }
            }
            cont.yield(.exited(proc.terminationStatus))
            cont.finish()
        }

        do { try p.run() } catch {
            cont.finish()
            throw YTError(message: "Could not run \(path): \(error.localizedDescription)")
        }
        return (p, stream)
    }

    /// stderr: everything ffmpeg says, with the input duration picked out of the banner.
    static func banner(from line: String) -> FFEvent? {
        if let seconds = duration(in: line) { return .duration(seconds) }
        return .log(line)
    }

    /// "  Duration: 00:00:06.00, start: 0.000000, bitrate: 126 kb/s" -> 6.0
    static func duration(in line: String) -> Double? {
        guard let range = line.range(of: #"Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#,
                                     options: .regularExpression) else { return nil }
        let digits = line[range].dropFirst("Duration:".count).trimmingCharacters(in: .whitespaces)
        let parts = digits.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// stdout: `-progress` emits a block of key=value lines ending in `progress=`.
    /// ponytail: unchecked Sendable is safe for the same reason LineReader's box is —
    /// a FileHandle calls its readability handler serially.
    final class ProgressAccumulator: @unchecked Sendable {
        private var seconds: Double?
        private var speed = ""
        private var size = ""

        func consume(_ line: String) -> FFEvent? {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch pair[0] {
            // out_time_ms is a long-standing ffmpeg misnomer — it also holds microseconds —
            // so out_time_us is read instead, with the timecode as the fallback.
            case "out_time_us":
                if let us = Double(value), us >= 0 { seconds = us / 1_000_000 }
            case "out_time":
                if seconds == nil { seconds = Timecode.seconds(value) }
            case "speed":
                speed = value == "N/A" ? "" : value
            case "total_size":
                size = Int64(value).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            case "progress":
                defer { seconds = nil }
                guard let s = seconds else { return nil }
                return .progress(seconds: s, speed: speed, size: size)
            default:
                break
            }
            return nil
        }
    }

    /// ffmpeg's failures are usually the last non-empty stderr line; everything above it
    /// is stream layout the user did not ask for.
    static func cleanError(_ tail: String) -> String {
        let lines = tail.split(whereSeparator: \.isNewline).map(String.init)
        let noise = #"^(\s|Input #|Output #|Stream #|\s*Metadata|\s*encoder|\s*Duration|\s*handler|frame=|\[.*@ 0x)"#
        let candidate = lines.reversed().first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && $0.range(of: noise, options: .regularExpression) == nil
        }
        guard var message = candidate else { return "ffmpeg failed." }
        // "file.mp4: Invalid argument" reads better without the path repeated back.
        if let colon = message.range(of: ": "), message[..<colon.lowerBound].contains("/") {
            message = String(message[colon.upperBound...])
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Input filtering

    /// What the drop zone accepts. Asking UTType beats a hand-kept extension list —
    /// it already knows every container QuickTime and ffmpeg share.
    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            // ffmpeg reads plenty of things Launch Services has never heard of; only
            // reject what is positively known to be something else.
            return !url.pathExtension.isEmpty
        }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .audio)
            || type.conforms(to: .movie) || type.conforms(to: .video)
    }
}
