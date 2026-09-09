import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class DownloadQueue {
    var jobs: [DownloadJob] = []

    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var logs: [UUID: [String]] = [:]
    // Runtime only — a retry count has no business surviving a relaunch, and keeping it
    // out of DownloadJob keeps the persisted JSON decodable by older builds.
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var powerAssertion: NSObjectProtocol?

    private var maxConcurrent: Int { max(1, Prefs.int(Prefs.Key.maxConcurrent)) }
    var activeCount: Int { jobs.count(where: { $0.state.isActive }) }
    var hasFinished: Bool { jobs.contains { $0.state == .done || $0.state == .failed } }

    /// Mean progress across everything still in flight, for the window's overall bar.
    var overallProgress: Double? {
        let live = jobs.filter { $0.state != .done && $0.state != .failed }
        guard !live.isEmpty else { return nil }
        return live.reduce(0) { $0 + $1.progress } / Double(live.count)
    }

    init() {
        load()
        // Anything mid-flight when we last quit is resumable: yt-dlp --continue picks up the .part file.
        for i in jobs.indices where jobs[i].state.isActive || jobs[i].state == .queued {
            jobs[i].state = .paused
            jobs[i].speed = ""
            jobs[i].eta = ""
        }
    }

    // MARK: - Queue control

    /// Returns how many were skipped as already in flight.
    @discardableResult
    func add(_ new: [DownloadJob]) -> Int {
        let inFlight = Set(jobs.filter { $0.state != .done && $0.state != .failed }
            .map { "\($0.url)|\($0.kind.rawValue)" })
        let fresh = new.filter { !inFlight.contains("\($0.url)|\($0.kind.rawValue)") }
        jobs.append(contentsOf: fresh)
        save()
        pump()
        return new.count - fresh.count
    }

    func pump() {
        defer { updatePowerAssertion() }
        guard YTDLP.isInstalled else { return }
        var slots = maxConcurrent - activeCount
        guard slots > 0 else { return }
        for job in jobs where job.state == .queued {
            guard slots > 0 else { break }
            launch(job.id)
            slots -= 1
        }
    }

    func pause(_ id: UUID) {
        update(id) { $0.state = .paused; $0.speed = ""; $0.eta = "" }
        // SIGINT lets yt-dlp exit cleanly and keep its .part file.
        processes[id]?.interrupt()
        save()
    }

    func resume(_ id: UUID) {
        attempts[id] = 0                       // a manual retry starts the budget over
        update(id) { $0.state = .queued; $0.error = nil; $0.details = nil }
        save()
        pump()
    }

    func retry(_ id: UUID) { resume(id) }

    func remove(_ id: UUID) {
        // ponytail: leaves any .part file on disk — yt-dlp reuses it if the same URL is re-added.
        processes[id]?.interrupt()
        processes[id] = nil
        logs[id] = nil
        attempts[id] = nil
        jobs.removeAll { $0.id == id }
        save()
        pump()
    }

    func pauseAll() { for j in jobs where j.state.isActive || j.state == .queued { pause(j.id) } }
    func resumeAll() { for j in jobs where j.state == .paused || j.state == .failed { resume(j.id) } }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed }
        save()
    }

    // MARK: - Running

    private func launch(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.createDirectory(atPath: job.destination, withIntermediateDirectories: true)

        update(id) { $0.state = .downloading; $0.error = nil; $0.speed = ""; $0.eta = "" }
        logs[id] = []

        do {
            let (process, events) = try YTDLP.start(job)
            processes[id] = process
            Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event, for: id)
                }
            }
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            save()
        }
    }

    private func handle(_ event: YTEvent, for id: UUID) {
        switch event {
        case let .progress(percent, speed, eta, size):
            update(id) {
                guard $0.state != .paused else { return }
                $0.state = .downloading
                $0.progress = percent
                $0.speed = speed
                $0.eta = eta
                $0.size = size
            }

        case let .file(path):
            update(id) { $0.outputPath = path }

        case let .log(line):
            logs[id, default: []].append(line)
            if logs[id]!.count > 40 { logs[id]!.removeFirst() }
            // Merging / extracting audio / writing tags happen after the bytes are in.
            if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]")
                || line.hasPrefix("[Metadata]") || line.hasPrefix("[EmbedThumbnail]")
                || line.hasPrefix("[EmbedSubtitle]") || line.hasPrefix("[VideoRemuxer]") {
                update(id) { if $0.state == .downloading { $0.state = .processing; $0.speed = ""; $0.eta = "" } }
            }

        case let .exited(code):
            processes[id] = nil
            let tail = (logs[id] ?? []).joined(separator: "\n")
            logs[id] = nil
            update(id) { job in
                switch job.state {
                case .paused:
                    break                       // user asked for this; keep the partial file
                default:
                    if code == 0 {
                        job.state = .done
                        job.progress = 1
                    } else {
                        let message = YTDLP.cleanError(tail)
                        job.details = tail
                        // YouTube intermittently degrades to a player client that refuses the
                        // video; a second attempt usually succeeds. A sign-in failure will not
                        // fix itself, so that one goes straight to the user.
                        if attempts[id, default: 0] < 1, !YTDLP.isAuthError(message) {
                            attempts[id, default: 0] += 1
                            job.state = .queued
                            job.error = nil
                        } else {
                            job.state = .failed
                            job.error = message
                        }
                    }
                }
                job.speed = ""
                job.eta = ""
            }
            if let finished = jobs.first(where: { $0.id == id }), finished.state != .queued {
                notify(finished)
            }
            save()
            pump()
        }
    }

    /// Downloads are why the machine is on; don't let it idle-sleep mid-transfer.
    private func updatePowerAssertion() {
        let busy = activeCount > 0
        if busy, powerAssertion == nil {
            powerAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Downloading")
        } else if !busy, let token = powerAssertion {
            ProcessInfo.processInfo.endActivity(token)
            powerAssertion = nil
        }
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ job: DownloadJob) {
        let content = UNMutableNotificationContent()
        switch job.state {
        case .done:
            content.title = "Download Complete"
            content.body = job.title
        case .failed:
            content.title = "Download Failed"
            content.body = "\(job.title) — \(job.error ?? "Unknown error")"
        default:
            return
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    private func update(_ id: UUID, _ body: (inout DownloadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[i])
    }

    // MARK: - Persistence

    private static let storeURL = AppSupport.file("queue.json")

    /// Called on state transitions only — not on every progress tick.
    func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        do {
            jobs = try JSONDecoder().decode([DownloadJob].self, from: data)
        } catch {
            // Never discard a queue we cannot read — keep the file so it can be recovered.
            let kept = Self.storeURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: Self.storeURL, to: kept)
            NSLog("VideoDart: queue.json unreadable (\(error)) — kept at \(kept.path)")
        }
    }
}
