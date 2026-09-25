# Changelog

All notable changes to VideoDart are documented here. Versions follow
[semantic versioning](https://semver.org).

## 0.5.1 (Beta), 2026-09-25

### Fixed

- **Convert settings stopped updating on screen.** Changes were saved, but the settings
  panel kept showing the old values: the Quality slider snapped back when dragged, and
  switching between Target size, Bitrate and Quality left the old controls showing. Broken
  in 0.4.1 too.
- **Edits went nowhere while a finished conversion was selected.** With a row in the
  Converting section selected, the panel showed the default settings but saved every
  change to no output at all. Those edits now go to the default settings.
- **The Size limit field no longer takes the text cursor** when the Convert pane opens.

## 0.5.0 (Beta), 2026-09-25

Delivery specs ("under 20 MB, no audio, VBR two-pass") and a simple grade.

### Added

- **Size limit.** Bitrate and Quality modes take an optional cap in MB. In Bitrate
  mode a clip too long for the asked rate drops to whatever fits, so "35 Mbps, but under
  20 MB" does what it says. With VP9 in Quality mode the cap becomes constrained quality.
- **Two-pass encoding** for H.264, H.265 and VP9. The first pass reads the clip to plan
  the bitrate, the second encodes it; each is half the progress bar. H.264 and H.265 offer
  it in Bitrate and Target size modes, since x264 refuses two-pass with CRF.
- **Color.** Brightness, contrast and saturation sliders, and a `.cube` / `.3dl` LUT
  applied to the export. The LUT is applied first, so a log-to-Rec.709 LUT normalises the
  footage and the sliders then adjust the result. Saved with the preset.
- **Automatic Measure.** Quality-mode outputs under five minutes are measured as soon as
  the file is read, one at a time, instead of waiting for the Measure button.

### Fixed

- **A measurement that finished after its settings changed is thrown away** rather than
  shown against settings it never measured.

## 0.4.1 (Beta), 2026-09-15

Ready for macOS 27 Golden Gate.

### Changed

- **Built for macOS 27.** VideoDart is now built with the macOS 27 SDK.
- **Updater on macOS 27.** In-app updates move to Sparkle 2.10.0, the release
  with Sparkle's macOS 27 fixes.

## 0.4.0 (Beta), 2026-09-15

Size becomes something you set, not something you find out afterwards.

### Added

- **Quality is now an explicit choice: Target size, Bitrate, or Quality (CRF).** It used
  to be implied by the codec, which is how a hardware encoder ended up showing a CRF
  slider it ignores. Target size takes a figure in MB and works the bitrate out per file
  from that file's length, capping the peaks so one busy scene can't overshoot.
- **Estimated output size, per output and totalled in the footer.** Exact arithmetic in
  bitrate and target-size modes. CRF genuinely cannot be predicted — it spends whatever
  the picture needs — so those rows get a **Measure** button that encodes a few seconds
  from the middle of the clip and scales the result up. Measured at within 3% of a real
  full encode in testing.
- **One window.** Download and Convert are a segmented switch in the toolbar instead of
  two separate windows, so conversion is visible instead of hidden in the Window menu.
- **Several outputs per file.** Each file in the list has a **+**: add another output and
  the same clip can go out as an MP4 and an MP3 in one pass.
- **Multi-selection.** Select any number of output rows and the inspector edits all of
  them at once; picking a preset from the toolbar applies it to the whole selection.
- **Reset.** Puts finished conversions back in the list with their settings intact, for
  when the answer to "how did that come out" is "smaller, please".
- **Files are probed as they land** — duration, dimensions and size show on the row, and
  every size estimate depends on that duration.
- **A "Fit to 25 MB" preset**, since that is the shape of most "why won't this upload"
  problems.

### Fixed

- **A hardware codec no longer shows a CRF slider.** Changing codecs now reconciles both
  the quality mode and the container against what that encoder can actually do, so
  neither can be left stranded on a setting that gets silently dropped at encode time.
- **Built-in presets keep their identity between launches.** They were rebuilt with a
  fresh UUID each time, so "remember the preset I last used" could never resolve one and
  quietly reverted to the first in the list.
- **The target-size and bitrate fields no longer print their value twice.** The
  `TextField` that takes a number renders its first argument as a label, not as
  placeholder text.
- **Followers-only Instagram posts now offer sign-in.** "Only available for registered
  users who follow this account" matched none of the sign-in phrasings, so the sheet
  showed a dead-end error instead of the browser picker that fixes it.

### Changed

- Video and audio bitrates are stored as plain kbit/s integers rather than ffmpeg rate
  strings ("8M", "192k"). A `presets.json` written by 0.3.0 is migrated on read, keeping
  its numbers and inferring the quality mode its codec implied.

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
