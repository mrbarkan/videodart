import Foundation

/// A JSON value that can cross actors. `JSONSerialization` hands back `Any`, which Swift 6
/// won't let a tool call carry from the socket's thread to the main actor and back.
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    /// Nil for anything that isn't JSON. A bare scalar parses: it is valid JSON and an
    /// invalid request, and those two get different error codes.
    init?(parsing text: String) {
        guard let any = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        else { return nil }
        self.init(any)
    }

    private init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            // Foundation bridges true to an NSNumber that also answers as 1; only the
            // type id tells them apart, and an id of 1 must not come back as true.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(JSON.init))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init))
        default: self = .null
        }
    }

    private var any: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(d):
            // Request ids are echoed back, and a client that sent 7 compares against 7,
            // not 7.0. Infinity and NaN have no JSON spelling at all.
            guard d.isFinite else { return NSNull() }
            return d == d.rounded() && abs(d) < 9e15 ? Int64(d) as Any : d
        case let .string(s): return s
        case let .array(a): return a.map(\.any)
        case let .object(o): return o.mapValues(\.any)
        }
    }

    /// One line, no newline inside it: the transport is newline-delimited. Keys are
    /// sorted so SelfCheck can compare text.
    var line: String {
        let data = (try? JSONSerialization.data(
            withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    subscript(key: String) -> JSON? {
        if case let .object(o) = self { o[key] } else { nil }
    }

    var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    var doubleValue: Double? { if case let .number(d) = self { d } else { nil } }
    var objectValue: [String: JSON]? { if case let .object(o) = self { o } else { nil } }
    var arrayValue: [JSON]? { if case let .array(a) = self { a } else { nil } }
    /// Whole numbers only: playlist item 2.5 is a mistake, not item 2.
    var intValue: Int? {
        guard case let .number(d) = self, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return Int(d)
    }

    static func optional(_ text: String?) -> JSON { text.map(JSON.string) ?? .null }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Bytes in, whole lines out. A read from a pipe or socket ends wherever the kernel
/// stopped, which is mid-message as often as not, and can just as well hold three.
struct LineBuffer {
    private var pending = Data()

    /// A peer that never sends a newline would otherwise grow this until the app dies.
    static let limit = 16 * 1024 * 1024
    var isOverLimit: Bool { pending.count > Self.limit }

    mutating func append(_ bytes: Data) -> [String] {
        pending.append(bytes)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            // Blank lines carry nothing, and a client on Windows line endings is still a client.
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        return lines
    }
}

/// The protocol and the tools' argument handling, with no socket, queue or disk behind
/// them — so SelfCheck can run every branch, and `MCPServer` only has to carry out what
/// these functions have already decided is valid.
enum MCP {
    // MARK: - JSON-RPC

    /// Newest first; the first is what a client asking for something else is offered.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    enum Incoming: Equatable {
        case reply(JSON)
        /// A notification, or a response to a request this server never sent.
        case silent
        case call(id: JSON, name: String, arguments: [String: JSON])
    }

    static func route(_ line: String, appVersion: String) -> Incoming {
        guard let message = JSON(parsing: line) else {
            return .reply(error(id: .null, code: -32700, "Parse error: that line is not JSON."))
        }
        guard case let .object(fields) = message else {
            return .reply(error(id: .null, code: -32600, "Invalid request: expected one JSON object per line."))
        }
        guard let method = fields["method"]?.stringValue else {
            if fields["result"] != nil || fields["error"] != nil { return .silent }
            return .reply(error(id: fields["id"] ?? .null, code: -32600, "Invalid request: no method."))
        }
        // No id is a notification, and a notification is never answered — not even with
        // an error, or a client that sends one this server doesn't know would see noise.
        guard let id = fields["id"], id != .null else { return .silent }
        let params = fields["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            return .reply(response(id: id, initializeResult(
                requested: params["protocolVersion"]?.stringValue, appVersion: appVersion)))
        case "ping":
            return .reply(response(id: id, [:]))
        case "tools/list":
            return .reply(response(id: id, ["tools": .array(tools.map(\.json))]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .reply(error(id: id, code: -32602, "tools/call needs the name of a tool."))
            }
            guard tool(name) != nil else {
                return .reply(error(id: id, code: -32602, "Unknown tool: \(name)"))
            }
            switch params["arguments"] {
            case nil, .null?: return .call(id: id, name: name, arguments: [:])
            case let .object(arguments)?: return .call(id: id, name: name, arguments: arguments)
            default: return .reply(error(id: id, code: -32602, "The arguments for \(name) must be an object."))
            }
        default:
            return .reply(error(id: id, code: -32601, "Method not found: \(method)"))
        }
    }

    static func response(id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSON, code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func initializeResult(requested: String?, appVersion: String) -> JSON {
        let version = requested.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "videodart", "version": .string(appVersion)],
            "instructions": .string(instructions),
        ]
    }

    static let instructions = """
        VideoDart downloads video with yt-dlp and converts it with FFmpeg, in the queues \
        the user sees in the app. To download: add_download, then wait_for_jobs with the \
        returned ids until the state is done; output_path is the file. To convert: \
        list_presets, then convert with paths or download_ids and a preset, then \
        wait_for_jobs. wait_for_jobs returns after at most 120 seconds; call it again while \
        timed_out is true. Use stage_for_convert instead of convert when the user should \
        choose the settings themselves.
        """

    /// The text block is for clients that predate structured content; both say the same.
    static func success(_ payload: JSON) -> JSON {
        ["content": [["type": "text", "text": .string(payload.line)]], "structuredContent": payload]
    }

    /// A tool that fails is still a successful JSON-RPC call: the sentence is for the
    /// model to read and act on, which a protocol error never reaches.
    static func failure(_ message: String) -> JSON {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    struct ToolError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Tools

    struct Tool {
        var name: String
        var description: String
        var properties: [String: JSON] = [:]
        var required: [String] = []
        /// Probes, or waits. These answer whenever they finish instead of holding up
        /// the requests behind them on the same connection.
        var slow = false

        var json: JSON {
            ["name": .string(name), "description": .string(description),
             "inputSchema": ["type": "object", "properties": .object(properties),
                             "required": .array(required.map(JSON.string))]]
        }
    }

    static func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }

    private static func text(_ description: String, oneOf values: [String]? = nil) -> JSON {
        var schema: [String: JSON] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSON.string)) }
        return .object(schema)
    }

    private static func list(_ description: String, of type: String = "string") -> JSON {
        ["type": "array", "items": ["type": .string(type)], "description": .string(description)]
    }

    private static let sourceProperties: [String: JSON] = [
        "paths": list("Absolute paths of media files on this Mac."),
        "download_ids": list("Ids of finished downloads, from add_download or list_downloads."),
    ]

    static let tools: [Tool] = [
        Tool(name: "get_status",
             description: "App version, whether yt-dlp, ffmpeg and the JavaScript runtime are installed, the default folders, and how many jobs are in each state in both queues."),
        Tool(name: "probe_url",
             description: "Reads a link without downloading anything: its title, whether it is a playlist, and its entries.",
             properties: ["url": text("An http or https link to a video or playlist.")],
             required: ["url"], slow: true),
        Tool(name: "add_download",
             description: "Queues a download, one job per playlist entry. Returns the new jobs and how many were skipped because they are already in the queue. Follow with wait_for_jobs.",
             properties: [
                "url": text("An http or https link to a video or playlist."),
                "kind": text("What to fetch. Default video_audio.", oneOf: downloadKinds.map(\.name)),
                "quality": text("\"best\" (default) or a maximum height such as \"1080\". Ignored for audio."),
                "container": text("For video: mp4 (default), mkv or original. For audio: m4a (default), mp3, opus, flac or original."),
                "subtitles": text("Default off. Ignored for audio.", oneOf: SubsOption.allCases.map(\.rawValue)),
                "subtitle_languages": text("Comma separated, such as \"en,es\", or \"all\". Default: the user's setting."),
                "destination": text("Absolute folder to save into. Default: the user's download folder."),
                "playlist_items": list("1-based indexes of the playlist entries to download. Default: all of them.", of: "integer"),
             ],
             required: ["url"], slow: true),
        Tool(name: "list_downloads",
             description: "The download queue, optionally only the jobs in one state or with the given ids.",
             properties: [
                "state": text("Only jobs in this state.", oneOf: downloadStates),
                "ids": list("Only these jobs."),
             ]),
        Tool(name: "control_downloads",
             description: "Pause, resume, retry or remove downloads, or clear the finished ones. Removing a job never deletes a downloaded file.",
             properties: [
                "action": text("What to do.", oneOf: downloadActions),
                "ids": list("The jobs to act on. Omit for every job the action applies to; remove requires it."),
             ],
             required: ["action"]),
        Tool(name: "list_presets",
             description: "The conversion presets, built-in and saved by the user: id, name, built_in and a one-line summary of what each produces."),
        Tool(name: "convert",
             description: "Queues conversions right away, one per file, and returns the jobs. Nothing is queued unless every file, the preset and the trim are valid. Follow with wait_for_jobs.",
             properties: sourceProperties.merging([
                "preset": text("A preset's name or id, from list_presets. Default: the preset the user last chose."),
                "trim_start": text("Where to start, as seconds or h:mm:ss. Default: the beginning."),
                "trim_end": text("Where to stop, as seconds or h:mm:ss. Default: the end."),
                "destination": text("Absolute folder for the converted files. Default: the Convert pane's folder setting, which is normally beside each source."),
             ]) { first, _ in first },
             slow: true),
        Tool(name: "stage_for_convert",
             description: "Puts files in the Convert pane's list and shows that pane, without converting, so the user can choose the settings themselves.",
             properties: sourceProperties),
        Tool(name: "list_conversions",
             description: "The convert queue, optionally only the jobs in one state or with the given ids.",
             properties: [
                "state": text("Only jobs in this state.", oneOf: conversionStates),
                "ids": list("Only these jobs."),
             ]),
        Tool(name: "control_conversions",
             description: "Cancel, retry or remove conversions, or clear the finished ones. Cancelling deletes the half-written output; removing a finished job keeps its file.",
             properties: [
                "action": text("What to do.", oneOf: conversionActions),
                "ids": list("The jobs to act on. Omit for every job the action applies to; remove requires it."),
             ],
             required: ["action"]),
        Tool(name: "wait_for_jobs",
             description: "Waits until every listed job is done, failed, cancelled or paused, or until the timeout, then returns the jobs as they are and whether it timed_out. Takes download and conversion ids together.",
             properties: [
                "ids": list("Download and/or conversion job ids."),
                "timeout_seconds": ["type": "number", "description": "How long to wait. Default 30, at most 120."],
             ],
             required: ["ids"], slow: true),
    ]

    // MARK: - Reading arguments

    static func string(_ arguments: [String: JSON], _ key: String) throws -> String? {
        switch arguments[key] {
        case nil, .null?: return nil
        case let .string(s)?: return s
        default: throw ToolError("\(key) must be a string.")
        }
    }

    /// A lone string is taken as a list of one; models send that often enough.
    static func strings(_ arguments: [String: JSON], _ key: String) throws -> [String]? {
        switch arguments[key] {
        case nil, .null?: return nil
        case let .string(s)?: return [s]
        case let .array(items)?:
            return try items.map {
                guard let s = $0.stringValue else { throw ToolError("\(key) must be a list of strings.") }
                return s
            }
        default: throw ToolError("\(key) must be a list of strings.")
        }
    }

    static func ids(_ arguments: [String: JSON], _ key: String) throws -> [UUID]? {
        try strings(arguments, key)?.map {
            guard let id = UUID(uuidString: $0) else { throw ToolError("\"\($0)\" in \(key) is not a job id.") }
            return id
        }
    }

    /// "~/Movies" is how a person writes a folder, and so how a model relays it.
    static func absolutePath(_ text: String, _ key: String) throws -> String {
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ToolError("\(key) must be an absolute path; got \"\(text)\".") }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Downloads

    static let downloadKinds: [(name: String, kind: MediaKind)] =
        [("video_audio", .videoAudio), ("video", .video), ("audio", .audio)]
    static let downloadStates = ["queued", "downloading", "processing", "paused", "done", "failed"]
    static let downloadActions = ["pause", "resume", "retry", "remove", "clear_finished"]
    static let videoContainers = ["mp4", "mkv", "original"]
    static let audioContainers = ["m4a", "mp3", "opus", "flac", "original"]

    /// What `add_download` was asked for, checked before the link is read: a bad `kind`
    /// should cost the agent nothing, not a network round trip.
    struct DownloadRequest: Equatable {
        var url: String
        var kind: MediaKind
        var quality: String
        var container: String
        var subs: SubsOption
        var subLangs: String?           // nil is the user's setting
        var destination: String?        // nil is the user's folder
        var playlistItems: [Int]?       // 1-based; nil is every entry
    }

    static func link(_ arguments: [String: JSON]) throws -> String {
        guard let url = try string(arguments, "url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { throw ToolError("url is required.") }
        // The link ends up as a bare yt-dlp argument. Anything starting with a dash would
        // be read as an option — and yt-dlp has options that run commands.
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
              !url.contains(where: \.isWhitespace) else {
            throw ToolError("url must be an http or https link; got \"\(url)\".")
        }
        return url
    }

    static func downloadRequest(_ arguments: [String: JSON]) throws -> DownloadRequest {
        let url = try link(arguments)

        let kindName = try string(arguments, "kind") ?? "video_audio"
        guard let kind = downloadKinds.first(where: { $0.name == kindName })?.kind else {
            throw ToolError("kind \"\(kindName)\" is not one of \(downloadKinds.map(\.name).joined(separator: ", ")).")
        }

        var quality = "best"
        switch arguments["quality"] {
        case nil, .null?: break
        case let .string(s)? where s == "best": quality = s
        // "1080p" is what the app's own menu calls it.
        case let .string(s)? where Int(s.hasSuffix("p") ? String(s.dropLast()) : s).map({ $0 > 0 }) == true:
            quality = s.hasSuffix("p") ? String(s.dropLast()) : s
        case let .number(n)? where n > 0 && n == n.rounded(): quality = String(Int(n))
        default: throw ToolError("quality must be \"best\" or a height such as \"1080\".")
        }

        let allowed = kind == .audio ? audioContainers : videoContainers
        let container = try string(arguments, "container")?.lowercased() ?? allowed[0]
        guard allowed.contains(container) else {
            throw ToolError("container \"\(container)\" is not available for \(kindName); use one of \(allowed.joined(separator: ", ")).")
        }

        let subsName = try string(arguments, "subtitles") ?? "off"
        guard let subs = SubsOption(rawValue: subsName) else {
            throw ToolError("subtitles \"\(subsName)\" is not one of off, embed, sidecar.")
        }

        var items: [Int]?
        if let raw = arguments["playlist_items"], raw != .null {
            guard let list = raw.arrayValue, !list.isEmpty else {
                throw ToolError("playlist_items must be a list of 1-based indexes, or left out for every entry.")
            }
            var seen: Set<Int> = []
            items = try list.compactMap {
                guard let index = $0.intValue, index >= 1 else {
                    throw ToolError("playlist_items must be whole numbers from 1; got \($0.line).")
                }
                return seen.insert(index).inserted ? index : nil
            }
        }

        return DownloadRequest(
            url: url, kind: kind,
            quality: kind == .audio ? "best" : quality,
            container: container,
            // As the Add sheet does: an audio file has nowhere to put them.
            subs: kind == .audio ? .off : subs,
            subLangs: try strings(arguments, "subtitle_languages")?.joined(separator: ","),
            destination: try string(arguments, "destination").map { try absolutePath($0, "destination") },
            playlistItems: items)
    }

    /// The Add sheet's last step, without the sheet.
    static func downloadJobs(_ request: DownloadRequest, info: MediaInfo,
                             defaultDestination: String, defaultSubLangs: String) throws -> [DownloadJob] {
        var entries = info.entries
        if let items = request.playlistItems {
            if let beyond = items.first(where: { $0 > entries.count }) {
                throw ToolError("playlist_items names entry \(beyond), but this link has \(entries.count).")
            }
            entries = items.map { info.entries[$0 - 1] }
        }
        guard !entries.isEmpty else { throw ToolError("That link has nothing to download.") }
        return entries.map { entry in
            DownloadJob(url: entry.url, title: entry.title, uploader: entry.uploader,
                        thumbnail: entry.thumbnail, duration: entry.duration,
                        kind: request.kind, quality: request.quality, container: request.container,
                        subs: request.subs, subLangs: request.subLangs ?? defaultSubLangs,
                        destination: request.destination ?? defaultDestination)
        }
    }

    static func describe(_ info: MediaInfo) -> JSON {
        ["title": .string(info.title), "is_playlist": .bool(info.isPlaylist),
         "entries": .array(info.entries.enumerated().map { index, entry in
             ["index": .number(Double(index + 1)), "title": .string(entry.title),
              "duration": entry.duration.map(JSON.number) ?? .null, "url": .string(entry.url)]
         })]
    }

    static func describe(_ job: DownloadJob) -> JSON {
        ["type": "download", "id": .string(job.id.uuidString), "title": .string(job.title),
         "state": .string(job.state.rawValue), "progress": .number(job.progress),
         "output_path": .optional(job.outputPath), "error": .optional(job.error),
         "url": .string(job.url),
         "kind": .string(downloadKinds.first { $0.kind == job.kind }?.name ?? job.kind.rawValue),
         "speed": .string(job.speed), "eta": .string(job.eta), "size": .string(job.size)]
    }

    /// The `state` and `ids` filters the two list tools share.
    static func filter<Job: Identifiable>(
        _ jobs: [Job], _ arguments: [String: JSON], states: [String], state: (Job) -> String
    ) throws -> [Job] where Job.ID == UUID {
        var kept = jobs
        if let wanted = try string(arguments, "state") {
            guard states.contains(wanted) else {
                throw ToolError("state \"\(wanted)\" is not one of \(states.joined(separator: ", ")).")
            }
            kept = kept.filter { state($0) == wanted }
        }
        if let only = try ids(arguments, "ids") { kept = kept.filter { only.contains($0.id) } }
        return kept
    }

    /// Which jobs an action lands on. With `ids`, the ones among them it applies to —
    /// pausing a finished download is a no-op, not an error; without, every job it applies
    /// to. An id that isn't in the queue is an error either way: the agent is working
    /// from a list that has gone stale and should look again.
    static func targets<Job: Identifiable>(
        action: String, actions: [String], ids: [UUID]?, jobs: [Job], applies: (String, Job, Bool) -> Bool
    ) throws -> [UUID] where Job.ID == UUID {
        guard actions.contains(action) else {
            throw ToolError("action \"\(action)\" is not one of \(actions.joined(separator: ", ")).")
        }
        if let ids {
            if let unknown = ids.first(where: { id in !jobs.contains { $0.id == id } }) {
                throw ToolError("No job with id \(unknown.uuidString).")
            }
        } else if action == "remove" {
            throw ToolError("remove needs ids: say which jobs. Use clear_finished to drop everything that has ended.")
        }
        return jobs.filter { job in
            (ids?.contains(job.id) ?? true) && applies(action, job, ids != nil)
        }.map(\.id)
    }

    static func downloadTargets(action: String, ids: [UUID]?, jobs: [DownloadJob]) throws -> [UUID] {
        try targets(action: action, actions: downloadActions, ids: ids, jobs: jobs) { action, job, _ in
            switch action {
            case "pause": job.state.isActive || job.state == .queued
            case "resume": job.state == .paused || job.state == .failed
            case "retry": job.state == .failed
            case "clear_finished": job.state == .done || job.state == .failed
            default: true
            }
        }
    }

    // MARK: - Conversions

    static let conversionStates = ["queued", "converting", "done", "failed", "cancelled"]
    static let conversionActions = ["cancel", "retry", "remove", "clear_finished"]

    static func conversionTargets(action: String, ids: [UUID]?, jobs: [ConvertJob]) throws -> [UUID] {
        try targets(action: action, actions: conversionActions, ids: ids, jobs: jobs) { action, job, named in
            switch action {
            case "cancel": job.state == .queued || job.state == .converting
            // "Convert Again" exists on a finished row, but only when that row is the
            // one asked for; a bare retry must not re-run everything that worked.
            case "retry": job.state == .failed || job.state == .cancelled || (named && job.state == .done)
            case "clear_finished": job.state == .done || job.state == .failed || job.state == .cancelled
            default: true
            }
        }
    }

    static func describe(_ job: ConvertJob) -> JSON {
        ["type": "conversion", "id": .string(job.id.uuidString), "title": .string(job.title),
         "state": .string(job.state.rawValue), "progress": .number(job.progress),
         "output_path": .optional(job.outputPath), "error": .optional(job.error),
         "source": .string(job.source.path), "preset": .string(job.preset.name)]
    }

    static func describe(_ preset: ConvertPreset) -> JSON {
        ["id": .string(preset.id.uuidString), "name": .string(preset.name),
         "built_in": .bool(preset.isBuiltIn), "summary": .string(preset.summary)]
    }

    /// By id, then by exact name, then by name whatever the case — in that order, so a
    /// saved "h.264 mp4" can't shadow the built-in an agent named exactly.
    static func preset(_ reference: String, in presets: [ConvertPreset]) -> ConvertPreset? {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: wanted), let match = presets.first(where: { $0.id == id }) { return match }
        return presets.first { $0.name == wanted }
            ?? presets.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    /// `paths` and `download_ids` as files, each one checked. Throws at the first that
    /// can't be converted, naming it, so nothing is half done.
    static func sources(_ arguments: [String: JSON], downloads: [DownloadJob],
                        exists: (String) -> Bool = isFile) throws -> [URL] {
        var urls: [URL] = []
        for text in try strings(arguments, "paths") ?? [] {
            let path = try absolutePath(text, "paths")
            guard exists(path) else { throw ToolError("There is no file at \(path).") }
            let url = URL(fileURLWithPath: path)
            guard FFmpeg.isMedia(url) else { throw ToolError("\(path) is not a video or audio file.") }
            urls.append(url)
        }
        for id in try ids(arguments, "download_ids") ?? [] {
            guard let job = downloads.first(where: { $0.id == id }) else {
                throw ToolError("No download with id \(id.uuidString).")
            }
            guard job.state == .done else {
                throw ToolError("The download \"\(job.title)\" hasn't finished; its state is \(job.state.rawValue).")
            }
            // A success without a path is the archive saying it was downloaded before.
            guard let path = job.outputPath else {
                throw ToolError("The download \"\(job.title)\" finished without a file: it was skipped as already downloaded.")
            }
            guard exists(path) else {
                throw ToolError("The file for the download \"\(job.title)\" is no longer at \(path).")
            }
            let url = URL(fileURLWithPath: path)
            guard FFmpeg.isMedia(url) else { throw ToolError("\(path) is not a video or audio file.") }
            urls.append(url)
        }
        guard !urls.isEmpty else { throw ToolError("Give at least one file, in paths or download_ids.") }
        var seen: Set<URL> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    /// Everything `convert` needs, or the reason it can't run. Nothing reaches the queue
    /// until all of it holds.
    struct ConvertPlan: Equatable {
        var sources: [URL]
        var preset: ConvertPreset
        var trimStart: String
        var trimEnd: String
        var destination: String         // "" writes beside each source
    }

    static func convertPlan(_ arguments: [String: JSON], presets: [ConvertPreset], remembered: String,
                            defaultDestination: String, downloads: [DownloadJob],
                            exists: (String) -> Bool = isFile) throws -> ConvertPlan {
        let chosen: ConvertPreset
        if let reference = try string(arguments, "preset") {
            guard let match = preset(reference, in: presets) else {
                throw ToolError("No preset named \"\(reference)\". Call list_presets for the names and ids.")
            }
            chosen = match
        } else {
            // A remembered preset that has since been deleted falls back as the pane does.
            chosen = preset(remembered, in: presets) ?? presets.first ?? ConvertPreset.builtIns[0]
        }

        let start = try timecode(arguments, "trim_start"), end = try timecode(arguments, "trim_end")
        guard StagedOutput(preset: chosen, trimStart: start, trimEnd: end).trimIsValid else {
            throw ToolError("trim_end (\(end)) must be later than trim_start (\(start.isEmpty ? "0" : start)).")
        }

        return ConvertPlan(
            sources: try sources(arguments, downloads: downloads, exists: exists),
            // What the pane does to every preset before it runs: a container or mode the
            // codec can't take becomes an ffmpeg failure otherwise.
            preset: chosen.reconciled(),
            trimStart: start, trimEnd: end,
            destination: try string(arguments, "destination").map { try absolutePath($0, "destination") }
                ?? defaultDestination)
    }

    /// The text `ConvertJob` keeps, from either spelling: "1:30" or 90.
    private static func timecode(_ arguments: [String: JSON], _ key: String) throws -> String {
        let text: String
        switch arguments[key] {
        case nil, .null?: return ""
        case let .string(s)?: text = s.trimmingCharacters(in: .whitespaces)
        case let .number(n)?: text = JSON.number(n).line
        default: throw ToolError("\(key) must be seconds or a timecode such as 1:30.")
        }
        guard text.isEmpty || Timecode.seconds(text) != nil else {
            throw ToolError("\(key) \"\(text)\" is not a time. Use seconds (90) or a timecode (1:30, 0:01:30).")
        }
        return text
    }

    // MARK: - Waiting

    /// Paused counts: nothing more will happen to it until somebody resumes it, and an
    /// agent told "still running" would wait out every timeout it has.
    static func isSettled(_ state: JobState) -> Bool { state == .done || state == .failed || state == .paused }
    static func isSettled(_ state: ConvertState) -> Bool { state == .done || state == .failed || state == .cancelled }

    static func timeout(_ arguments: [String: JSON]) throws -> Double {
        switch arguments["timeout_seconds"] {
        case nil, .null?: return 30
        case let .number(n)? where n.isFinite: return min(120, max(0, n))
        default: throw ToolError("timeout_seconds must be a number of seconds.")
        }
    }

    // MARK: - Connecting a client

    /// The path as a shell word. Quoted only when it has to be, so the usual
    /// /Applications path stays readable in the copied line.
    static func shellWord(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%")
        guard text.isEmpty || text.unicodeScalars.contains(where: { !plain.contains($0) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func claudeCommand(executable: String) -> String {
        "claude mcp add videodart -- \(shellWord(executable)) --mcp"
    }

    static func clientConfig(executable: String) -> String {
        let config: JSON = ["mcpServers": ["videodart": ["command": .string(executable), "args": ["--mcp"]]]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: Data(config.line.utf8)),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return config.line }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The socket both halves meet at, and the few POSIX calls each needs. Nonisolated on
/// purpose: these run on the relay's threads and the server's accept queue, and a closure
/// written inside a main-actor type is assumed to run there — Swift 6 traps when it doesn't.
enum MCPSocket {
    static let url = AppSupport.file("mcp.sock")

    /// Nil when the path doesn't fit: `sun_path` is 104 bytes including the terminator.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func stream() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        // Writing to a peer that has gone raises SIGPIPE, whose default is to kill the
        // process: one agent quitting mid-reply would take the app and its downloads along.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// A connected descriptor, or -1.
    static func connect(_ path: String) -> Int32 {
        guard var address = address(path) else { return -1 }
        let fd = stream()
        guard fd >= 0 else { return -1 }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    /// A listening descriptor at `path`, readable by this user alone, or -1.
    static func listen(_ path: String) -> Int32 {
        guard var address = address(path) else { return -1 }
        let fd = stream()
        guard fd >= 0 else { return -1 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return -1
        }
        // The accept loop drains until there is nothing left; it must not then block.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Calls `onClient` with each accepted descriptor. Cancelling the source closes the
    /// listening descriptor, which is the only way to stop.
    static func acceptLoop(_ fd: Int32, onClient: @escaping @Sendable (Int32) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "com.barkan.VideoDart.mcp.accept"))
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // Inherited from the listener on macOS, and the reader wants to block.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                onClient(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// False once the peer is gone. Partial writes and EINTR are the kernel's business,
    /// not the caller's.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if errno != EINTR { return false }
            }
            return true
        }
    }

    /// Nil at end of input or on an error that isn't an interruption.
    static func readSome(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 || errno != EINTR { return nil }
        }
    }
}
