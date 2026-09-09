# Changelog

All notable changes to VideoDart are documented here. Versions follow
[semantic versioning](https://semver.org).

## 0.3.0 (Beta), 2026-09-09

First public release, and the one where the app stops being only a downloader.

### Added

- **Conversion.** A separate window (**⌘⇧C**) with its own queue. Drop video or audio
  files on it, pick a preset, convert. It runs alongside the download window rather
  than competing with it, because converting a folder of clips and watching a
  playlist come down are two things people do at the same time.
- **Eleven built-in presets.** H.264 MP4 and a smaller 720p variant, hardware-accelerated
  H.264 via VideoToolbox, H.265 (tagged `hvc1`, so QuickTime and Photos will actually
  open it), ProRes 422 HQ, WebM VP9, MP3 320 / M4A 256 / WAV audio exports, a lossless
  remux to MP4, and one that only strips the audio track.
- **Saveable presets.** Every FFmpeg control is exposed — codec, CRF or bitrate,
  resolution cap, frame rate, audio codec and bitrate, container, and a raw flags field
  passed through verbatim. Name a set and it joins the menu. Yours live in
  `presets.json`; the built-ins are never written to disk, so improving one in a later
  release reaches everybody instead of being shadowed by a stale saved copy.
- **Video and audio as separate switches.** Export both, either alone, or drop a track
  entirely, without hunting for the preset that happens to do it.
- **Trim points per file.** `1:30`, `0:01:30` and `90` all parse; `1:70` doesn't, and
  says so rather than becoming a silently wrong seek.
- **Self-updating.** Sparkle, with **VideoDart → Check for Updates…** for the manual path.

### Changed

- **The app is now called VideoDart** (it was Video Downloader). Your queue, saved
  presets and the ~90 MB of downloaded tools move themselves to the new Application
  Support folder on first launch — nothing is re-downloaded and nothing is lost.
- **Codec menus only offer what your FFmpeg can do.** The list is filtered against the
  resolved binary's real encoder table. Builds differ, and picking a codec that isn't
  there used to mean a job that failed a minute later with "Unknown encoder".
- **`AppSupport` is the single place on-disk paths are decided.** Four files used to
  rebuild the same path by hand.

### Fixed

- **Converting a file in place can no longer destroy it.** MP4 to MP4 in the same folder
  would have handed FFmpeg its own input as the output and truncated the original to
  nothing. Output paths now always resolve to a free name.
- **Cancelling or removing a running job cleans up after itself.** The half-written file
  is deleted once FFmpeg has actually exited, not while it is still being written — a
  truncated MP4 sitting next to the source is indistinguishable from a finished one
  until you play it.
- **Closing the Convert window no longer abandons a running encode.** The queue belongs
  to the app, not to the window.
