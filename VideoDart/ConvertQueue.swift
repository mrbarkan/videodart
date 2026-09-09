import Foundation
import Observation
import UserNotifications

/// Deliberately smaller than `DownloadQueue`. A conversion reads a file that is already
/// on disk, so there is nothing to resume after a relaunch and nothing worth persisting;
/// and it runs one job at a time because ffmpeg already saturates every core — running
/// two only trades wall-clock for memory.
///
/// ponytail: serial, in memory, no retry budget. Add concurrency when a real workload
/// shows the cores idling, not before.
@MainActor @Observable
final class ConvertQueue {
    var jobs: [ConvertJob] = []

    @ObservationIgnored private var running: (id: UUID, process: Process)?
    @ObservationIgnored private var logs: [UUID: [String]] = [:]
    @ObservationIgnored private var powerAssertion: NSObjectProtocol?
    /// Jobs the user removed while they were running; dropped once ffmpeg actually exits.
    @ObservationIgnored private var removeOnExit: Set<UUID> = []

    var activeCount: Int { jobs.count { $0.state == .converting } }
    var hasFinished: Bool { jobs.contains { $0.state == .done || $0.state == .failed || $0.state == .cancelled } }

    var overallProgress: Double? {
        let live = jobs.filter { $0.state == .queued || $0.state == .converting }
        guard !live.isEmpty else { return nil }
        return live.reduce(0) { $0 + $1.progress } / Double(live.count)
    }

    // MARK: - Queue control

    func add(_ new: [ConvertJob]) {
        jobs.append(contentsOf: new)
        pump()
    }

    func pump() {
        defer { updatePowerAssertion() }
        guard FFmpeg.isInstalled, running == nil,
              let next = jobs.first(where: { $0.state == .queued }) else { return }
        launch(next.id)
    }

    /// Stops the job and takes the half-written output with it. A truncated MP4 left
    /// beside the source is indistinguishable from a finished one until it is played.
    func cancel(_ id: UUID) {
        update(id) { $0.state = .cancelled; $0.speed = "" }
        if running?.id == id {
            running?.process.terminate()
        } else {
            discardOutput(of: id)
            pump()
        }
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued; $0.progress = 0; $0.error = nil; $0.details = nil }
        pump()
    }

    func remove(_ id: UUID) {
        // Terminating is asynchronous. Deleting the output now would race ffmpeg, which
        // is still writing it and would leave the file behind after the job is gone —
        // so the row is dropped from the exit handler instead, once ffmpeg has stopped.
        if running?.id == id {
            removeOnExit.insert(id)
            cancel(id)
            return
        }
        discardOutput(of: id)
        jobs.removeAll { $0.id == id }
        logs[id] = nil
        pump()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    /// Only ever removes a file this app wrote in this session, and never one that
    /// finished successfully.
    private func discardOutput(of id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state != .done,
              let path = job.outputPath else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Running

    private func launch(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard FileManager.default.fileExists(atPath: job.source.path) else {
            update(id) { $0.state = .failed; $0.error = "The source file is no longer there." }
            pump()
            return
        }
        if let dir = job.destinationDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let output = FFmpeg.outputURL(for: job)
        update(id) {
            $0.state = .converting
            $0.error = nil
            $0.outputPath = output.path
            // Trimming makes the output shorter than the source, so the progress
            // denominator is the span, not what ffmpeg reports for the input.
            $0.duration = FFmpeg.trimDuration($0)
        }
        logs[id] = []

        do {
            let (process, events) = try FFmpeg.start(job, output: output)
            running = (id, process)
            Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event, for: id)
                }
            }
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            running = nil
            pump()
        }
    }

    private func handle(_ event: FFEvent, for id: UUID) {
        switch event {
        case let .duration(seconds):
            // A trim already fixed the denominator; the banner would overstate it.
            update(id) { if $0.duration == nil { $0.duration = max(0, seconds - (Timecode.seconds($0.trimStart) ?? 0)) } }

        case let .progress(seconds, speed, size):
            update(id) {
                guard $0.state == .converting else { return }
                if let total = $0.duration, total > 0 {
                    $0.progress = min(1, seconds / total)
                }
                $0.speed = speed
                $0.outputSize = size
            }

        case let .log(line):
            logs[id, default: []].append(line)
            if logs[id]!.count > 60 { logs[id]!.removeFirst() }

        case let .exited(code):
            running = nil
            let tail = (logs[id] ?? []).joined(separator: "\n")
            logs[id] = nil
            update(id) { job in
                switch job.state {
                case .cancelled:
                    break                    // the user asked; discardOutput cleans up below
                default:
                    if code == 0 {
                        job.state = .done
                        job.progress = 1
                    } else {
                        job.state = .failed
                        job.details = tail
                        job.error = FFmpeg.cleanError(tail)
                    }
                }
                job.speed = ""
            }
            if let finished = jobs.first(where: { $0.id == id }) {
                if finished.state != .done { discardOutput(of: id) }
                if removeOnExit.remove(id) != nil {
                    jobs.removeAll { $0.id == id }   // removed mid-run; the file is gone now too
                } else {
                    notify(finished)
                }
            }
            pump()
        }
    }

    /// A long encode is why the machine is on; don't let it idle-sleep mid-job.
    private func updatePowerAssertion() {
        let busy = activeCount > 0
        if busy, powerAssertion == nil {
            powerAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Converting")
        } else if !busy, let token = powerAssertion {
            ProcessInfo.processInfo.endActivity(token)
            powerAssertion = nil
        }
    }

    private func notify(_ job: ConvertJob) {
        let content = UNMutableNotificationContent()
        switch job.state {
        case .done:
            content.title = "Conversion Complete"
            content.body = job.title
        case .failed:
            content.title = "Conversion Failed"
            content.body = "\(job.title) — \(job.error ?? "Unknown error")"
        default:
            return
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    private func update(_ id: UUID, _ body: (inout ConvertJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[i])
    }
}
