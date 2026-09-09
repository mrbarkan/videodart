import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case audio, video, videoAudio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .audio: "Audio only"
        case .video: "Video only"
        case .videoAudio: "Video + audio"
        }
    }
    var symbol: String {
        switch self {
        case .audio: "waveform"
        case .video: "film"
        case .videoAudio: "play.rectangle"
        }
    }
}

/// What the Add sheet offers. `.both` fans out into two jobs; it is never stored on a job.
enum AddChoice: String, CaseIterable, Identifiable, Hashable {
    case audio, video, videoAudio, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .audio: "Audio"
        case .video: "Video"
        case .videoAudio: "Video + audio"
        case .both: "Both, split"
        }
    }
    var kinds: [MediaKind] {
        switch self {
        case .audio: [.audio]
        case .video: [.video]
        case .videoAudio: [.videoAudio]
        case .both: [.videoAudio, .audio]
        }
    }
}

enum SubsOption: String, Codable, CaseIterable, Identifiable, Hashable {
    case off, embed, sidecar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "None"
        case .embed: "Embedded"
        case .sidecar: "Separate .srt"
        }
    }
}

enum JobState: String, Codable, Hashable {
    case queued, downloading, processing, paused, done, failed

    var isActive: Bool { self == .downloading || self == .processing }
    var label: String {
        switch self {
        case .queued: "Waiting"
        case .downloading: "Downloading"
        case .processing: "Processing"
        case .paused: "Paused"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

struct DownloadJob: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var uploader: String = ""
    var thumbnail: String?
    var duration: Double?
    var kind: MediaKind
    var quality: String = "best"     // "best" or a max height, e.g. "1080"
    var container: String            // mp4/mkv/original — or m4a/mp3/opus/flac for audio
    var subs: SubsOption = .off
    var subLangs: String = "en"
    var destination: String
    var state: JobState = .queued
    var progress: Double = 0
    var speed: String = ""
    var eta: String = ""
    var size: String = ""
    var outputPath: String?
    var error: String?
    var details: String?      // raw yt-dlp tail, for "Copy Error Details"
    var addedAt = Date()

    var subtitle: String {
        var parts: [String] = []
        if !uploader.isEmpty { parts.append(uploader) }
        if let duration { parts.append(duration.asDuration) }
        parts.append(kind.label)
        if kind != .audio, quality != "best" { parts.append("\(quality)p") }
        if container != "original" { parts.append(container.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

extension Double {
    /// 3725 -> "1:02:05"
    var asDuration: String {
        let t = Int(self)
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension DownloadJob {
    /// Decoding is deliberately lenient: every key falls back to its default when absent.
    /// Synthesized decoding ignores default values and throws on a missing key, so adding
    /// one field made every previously saved queue unreadable — and load() discarded it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? url
        uploader = try c.decodeIfPresent(String.self, forKey: .uploader) ?? ""
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .videoAudio
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? "best"
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? "mp4"
        subs = try c.decodeIfPresent(SubsOption.self, forKey: .subs) ?? .off
        subLangs = try c.decodeIfPresent(String.self, forKey: .subLangs) ?? "en"
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
            ?? NSHomeDirectory() + "/Downloads"
        state = try c.decodeIfPresent(JobState.self, forKey: .state) ?? .queued
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        speed = try c.decodeIfPresent(String.self, forKey: .speed) ?? ""
        eta = try c.decodeIfPresent(String.self, forKey: .eta) ?? ""
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? ""
        outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        details = try c.decodeIfPresent(String.self, forKey: .details)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }
}
