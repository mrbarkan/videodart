import AppKit
import Observation

/// One agent's connection. Lives off the main actor: a blocking read has its own thread,
/// and writes go through a queue so a client that stops reading stalls that queue and
/// not the window.
final class MCPConnection: @unchecked Sendable {
    let lines: AsyncStream<String>

    private let fd: Int32
    private let continuation: AsyncStream<String>.Continuation
    private let writes = DispatchQueue(label: "com.barkan.VideoDart.mcp.write")
    private let lock = NSLock()
    private var closed = false
    private var ended = false

    /// True once the client has stopped sending — it quit, or closed its end. Whatever
    /// is still waiting on its behalf should stop waiting.
    var inputEnded: Bool { lock.withLock { ended } }

    init(fd: Int32) {
        self.fd = fd
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        Thread.detachNewThread { [self] in
            var buffer = LineBuffer()
            while let bytes = MCPSocket.readSome(fd), !buffer.isOverLimit {
                for line in buffer.append(bytes) { continuation.yield(line) }
            }
            lock.withLock { ended = true }
            continuation.finish()
        }
    }

    func send(_ message: JSON) {
        let data = Data((message.line + "\n").utf8)
        writes.async { [self] in
            guard !lock.withLock({ closed }) else { return }
            MCPSocket.writeAll(fd, data)
        }
    }

    /// Closes after everything already queued has gone out. A relay whose stdin ended
    /// has only half-closed, and is still reading for the answers it is owed.
    func finish() {
        writes.async { [self] in
            lock.withLock {
                guard !closed else { return }
                closed = true
                close(fd)
            }
        }
    }

    /// Wakes the reader now, for when the server itself is going away. The lock is what
    /// keeps this from landing on a descriptor number that has been closed and reused.
    func drop() {
        lock.withLock { if !closed { shutdown(fd, SHUT_RDWR) } }
    }
}

/// The MCP server agents talk to, through the `--mcp` relay. It lives in the app, not in
/// the relay, so everything an agent does goes through the same two queues the window
/// shows — one owner of `queue.json`, and nothing happening where the user can't see it.
@MainActor @Observable
final class MCPServer {
    enum Status: Equatable {
        case off
        case listening
        case unavailable(String)
    }

    private(set) var status: Status = .off

    @ObservationIgnored private let queue: DownloadQueue
    @ObservationIgnored private let converter: ConvertQueue
    @ObservationIgnored private let presets: PresetStore
    @ObservationIgnored private let staging: Staging
    @ObservationIgnored private let navigator: Navigator

    @ObservationIgnored private var listener: DispatchSourceRead?
    @ObservationIgnored private var connections: [ObjectIdentifier: MCPConnection] = [:]
    /// The preference as last acted on. Every change to any default posts the same
    /// notification, and only this one is a reason to touch the socket.
    @ObservationIgnored private var wanted = false

    private static let version =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    init(queue: DownloadQueue, converter: ConvertQueue, presets: PresetStore,
         staging: Staging, navigator: Navigator) {
        self.queue = queue
        self.converter = converter
        self.presets = presets
        self.staging = staging
        self.navigator = navigator

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.followPreference() } }
        // A socket file left behind is harmless — the next launch finds nobody answering
        // and replaces it — but there is no reason to leave one on a clean quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }

    /// Starts or stops listening to match Settings ▸ Agents. Safe to call at any time.
    func followPreference() {
        let enabled = Prefs.bool(Prefs.Key.mcpEnabled)
        guard enabled != wanted else { return }
        wanted = enabled
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        let path = MCPSocket.url.path
        guard MCPSocket.address(path) != nil else {
            status = .unavailable("The path to VideoDart’s folder is too long for a socket: \(path)")
            return
        }
        if FileManager.default.fileExists(atPath: path) {
            // Two copies can be running — a build from Xcode beside the installed one.
            // Whoever got here first keeps the socket: taking it would cut off the agents
            // already connected to that copy. Only a file nobody answers at is stale.
            let probe = MCPSocket.connect(path)
            if probe >= 0 {
                close(probe)
                status = .unavailable("Another copy of VideoDart is already answering agents.")
                return
            }
            unlink(path)
        }
        let fd = MCPSocket.listen(path)
        guard fd >= 0 else {
            status = .unavailable("Could not open the socket: \(String(cString: strerror(errno))).")
            return
        }
        listener = MCPSocket.acceptLoop(fd) { [weak self] client in
            Task { @MainActor in
                guard let self, self.listener != nil else { close(client); return }
                self.adopt(client)
            }
        }
        status = .listening
    }

    private func stop() {
        guard let listener else {
            status = .off
            return
        }
        listener.cancel()
        self.listener = nil
        // Only ever our own: start() refuses to listen while another copy answers here.
        unlink(MCPSocket.url.path)
        for connection in connections.values { connection.drop() }
        status = .off
    }

    // MARK: - Connections

    private func adopt(_ fd: Int32) {
        let connection = MCPConnection(fd: fd)
        connections[ObjectIdentifier(connection)] = connection
        Task {
            await serve(connection)
            connections[ObjectIdentifier(connection)] = nil
            connection.finish()
        }
    }

    /// Requests are taken in the order they arrive and the quick ones answered in that
    /// order. The slow ones — a probe, a wait — run alongside and answer when they are
    /// done: JSON-RPC matches replies by id, and a two-minute wait must not hold a
    /// `list_downloads` sent after it. Other connections never wait on this one at all.
    private func serve(_ connection: MCPConnection) async {
        await withTaskGroup(of: Void.self) { group in
            for await line in connection.lines {
                switch MCP.route(line, appVersion: Self.version) {
                case .silent:
                    break
                case let .reply(message):
                    connection.send(message)
                case let .call(id, name, arguments):
                    if MCP.tool(name)?.slow == true {
                        group.addTask { await self.answer(id, name, arguments, on: connection) }
                    } else {
                        await answer(id, name, arguments, on: connection)
                    }
                }
            }
            // The group waits here for the slow calls still running, so their answers
            // are queued before the caller closes the connection.
        }
    }

    private func answer(_ id: JSON, _ name: String, _ arguments: [String: JSON],
                        on connection: MCPConnection) async {
        let result: JSON
        do {
            result = MCP.success(try await run(name, arguments, connection))
        } catch let error as MCP.ToolError {
            result = MCP.failure(error.message)
        } catch {
            result = MCP.failure(error.localizedDescription)
        }
        connection.send(MCP.response(id: id, result))
    }

    // MARK: - Tools

    private func run(_ name: String, _ arguments: [String: JSON],
                     _ connection: MCPConnection) async throws -> JSON {
        switch name {
        case "get_status":
            return status(of: queue.jobs.map(\.state.rawValue), converter.jobs.map(\.state.rawValue))

        case "probe_url":
            let url = try MCP.link(arguments)
            try requireYTDLP()
            return MCP.describe(try await YTDLP.probe(url))

        case "add_download":
            let request = try MCP.downloadRequest(arguments)
            try requireYTDLP()
            let info = try await YTDLP.probe(request.url)
            let new = try MCP.downloadJobs(
                request, info: info,
                defaultDestination: Prefs.string(Prefs.Key.downloadDir),
                defaultSubLangs: Prefs.string(Prefs.Key.subLangs))
            let skipped = queue.add(new)
            // Read back from the queue: a job already in flight was not added, and one
            // that was has usually started by now.
            let added = new.compactMap { job in queue.jobs.first { $0.id == job.id } }
            return ["jobs": .array(added.map(MCP.describe)), "skipped": .number(Double(skipped))]

        case "list_downloads":
            let jobs = try MCP.filter(queue.jobs, arguments, states: MCP.downloadStates) { $0.state.rawValue }
            return ["jobs": .array(jobs.map(MCP.describe))]

        case "control_downloads":
            let action = try MCP.string(arguments, "action") ?? ""
            let targets = try MCP.downloadTargets(
                action: action, ids: try MCP.ids(arguments, "ids"), jobs: queue.jobs)
            for id in targets {
                switch action {
                case "pause": queue.pause(id)
                case "resume": queue.resume(id)
                case "retry": queue.retry(id)
                // remove, and clear_finished, which is remove for the ones that ended.
                // Neither touches a downloaded file.
                default: queue.remove(id)
                }
            }
            return ["affected": .array(targets.map { .string($0.uuidString) }),
                    "jobs": .array(snapshot(targets).jobs)]

        case "list_presets":
            return ["presets": .array(presets.all.map(MCP.describe))]

        case "convert":
            let plan = try MCP.convertPlan(
                arguments, presets: presets.all,
                remembered: Prefs.string(Prefs.Key.convertPreset),
                defaultDestination: Prefs.string(Prefs.Key.convertDir),
                downloads: queue.jobs)
            guard FFmpeg.isInstalled else {
                throw MCP.ToolError("ffmpeg isn't installed yet. Open VideoDart and use its install banner, then try again.")
            }
            var jobs: [ConvertJob] = []
            for source in plan.sources {
                // The probe is not optional decoration: a size-target preset divides by
                // the duration it reports.
                jobs.append(ConvertJob(
                    source: source, preset: plan.preset, probe: await FFmpeg.inspect(source),
                    destination: plan.destination, trimStart: plan.trimStart, trimEnd: plan.trimEnd))
            }
            converter.add(jobs)
            return ["jobs": .array(snapshot(jobs.map(\.id)).jobs)]

        case "stage_for_convert":
            let sources = try MCP.sources(arguments, downloads: queue.jobs)
            staging.adopt(sources)
            navigator.pane = .convert
            return ["staged": .array(sources.map { .string($0.path) }),
                    "note": "The files are in VideoDart's Convert pane. Nothing is converting; the user chooses the settings and presses Convert."]

        case "list_conversions":
            let jobs = try MCP.filter(converter.jobs, arguments, states: MCP.conversionStates) { $0.state.rawValue }
            return ["jobs": .array(jobs.map(MCP.describe))]

        case "control_conversions":
            let action = try MCP.string(arguments, "action") ?? ""
            let targets = try MCP.conversionTargets(
                action: action, ids: try MCP.ids(arguments, "ids"), jobs: converter.jobs)
            for id in targets {
                switch action {
                case "cancel": converter.cancel(id)
                case "retry": converter.retry(id)
                // ConvertQueue.remove keeps the output of a job that finished.
                default: converter.remove(id)
                }
            }
            return ["affected": .array(targets.map { .string($0.uuidString) }),
                    "jobs": .array(snapshot(targets).jobs)]

        case "wait_for_jobs":
            return try await wait(arguments, connection)

        default:
            throw MCP.ToolError("Unknown tool: \(name)")
        }
    }

    private func requireYTDLP() throws {
        guard YTDLP.isInstalled else {
            throw MCP.ToolError("yt-dlp isn't installed yet. Open VideoDart and use its install banner, then try again.")
        }
    }

    private func status(of downloads: [String], _ conversions: [String]) -> JSON {
        func counts(_ states: [String]) -> JSON {
            .object(Dictionary(states.map { ($0, 1.0) }, uniquingKeysWith: +).mapValues(JSON.number))
        }
        let convertDir = Prefs.string(Prefs.Key.convertDir)
        return [
            "version": .string(Self.version),
            "installed": ["yt_dlp": .bool(YTDLP.isInstalled), "ffmpeg": .bool(YTDLP.isFFmpegInstalled),
                          "js_runtime": .bool(YTDLP.isJSRuntimeInstalled)],
            "download_folder": .string(Prefs.string(Prefs.Key.downloadDir)),
            "convert_folder": convertDir.isEmpty ? .null : .string(convertDir),
            "downloads": counts(downloads),
            "conversions": counts(conversions),
        ]
    }

    /// The jobs behind `ids` as they are now, from whichever queue has them, and whether
    /// all of them have stopped moving. One that has been removed since counts as stopped
    /// — nothing further will happen to it — and is reported so rather than dropped.
    private func snapshot(_ ids: [UUID]) -> (jobs: [JSON], settled: Bool, unknown: [UUID]) {
        var jobs: [JSON] = [], settled = true, unknown: [UUID] = []
        for id in ids {
            if let job = queue.jobs.first(where: { $0.id == id }) {
                jobs.append(MCP.describe(job))
                settled = settled && MCP.isSettled(job.state)
            } else if let job = converter.jobs.first(where: { $0.id == id }) {
                jobs.append(MCP.describe(job))
                settled = settled && MCP.isSettled(job.state)
            } else {
                jobs.append(["id": .string(id.uuidString), "state": "removed"])
                unknown.append(id)
            }
        }
        return (jobs, settled, unknown)
    }

    /// Polls rather than observes: both queues change on every progress tick, and four
    /// looks a second at two small arrays is cheaper than getting a wake-up for each.
    /// Sleeping gives the main actor back between looks, so the window never notices.
    private func wait(_ arguments: [String: JSON], _ connection: MCPConnection) async throws -> JSON {
        guard let ids = try MCP.ids(arguments, "ids"), !ids.isEmpty else {
            throw MCP.ToolError("ids is required: the jobs to wait for.")
        }
        let timeout = try MCP.timeout(arguments)
        if let missing = snapshot(ids).unknown.first {
            throw MCP.ToolError("No job with id \(missing.uuidString).")
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            let now = snapshot(ids)
            // A client that has gone can't read the answer; holding its wait open for two
            // minutes would only keep the relay and this task alive for nobody.
            let expired = ContinuousClock.now >= deadline || connection.inputEnded
            if now.settled || expired {
                return ["jobs": .array(now.jobs), "timed_out": .bool(!now.settled)]
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
