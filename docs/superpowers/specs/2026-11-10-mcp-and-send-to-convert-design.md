# MCP connector and "send downloads to Convert"

2026-11-10. Two features, one shared piece of groundwork.

Decisions marked **(call)** were made while writing this, not by the owner. They are the
ones to check.

## Why

1. **Agents.** The owner wants to say "download this and give me a 25 MB MP4" to an agent
   and have VideoDart do it, visibly, in its own queues. Today the only way in is the UI.
2. **Download → Convert is a detour.** A finished download can only reach the Convert pane
   by finding the file in Finder and dragging it back into the app it came from.

## Goals

- Any MCP client (Claude Code, Claude Desktop, Cursor, Codex) connects with one copied
  command, and can download, convert, watch progress and read results.
- What an agent does appears in the same queues the user sees. No second, hidden engine.
- From the Download pane: one click sends one finished download to Convert; select several
  and send them together.
- From the Convert pane: finished downloads can be picked without leaving it.

## Non-goals

- No remote access, no network port, no auth tokens.
- No MCP resources, prompts, sampling or progress notifications. Tools only.
- No agent access to Settings (cookies, paths, update channel) or to preset editing.
- No new dependencies. Sparkle stays the only one.
- No persistence of the convert queue or staging list across relaunches (unchanged).

## Anti-goals

- A localhost HTTP server. Any web page the user visits can reach one.
- An agent path that bypasses `DownloadQueue` / `ConvertQueue` and runs yt-dlp or ffmpeg
  itself. Two writers of `queue.json` is how a queue gets wiped.
- Changing what double-click, Pause, Remove or drag-and-drop do today.

---

## Part 0 — Groundwork: staging moves up to the app

`Staging` is `@State` inside `ConvertView`, and `ContentView` builds `ConvertView` only
while the Convert pane is showing. So staged files are thrown away on switching to
Download, and nothing outside `ConvertView` can add to the list. Both features need it.

- `VideoDartApp` owns one `Staging` (`@State`, like `converter`) and passes it by
  `.environment`. `ConvertView` reads it from the environment instead of creating it.
- `adopt` moves from `ConvertView` onto `Staging`:

  ```swift
  /// Adds files not already staged, probes them, selects their outputs.
  /// Returns the ids of the outputs now selected (new and already-staged alike).
  @discardableResult
  func adopt(_ urls: [URL]) -> [UUID]
  ```

  A URL already staged is not added twice; its existing outputs are selected instead.
  New files get one output with `workingPreset`, exactly as a drop does now. Selection
  becomes the adopted outputs, so the inspector edits what just arrived.
- Side effect, intended: the staging list now survives switching panes.
- `VD_STAGE` / `VD_AUTOCONVERT` keep working.

## Part 1 — Send downloads to Convert

"Convertible" means: a `DownloadJob` with `state == .done`, an `outputPath`, the file
still on disk, and `FFmpeg.isMedia` true for it.

### From the Download pane

- **Row button.** A done row gains a Convert button (`wand.and.rays`, the Convert pane's
  own symbol) next to Show in Finder. Disabled when the row isn't convertible. The
  controls column widens to fit three buttons; it stays fixed-width so rows don't shift.
- **Context menu.** "Convert…" above "Open Source Page", same enablement.
- **Multi-select.** The download list becomes selectable (`List(selection:)` of job ids;
  ⌘A, shift-click, ⌘-click). With a selection:
  - the context menu on the selection offers "Convert N Files" (N = convertible ones;
    hidden when N is 0);
  - the status bar shows a "Convert N Selected" button to the left of the folder link.
- **More menu.** "Convert All Finished", disabled when nothing is convertible.
- Every one of these calls `staging.adopt(urls)` and sets `navigator.pane = .convert`.
  Nothing starts converting; the user lands on the staging list with the new outputs
  selected and the preset inspector pointed at them.
- Double-click still opens the file. If `List(selection:)` swallows the existing
  `onTapGesture(count: 2)`, use the list's `contextMenu(forSelectionType:primaryAction:)`
  for it instead — the behaviour is what must survive, not the mechanism.

### From the Convert pane

- The toolbar's "Add Files…" button becomes a menu with the same icon **(call)**:
  - "Choose Files…" (today's panel)
  - a "Finished Downloads" section listing convertible downloads, newest first, at most
    10, by title — each adopts that file
  - "All Finished Downloads" when there are two or more
  The section is absent when there are none.
- The empty state gains a second button, "Add Finished Downloads", shown only when at
  least one exists.

Put the "which downloads are convertible, newest first" logic in one place
(`DownloadQueue.convertible`), not in each view.

## Part 2 — MCP connector

### Shape **(call)**

The app's own executable doubles as a stdio MCP server:

```sh
claude mcp add videodart -- /Applications/VideoDart.app/Contents/MacOS/VideoDart --mcp
```

Launched with `--mcp`, the binary never starts SwiftUI. It is a relay: it connects to the
running app over a Unix domain socket, starts the app first if it isn't running, then
copies stdin lines to the socket and socket lines to stdout. All protocol and tool logic
lives in the GUI app, so the queues stay single-owner and the user watches the agent work.

Why this and not the alternatives: stdio is the one transport every client supports;
a socket file under Application Support is reachable only by the same user (mode 0600)
and by no browser; and there is no second binary to sign or keep in step.

### Pieces

**Entry point.** `@main` moves off `VideoDartApp` onto a tiny `enum Main`: `--mcp` in
`CommandLine.arguments` → `MCPBridge.run()` (never returns); otherwise
`VideoDartApp.main()`. The bridge must not touch `NSApplication`, Sparkle, `Prefs`, or
`SelfCheck`.

**`MCPBridge` (relay process).**
- Socket path: `AppSupport.file("mcp.sock")`.
- Connect. On failure, `open -g <Bundle.main.bundleURL>` (background, no focus steal) and
  retry for up to 15 s. Still nothing → answer each incoming request with a JSON-RPC error
  saying VideoDart could not be started or has agent access turned off, and keep running
  so the client shows the reason instead of a dead server.
- Stdout carries protocol lines only. Diagnostics go to stderr.
- stdin EOF or socket close → exit 0.

**`MCPServer` (in the app).** Owned by `VideoDartApp`, given the download queue, convert
queue, preset store, staging and navigator.
- Listens on the socket when `Prefs.Key.mcpEnabled` is true (**default true (call)** —
  the socket is same-user only, and a same-user process can already run yt-dlp itself).
  Toggling the pref starts/stops the listener without a relaunch. Remove a stale socket
  file before binding; `chmod 0600`; unlink on quit.
- `sockaddr_un` holds 103 bytes of path. If the path is longer, don't listen and let
  Settings say why.
- Several clients at once is normal. One connection each, newline-delimited JSON-RPC 2.0,
  requests handled on the main actor.
- Methods: `initialize`, `notifications/initialized` (no reply), `ping`, `tools/list`,
  `tools/call`. Anything else with an id → `-32601`. Unparseable line → `-32700`.
- `initialize` replies with the client's requested `protocolVersion` if it is one of
  `2025-06-18`, `2025-03-26`, `2024-11-05`, else `2025-06-18`; capabilities `{tools: {}}`;
  `serverInfo` name `videodart`, version from the bundle; and a short `instructions`
  string describing the download → wait → convert flow.
- Tool results: `content: [{type: "text", text: <JSON>}]` plus the same object as
  `structuredContent`. A tool failure is a result with `isError: true` and a plain
  sentence an agent can act on, not a JSON-RPC error.

**Settings.** A fourth tab, "Agents" (`sparkles` or similar):
- Toggle "Let agents control VideoDart".
- Status line: listening / off / why not.
- "Copy Claude Code Command" (the line above, with this copy's real executable path) and
  "Copy MCP Config" (the `{"mcpServers": {"videodart": {"command": …, "args": ["--mcp"]}}}`
  JSON for Claude Desktop, Cursor and the rest).
- One sentence on what agents can and cannot do.

### Tools

Names are snake_case. Every argument not marked required is optional. Job ids are UUID
strings. Every job object carries `id`, `title`, `state`, `progress` (0–1), `output_path`,
`error`; downloads add `url`, `kind`, `speed`, `eta`, `size`; conversions add `source`,
`preset`.

| Tool | Arguments | Does |
|---|---|---|
| `get_status` | — | App version; whether yt-dlp, ffmpeg and the JS runtime are installed; default download folder; counts of jobs by state in both queues. |
| `probe_url` | `url`* | Title, whether it is a playlist, entries (index, title, duration, url). No side effects. |
| `add_download` | `url`*, `kind` (`video_audio` default, `video`, `audio`), `quality` (`best` default or a height like `1080`), `container` (`mp4`/`mkv`/`original`; for audio `m4a`/`mp3`/`opus`/`flac`/`original`), `subtitles` (`off`/`embed`/`sidecar`), `subtitle_languages`, `destination` (absolute folder; default the user's), `playlist_items` (1-based indexes; default all) | Probes, then queues one job per entry — the Add sheet without the sheet. Returns the new jobs and how many were skipped as already queued. |
| `list_downloads` | `state`, `ids` | The download queue, optionally filtered. |
| `control_downloads` | `action`* (`pause`/`resume`/`retry`/`remove`/`clear_finished`), `ids` (omit for all, where that makes sense) | `remove` requires `ids`. Removing never deletes a downloaded file (it doesn't in the UI either). |
| `list_presets` | — | Built-in and saved presets: `id`, `name`, `built_in`, `summary`. |
| `convert` | `paths` and/or `download_ids` (at least one item between them)*, `preset` (name or id; default the user's remembered preset), `trim_start`, `trim_end`, `destination` (default: the Convert pane's folder setting) | Queues conversions immediately and returns the jobs. Unknown preset, missing file, non-media file, unfinished download, bad timecode → `isError` naming the offender; nothing is queued unless everything is valid. |
| `stage_for_convert` | `paths` and/or `download_ids`* | Puts files in the Convert pane's staging list and switches to it, for the human to choose settings. The agent-side twin of Part 1. |
| `list_conversions` | `state`, `ids` | The convert queue. |
| `control_conversions` | `action`* (`cancel`/`retry`/`remove`/`clear_finished`), `ids` | As the UI's buttons. |
| `wait_for_jobs` | `ids`* (download and/or convert), `timeout_seconds` (default 30, max 120) | Returns when every listed job is done, failed, cancelled or paused, or at the timeout — with the jobs' current state either way, and `timed_out`. This is what saves an agent a polling loop. |

`convert` builds its `ConvertJob` the way `ConvertView.job(for:_:)` does, including the
probe (duration and size) — a size-target preset divides by duration, and a job queued
without one goes out at a flat 8 Mbps. Share that code rather than copying it.

Not offered on purpose: editing presets, raw ffmpeg flags per call (a saved preset can
carry them), changing settings, deleting files.

## Constraints that come from the codebase

- Swift 6 strict concurrency. Both queues, the preset store and staging are `@MainActor`.
- **SelfCheck is the test suite.** Anything with a branch gets a check there, in the
  existing style. At minimum: JSON-RPC parsing (bad JSON, missing id, unknown method),
  the `initialize` version negotiation, `tools/list` containing every tool with a valid
  `inputSchema`, `add_download` argument → `DownloadJob` mapping (kinds, audio container,
  `playlist_items`, a bad `kind`), preset lookup by name and by id, `convert`'s
  all-or-nothing validation, and `DownloadQueue.convertible` filtering. That means the
  argument-mapping and validation code must be callable without a socket or a running
  process — write it as pure functions and have the server call them.
- `Prefs.Key.mcpEnabled` is a pref, not a persisted model; `DownloadJob` and
  `ConvertPreset` gain no fields, so the lenient-decoding cases don't change.
- `AppSupport.directory` stays the only place an on-disk path is decided.
- `FFmpeg.outputURL` is untouched.
- Deployment target is macOS 14; the Liquid Glass fallbacks via `adaptiveGlass` stay.
- Release builds are hardened-runtime and notarized, unsandboxed. Nothing here needs an
  entitlement.

## Done means

1. Debug build succeeds and the app launches (SelfCheck didn't trap).
2. A finished download reaches the Convert staging list by row button, by multi-select,
   and from the Convert pane's Add menu; staged files survive switching panes.
3. With the app running, piping `initialize` → `tools/list` → `list_presets` into
   `VideoDart --mcp` returns well-formed replies; with the app not running, the same
   pipe starts it.
4. Through the bridge: `convert` on a small local file with a built-in preset, then
   `wait_for_jobs`, ends `done` with an `output_path` that exists.
5. README gains a short "Use with an agent" section; CHANGELOG gets an Unreleased entry;
   CLAUDE.md's "on purpose" list gains the socket-not-HTTP and single-owner-queues points.

## Left to the builder

File layout (suggested: `MCP.swift` for server and tools, `MCPBridge.swift` for the
relay), POSIX sockets vs Network.framework, the exact wording of UI strings and tool
descriptions, how the status bar button animates in.

## Build order

1. Part 0 + Part 1 (one pass — same files).
2. Part 2 (new files, plus the entry point, Settings tab, docs).
