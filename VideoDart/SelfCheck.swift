#if DEBUG
import Foundation

/// ponytail: one assert-based check instead of a test target — it runs on every Debug
/// launch, so a broken progress parser or argument builder traps immediately.
enum SelfCheck {
    static func run() {
        // Progress line parsing
        guard case let .progress(pct, speed, eta, size) =
                YTDLP.event(from: "PROG| 42.3%|  1.25MiB/s|00:31|20.3MiB|48.0MiB")
        else { fatalError("progress not parsed") }
        assert(abs(pct - 0.423) < 0.0001, "percent \(pct)")
        assert(speed == "1.25MiB/s", speed)
        assert(eta == "00:31", eta)
        assert(size == "20.3MiB of 48.0MiB", size)

        // Unknown percent must not crash or produce NaN
        // Live streams report N/A for most fields; none of it may reach the UI as "N/A".
        guard case let .progress(unknown, s1, e1, sz1) =
                YTDLP.event(from: "PROG|   N/A%|   N/A|N/A|1.5MiB|N/A")
        else { fatalError("N/A progress not parsed") }
        assert(unknown == 0, "N/A should read as 0, got \(unknown)")
        assert(s1.isEmpty && e1.isEmpty, "N/A must become empty, not \"N/A\"")
        assert(sz1 == "1.5MiB", "unknown total should show what has arrived, got \(sz1)")

        // Verbatim final line from a real download — yt-dlp switches to bare "NA" here.
        guard case let .progress(_, _, e2, sz2) =
                YTDLP.event(from: "PROG|100.0%|2.97MiB/s|NA|NA|   1.86MiB")
        else { fatalError("final progress line not parsed") }
        assert(e2.isEmpty, "bare NA eta must be swallowed, got \(e2)")
        assert(sz2 == "1.86MiB", "bare NA downloaded must not print, got \(sz2)")

        guard case let .file(path) = YTDLP.event(from: "FILE|/Users/x/Downloads/Clip [abc].mp4") else {
            fatalError("filepath not parsed")
        }
        assert(path.hasSuffix("Clip [abc].mp4"), path)

        guard case .log = YTDLP.event(from: "[Merger] Merging formats") else { fatalError("log not parsed") }

        // Argument builder: the URL is always last, and the format selector matches the kind.
        let base = DownloadJob(url: "https://example.com/v", title: "t", kind: .videoAudio,
                               quality: "1080", container: "mp4", destination: "/tmp")
        let video = YTDLP.arguments(for: base)
        assert(video.last == "https://example.com/v", "url must be the final argument")
        assert(video.contains("--merge-output-format"), "video+audio must merge")
        assert(video.contains { $0.contains("height<=?1080") }, "quality cap missing")

        var audio = base
        audio.kind = .audio
        audio.container = "mp3"
        let audioArgs = YTDLP.arguments(for: audio)
        assert(audioArgs.contains("-x"), "audio must extract")
        assert(!audioArgs.contains("--merge-output-format"), "audio must not merge")

        var original = base
        original.container = "original"
        assert(!YTDLP.arguments(for: original).contains("--merge-output-format"),
               "\"keep original\" must not force a container")

        // "MP4" means QuickTime plays it: H.264 and AAC win at each resolution, but
        // resolution still ranks first. Audio and other containers keep yt-dlp's ranking.
        assert(adjacent(video, ["-S", "res,vcodec:h264,acodec:m4a"]), "MP4 must prefer H.264 + AAC")
        assert(!audioArgs.contains("-S"), "audio picks its own codec")
        assert(!YTDLP.arguments(for: original).contains("-S"), "\"keep original\" means as uploaded")

        // Both halves of "Both, split" share a video id; one archive file made whichever
        // ran second finish as "Already downloaded", with no file.
        assert(YTDLP.archive(for: .audio) != YTDLP.archive(for: .videoAudio))
        assert(YTDLP.archive(for: .video) == YTDLP.archive(for: .videoAudio))

        // Speed limit: yt-dlp's syntax, forgiving of a space and case; anything else is
        // dropped, because passing it on failed every job.
        assert(YTDLP.rateLimit("2M") == "2M")
        assert(YTDLP.rateLimit(" 500 k") == "500K")
        assert(YTDLP.rateLimit("2.5M") == "2.5M")
        assert(YTDLP.rateLimit("1000") == "1000")
        assert(YTDLP.rateLimit("2 MB/s") == nil, "a unit yt-dlp rejects must not be passed on")
        assert(YTDLP.rateLimit("0") == nil, "zero is not a limit")
        assert(YTDLP.rateLimit("") == nil)

        // Error extraction strips yt-dlp's CLI hints, wiki links and "[extractor] id:" prefix.
        let raw = """
        [youtube] Extracting URL
        ERROR: [youtube] P1-Era4suVg: Sign in to confirm your age. This video may be \
        inappropriate for some users. Use --cookies-from-browser or --cookies for the \
        authentication. See https://github.com/yt-dlp/yt-dlp/wiki/FAQ for how to pass cookies
        """
        let cleaned = YTDLP.cleanError(raw)
        assert(cleaned == "Sign in to confirm your age. This video may be inappropriate for some users.",
               "got: \(cleaned)")
        assert(YTDLP.isAuthError(cleaned), "age gate must offer the sign-in fix")

        // A message whose colon belongs to the text keeps its context.
        let http = YTDLP.cleanError("ERROR: [generic] Unable to download webpage: HTTP Error 404")
        assert(http == "Unable to download webpage: HTTP Error 404", "got: \(http)")
        assert(!YTDLP.isAuthError(http), "404 is not a sign-in problem")

        // Instagram, verbatim. Stories phrase the wall as "log in", which the old literal
        // list missed entirely — the sheet then offered no browser picker, leaving the
        // user at a dead end for a link one cookie source away from working.
        let story = YTDLP.cleanError("""
        ERROR: [instagram:story] You need to log in to access this content. Use \
        --cookies-from-browser or --cookies for the authentication. See  \
        https://github.com/yt-dlp/yt-dlp/wiki/FAQ  for how to manually pass cookies
        """)
        assert(story == "You need to log in to access this content.", "got: \(story)")
        assert(YTDLP.isAuthError(story), "\"log in\" must offer the sign-in fix")

        // Reels put the hint mid-sentence and double-space "See  https", so neither
        // " Use --" nor " See http" matched and 550 characters of CLI boilerplate,
        // wiki links and issue-tracker prose reached the user intact.
        let reel = YTDLP.cleanError("""
        ERROR: [Instagram] C8QltEXSBjK: Instagram sent an empty media response. Check if \
        this post is accessible in your browser without being logged-in. If it is not, \
        then use --cookies-from-browser or --cookies for the authentication. See  \
        https://github.com/yt-dlp/yt-dlp/wiki/FAQ  for how to manually pass cookies. \
        Otherwise, please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= \
        . Confirm you are on the latest version using  yt-dlp -U
        """)
        assert(reel == "Instagram sent an empty media response. Check if this post is "
               + "accessible in your browser without being logged-in.", "got: \(reel)")
        assert(YTDLP.isAuthError(reel), "hyphenated \"logged-in\" must still offer the fix")

        // Followers-only posts use yt-dlp's default login-required wording, no "log in" at all.
        let followers = YTDLP.cleanError("""
        ERROR: [Instagram] DdH9q19J5VJg9uPUZ_jDGI0TP2fzwkHxA748fI0: This content is only \
        available for registered users who follow this account. Use --cookies-from-browser \
        or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ
        """)
        assert(followers == "This content is only available for registered users who follow this account.",
               "got: \(followers)")
        assert(YTDLP.isAuthError(followers), "\"registered users\" must offer the sign-in fix")

        // A profile that names no folder. "cookies" made this read as a sign-in wall, and
        // picking the same browser again in that sheet just repeated it — the fix is the
        // Profile field, which only Settings has.
        let missing = """
        ERROR: could not find chrome cookies database in "/Users/u/Library/Application Support/Google/Chrome/u"
        """
        let profile = YTDLP.cleanError(missing, blocked: { _ in false })
        assert(profile.hasPrefix("Couldn’t find Chrome’s cookies."), "got: \(profile)")
        assert(YTDLP.isCookieSetupError(profile), "a missing cookie database must point at Settings")
        assert(!YTDLP.isAuthError(profile), "a missing cookie database is not a sign-in wall")
        assert(!YTDLP.isCookieSetupError(story), "a real sign-in wall is not a settings problem")

        // The same yt-dlp words when macOS keeps VideoDart out of the browser's folder —
        // which only shows when launched from Finder, never from a terminal.
        let blocked = YTDLP.cleanError(missing, blocked: { $0 == "chrome" })
        assert(blocked.hasPrefix("macOS isn’t letting VideoDart read Chrome’s cookies."), "got: \(blocked)")
        assert(YTDLP.isCookiePermissionError(blocked) && !YTDLP.isCookieSetupError(blocked))
        assert(!YTDLP.isAuthError(blocked), "a privacy refusal is not a sign-in wall")
        let safari = YTDLP.cleanError("ERROR: [Errno 1] Operation not permitted: '/Users/u/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'")
        assert(YTDLP.isCookiePermissionError(safari), "got: \(safari)")
        assert(!YTDLP.isCookieFolderBlocked("none") && !YTDLP.isCookieFolderBlocked("file"))

        // Chrome's "Local State", trimmed: profiles come back in the browser's own order,
        // named as it names them, with the folder yt-dlp needs.
        let localState = #"""
        {"profile":{"last_used":"Default","profiles_order":["Default","Profile 7","Profile 2"],
         "info_cache":{"Profile 7":{"name":"Work","user_name":"w@example.com"},
                       "Default":{"name":"David","user_name":"d@example.com"},
                       "Profile 2":{"name":"","user_name":""}}}}
        """#
        let listed = YTDLP.profiles(fromLocalState: Data(localState.utf8))
        assert(listed.map(\.folder) == ["Default", "Profile 7", "Profile 2"], "got \(listed.map(\.folder))")
        assert(listed[0].label == "David — d@example.com")
        assert(listed[2].label == "Profile 2", "a nameless profile falls back to its folder")
        assert(YTDLP.profiles(fromLocalState: Data("{}".utf8)).isEmpty)
        // A sign-in wall despite cookies names what was sent, so a wrong profile shows.
        assert(YTDLP.profileHint(source: "chrome", profile: "")?.contains("whichever Chrome profile changed last") == true)
        assert(YTDLP.profileHint(source: "none", profile: "") == nil)
        assert(YTDLP.profileHint(source: "file", profile: "") == nil)

        assert(YTDLP.displayTitle("DHC August Video_02.mp4") == "DHC August Video_02")
        assert(YTDLP.displayTitle("Talk: v1.0 of the thing") == "Talk: v1.0 of the thing",
               "a dot that is not a media extension must survive")
        assert(YTDLP.displayTitle(".mp4") == ".mp4", "a bare extension is not a title to strip")

        // Adding a field must not orphan existing queue.json files: DownloadQueue.load()
        // swallows decode errors, so a break here silently wipes the user's queue.
        let job = DownloadJob(url: "u", title: "t", kind: .audio, container: "m4a", destination: "/tmp")
        let encoded = try! JSONEncoder().encode([job])
        assert(!String(decoding: encoded, as: UTF8.self).contains("details"),
               "nil optionals must be omitted, so older files lack the key")
        assert((try? JSONDecoder().decode([DownloadJob].self, from: encoded)) != nil,
               "a job missing the newer keys must still decode")

        // The real v1 on-disk shape, verbatim: no "size", no "details". A round trip of a
        // freshly built job cannot catch this, because it always writes the current keys.
        let legacy = """
        [{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","url":"https://example.com/v",
        "title":"Old Job","uploader":"","kind":"videoAudio","quality":"best","container":"mp4",
        "subs":"off","subLangs":"en","destination":"/tmp","state":"done","progress":1,
        "speed":"","eta":"","addedAt":778000000}]
        """
        let restored = try? JSONDecoder().decode([DownloadJob].self, from: Data(legacy.utf8))
        assert(restored?.count == 1, "a queue.json from an older build must still load")
        assert(restored?.first?.size == "", "a field added later must fall back to its default")
        assert(restored?.first?.title == "Old Job", "existing values must survive")

        // The update banner compares dated versions; age alone used to nag about a copy
        // that was already the newest release.
        assert(YTDLP.isBehind("2026.07.01", latest: "2026.08.19"), "older release must be behind")
        assert(!YTDLP.isBehind("2026.08.19", latest: "2026.08.19"), "the latest release is current, however old")
        assert(YTDLP.isBehind("2025.12.31", latest: "2026.01.02"), "year boundary must compare numerically")
        assert(YTDLP.isBehind("2026.08.09", latest: "2026.08.10"), "components compare as numbers, not text")
        // Nightly builds carry a fourth component; it must not defeat the parse.
        assert(!YTDLP.isBehind("2026.08.19.232355", latest: "2026.08.19"), "same-day nightly is current")
        assert(!YTDLP.isBehind("2026.08.20.010203", latest: "2026.08.19"), "a newer nightly is current")
        assert(!YTDLP.isBehind("not a version", latest: "2026.08.19"), "unparseable version must not warn")
        assert(!YTDLP.isBehind("2026.08.19", latest: ""), "an unknown latest must not warn")
        // Both feeds, trimmed from verbatim responses. A Homebrew copy is measured against
        // the formula, not GitHub: brew trails by a day or two and can't install what it
        // doesn't have yet.
        let formula = #"{"name":"yt-dlp","versions":{"stable":"2026.10.21","head":"HEAD","bottle":true},"revision":1}"#
        assert(YTDLP.formulaVersion(Data(formula.utf8)) == "2026.10.21", "Homebrew's stable version")
        let release = #"{"tag_name":"2026.10.26","name":"yt-dlp 2026.10.26","prerelease":false}"#
        assert(YTDLP.releaseTag(Data(release.utf8)) == "2026.10.26", "GitHub's release tag")
        assert(YTDLP.formulaVersion(Data(release.utf8)) == nil, "the wrong feed must not parse as the right one")

        convert()
    }

    /// True when `flags` appears as consecutive arguments — `contains` alone would pass
    /// on "-crf" and "20" sitting at opposite ends of the command line.
    private static func adjacent(_ args: [String], _ flags: [String]) -> Bool {
        guard let i = args.firstIndex(of: flags[0]), i + flags.count <= args.count else { return false }
        return Array(args[i..<(i + flags.count)]) == flags
    }

    private static func convert() {
        // MARK: Timecodes
        assert(Timecode.seconds("90") == 90)
        assert(Timecode.seconds("1:30") == 90)
        assert(Timecode.seconds("0:01:30") == 90)
        assert(Timecode.seconds("1:02:03.5") == 3723.5)
        assert(Timecode.seconds("01:01") == 61, "equal components must both be validated")
        assert(Timecode.seconds("") == nil)
        assert(Timecode.seconds("abc") == nil)
        assert(Timecode.seconds("-5") == nil, "a negative seek is not a trim point")
        assert(Timecode.seconds("1:70") == nil, "70 seconds is a typo, not 70 seconds")
        assert(Timecode.seconds("1.5:00") == nil, "only the last component may be fractional")
        assert(Timecode.seconds("1:2:3:4") == nil)

        // MARK: Extra-flag tokenizing
        assert(FFmpeg.tokenize("-preset medium -movflags +faststart")
               == ["-preset", "medium", "-movflags", "+faststart"])
        assert(FFmpeg.tokenize("-vf \"eq=contrast=1.2\"") == ["-vf", "eq=contrast=1.2"],
               "a quoted argument is one token, not two")
        assert(FFmpeg.tokenize("-metadata title=\"a b\"") == ["-metadata", "title=a b"])
        assert(FFmpeg.tokenize("").isEmpty)
        assert(FFmpeg.tokenize("   ").isEmpty)

        // MARK: Argument builder
        let source = URL(fileURLWithPath: "/tmp/clip.mov")
        let output = URL(fileURLWithPath: "/tmp/clip.mp4")

        var h264 = ConvertPreset(name: "t")
        h264.videoCodec = "libx264"; h264.qualityMode = .crf; h264.crf = 20
        h264.audioCodec = "aac"; h264.audioKbps = 192
        h264.container = "mp4"; h264.extraFlags = "-movflags +faststart"
        let plain = FFmpeg.arguments(for: ConvertJob(source: source, preset: h264), output: output)
        assert(plain.last == "/tmp/clip.mp4", "the output path must be the final argument")
        assert(plain.contains("-nostdin"), "a GUI-spawned ffmpeg must not wait on stdin")
        assert(adjacent(plain, ["-i", "/tmp/clip.mov"]))
        assert(adjacent(plain, ["-c:v", "libx264"]))
        assert(adjacent(plain, ["-crf", "20"]))
        assert(adjacent(plain, ["-c:a", "aac"]))
        assert(adjacent(plain, ["-b:a", "192k"]))
        assert(adjacent(plain, ["-movflags", "+faststart"]), "extra flags must survive tokenizing")
        assert(!plain.contains("-ss"), "an untrimmed job must not seek")
        assert(!plain.contains("-vf"), "no resolution cap means no filter chain")

        // The VideoToolbox encoders silently ignore -crf; sending it would ship a file at
        // whatever bitrate they picked while the UI claimed a quality had been chosen.
        var hardware = h264
        hardware.videoCodec = "h264_videotoolbox"; hardware.qualityMode = .bitrate; hardware.videoKbps = 8000
        let hw = FFmpeg.arguments(for: ConvertJob(source: source, preset: hardware), output: output)
        assert(!hw.contains("-crf"), "a bitrate encoder must not be handed -crf")
        assert(adjacent(hw, ["-b:v", "8000k"]))

        var prores = h264
        prores.videoCodec = "prores_ks"; prores.proresProfile = 3; prores.container = "mov"
        let pr = FFmpeg.arguments(for: ConvertJob(source: source, preset: prores), output: output)
        assert(adjacent(pr, ["-profile:v", "3"]))
        assert(!pr.contains("-crf"))

        var remux = h264
        remux.videoCodec = Encoders.copyID; remux.audioCodec = Encoders.copyID
        remux.maxHeight = 1080          // meaningless while copying, and must not be emitted
        let copied = FFmpeg.arguments(for: ConvertJob(source: source, preset: remux), output: output)
        assert(adjacent(copied, ["-c:v", "copy"]))
        assert(adjacent(copied, ["-c:a", "copy"]))
        assert(!copied.contains("-vf"), "a copied stream cannot be scaled")
        assert(!copied.contains("-crf"))
        assert(remux.isCopyOnly, "the UI promises \"lossless\" off this flag")

        var muted = h264
        muted.includeAudio = false
        let noAudio = FFmpeg.arguments(for: ConvertJob(source: source, preset: muted), output: output)
        assert(noAudio.contains("-an"))
        assert(!noAudio.contains("-c:a"))

        var audioOnly = h264
        audioOnly.includeVideo = false
        let noVideo = FFmpeg.arguments(for: ConvertJob(source: source, preset: audioOnly), output: output)
        assert(noVideo.contains("-vn"))
        assert(!noVideo.contains("-c:v"))

        var scaled = h264
        scaled.maxHeight = 720; scaled.fps = 30
        let small = FFmpeg.arguments(for: ConvertJob(source: source, preset: scaled), output: output)
        // The escaped comma matters: ffmpeg reads a bare one as a filter separator and
        // rejects the graph, so this is the difference between 720p and a failed job.
        assert(adjacent(small, ["-vf", "scale=-2:trunc(min(ih\\,720)/2)*2"]),
               "got: \(small.first { $0.hasPrefix("scale") } ?? "no scale filter")")
        assert(adjacent(small, ["-r", "30"]))

        // MARK: Trimming
        var trimmed = ConvertJob(source: source, preset: h264)
        trimmed.trimStart = "1:30"
        trimmed.trimEnd = "2:00"
        let cut = FFmpeg.arguments(for: trimmed, output: output)
        let ss = cut.firstIndex(of: "-ss")!
        let input = cut.firstIndex(of: "-i")!
        assert(ss < input, "-ss must seek the input; after -i it decodes and discards instead")
        assert(adjacent(cut, ["-ss", "90.000"]))
        assert(adjacent(cut, ["-t", "30.000"]), "the span, not the end point")
        assert(FFmpeg.trimDuration(trimmed) == 30)

        var backwards = trimmed
        backwards.trimEnd = "1:00"                  // before the start
        assert(FFmpeg.trimDuration(backwards) == nil, "an inverted trim must not become -t")
        assert(!FFmpeg.arguments(for: backwards, output: output).contains("-t"))

        var openEnded = ConvertJob(source: source, preset: h264)
        openEnded.trimStart = "0:10"
        assert(FFmpeg.trimDuration(openEnded) == nil, "no end point means run to the end")

        // MARK: Output naming — the data-loss guard
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-selfcheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp4 = dir.appendingPathComponent("clip.mp4")
        FileManager.default.createFile(atPath: mp4.path, contents: Data())
        let sameFormat = ConvertJob(source: mp4, preset: h264)   // mp4 -> mp4, beside itself
        let first = FFmpeg.outputURL(for: sameFormat)
        assert(first.path != mp4.path,
               "handing ffmpeg its own input as the output truncates the source to nothing")
        assert(first.lastPathComponent == "clip (converted).mp4", first.lastPathComponent)

        FileManager.default.createFile(atPath: first.path, contents: Data())
        assert(FFmpeg.outputURL(for: sameFormat).lastPathComponent == "clip (converted 2).mp4")

        var keepContainer = h264
        keepContainer.container = "original"
        let kept = FFmpeg.outputURL(for: ConvertJob(source: dir.appendingPathComponent("a.mkv"),
                                                    preset: keepContainer))
        assert(kept.pathExtension == "mkv", "\"same as source\" must not rename the container")

        // MARK: ffmpeg output parsing
        assert(FFmpeg.duration(in: "  Duration: 00:00:06.00, start: 0.000000, bitrate: 126 kb/s") == 6)
        assert(FFmpeg.duration(in: "  Duration: 01:02:03.50, start: 0.000000") == 3723.5)
        assert(FFmpeg.duration(in: "  Duration: N/A, bitrate: N/A") == nil)
        assert(FFmpeg.duration(in: "  Stream #0:0: Video: h264, yuv420p, 640x360") == nil)

        // A verbatim -progress block. Nothing may surface until the terminator arrives,
        // or the bar jumps on a half-read block.
        let accumulator = FFmpeg.ProgressAccumulator()
        for line in ["frame=180", "fps=0.00", "stream_0_0_q=-1.0", "bitrate= 121.7kbits/s",
                     "total_size=91273", "out_time_us=6000000", "out_time_ms=6000000",
                     "out_time=00:00:06.000000", "dup_frames=0", "drop_frames=0", "speed=61.2x"] {
            assert(accumulator.consume(line) == nil, "emitted early on: \(line)")
        }
        guard case let .progress(seconds, speed, size)? = accumulator.consume("progress=continue")
        else { fatalError("progress block not parsed") }
        assert(seconds == 6, "expected 6s, got \(seconds)")
        assert(speed == "61.2x", speed)
        assert(!size.isEmpty, "total_size should reach the row")

        // Live inputs report N/A; none of it may reach the UI as the literal string.
        let unknown = FFmpeg.ProgressAccumulator()
        _ = unknown.consume("out_time_us=1500000")
        _ = unknown.consume("speed=N/A")
        guard case let .progress(_, blank, _)? = unknown.consume("progress=end")
        else { fatalError("final progress block not parsed") }
        assert(blank.isEmpty, "N/A must become empty, not \"N/A\"")

        // MARK: Errors
        let failure = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/tmp/a.mov':
          Duration: 00:00:06.00, start: 0.000000, bitrate: 126 kb/s
          Stream #0:0: Video: h264 (avc1 / 0x31637661), yuv420p, 640x360
        Unknown encoder 'libx266'
        """
        assert(FFmpeg.cleanError(failure) == "Unknown encoder 'libx266'", FFmpeg.cleanError(failure))
        assert(FFmpeg.cleanError("/tmp/some file.mov: Invalid data found when processing input")
               == "Invalid data found when processing input", "the path is already on the row")
        assert(!FFmpeg.cleanError("").isEmpty, "a silent failure still needs a message")
        // ffmpeg 9, verbatim and trimmed: the cause comes first, then the unwinding. Read
        // from the bottom, both of these used to say only "Conversion failed!".
        let svt = FFmpeg.cleanError("""
        [libx264 @ 0x771b029180] profile High, level 1.2, 4:2:0, 8-bit
        Svt[error]: Max Bitrate only supported with CRF mode
        [libsvtav1 @ 0x7929025180] Error setting encoder parameters: bad parameter (0x80001005)
        [vf#0:0 @ 0x7929030000] Task finished with error code: -22 (Invalid argument)
        [out#0/mp4 @ 0x7a5500c780] Nothing was written into output file, because at least one of its streams received no packets.
        Conversion failed!
        """)
        assert(svt == "Max Bitrate only supported with CRF mode", "got: \(svt)")
        let webm = FFmpeg.cleanError("""
        [libvpx-vp9 @ 0x7849049180] Neither bitrate nor constrained quality specified, using default CRF of 32
        [webm @ 0x7848c11400] Only VP8 or VP9 or AV1 video and Vorbis or Opus audio and WebVTT subtitles are supported for WebM.
        [out#0/webm @ 0x784904c300] Could not write header (incorrect codec parameters ?): Invalid argument
        [vf#0:0 @ 0x7848c24000] Error sending frames to consumers: Invalid argument
        Conversion failed!
        """)
        assert(webm.hasPrefix("Only VP8 or VP9 or AV1 video"), "got: \(webm)")


        // MARK: Quality modes — the size-led ones and what they emit
        // A CRF-capable codec asked for a bitrate must stop emitting -crf entirely;
        // sending both lets x264 quietly ignore the number the user actually set.
        var rateMode = h264
        rateMode.qualityMode = .bitrate
        rateMode.videoKbps = 2500
        let rated = FFmpeg.arguments(for: ConvertJob(source: source, preset: rateMode), output: output)
        assert(adjacent(rated, ["-b:v", "2500k"]))
        assert(!rated.contains("-crf"), "bitrate mode must not also send a CRF")
        assert(!rated.contains("-maxrate"), "only a target budget needs its peaks capped")

        var sized = h264
        sized.qualityMode = .targetSize
        sized.targetSizeMB = 25
        sized.audioKbps = 128
        // 25 MB over 100 s is 2000 kbit/s all in; 3% headroom then the audio comes off.
        assert(sized.videoKbps(forDuration: 100) == Int(25 * 8000 / 100 * 0.97) - 128,
               "got \(sized.videoKbps(forDuration: 100))")
        assert(sized.videoKbps(forDuration: 100) > 1700 && sized.videoKbps(forDuration: 100) < 1950,
               "a 25 MB / 100 s budget should land near 1.8 Mbit/s")
        // A clip long enough to make the budget absurd must still produce a legal bitrate.
        assert(sized.videoKbps(forDuration: 90_000) >= 64, "bitrate must never go to zero or negative")
        assert(sized.videoKbps(forDuration: nil) == sized.videoKbps,
               "with no duration there is nothing to divide, so fall back to the plain rate")

        var sizedJob = ConvertJob(source: source, preset: sized)
        sizedJob.sourceDuration = 100
        let budgeted = FFmpeg.arguments(for: sizedJob, output: output)
        assert(budgeted.contains("-maxrate") && budgeted.contains("-bufsize"),
               "a target is a promise about the whole file; peaks must be capped")
        assert(!budgeted.contains("-crf"))
        var av1Sized = sized
        av1Sized.videoCodec = "libsvtav1"
        var av1Job = ConvertJob(source: source, preset: av1Sized)
        av1Job.sourceDuration = 100
        assert(!FFmpeg.arguments(for: av1Job, output: output).contains("-maxrate"),
               "SVT-AV1 rejects -maxrate outside CRF mode and writes nothing")

        // Measure encodes four seconds of a longer clip; the size cap is the clip's.
        var cappedCRF = h264
        cappedCRF.maxSizeMB = 100
        var sample = ConvertJob(source: source, preset: cappedCRF)
        sample.trimStart = "0"; sample.trimEnd = "4"
        let sampleArgs = FFmpeg.arguments(for: sample, output: output, budgetDuration: 400)
        let wholeArgs = FFmpeg.arguments(for: sample, output: output)
        assert(adjacent(sampleArgs, ["-maxrate", "\(Int(100 * 8000 / 400 * 0.97) - 192)k"]),
               "the sample must be capped for 400 s, got \(sampleArgs)")
        assert(sampleArgs != wholeArgs, "without the clip's length the cap spreads over 4 s")

        // VP9 needs the bitrate pinned to zero for -crf to mean constant quality, and
        // must NOT get that pin when it is being asked for a real bitrate.
        var vp9 = h264
        vp9.videoCodec = "libvpx-vp9"; vp9.container = "webm"; vp9.audioCodec = "libopus"
        vp9.qualityMode = .crf
        assert(adjacent(FFmpeg.arguments(for: ConvertJob(source: source, preset: vp9), output: output),
                        ["-b:v", "0"]), "VP9 CRF needs -b:v 0 or it targets its own default rate")
        vp9.qualityMode = .bitrate
        vp9.videoKbps = 1500
        assert(adjacent(FFmpeg.arguments(for: ConvertJob(source: source, preset: vp9), output: output),
                        ["-b:v", "1500k"]), "VP9 in bitrate mode must not be pinned to 0")

        // MARK: Size cap — "35 Mbps, but under 20 MB"
        var capped = h264
        capped.qualityMode = .bitrate; capped.videoKbps = 35_000; capped.maxSizeMB = 20
        capped.includeAudio = false
        assert(capped.videoKbps(forDuration: 3) == 35_000, "a short clip fits at the asked rate")
        assert(capped.videoKbps(forDuration: 60) == Int(20 * 8000 / 60 * 0.97),
               "a long one drops to what fits, got \(capped.videoKbps(forDuration: 60))")
        var cappedJob = ConvertJob(source: source, preset: capped)
        cappedJob.sourceDuration = 60
        let cappedArgs = FFmpeg.arguments(for: cappedJob, output: output)
        assert(adjacent(cappedArgs, ["-b:v", "\(Int(20 * 8000 / 60 * 0.97))k"]))
        assert(cappedArgs.contains("-maxrate"), "a size promise caps its peaks")
        assert(capped.estimatedBytes(duration: 60, sourceBytes: nil, sourceDuration: nil)! <= 20_000_000)
        var sizedCapped = sized
        sizedCapped.maxSizeMB = 5
        assert(sizedCapped.videoKbps(forDuration: 100) == sized.videoKbps(forDuration: 100),
               "target-size mode already is a cap; a second one must not apply")

        var vp9Capped = vp9
        vp9Capped.qualityMode = .crf; vp9Capped.maxSizeMB = 20; vp9Capped.includeAudio = false
        var vp9Job = ConvertJob(source: source, preset: vp9Capped)
        vp9Job.sourceDuration = 60
        assert(adjacent(FFmpeg.arguments(for: vp9Job, output: output), ["-b:v", "\(Int(20 * 8000 / 60 * 0.97))k"]),
               "capped VP9 CRF is constrained quality: the cap goes in -b:v instead of 0")

        // MARK: Two-pass
        assert(!h264.supportsTwoPass, "x264 rejects CRF with two passes")
        assert(rateMode.supportsTwoPass && sized.supportsTwoPass)
        assert(vp9Capped.supportsTwoPass, "VP9 takes CRF two-pass as constrained quality")
        assert(!hardware.supportsTwoPass, "VideoToolbox has no multi-pass")
        var passJob = ConvertJob(source: source, preset: rateMode)
        passJob.pass = 1
        let pass1 = FFmpeg.arguments(for: passJob, output: output)
        assert(adjacent(pass1, ["-pass", "1"]) && pass1.contains("-passlogfile"))
        assert(pass1.contains("-an") && pass1.suffix(3) == ["-f", "null", "/dev/null"],
               "pass 1 analyses video only and writes no file")
        passJob.pass = 2
        let pass2 = FFmpeg.arguments(for: passJob, output: output)
        assert(adjacent(pass2, ["-pass", "2"]) && pass2.last == output.path && !pass2.contains("-an"))
        assert(!FFmpeg.arguments(for: ConvertJob(source: source, preset: rateMode), output: output)
            .contains("-pass"), "a single-pass job must not mention passes")
        var x265 = rateMode
        x265.videoCodec = "libx265"
        var x265Job = ConvertJob(source: source, preset: x265)
        x265Job.pass = 2
        let x265Args = FFmpeg.arguments(for: x265Job, output: output)
        assert(!x265Args.contains("-pass"), "libx265 ignores -pass")
        assert(x265Args.contains { $0.hasPrefix("pass=2:stats=") })

        // MARK: Color
        assert(!FFmpeg.arguments(for: ConvertJob(source: source, preset: h264), output: output).contains("-vf"),
               "neutral color settings must emit no filter")
        var graded = scaled
        graded.contrast = 1.1; graded.lutPath = "/tmp/a,b: c.cube"
        let gradedArgs = FFmpeg.arguments(for: ConvertJob(source: source, preset: graded), output: output)
        let vf = gradedArgs[gradedArgs.firstIndex(of: "-vf")! + 1]
        assert(vf.hasPrefix("scale=") && vf.contains(#",lut3d=file=/tmp/a\,b\\: c.cube,eq="#), vf)
        assert(vf.hasSuffix("eq=brightness=0.00:contrast=1.10:saturation=1.00"), vf)
        assert(FFmpeg.filterEscape("it's") == #"it\\\'s"#, FFmpeg.filterEscape("it's"))
        var gradedCopy = graded
        gradedCopy.videoCodec = Encoders.copyID
        assert(!FFmpeg.arguments(for: ConvertJob(source: source, preset: gradedCopy), output: output)
            .contains("-vf"), "a copied stream cannot be filtered")

        // MARK: Size estimation
        assert(rateMode.estimatedBytes(duration: 60, sourceBytes: nil, sourceDuration: nil)
               == Int64((2500.0 + 192) * 1000 * 60 / 8), "bitrate mode is exact arithmetic")
        assert(sized.estimatedBytes(duration: 60, sourceBytes: nil, sourceDuration: nil)
               == 25_000_000, "target-size mode estimates the target itself")
        assert(h264.estimatedBytes(duration: 60, sourceBytes: nil, sourceDuration: nil) == nil,
               "CRF cannot be predicted — that nil is what puts a Measure button on the row")
        assert(rateMode.estimatedBytes(duration: nil, sourceBytes: nil, sourceDuration: nil) == nil,
               "no duration, no estimate")

        var remuxOnly = h264
        remuxOnly.videoCodec = Encoders.copyID
        remuxOnly.audioCodec = Encoders.copyID
        assert(remuxOnly.estimatedBytes(duration: 30, sourceBytes: 1000, sourceDuration: 60) == 500,
               "a copy of half the clip is half the bytes")
        assert(remuxOnly.estimatedBytes(duration: 120, sourceBytes: 1000, sourceDuration: 60) == 1000,
               "an untrimmed copy is the whole source, never more")

        // A copied or lossless track spends what it spends; the budget has to leave room
        // for it, or a 25 MB target with copied 256k audio lands near 44 MB.
        var sizedCopyAudio = sized
        sizedCopyAudio.audioCodec = Encoders.copyID
        assert(sizedCopyAudio.videoKbps(forDuration: 100) == Int(25 * 8000 / 100 * 0.97) - 320,
               "copied audio must be reserved, got \(sizedCopyAudio.videoKbps(forDuration: 100))")
        var sizedWAV = sized
        sizedWAV.audioCodec = "pcm_s16le"
        assert(sizedWAV.videoKbps(forDuration: 100) < sized.videoKbps(forDuration: 100) - 1000,
               "uncompressed audio takes most of a small budget")
        var sizedSilent = sized
        sizedSilent.includeAudio = false
        assert(sizedSilent.videoKbps(forDuration: 100) == Int(25 * 8000 / 100 * 0.97),
               "no audio, nothing to reserve")

        // MARK: Containers must take both streams
        var vp9AAC = h264
        vp9AAC.videoCodec = "libvpx-vp9"
        assert(vp9AAC.allowedContainers == ["mkv"], "WebM refuses AAC; got \(vp9AAC.allowedContainers)")
        var h264PCM = h264
        h264PCM.audioCodec = "pcm_s16le"
        assert(!h264PCM.allowedContainers.contains("mp4"), "MP4 takes no PCM")
        var av1MP3 = h264
        av1MP3.videoCodec = "libsvtav1"; av1MP3.audioCodec = "libmp3lame"
        assert(av1MP3.allowedContainers.contains("mp4"), "MP3 muxes into MP4")
        for preset in ConvertPreset.builtIns {
            assert(preset.reconciled() == preset, "built-in \(preset.name) must already be consistent")
        }

        // MARK: Editing several outputs: only the edited field travels
        let mp3 = ConvertPreset.builtIns.first { $0.name == "Audio: MP3 320" }!
        var nudged = h264
        nudged.audioKbps = 256
        let changes = ConvertPreset.changedFields(from: h264, to: nudged)
        assert(changes.keys.sorted() == ["audioKbps"], "got \(changes.keys.sorted())")
        let stillMP3 = mp3.applying(changes)
        assert(stillMP3.audioKbps == 256, "the edit must land")
        assert(!stillMP3.includeVideo && stillMP3.container == "mp3" && stillMP3.audioCodec == "libmp3lame",
               "an MP3 output must not become the first row's MP4")
        assert(stillMP3.id == mp3.id && stillMP3.name == mp3.name, "identity is not an edit")
        assert(mp3.applying([:]) == mp3)

        // And through Staging, the object the inspector edits: an MP4 and an MP3 output
        // selected together, one bitrate nudged.
        MainActor.assumeIsolated {
            let staging = Staging()
            let mp4Out = StagedOutput(preset: h264), mp3Out = StagedOutput(preset: mp3)
            staging.files = [StagedFile(url: source, outputs: [mp4Out, mp3Out])]
            staging.selection = [mp4Out.id, mp3Out.id]
            var edit = staging.editedPreset
            edit.audioKbps = 256
            staging.editedPreset = edit
            let after = staging.files[0].outputs.map(\.preset)
            assert(after.allSatisfy { $0.audioKbps == 256 }, "the edit must reach every selected output")
            assert(after[1].container == "mp3" && !after[1].includeVideo, "the MP3 output must stay MP3")
            assert(after[0].container == "mp4" && after[0].includeVideo)
            // Picking a preset is the whole preset, on all of them.
            staging.apply(mp3)
            assert(staging.files[0].outputs.allSatisfy { $0.preset == mp3.reconciled() })
            assert(staging.selectedPresetID == mp3.id)
            // With nothing selected, edits go to the preset new files get, not to rows.
            staging.selection = []
            var working = staging.editedPreset
            working.crf = 30
            staging.editedPreset = working
            assert(staging.workingPreset.crf == 30)
            assert(staging.files[0].outputs.allSatisfy { $0.preset == mp3.reconciled() })
        }

        // MARK: Which modes each codec can offer
        assert(h264.availableQualityModes == [.targetSize, .bitrate, .crf])
        assert(hardware.availableQualityModes == [.targetSize, .bitrate],
               "the VideoToolbox encoders have no CRF to offer")
        assert(prores.availableQualityModes.isEmpty, "ProRes takes a profile, not a rate")
        assert(remux.availableQualityModes.isEmpty, "a copied stream has no quality to set")

        // The remembered-preset lookup is by id, and built-ins are reconstructed every
        // launch — a random id there means the setting never resolves and silently
        // reverts to the first preset.
        assert(ConvertPreset.stableID("H.264 MP4") == ConvertPreset.stableID("H.264 MP4"),
               "a built-in id must not change between launches")
        assert(ConvertPreset.stableID("H.264 MP4") != ConvertPreset.stableID("H.265 MP4"))
        assert(Set(ConvertPreset.builtIns.map(\.id)).count == ConvertPreset.builtIns.count,
               "two built-ins sharing an id would make one unpickable")

        // MARK: Reconciling after a codec change
        // Switching a CRF preset to a hardware encoder must not leave CRF selected: that
        // encoder has no such flag, so the number the user set would be silently dropped.
        var switched = h264
        switched.videoCodec = "h264_videotoolbox"
        let fixedMode = switched.reconciled()
        assert(fixedMode.qualityMode == .bitrate,
               "a codec with no CRF must not keep CRF selected, got \(fixedMode.qualityMode)")

        // And switching to a codec that cannot live in the current container must move it.
        var toVP9 = h264                       // container is mp4
        toVP9.videoCodec = "libvpx-vp9"
        toVP9.audioCodec = "libopus"
        let fixedContainer = toVP9.reconciled()
        assert(fixedContainer.allowedContainers.contains(fixedContainer.container),
               "\(fixedContainer.container) is not muxable by VP9")
        assert(fixedContainer.container == "webm", "got \(fixedContainer.container)")

        // A preset that is already consistent must come back untouched, or every edit
        // would quietly rewrite something the user chose.
        assert(h264.reconciled() == h264, "reconciling a valid preset must change nothing")
        assert(sized.reconciled().qualityMode == .targetSize, "a supported mode must survive")

        // MARK: 0.3.0 presets.json — rates were strings, and there was no mode at all
        assert(ConvertPreset.parseRate("8M") == 8000)
        assert(ConvertPreset.parseRate("192k") == 192)
        assert(ConvertPreset.parseRate("2500") == 2500)
        assert(ConvertPreset.parseRate(nil) == nil)
        assert(ConvertPreset.parseRate("") == nil)

        let v030 = """
        [{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","name":"Old Hardware","isBuiltIn":false,
        "videoCodec":"h264_videotoolbox","videoBitrate":"8M","audioCodec":"aac",
        "audioBitrate":"256k","container":"mp4","crf":20}]
        """
        let migrated = try? JSONDecoder().decode([ConvertPreset].self, from: Data(v030.utf8))
        assert(migrated?.first?.videoKbps == 8000, "an \"8M\" string must survive as 8000 kbit/s")
        assert(migrated?.first?.audioKbps == 256, "got \(String(describing: migrated?.first?.audioKbps))")
        assert(migrated?.first?.qualityMode == .bitrate,
               "a 0.3.0 preset has no mode; it must be inferred from the codec, as that build did")

        let v030crf = """
        [{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA428","name":"Old x264","videoCodec":"libx264",
        "crf":18,"videoBitrate":"8M","audioBitrate":"192k","container":"mp4"}]
        """
        let migratedCRF = try? JSONDecoder().decode([ConvertPreset].self, from: Data(v030crf.utf8))
        assert(migratedCRF?.first?.qualityMode == .crf, "a CRF codec infers CRF mode")
        assert(migratedCRF?.first?.crf == 18, "and keeps the number it was set to")

        // Round-tripping the new shape must not resurrect the legacy keys.
        let reencoded = try! JSONEncoder().encode([rateMode])
        assert(!String(decoding: reencoded, as: UTF8.self).contains("videoBitrate"),
               "the 0.3.0 string keys are read-only; writing them again would be a second source of truth")
        assert((try? JSONDecoder().decode([ConvertPreset].self, from: reencoded))?.first?.videoKbps == 2500)

        // MARK: Presets
        assert(FFmpeg.isMedia(URL(fileURLWithPath: "/tmp/a.mov")))
        assert(FFmpeg.isMedia(URL(fileURLWithPath: "/tmp/a.mp3")))
        assert(!FFmpeg.isMedia(URL(fileURLWithPath: "/tmp/a.txt")))
        assert(!FFmpeg.isMedia(URL(fileURLWithPath: "/tmp/a.pdf")))

        // Every built-in must name a codec the catalogue knows and a container that codec
        // can actually mux — a typo here ships a preset that fails on every file.
        for preset in ConvertPreset.builtIns {
            assert(!preset.includeVideo || Encoders.video(preset.videoCodec) != nil,
                   "\(preset.name): unknown video codec \(preset.videoCodec)")
            assert(!preset.includeAudio || Encoders.audio(preset.audioCodec) != nil,
                   "\(preset.name): unknown audio codec \(preset.audioCodec)")
            assert(preset.allowedContainers.contains(preset.container),
                   "\(preset.name): \(preset.container) is not offered for its codec")
            assert(!preset.summary.isEmpty)
        }

        var mine = ConvertPreset(name: "Mine")
        mine.crf = 33
        let encoded = try! JSONEncoder().encode([mine])
        let round = try? JSONDecoder().decode([ConvertPreset].self, from: encoded)
        assert(round?.first?.crf == 33)
        assert(round?.first?.name == "Mine")

        // The shape an older build would have written: adding a field must not orphan an
        // existing presets.json, because PresetStore.init silently drops what it cannot read.
        let legacy = """
        [{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","name":"Old","isBuiltIn":false,
        "videoCodec":"libx264","crf":18,"container":"mp4"}]
        """
        let restored = try? JSONDecoder().decode([ConvertPreset].self, from: Data(legacy.utf8))
        assert(restored?.count == 1, "an older presets.json must still load")
        assert(restored?.first?.crf == 18, "existing values must survive")
        assert(restored?.first?.audioKbps == 192, "a field added later falls back to its default")
        assert(restored?.first?.maxSizeMB == 0 && restored?.first?.twoPass == false
               && restored?.first?.contrast == 1 && restored?.first?.saturation == 1
               && restored?.first?.lutPath == "", "0.4 presets predate size caps, passes and color")

        var roundGraded = graded
        roundGraded.twoPass = true; roundGraded.maxSizeMB = 20
        let gradedRound = try? JSONDecoder().decode(ConvertPreset.self, from: JSONEncoder().encode(roundGraded))
        assert(gradedRound == roundGraded, "every new field must survive a save")

        // One wrong-typed value, or a mode a newer build added, must cost that field —
        // not the preset, and through the store not every preset in the file.
        let future = """
        [{"name":"Future","qualityMode":"perceptual","crf":"18","videoCodec":"libx265","audioKbps":160},
         {"name":"Fine","crf":22},
         7]
        """
        let decoded = PresetStore.decode(Data(future.utf8))
        assert(decoded.presets.count == 2, "a bad entry must not take the others; got \(decoded.presets.count)")
        assert(decoded.lost, "the dropped entry must be reported so the file is kept")
        assert(decoded.presets[0].name == "Future" && decoded.presets[0].audioKbps == 160,
               "readable fields survive their unreadable neighbours")
        assert(decoded.presets[0].crf == 20, "a wrong-typed field falls back to its default")
        assert(decoded.presets[0].qualityMode == .crf, "an unknown mode is inferred from the codec")
        assert(decoded.presets[1].crf == 22)
        assert(!PresetStore.decode(Data(legacy.utf8)).lost)

        // A preset saved from the old VP9 built-in loses the -b:v 0 that overrode its
        // size controls; anything else in its flags, and other codecs' flags, stay.
        let oldVP9 = PresetStore.decode(Data("""
        [{"name":"Mine","videoCodec":"libvpx-vp9","extraFlags":"-b:v 0 -row-mt 1"},
         {"name":"Raw","videoCodec":"libx264","extraFlags":"-b:v 0"}]
        """.utf8)).presets
        assert(oldVP9[0].extraFlags == "-row-mt 1", "got \(oldVP9[0].extraFlags)")
        assert(oldVP9[1].extraFlags == "-b:v 0", "only the VP9 legacy flag is removed")
        assert(PresetStore.decode(Data("not json".utf8)).lost)
    }
}
#endif
