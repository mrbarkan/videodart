import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A file waiting to be converted. Trim points live here rather than on the preset
/// because they are a property of this clip, not of the settings you save and reuse.
private struct StagedFile: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var trimStart = ""
    var trimEnd = ""

    /// A field that is neither empty nor a valid timecode; the Convert button waits.
    var trimIsValid: Bool {
        (trimStart.isEmpty || Timecode.seconds(trimStart) != nil)
            && (trimEnd.isEmpty || Timecode.seconds(trimEnd) != nil)
            && !(Timecode.seconds(trimEnd) != nil
                 && Timecode.seconds(trimEnd)! <= (Timecode.seconds(trimStart) ?? 0))
    }
}

struct ConvertView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(ConvertQueue.self) private var queue
    @Environment(PresetStore.self) private var presets
    @State private var preset = ConvertPreset.builtIns[0]
    @State private var pickedPresetID = ConvertPreset.builtIns[0].id
    @State private var staged: [StagedFile] = []
    @State private var isDropTarget = false
    @State private var showInspector = true
    @State private var savingPreset = false
    @State private var newPresetName = ""
    @State private var ffmpegInstalled = FFmpeg.isInstalled
    @State private var installer = ToolInstaller()

    @AppStorage(Prefs.Key.convertDir) private var convertDir = ""
    @AppStorage(Prefs.Key.convertPreset) private var rememberedPreset = ""

    private var settle: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }
    private var quick: Animation? { reduceMotion ? nil : .smooth(duration: 0.18) }

    private var canConvert: Bool {
        ffmpegInstalled && !staged.isEmpty && staged.allSatisfy(\.trimIsValid)
    }

    /// True once the controls no longer match the preset that was picked — the cue for
    /// offering "Save as Preset", and for not pretending a built-in was changed.
    private var isModified: Bool {
        guard let original = presets.all.first(where: { $0.id == pickedPresetID }) else { return true }
        var comparable = preset
        comparable.id = original.id
        comparable.name = original.name
        comparable.isBuiltIn = original.isBuiltIn
        return comparable != original
    }

    var body: some View {
        VStack(spacing: 0) {
            if !ffmpegInstalled { missingFFmpeg }
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 460)
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            PresetEditor(preset: $preset)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter(FFmpeg.isMedia)
            guard !media.isEmpty else { return false }
            withAnimation(settle) { staged += media.map { StagedFile(url: $0) } }
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(3)
                .allowsHitTesting(false)
                .opacity(isDropTarget ? 1 : 0)
                .animation(quick, value: isDropTarget)
        }
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitPreset() }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("These settings become a preset you can pick again.")
        }
        .onChange(of: pickedPresetID) { _, id in
            if let picked = presets.all.first(where: { $0.id == id }) { preset = picked }
            rememberedPreset = id.uuidString
        }
        // The window is closable, so reopening it should not silently drop back to the
        // first built-in after the user picked something else.
        .task {
            if let saved = UUID(uuidString: rememberedPreset),
               let picked = presets.all.first(where: { $0.id == saved }) {
                pickedPresetID = picked.id
                preset = picked
            }
        }
        // Changing the codec can strand the container on something ffmpeg will not
        // mux — H.265 stays selected while the container still says WebM, and the job
        // fails a minute later instead of at the moment of the choice.
        .onChange(of: preset.videoCodec) { _, _ in snapContainer() }
        .onChange(of: preset.audioCodec) { _, _ in snapContainer() }
        .onChange(of: preset.includeVideo) { _, _ in snapContainer() }
        .onChange(of: preset.includeAudio) { _, _ in snapContainer() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ffmpegInstalled = FFmpeg.isInstalled
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Picker("Preset", selection: $pickedPresetID) {
                    Section("Built-in") {
                        ForEach(ConvertPreset.builtIns) { Text($0.name).tag($0.id) }
                    }
                    if !presets.custom.isEmpty {
                        Section("Yours") {
                            ForEach(presets.custom) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                .labelsHidden()
                .frame(minWidth: 200)

                if isModified {
                    Text("Modified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(quick, value: isModified)
        }
        ToolbarItem {
            Menu("Presets", systemImage: "slider.horizontal.3") {
                Button("Save as Preset…") { beginSavePreset() }
                if let current = presets.custom.first(where: { $0.id == pickedPresetID }) {
                    Button("Update “\(current.name)”") {
                        var updated = preset
                        updated.id = current.id
                        updated.name = current.name
                        presets.save(updated)
                    }
                    .disabled(!isModified)
                    Divider()
                    Button("Delete “\(current.name)”", role: .destructive) {
                        presets.delete(current.id)
                        pickedPresetID = ConvertPreset.builtIns[0].id
                    }
                }
                Divider()
                Button("Show Presets File") {
                    NSWorkspace.shared.activateFileViewerSelecting([PresetStore.storeURL])
                }
            }
            .menuIndicator(.hidden)
        }
        ToolbarItem {
            Button("Add Files…", systemImage: "plus") { chooseFiles() }
                .help("Choose files to convert")
        }
        ToolbarItem {
            Button("Settings", systemImage: "sidebar.trailing") {
                withAnimation(settle) { showInspector.toggle() }
            }
            .help("Show or hide the conversion settings")
        }
    }

    @ViewBuilder
    private var content: some View {
        if staged.isEmpty, queue.jobs.isEmpty {
            ContentUnavailableView {
                Label("Drop Files to Convert", systemImage: "arrow.down.doc")
            } description: {
                Text("Drag video or audio files onto this window, or use Add Files.")
            } actions: {
                Button("Add Files…") { chooseFiles() }
                    .adaptiveGlass(prominent: true)
            }
        } else {
            List {
                if !staged.isEmpty {
                    Section("Ready to convert") {
                        ForEach($staged) { file in
                            StagedRow(file: file) {
                                withAnimation(settle) { staged.removeAll { $0.id == file.id } }
                            }
                        }
                    }
                }
                if !queue.jobs.isEmpty {
                    Section("Converting") {
                        ForEach(queue.jobs) { ConvertRow(job: $0) }
                    }
                }
            }
            .listStyle(.inset)
            .animation(settle, value: queue.jobs.map(\.state))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let overall = queue.overallProgress, queue.activeCount > 0 {
                ProgressView(value: overall)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
            }
            Menu {
                Button("Alongside the original") { convertDir = "" }
                Button("Choose Folder…") { chooseDestination() }
                if !convertDir.isEmpty {
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: convertDir))
                    }
                }
            } label: {
                Label(convertDir.isEmpty
                      ? "Alongside the original"
                      : URL(fileURLWithPath: convertDir).lastPathComponent,
                      systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if queue.hasFinished {
                Button("Clear Finished") { queue.clearFinished() }
                    .controlSize(.small)
            }
            Button(convertLabel) { convert() }
                .adaptiveGlass(prominent: true)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canConvert)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.bar))
        .animation(quick, value: canConvert)
    }

    private var convertLabel: String {
        staged.count > 1 ? "Convert \(staged.count) Files" : "Convert"
    }

    /// Same one-button setup the download window offers; ffmpeg is shared between them.
    private var missingFFmpeg: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ffmpeg not found").font(.callout.weight(.medium))
                    Text("Nothing can be converted until it is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if case let .working(label, fraction) = installer.phase {
                    ProgressView(value: fraction) { Text(label).font(.caption) }
                        .progressViewStyle(.linear)
                        .frame(width: 160)
                } else {
                    Button("Install") {
                        Task {
                            await installer.install()
                            ffmpegInstalled = FFmpeg.isInstalled
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
        }
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
    }

    // MARK: - Actions

    private func convert() {
        let destination = convertDir.isEmpty ? nil : convertDir
        queue.add(staged.map {
            ConvertJob(source: $0.url, preset: preset, destinationDir: destination,
                       trimStart: $0.trimStart, trimEnd: $0.trimEnd)
        })
        withAnimation(settle) { staged.removeAll() }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent, .movie, .video, .audio]
        guard panel.runModal() == .OK else { return }
        withAnimation(settle) { staged += panel.urls.map { StagedFile(url: $0) } }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { convertDir = url.path }
    }

    private func beginSavePreset() {
        newPresetName = isModified ? "\(preset.name) Copy" : preset.name
        savingPreset = true
    }

    private func commitPreset() {
        var fresh = preset
        fresh.id = UUID()
        fresh.name = newPresetName.trimmingCharacters(in: .whitespaces)
        presets.save(fresh)
        preset = fresh
        pickedPresetID = fresh.id
    }

    private func snapContainer() {
        let allowed = preset.allowedContainers
        if !allowed.contains(preset.container), let first = allowed.first {
            preset.container = first
        }
    }
}

// MARK: - Rows

private struct StagedRow: View {
    @Binding var file: StagedFile
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("Trim").font(.caption).foregroundStyle(.secondary)
                    TextField("start", text: $file.trimStart)
                        .frame(width: 68)
                    Text("to").font(.caption).foregroundStyle(.secondary)
                    TextField("end", text: $file.trimEnd)
                        .frame(width: 68)
                    if !file.trimIsValid {
                        Label("Use 1:23 or 0:01:23", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button("Remove", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

private struct ConvertRow: View {
    @Environment(ConvertQueue.self) private var queue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let job: ConvertJob

    private var fileURL: URL? {
        job.state == .done ? job.outputPath.map { URL(fileURLWithPath: $0) } : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).lineLimit(1).truncationMode(.middle)
                Text(job.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if job.state == .converting {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 380)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: job.progress)
                    Text(detail)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(job.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 4)
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Show in Finder") { reveal() }.disabled(fileURL == nil)
            Button("Show Original") {
                NSWorkspace.shared.activateFileViewerSelecting([job.source])
            }
            if let details = job.details {
                Divider()
                Button("Copy Error Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details, forType: .string)
                }
            }
        }
    }

    private var icon: String {
        switch job.state {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "slash.circle"
        case .converting: "gearshape.2"
        case .queued: "clock"
        }
    }

    private var tint: Color {
        switch job.state {
        case .done: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var detail: String {
        [job.progress > 0 ? "\(Int(job.progress * 100))%" : "",
         job.outputSize, job.speed]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    private var status: String {
        switch job.state {
        case .done: fileURL?.lastPathComponent ?? "Done"
        case .failed: job.error ?? "Failed"
        default: job.state.label
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch job.state {
            case .queued, .converting:
                Button("Cancel", systemImage: "xmark") { queue.cancel(job.id) }
            case .failed, .cancelled:
                Button("Retry", systemImage: "arrow.clockwise") { queue.retry(job.id) }
            case .done:
                Button("Show in Finder", systemImage: "folder") { reveal() }
            }
            Button("Remove", systemImage: "trash") { queue.remove(job.id) }
        }
        .labelStyle(.iconOnly)
        .adaptiveGlass()
        .controlSize(.small)
        .frame(width: 62, alignment: .trailing)
    }

    private func open() {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reveal() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Inspector

/// The full ffmpeg controls. Every picker is filtered against what the resolved ffmpeg
/// actually supports, so a preset can never name an encoder this build lacks.
private struct PresetEditor: View {
    @Binding var preset: ConvertPreset
    /// The only text field in the form, so SwiftUI hands it first responder on open with
    /// its contents selected — one stray keystroke from wiping the preset's flags.
    @FocusState private var editingFlags: Bool

    private static let heights = [(0, "Keep original"), (2160, "2160p"), (1440, "1440p"),
                                  (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p")]
    private static let rates: [(Double, String)] = [(0, "Keep original"), (60, "60"), (30, "30"),
                                                    (25, "25"), (24, "24"), (15, "15")]

    var body: some View {
        Form {
            Section("Video") {
                Toggle("Include video", isOn: $preset.includeVideo)
                if preset.includeVideo {
                    Picker("Codec", selection: $preset.videoCodec) {
                        ForEach(Encoders.availableVideo) { Text($0.label).tag($0.id) }
                    }
                    quality
                    if preset.videoCodec != Encoders.copyID {
                        Picker("Resolution", selection: $preset.maxHeight) {
                            ForEach(Self.heights, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Picker("Frame rate", selection: $preset.fps) {
                            ForEach(Self.rates, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
            }

            Section("Audio") {
                Toggle("Include audio", isOn: $preset.includeAudio)
                if preset.includeAudio {
                    Picker("Codec", selection: $preset.audioCodec) {
                        ForEach(Encoders.availableAudio) { Text($0.label).tag($0.id) }
                    }
                    if Encoders.audio(preset.audioCodec)?.takesBitrate == true {
                        Picker("Bitrate", selection: $preset.audioBitrate) {
                            ForEach(["320k", "256k", "192k", "160k", "128k", "96k"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    }
                }
            }

            Section {
                Picker("Container", selection: $preset.container) {
                    ForEach(preset.allowedContainers, id: \.self) {
                        Text($0 == "original" ? "Same as source" : $0.uppercased()).tag($0)
                    }
                }
                TextField("Extra flags", text: $preset.extraFlags, prompt: Text("None"))
                    .font(.system(.body, design: .monospaced))
                    .help("Passed to ffmpeg verbatim, e.g. -preset slow -movflags +faststart")
                    .focused($editingFlags)
            } footer: {
                if preset.isCopyOnly {
                    Text("Streams are copied, not re-encoded — fast and lossless. Trim points snap to the nearest keyframe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task { editingFlags = false }
    }

    @ViewBuilder
    private var quality: some View {
        switch Encoders.video(preset.videoCodec)?.quality {
        case .crf:
            let range = Encoders.video(preset.videoCodec)?.crfRange ?? 0...51
            VStack(alignment: .leading, spacing: 2) {
                // Lower is better is the opposite of every other quality slider people
                // meet, so the number and its direction are both spelled out.
                LabeledContent("Quality") {
                    Text("CRF \(preset.crf)").monospacedDigit()
                }
                Slider(value: Binding(get: { Double(preset.crf) },
                                      set: { preset.crf = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Best").font(.caption2)
                } maximumValueLabel: {
                    Text("Smallest").font(.caption2)
                }
            }
        case .bitrate:
            Picker("Bitrate", selection: $preset.videoBitrate) {
                ForEach(["20M", "12M", "8M", "5M", "3M", "1M"], id: \.self) { Text($0).tag($0) }
            }
        case .prores:
            Picker("Profile", selection: $preset.proresProfile) {
                ForEach(Encoders.proresProfiles, id: \.0) { Text($0.1).tag($0.0) }
            }
        default:
            EmptyView()
        }
    }
}
