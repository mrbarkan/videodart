import SwiftUI
import AppKit

/// Translucency is a material, not decoration — when the system asks for less of it,
/// fall back to a solid control rather than a glass one that loses contrast.
private struct AdaptiveGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        // Liquid Glass exists only on macOS 26, and is the wrong material when the system
        // asks for less transparency. Both cases fall back to the same solid styles, so
        // this one modifier is the only place the OS version matters.
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func adaptiveGlass(prominent: Bool = false) -> some View {
        modifier(AdaptiveGlass(prominent: prominent))
    }
}

/// One notice row, reused by every "something needs your attention" state.
private struct NoticeBanner: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var command: String? = nil
    var install: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let install {
                    Button("Install", action: install).controlSize(.small)
                }
                if let command {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
                if let onDismiss {
                    Button("Dismiss", systemImage: "xmark", action: onDismiss)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
        }
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ContentView: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage(Prefs.Key.watchClipboard) private var watchClipboard = true

    @State private var urlText = ""
    @State private var pending: String?
    @State private var isDropTarget = false
    @State private var ytdlpAge: Int?
    @State private var staleDismissed = false
    @State private var toolInstalled = YTDLP.isInstalled
    @State private var ffmpegInstalled = YTDLP.isFFmpegInstalled
    @State private var jsRuntimeInstalled = YTDLP.isJSRuntimeInstalled
    @State private var ffmpegDismissed = false
    @State private var installer = ToolInstaller()
    @State private var pasteboardCount = NSPasteboard.general.changeCount
    @FocusState private var urlFocused: Bool

    /// Critically damped by default — graceful, no overshoot, and silent under Reduce Motion.
    private var settle: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }
    private var quick: Animation? { reduceMotion ? nil : .smooth(duration: 0.18) }
    // Nothing can be queued without the tool, so the button must not invite the attempt.
    private var canAdd: Bool { toolInstalled && !urlText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if !toolInstalled, queue.jobs.isEmpty {
                missingTool
            } else if queue.jobs.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Queued", systemImage: "arrow.down.circle")
                } description: {
                    Text("Paste a link above, drop one onto this window, or press ⇧⌘V.")
                }
            } else {
                List {
                    ForEach(queue.jobs) { JobRow(job: $0) }
                }
                .listStyle(.inset)
                .animation(settle, value: queue.jobs.map(\.state))
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            pending = first.absoluteString
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(3)
                .opacity(isDropTarget ? 1 : 0)
                .allowsHitTesting(false)
                .animation(quick, value: isDropTarget)
        }
        .sheet(item: $pending) { AddSheet(url: $0).environment(queue) }
        .onAppear {
            urlFocused = true
            #if DEBUG
            if let preset = ProcessInfo.processInfo.environment["VD_OPEN_SHEET"]
                ?? UserDefaults.standard.string(forKey: "VDOpenSheet") { pending = preset }
            if ProcessInfo.processInfo.environment["VD_RUN_INSTALL"] != nil { runInstall() }
            #endif
        }
        .task { await refreshTooling() }
        // macOS has no clipboard-change notification; activation is the natural moment to
        // look — and the natural moment to notice that yt-dlp was installed meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            adoptClipboardLink()
            Task { await refreshTooling() }
        }
        // Zero-opacity buttons are the compact way to hang window-scoped shortcuts off
        // a view's own @FocusState without routing an action through the menu commands.
        .background {
            ZStack {
                Button("") { urlFocused = true }.keyboardShortcut("l", modifiers: .command)
                Button("") { pasteAndDownload() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            .opacity(0)
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TextField("Paste a video or playlist link", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300, idealWidth: 440)
                .focused($urlFocused)
                .onSubmit(submit)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { submit() } label: {
                Label("Add", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)   // a named action beats a bare glyph
            // Always prominent. Dropping to plain glass while disabled turned it into a
            // low-contrast grey ghost that read as broken; a dimmed accent button is the
            // standard, legible way to say "this is the action, it just isn't ready yet".
            .adaptiveGlass(prominent: true)
            .disabled(!canAdd)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Add to queue (⌘↩)")
            .animation(quick, value: canAdd)
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis") {
                Button("Paste and Download") { pasteAndDownload() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Open Downloads Folder") { openDownloadsFolder() }
                Divider()
                Button("Pause All") { queue.pauseAll() }
                Button("Resume All") { queue.resumeAll() }
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.hasFinished)
            }
            .menuIndicator(.hidden)   // the stray chevron just adds noise next to the glyph
        }
    }

    /// Status feedback, not errors: each of these is fixable in one command.
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if !toolInstalled, !queue.jobs.isEmpty {
                NoticeBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                             title: "yt-dlp not found",
                             message: "Nothing can download until it is installed.",
                             command: "brew install yt-dlp")
            }
            if toolInstalled, !jsRuntimeInstalled {
                NoticeBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                             title: "JavaScript runtime not found",
                             message: "YouTube signs its formats behind a JS challenge; without one, only thumbnails are available.",
                             command: "brew install deno",
                             install: { runInstall() })
            }
            if toolInstalled, !ffmpegInstalled, !ffmpegDismissed {
                NoticeBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                             title: "ffmpeg not found",
                             message: "Merging video with audio, extracting audio and embedding all need it.",
                             command: "brew install ffmpeg",
                             install: { runInstall() },
                             onDismiss: { ffmpegDismissed = true })
            }
            if let days = ytdlpAge, days > 14, !staleDismissed {
                NoticeBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                             title: "yt-dlp is \(days) days old",
                             message: "YouTube changes often — a stale copy is the usual cause of failures.",
                             command: "brew upgrade yt-dlp",
                             onDismiss: { staleDismissed = true })
            }
        }
        .animation(settle, value: toolInstalled)
        .animation(settle, value: ffmpegInstalled)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let overall = queue.overallProgress, queue.activeCount > 0 {
                ProgressView(value: overall)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                Text("\(queue.activeCount) downloading · \(Int(overall * 100))%")
                    .monospacedDigit()
            } else {
                Text("\(queue.jobs.count) item\(queue.jobs.count == 1 ? "" : "s")")
            }
            Spacer()
            Button(action: openDownloadsFolder) {
                Label(URL(fileURLWithPath: Prefs.string(Prefs.Key.downloadDir)).lastPathComponent,
                      systemImage: "folder")
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.bar))
        .animation(settle, value: queue.activeCount)
    }

    /// First run on a machine without Homebrew. One button, no terminal.
    @ViewBuilder
    private var missingTool: some View {
        ContentUnavailableView {
            Label("One-Time Setup", systemImage: "arrow.down.circle")
        } description: {
            switch installer.phase {
            case let .failed(message):
                Text(message)
            case .working, .done:
                Text("Fetching the tools this app needs. This happens once.")
            case .idle:
                Text("This app needs three tools: yt-dlp to fetch, ffmpeg to assemble, and a JavaScript runtime that YouTube's format signing requires. It can download all three for you — about 90 MB to download, kept in Application Support, updating independently of this app.")
            }
        } actions: {
            switch installer.phase {
            case let .working(label, fraction):
                VStack(spacing: 6) {
                    ProgressView(value: fraction) { Text(label) }
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            case .idle, .done:
                Button("Download and Install") { runInstall() }
                    .adaptiveGlass(prominent: true)
                SettingsLink { Text("I Already Have Them…") }
            case .failed:
                Button("Try Again") { runInstall() }
                    .adaptiveGlass(prominent: true)
                Button("Copy Homebrew Command") { copyToPasteboard("brew install yt-dlp ffmpeg") }
            }
        }
    }

    private func runInstall() {
        Task {
            await installer.install()
            await refreshTooling()
        }
    }

    /// Re-read tool availability. Called on launch and on every activation, so installing
    /// yt-dlp in a terminal and switching back updates the window without a relaunch.
    private func refreshTooling() async {
        let wasInstalled = toolInstalled
        toolInstalled = YTDLP.isInstalled
        ffmpegInstalled = YTDLP.isFFmpegInstalled
        jsRuntimeInstalled = YTDLP.isJSRuntimeInstalled
        if toolInstalled, ytdlpAge == nil || !wasInstalled {
            ytdlpAge = YTDLP.versionAge(await YTDLP.version())
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = trimmed
        urlText = ""
    }

    private func pasteAndDownload() {
        guard toolInstalled, let link = clipboardLink() else { return }
        pending = link
    }

    /// Fills the field but never acts on its own — the user still presses Return.
    /// Only when the field is empty, so it can't overwrite something being typed.
    private func adoptClipboardLink() {
        guard watchClipboard, toolInstalled else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        guard urlText.isEmpty, pending == nil, let link = clipboardLink() else { return }
        withAnimation(quick) { urlText = link }
        urlFocused = true
    }

    private func clipboardLink() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              text.lowercased().hasPrefix("http"), !text.contains(" ") else { return nil }
        return text
    }

    private func openDownloadsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Prefs.string(Prefs.Key.downloadDir)))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// Lets a bare URL string drive `.sheet(item:)`.
extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Row

struct JobRow: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let job: DownloadJob
    @State private var hovering = false

    private var fileURL: URL? { job.outputPath.map { URL(fileURLWithPath: $0) } }
    private var quick: Animation? { reduceMotion ? nil : .smooth(duration: 0.18) }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.headline)
                    .tracking(-0.2)          // larger text reads too loose at default tracking
                    .lineLimit(1)
                Text(job.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if job.state.isActive || job.state == .paused {
                    progressBlock
                } else {
                    statusRow
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { openFile() }
        .contextMenu { menu }
    }

    private var thumbnail: some View {
        AsyncImage(url: job.thumbnail.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: job.kind.symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5) }
        .opacity(job.state == .done ? 1 : 0.85)
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if job.state == .processing {
                    ProgressView()          // merging or tagging: no meaningful percentage
                } else {
                    ProgressView(value: job.progress)
                }
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 440)
            // yt-dlp reports in discrete jumps; a spring makes the bar glide between them.
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: job.progress)

            Text(detailLine)
                .font(.caption)
                .monospacedDigit()          // stops the numbers jittering as widths change
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detailLine: String {
        switch job.state {
        case .processing: "Merging and tagging…"
        case .paused: "Paused at \(Int(job.progress * 100))%"
        default:
            ["\(Int(job.progress * 100))%", job.size, job.speed,
             job.eta.isEmpty ? "" : "\(job.eta) left"]
                .filter { !$0.isEmpty }
                .joined(separator: "  ·  ")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 5) {
            Image(systemName: statusIcon).foregroundStyle(statusTint)
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(job.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .font(.caption)
        .help(job.error ?? job.outputPath ?? "")
    }

    private var statusIcon: String {
        switch job.state {
        case .done: fileURL == nil ? "checkmark.circle" : "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private var statusTint: Color {
        switch job.state {
        case .done: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var statusText: String {
        switch job.state {
        case .done:
            // No output path on a success means the archive already had this video.
            fileURL?.lastPathComponent ?? "Already downloaded"
        case .failed: job.error ?? "Failed"
        default: job.state.label
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch job.state {
            case .queued, .downloading, .processing:
                Button("Pause", systemImage: "pause.fill") { queue.pause(job.id) }
            case .paused:
                Button("Resume", systemImage: "play.fill") { queue.resume(job.id) }
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") { queue.retry(job.id) }
            case .done:
                Button("Show in Finder", systemImage: "folder") { revealInFinder() }
                    .disabled(fileURL == nil)
            }
            Button("Remove", systemImage: "xmark") { queue.remove(job.id) }
                .opacity(hovering ? 1 : 0)
        }
        .labelStyle(.iconOnly)
        .adaptiveGlass()
        .controlSize(.small)
        // Fixed width so a state change never shifts the rest of the row sideways.
        .frame(width: 62, alignment: .trailing)
        .animation(quick, value: hovering)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open File") { openFile() }.disabled(fileURL == nil)
        Button("Show in Finder") { revealInFinder() }.disabled(fileURL == nil)
        Divider()
        Button("Open Source Page") {
            if let u = URL(string: job.url) { NSWorkspace.shared.open(u) }
        }
        Button("Copy Link") { copy(job.url) }
        if let details = job.details {
            Button("Copy Error Details") { copy(details) }
        }
        Divider()
        Button("Remove", role: .destructive) { queue.remove(job.id) }
    }

    private func openFile() {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
