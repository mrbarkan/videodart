import Foundation
import CryptoKit

// MARK: - Encoder catalogue

/// How an encoder expresses quality. Each style takes a different flag and passing the
/// wrong one is a hard ffmpeg error, not a warning — libx264 rejects -profile:v 3 and
/// the VideoToolbox encoders silently ignore -crf, shipping whatever bitrate they like.
enum QualityStyle: String, Codable, Hashable {
    case none       // stream is copied or dropped; there is nothing to ask for
    case crf        // -crf N
    case bitrate    // -b:v 8M — the VideoToolbox encoders take nothing else
    case prores     // -profile:v N
}

/// How *you* say what you want. Separate from `QualityStyle`, which is what the encoder
/// accepts: the codec decides which of these are possible, you decide which you use.
/// Conflating the two is why a hardware codec used to show a CRF slider it ignores.
enum QualityMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case targetSize, bitrate, crf
    var id: String { rawValue }

    var label: String {
        switch self {
        case .targetSize: "Target size"
        case .bitrate: "Bitrate"
        case .crf: "Quality"
        }
    }
}

/// One row of the video codec picker. `id` is verbatim what follows `-c:v`.
struct VideoEncoder: Identifiable, Hashable {
    var id: String
    var label: String
    var quality: QualityStyle
    var crfRange: ClosedRange<Int> = 0...51
    var defaultCRF: Int = 20
    var containers: [String]
}

/// One row of the audio codec picker. `id` is verbatim what follows `-c:a`.
struct AudioEncoder: Identifiable, Hashable {
    var id: String
    var label: String
    var takesBitrate: Bool
    var containers: [String]
}

enum Encoders {
    /// "copy" and "none" are not encoders — they are the two ways to have no encoder —
    /// but they belong in the same picker, so they carry sentinel ids ffmpeg understands.
    static let copyID = "copy"
    static let noneID = "none"

    static let video: [VideoEncoder] = [
        VideoEncoder(id: copyID, label: "Copy (no re-encode)", quality: .none,
                     containers: ["original", "mp4", "mkv", "mov"]),
        VideoEncoder(id: "libx264", label: "H.264", quality: .crf,
                     crfRange: 0...51, defaultCRF: 20, containers: ["mp4", "mkv", "mov"]),
        VideoEncoder(id: "h264_videotoolbox", label: "H.264 (hardware)", quality: .bitrate,
                     containers: ["mp4", "mkv", "mov"]),
        VideoEncoder(id: "libx265", label: "H.265 / HEVC", quality: .crf,
                     crfRange: 0...51, defaultCRF: 24, containers: ["mp4", "mkv", "mov"]),
        VideoEncoder(id: "hevc_videotoolbox", label: "H.265 (hardware)", quality: .bitrate,
                     containers: ["mp4", "mkv", "mov"]),
        VideoEncoder(id: "prores_ks", label: "Apple ProRes", quality: .prores,
                     containers: ["mov", "mkv"]),
        VideoEncoder(id: "libvpx-vp9", label: "VP9", quality: .crf,
                     crfRange: 0...63, defaultCRF: 31, containers: ["webm", "mkv"]),
        VideoEncoder(id: "libsvtav1", label: "AV1", quality: .crf,
                     crfRange: 0...63, defaultCRF: 35, containers: ["mp4", "mkv", "webm"]),
    ]

    static let audio: [AudioEncoder] = [
        AudioEncoder(id: copyID, label: "Copy (no re-encode)", takesBitrate: false,
                     containers: ["original", "mp4", "mkv", "mov", "m4a"]),
        AudioEncoder(id: "aac", label: "AAC", takesBitrate: true,
                     containers: ["m4a", "mp4", "mkv", "mov"]),
        AudioEncoder(id: "libmp3lame", label: "MP3", takesBitrate: true, containers: ["mp3"]),
        AudioEncoder(id: "libopus", label: "Opus", takesBitrate: true,
                     containers: ["opus", "webm", "mkv"]),
        AudioEncoder(id: "flac", label: "FLAC (lossless)", takesBitrate: false,
                     containers: ["flac", "mkv"]),
        AudioEncoder(id: "pcm_s16le", label: "WAV (uncompressed)", takesBitrate: false,
                     containers: ["wav", "mov", "mkv"]),
    ]

    static func video(_ id: String) -> VideoEncoder? { video.first { $0.id == id } }
    static func audio(_ id: String) -> AudioEncoder? { audio.first { $0.id == id } }

    /// The catalogue above is what ffmpeg *can* ship; this is what the resolved binary
    /// actually has. Offering a codec the build lacks turns a preset into a failed job
    /// with an "Unknown encoder" message — cheaper to leave it out of the menu.
    @MainActor static var availableVideo: [VideoEncoder] {
        video.filter { $0.id == copyID || FFmpeg.supportedEncoders.contains($0.id) }
    }

    @MainActor static var availableAudio: [AudioEncoder] {
        audio.filter { $0.id == copyID || FFmpeg.supportedEncoders.contains($0.id) }
    }

    static let proresProfiles = [(0, "Proxy"), (1, "LT"), (2, "422"), (3, "422 HQ"), (4, "4444")]
}

// MARK: - Preset

/// Everything the argument builder needs, and the unit the user saves and re-picks.
/// Decoding is lenient for the same reason `DownloadJob`'s is: a field added in a later
/// build must not make an existing presets.json unreadable.
struct ConvertPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var isBuiltIn = false

    var includeVideo = true
    var includeAudio = true

    var videoCodec = "libx264"
    var proresProfile = 3
    var maxHeight = 0            // 0 keeps the source height; never upscales
    var fps = 0.0                // 0 keeps the source rate

    /// How the size/quality trade-off is expressed. `.targetSize` and `.bitrate` are
    /// predictable before encoding; `.crf` is not, which is the whole reason it is a
    /// choice rather than the only option.
    var qualityMode: QualityMode = .crf
    var crf = 20
    var videoKbps = 8000
    var targetSizeMB = 25.0

    var audioCodec = "aac"
    var audioKbps = 192

    var container = "mp4"        // or "original" to keep the source extension
    var extraFlags = ""          // raw ffmpeg arguments, inserted before the output path

    /// A preset that only remuxes finishes in seconds and cannot lose quality, which is
    /// worth saying in the UI rather than making the user infer it from the codec menus.
    var isCopyOnly: Bool {
        (!includeVideo || videoCodec == Encoders.copyID)
            && (!includeAudio || audioCodec == Encoders.copyID)
    }

    var audioTakesBitrate: Bool {
        includeAudio && audioCodec != Encoders.copyID
            && Encoders.audio(audioCodec)?.takesBitrate == true
    }

    /// Which ways of asking make sense for the chosen codec. ProRes and a copied stream
    /// take neither a bitrate nor a CRF, so they offer nothing; the VideoToolbox encoders
    /// have no CRF at all, so they offer the two size-led modes only.
    var availableQualityModes: [QualityMode] {
        guard includeVideo, let encoder = Encoders.video(videoCodec) else { return [] }
        switch encoder.quality {
        case .crf: return [.targetSize, .bitrate, .crf]
        case .bitrate: return [.targetSize, .bitrate]
        case .prores, .none: return []
        }
    }

    /// The video bitrate this preset asks for on a clip of the given length. Only
    /// target-size mode depends on the duration — the others are already absolute.
    func videoKbps(forDuration seconds: Double?) -> Int {
        guard qualityMode == .targetSize, let seconds, seconds > 0 else { return videoKbps }
        // MB here is what Finder shows: 10^6 bytes, so 1 MB is 8000 kbit.
        let budget = targetSizeMB * 8000 / seconds
        // Container overhead is small but real, and overshooting a target is worse than
        // undershooting it, so hand back 3% before splitting the rest with the audio.
        return max(64, Int(budget * 0.97) - (audioTakesBitrate ? audioKbps : 0))
    }

    /// What the output should weigh, when that is knowable without encoding it.
    /// `.crf` deliberately returns nil: only a real sample encode can answer it.
    func estimatedBytes(duration: Double?, sourceBytes: Int64?, sourceDuration: Double?) -> Int64? {
        guard let duration, duration > 0 else { return nil }
        if isCopyOnly {
            // Copying rewrites the same packets, so the source's own rate is exact.
            guard let sourceBytes, let sourceDuration, sourceDuration > 0 else { return nil }
            return Int64(Double(sourceBytes) * min(1, duration / sourceDuration))
        }
        let audio = audioTakesBitrate ? Double(audioKbps) : 0
        if !includeVideo {
            guard audio > 0 else { return nil }   // FLAC/WAV have no bitrate to reason from
            return Int64(audio * 1000 * duration / 8)
        }
        switch qualityMode {
        case .targetSize: return Int64(targetSizeMB * 1_000_000)
        case .bitrate: return Int64((Double(videoKbps) + audio) * 1000 * duration / 8)
        case .crf: return nil
        }
    }

    var summary: String {
        var parts: [String] = []
        if includeVideo {
            if videoCodec == Encoders.copyID {
                parts.append("Copy video")
            } else {
                var v = Encoders.video(videoCodec)?.label ?? videoCodec
                switch Encoders.video(videoCodec)?.quality {
                case .prores:
                    v += " " + (Encoders.proresProfiles.first { $0.0 == proresProfile }?.1 ?? "")
                case .crf, .bitrate:
                    switch qualityMode {
                    case .crf: v += " CRF \(crf)"
                    case .bitrate: v += " " + Self.rateLabel(videoKbps)
                    case .targetSize: v += " " + Self.sizeLabel(targetSizeMB)
                    }
                default: break
                }
                parts.append(v)
            }
            if maxHeight > 0 { parts.append("\(maxHeight)p") }
            if fps > 0 { parts.append("\(formattedFPS) fps") }
        } else {
            parts.append("No video")
        }
        if includeAudio {
            if audioCodec == Encoders.copyID {
                parts.append("Copy audio")
            } else {
                let a = Encoders.audio(audioCodec)
                parts.append((a?.label ?? audioCodec)
                             + (a?.takesBitrate == true ? " \(audioKbps)k" : ""))
            }
        } else {
            parts.append("No audio")
        }
        parts.append(container == "original" ? "Same container" : container.uppercased())
        return parts.joined(separator: " · ")
    }

    /// 2500 -> "2.5 Mbps", 800 -> "800 kbps"
    static func rateLabel(_ kbps: Int) -> String {
        kbps >= 1000
            ? String(format: "%g Mbps", (Double(kbps) / 1000 * 10).rounded() / 10)
            : "\(kbps) kbps"
    }

    static func sizeLabel(_ mb: Double) -> String {
        String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb)
    }

    /// 30.0 -> "30", 29.97 -> "29.97"
    var formattedFPS: String {
        fps == fps.rounded() ? String(Int(fps)) : String(format: "%g", fps)
    }

    /// Containers that make sense for the streams this preset actually writes. ffmpeg
    /// would reject H.265-in-WebM anyway; catching it in the picker is friendlier.
    var allowedContainers: [String] {
        if includeVideo, let e = Encoders.video(videoCodec) { return e.containers }
        if includeAudio, let e = Encoders.audio(audioCodec) { return e.containers }
        return ["original", "mp4", "mkv", "mov"]
    }

    /// Snaps the container and quality mode back to something the chosen codecs can
    /// actually do. Changing the codec strands both: H.265 with WebM still selected won't
    /// mux, and a hardware encoder with CRF still selected silently ignores the number.
    ///
    /// A pure function applied wherever the preset is written, rather than an .onChange in
    /// the editor: mutating a binding from a change observed on that same binding is a
    /// read-write cycle, and SwiftUI logs it as one.
    func reconciled() -> ConvertPreset {
        var fixed = self
        let containers = fixed.allowedContainers
        if !containers.contains(fixed.container), let first = containers.first {
            fixed.container = first
        }
        let modes = fixed.availableQualityModes
        if !modes.isEmpty, !modes.contains(fixed.qualityMode) {
            fixed.qualityMode = modes.contains(.bitrate) ? .bitrate : modes[0]
        }
        return fixed
    }

    // MARK: Codable

    /// Written by hand because the two bitrates changed shape in 0.4.0 — they were
    /// ffmpeg rate strings ("8M", "192k") and are now plain kbit/s integers. The old keys
    /// are still read so a presets.json saved by 0.3.0 keeps its numbers instead of
    /// silently falling back to the defaults.
    private enum CodingKeys: String, CodingKey {
        case id, name, isBuiltIn, includeVideo, includeAudio
        case videoCodec, proresProfile, maxHeight, fps
        case qualityMode, crf, videoKbps, targetSizeMB
        case audioCodec, audioKbps, container, extraFlags
        case videoBitrate, audioBitrate          // 0.3.0 only, migration in
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        includeVideo = try c.decodeIfPresent(Bool.self, forKey: .includeVideo) ?? true
        includeAudio = try c.decodeIfPresent(Bool.self, forKey: .includeAudio) ?? true
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec) ?? "libx264"
        proresProfile = try c.decodeIfPresent(Int.self, forKey: .proresProfile) ?? 3
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight) ?? 0
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 0
        crf = try c.decodeIfPresent(Int.self, forKey: .crf) ?? 20
        targetSizeMB = try c.decodeIfPresent(Double.self, forKey: .targetSizeMB) ?? 25
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec) ?? "aac"
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? "mp4"
        extraFlags = try c.decodeIfPresent(String.self, forKey: .extraFlags) ?? ""

        videoKbps = try c.decodeIfPresent(Int.self, forKey: .videoKbps)
            ?? Self.parseRate(try c.decodeIfPresent(String.self, forKey: .videoBitrate)) ?? 8000
        audioKbps = try c.decodeIfPresent(Int.self, forKey: .audioKbps)
            ?? Self.parseRate(try c.decodeIfPresent(String.self, forKey: .audioBitrate)) ?? 192

        // A 0.3.0 preset predates the mode entirely: infer it from the codec, which is
        // exactly what that build did implicitly.
        if let saved = try c.decodeIfPresent(QualityMode.self, forKey: .qualityMode) {
            qualityMode = saved
        } else {
            qualityMode = Encoders.video(videoCodec)?.quality == .bitrate ? .bitrate : .crf
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(includeVideo, forKey: .includeVideo)
        try c.encode(includeAudio, forKey: .includeAudio)
        try c.encode(videoCodec, forKey: .videoCodec)
        try c.encode(proresProfile, forKey: .proresProfile)
        try c.encode(maxHeight, forKey: .maxHeight)
        try c.encode(fps, forKey: .fps)
        try c.encode(qualityMode, forKey: .qualityMode)
        try c.encode(crf, forKey: .crf)
        try c.encode(videoKbps, forKey: .videoKbps)
        try c.encode(targetSizeMB, forKey: .targetSizeMB)
        try c.encode(audioCodec, forKey: .audioCodec)
        try c.encode(audioKbps, forKey: .audioKbps)
        try c.encode(container, forKey: .container)
        try c.encode(extraFlags, forKey: .extraFlags)
    }

    /// "8M" -> 8000, "192k" -> 192, "2500" -> 2500. Only ever fed 0.3.0's own output.
    static func parseRate(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let digits = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let suffix = text.uppercased().last
        return suffix == "M" ? Int(value * 1000) : Int(value)
    }

    init(name: String, isBuiltIn: Bool = false) {
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Built-in presets

extension ConvertPreset {
    /// The menu on first launch. Deliberately opinionated: one obvious default, one
    /// small-file option, one fast hardware option, and the handful of exports people
    /// actually ask a converter for.
    static let builtIns: [ConvertPreset] = [
        make("H.264 MP4") {
            $0.videoCodec = "libx264"; $0.qualityMode = .crf; $0.crf = 20
            $0.audioCodec = "aac"; $0.audioKbps = 192
            $0.container = "mp4"; $0.extraFlags = "-preset medium -movflags +faststart"
        },
        make("H.264 MP4 (Small)") {
            $0.videoCodec = "libx264"; $0.qualityMode = .crf; $0.crf = 26; $0.maxHeight = 720
            $0.audioCodec = "aac"; $0.audioKbps = 128
            $0.container = "mp4"; $0.extraFlags = "-preset medium -movflags +faststart"
        },
        make("H.264 (Hardware, Fast)") {
            $0.videoCodec = "h264_videotoolbox"; $0.qualityMode = .bitrate; $0.videoKbps = 8000
            $0.audioCodec = "aac"; $0.audioKbps = 192
            $0.container = "mp4"; $0.extraFlags = "-movflags +faststart"
        },
        make("H.265 MP4") {
            $0.videoCodec = "libx265"; $0.qualityMode = .crf; $0.crf = 24
            $0.audioCodec = "aac"; $0.audioKbps = 192
            // Without the hvc1 tag QuickTime and Photos refuse an otherwise valid file.
            $0.container = "mp4"; $0.extraFlags = "-preset medium -tag:v hvc1 -movflags +faststart"
        },
        make("ProRes 422 HQ") {
            $0.videoCodec = "prores_ks"; $0.proresProfile = 3
            $0.audioCodec = "pcm_s16le"
            $0.container = "mov"
        },
        make("WebM VP9") {
            $0.videoCodec = "libvpx-vp9"; $0.qualityMode = .crf; $0.crf = 31
            $0.audioCodec = "libopus"; $0.audioKbps = 128
            // VP9 reads -crf only when the bitrate is pinned to 0; otherwise it is a cap.
            $0.container = "webm"; $0.extraFlags = "-b:v 0 -row-mt 1"
        },
        make("Audio: MP3 320") {
            $0.includeVideo = false
            $0.audioCodec = "libmp3lame"; $0.audioKbps = 320
            $0.container = "mp3"
        },
        make("Audio: M4A 256") {
            $0.includeVideo = false
            $0.audioCodec = "aac"; $0.audioKbps = 256
            $0.container = "m4a"
        },
        make("Audio: WAV") {
            $0.includeVideo = false
            $0.audioCodec = "pcm_s16le"
            $0.container = "wav"
        },
        make("Fit to 25 MB") {
            $0.videoCodec = "libx264"; $0.qualityMode = .targetSize; $0.targetSizeMB = 25
            $0.audioCodec = "aac"; $0.audioKbps = 128
            $0.container = "mp4"; $0.extraFlags = "-preset medium -movflags +faststart"
        },
        make("Remux to MP4 (no re-encode)") {
            $0.videoCodec = Encoders.copyID
            $0.audioCodec = Encoders.copyID
            $0.container = "mp4"; $0.extraFlags = "-movflags +faststart"
        },
        make("Remove Audio") {
            $0.videoCodec = Encoders.copyID
            $0.includeAudio = false
            $0.container = "original"
        },
    ]

    private static func make(_ name: String, _ body: (inout ConvertPreset) -> Void) -> ConvertPreset {
        var p = ConvertPreset(name: name, isBuiltIn: true)
        p.id = stableID(name)
        body(&p)
        return p
    }

    /// Built-ins are rebuilt from source on every launch, so a fresh `UUID()` would be a
    /// different id each time and "remember the last preset I used" could never resolve
    /// one — it would silently fall back to the first built-in forever. Derived from the
    /// name so the id survives relaunches without anything being written to disk.
    static func stableID(_ name: String) -> UUID {
        var bytes = [UInt8](Insecure.MD5.hash(data: Data(name.utf8)))
        return bytes.withUnsafeMutableBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }
}

// MARK: - Preset store

/// User presets in Application Support beside queue.json. Built-ins are never written to
/// disk, so improving one in a later build reaches everybody instead of being shadowed
/// by a stale saved copy.
@MainActor @Observable
final class PresetStore {
    private(set) var custom: [ConvertPreset] = []

    var all: [ConvertPreset] { ConvertPreset.builtIns + custom }

    static let storeURL = AppSupport.file("presets.json")

    init() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = try? JSONDecoder().decode([ConvertPreset].self, from: data) else { return }
        custom = saved
    }

    func save(_ preset: ConvertPreset) {
        var fresh = preset
        fresh.isBuiltIn = false
        if let i = custom.firstIndex(where: { $0.id == fresh.id }) {
            custom[i] = fresh
        } else {
            custom.append(fresh)
        }
        write()
    }

    func delete(_ id: UUID) {
        custom.removeAll { $0.id == id }
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(custom) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

// MARK: - Job

enum ConvertState: String, Codable, Hashable {
    case queued, converting, done, failed, cancelled

    var label: String {
        switch self {
        case .queued: "Waiting"
        case .converting: "Converting"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct ConvertJob: Identifiable, Hashable {
    var id = UUID()
    var source: URL
    var preset: ConvertPreset
    var sourceDuration: Double?
    var sourceBytes: Int64?
    var destinationDir: String?   // nil writes beside the source
    var trimStart: String = ""    // timecode text exactly as typed; "" means from the top
    var trimEnd: String = ""      // "" means to the end

    var state: ConvertState = .queued
    var progress: Double = 0
    var duration: Double?         // learned from ffmpeg's own banner once it starts
    var speed: String = ""
    var outputSize: String = ""
    var outputPath: String?
    var error: String?
    var details: String?

    var title: String { source.lastPathComponent }

    var subtitle: String {
        var parts = [preset.name]
        if !trimStart.isEmpty || !trimEnd.isEmpty {
            parts.append("trim \(trimStart.isEmpty ? "start" : trimStart)–\(trimEnd.isEmpty ? "end" : trimEnd)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Timecodes

enum Timecode {
    /// Accepts "90", "1:30", "01:02:03", "1:02:03.5". Returns nil for anything else, so
    /// a typo becomes a disabled Convert button rather than an ffmpeg argument.
    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        // Indices, not value comparison: in "01:01" the two components are equal as
        // strings, and matching on content would skip the check on one of them.
        for (i, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Only the final component may be fractional; "1.5:00" is a typo, not 90s.
            if i < parts.count - 1, value != value.rounded() { return nil }
            // And only the leading one may reach 60; "1:70" is a typo too.
            if i > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// 3725.0 -> "1:02:05". Mirrors Double.asDuration but always includes hours when the
    /// clip is long enough, which is what a trim field wants back.
    static func text(_ seconds: Double) -> String { seconds.asDuration }
}
