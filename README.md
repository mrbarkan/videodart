# VideoDart

A native macOS app for **getting video off the web and into the format you need**.
Paste a link and it downloads; drop a file on it and it converts. It wraps
[yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org) in a
SwiftUI interface and **installs both for you** on first launch — no Homebrew, no
Terminal, nothing to configure.

## Features

### Downloading

- **Paste, drop, or copy** — paste a link in the toolbar, drag one onto the window,
  or just copy a URL in your browser and switch back: it lands in the field ready
  to go. Nothing downloads until you press Return.
- **Video, audio, or both** — grab video+audio, video only, audio only, or fan a
  single link out into two jobs at once. Quality up to 2160p, MP4/MKV or the
  original container, M4A/MP3/Opus/FLAC for audio.
- **Playlists and channels** — one link expands into a checklist of every video, so
  you pick what you actually want.
- **Subtitles** — burned into the container or written alongside as `.srt`, in any
  languages the site offers.
- **A real queue** — parallel downloads, pause and resume mid-transfer (the partial
  file is kept), automatic retry on the transient failures YouTube is prone to, and
  a queue that survives quitting the app.
- **Sign-in when a site demands it** — pull cookies from Safari, Chrome, Firefox and
  five other browsers, or a `cookies.txt` file. When a download hits an age gate or
  a members-only wall, the error offers the fix instead of a wall of CLI hints.
- **Skip what you already have** — an optional archive means re-adding a playlist
  downloads only what is new.

### Converting

- **Drop files, pick a preset, convert.** A separate window (**⌘⇧C**) with its own
  queue, so a batch encode and a playlist download run side by side.
- **Eleven built-in presets** — H.264 MP4, a smaller 720p variant, hardware-accelerated
  H.264, H.265, ProRes 422 HQ, WebM VP9, MP3/M4A/WAV audio exports, an instant
  lossless remux to MP4, and one that just strips the audio track.
- **Save your own.** Every control is exposed — codec, CRF or bitrate, resolution cap,
  frame rate, audio codec and bitrate, container, plus a raw flags field that goes
  straight to FFmpeg. Name a set of them and it joins the preset menu.
- **Export video and audio, or either alone** — two toggles, no preset gymnastics.
- **Trim** — type in and out points per file (`1:30`, `0:01:30`, `90` all work).
- **Remux without re-encoding** — change container losslessly in seconds.
- **Only codecs you actually have.** The pickers are filtered against what your
  FFmpeg build really supports, so a preset can never name a missing encoder.

### Throughout

- Converted files never overwrite their source, even converting MP4 to MP4 in place.
- The Mac won't idle-sleep mid-transfer, and you get a notification when a job lands.
- Self-updating via [Sparkle](https://sparkle-project.org) — or **VideoDart →
  Check for Updates…** whenever you like.

## Install

Grab the latest signed `.dmg` from the
[Releases](https://github.com/mrbarkan/videodart/releases) page and drag VideoDart to
Applications. It is Developer ID signed and notarized, so it opens without the
Privacy & Security detour.

On first launch it offers to download the three tools it needs — yt-dlp to fetch,
FFmpeg to assemble and convert, and a JavaScript runtime that YouTube's format
signing requires. About 90 MB, kept in Application Support, updated independently of
the app. If you already have them via Homebrew, it finds those instead.

## Requirements

- macOS 14+, Xcode 26 / Swift 6 to build.

## Build & run

```sh
xcodebuild -project VideoDart.xcodeproj -scheme VideoDart \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Or open `VideoDart.xcodeproj` in Xcode and press Run. The Sparkle dependency resolves
automatically via SwiftPM.

There is no test target. Debug builds run `SelfCheck.run()` at startup instead — an
assert-based suite covering the progress parsers, both argument builders, error
cleanup, timecodes, output-path collision handling and the on-disk format of every
persisted file. A regression traps immediately on launch rather than waiting for a
test run. See `VideoDart/SelfCheck.swift`.

## Architecture

Plain SwiftUI with `@Observable` models; no third-party dependencies beyond Sparkle.

- **`YTDLP.swift`** / **`FFmpeg.swift`** — the two tool wrappers. Both build an
  argument list, spawn the binary, and expose the live `Process` alongside an
  `AsyncStream` of parsed events. They share `LineReader`, which turns a pipe into
  whole lines so a chunk boundary never lands mid-progress-report.
- **`DownloadQueue.swift`** — concurrent, persisted to `queue.json`, with pause/resume
  and a retry budget. **`ConvertQueue.swift`** — deliberately smaller: serial, in
  memory, because FFmpeg already saturates every core.
- **`Convert.swift`** — the encoder catalogue, presets, and the preset store.
- **`Runtime.swift`** — `AppSupport` (the one place on-disk paths are decided) and
  `ToolInstaller`, which fetches yt-dlp, FFmpeg and Deno into Application Support.
  They live outside the app bundle on purpose: a binary inside a signed bundle can't
  be replaced without invalidating the signature, which would freeze yt-dlp between
  app releases — exactly the staleness the app warns you about.
- **`ContentView.swift`** / **`ConvertView.swift`** — the two windows.

State lives in `~/Library/Application Support/VideoDart/`.

## Releasing

See [NOTARIZING.md](NOTARIZING.md). `./make-release.sh 0.3.0` builds, signs, notarizes
and staples both the app and the DMG, then writes the Sparkle `appcast.xml`.

## License

Released under the [MIT License](LICENSE). © 2026 Mr. Barkan.

VideoDart bundles nothing at build time; yt-dlp (Unlicense), FFmpeg (LGPL/GPL) and
Deno (MIT) are downloaded at runtime and remain under their own licenses.
