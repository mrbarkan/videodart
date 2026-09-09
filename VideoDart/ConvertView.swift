import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One thing to produce from one source file. A file can have several — the same clip as
/// an MP4 and an MP3, say — which is why the preset lives here and not on the file.
struct StagedOutput: Identifiable, Hashable {
    let id = UUID()
    var preset: ConvertPreset
    var trimStart = ""
    var trimEnd = ""
    /// Result of the Measure button. Cleared whenever the settings it described change,
    /// because a stale measurement is worse than no measurement.
    var measured: Int64?
    var measuring = false

    var trimIsValid: Bool {
        (trimStart.isEmpty || Timecode.seconds(trimStart) != nil)
            && (trimEnd.isEmpty || Timecode.seconds(trimEnd) != nil)
            && !(Timecode.seconds(trimEnd) != nil
                 && Timecode.seconds(trimEnd)! <= (Timecode.seconds(trimStart) ?? 0))
    }
}

/// A dropped file plus what ffmpeg says about it. The probe is what makes a size estimate
/// possible at all: every estimate is a bitrate multiplied by a duration.
struct StagedFile: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var probe: FFmpeg.MediaProbe?
    var outputs: [StagedOutput]

    var caption: String {
        var parts: [String] = []
        if let d = probe?.duration { parts.append(d.asDuration) }
        if let r = probe?.resolution { parts.append(r) }
        if let bytes = probe?.bytes, bytes > 0 { parts.append(ByteCount.string(bytes)) }
        return parts.joined(separator: " · ")
    }
}

enum ByteCount {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ConvertView: View {
    @Environment(ConvertQueue.self) private var queue
    @Environment(PresetStore.self) private var presets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var staged: [StagedFile] = []
    @State private var selection: Set<UUID> = []
    /// The preset new outputs get, and what the inspector edits when nothing is selected.
    @State private var workingPreset = ConvertPreset.builtIns[0]
    @State private var pickedPresetID = ConvertPreset.builtIns[0].id
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

    private var allOutputs: [(file: StagedFile, output: StagedOutput)] {
        staged.flatMap { file in file.outputs.map { (file, $0) } }
    }

    private var selectedOutputs: [(file: StagedFile, output: StagedOutput)] {
        allOutputs.filter { selection.contains($0.output.id) }
    }

    private var canConvert: Bool {
        ffmpegInstalled && !allOutputs.isEmpty && allOutputs.allSatisfy { $0.output.trimIsValid }
    }

    /// Total of every estimate we have. Outputs still waiting on a Measure are excluded,
    /// so the number is flagged as a floor rather than quietly counting them as zero.
    private var totalEstimate: (bytes: Int64, complete: Bool) {
        var total: Int64 = 0
        var complete = true
        for pair in allOutputs {
            if let bytes = estimate(pair.file, pair.output) { total += bytes } else { complete = false }
        }
        return (total, complete)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !ffmpegInstalled { missingFFmpeg }
            content
            Divider()
            footer
        }
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            PresetEditor(preset: editedPreset, scope: inspectorScope)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .dropDestination(for: URL.self) { urls, _ in
            adopt(urls.filter(FFmpeg.isMedia))
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
            guard let picked = presets.all.first(where: { $0.id == id }) else { return }
            rememberedPreset = id.uuidString
            // Picking a preset with rows selected is how you say "these files, this
            // preset" — the whole point of being able to select more than one.
            if selection.isEmpty { workingPreset = picked } else { apply(picked) }
        }
        .task {
            if let saved = UUID(uuidString: rememberedPreset),
               let picked = presets.all.first(where: { $0.id == saved }) {
                pickedPresetID = picked.id
                workingPreset = picked
            }
            #if DEBUG
            // Same convention as VD_OPEN_SHEET on the download side: the staging list is
            // otherwise only reachable by dropping files, which a test cannot do. Runs
            // after the preset is restored, so staged rows get the one a drop would get.
            if let paths = ProcessInfo.processInfo.environment["VD_STAGE"], !paths.isEmpty {
                _ = adopt(paths.split(separator: "\n").map { URL(fileURLWithPath: String($0)) })
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ffmpegInstalled = FFmpeg.isInstalled
        }
    }

    // MARK: - Inspector plumbing

    private var inspectorScope: String {
        switch selectedOutputs.count {
        case 0: "Settings for files you add"
        case 1: selectedOutputs[0].file.url.lastPathComponent
        case let n: "Editing \(n) outputs"
        }
    }

    /// Reads the first selected output and writes to every selected one, so editing a
    /// control with six rows selected sets all six. With nothing selected it edits the
    /// preset that newly added outputs will get.
    private var editedPreset: Binding<ConvertPreset> {
        Binding(
            get: { selectedOutputs.first?.output.preset ?? workingPreset },
            set: { updated in
                let fixed = updated.reconciled()
                if selection.isEmpty { workingPreset = fixed } else { apply(fixed) }
            })
    }

    private func apply(_ preset: ConvertPreset) {
        for f in staged.indices {
            for o in staged[f].outputs.indices where selection.contains(staged[f].outputs[o].id) {
                staged[f].outputs[o].preset = preset
                staged[f].outputs[o].measured = nil    // it described the old settings
            }
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
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
            .frame(minWidth: 190)
            .help(selection.isEmpty
                  ? "The preset new files get"
                  : "Apply to the \(selection.count) selected output\(selection.count == 1 ? "" : "s")")
        }
        ToolbarItem {
            Menu("Presets", systemImage: "slider.horizontal.3") {
                Button("Save as Preset…") { beginSavePreset() }
                if let current = presets.custom.first(where: { $0.id == pickedPresetID }) {
                    Button("Update “\(current.name)”") {
                        var updated = editedPreset.wrappedValue
                        updated.id = current.id
                        updated.name = current.name
                        presets.save(updated)
                    }
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
                Text("Drag video or audio files here, or use Add Files. Each file can have more than one output.")
            } actions: {
                Button("Add Files…") { chooseFiles() }
                    .adaptiveGlass(prominent: true)
            }
        } else {
            List(selection: $selection) {
                ForEach($staged) { $file in
                    Section {
                        ForEach($file.outputs) { $output in
                            OutputRow(output: $output,
                                      estimate: estimate(file, output),
                                      onMeasure: { measure(file.id, output.id) },
                                      onRemove: { remove(output.id, from: file.id) })
                            .tag(output.id)
                        }
                    } header: {
                        FileHeader(file: file,
                                   onAdd: { addOutput(to: file.id) },
                                   onRemove: {
                                       withAnimation(settle) { staged.removeAll { $0.id == file.id } }
                                   })
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
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    Button("Remove \(ids.count) Output\(ids.count == 1 ? "" : "s")") { removeSelected(ids) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let overall = queue.overallProgress, queue.activeCount > 0 {
                ProgressView(value: overall)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
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

            if !allOutputs.isEmpty {
                Divider().frame(height: 14)
                let total = totalEstimate
                Text(total.bytes > 0
                     ? "\(total.complete ? "" : "at least ")\(ByteCount.string(total.bytes))"
                     : "size unknown")
                    .monospacedDigit()
                    .help(total.complete
                          ? "Estimated total output size"
                          : "Some outputs use CRF, whose size cannot be known without measuring")
            }

            Spacer()

            if queue.hasFinished {
                Button("Reset") { resetFinished() }
                    .controlSize(.small)
                    .help("Put finished files back in the list so you can change settings and convert again")
                Button("Clear") { queue.clearFinished() }
                    .controlSize(.small)
            }
            Button(convertLabel) { convert() }
                .adaptiveGlass(prominent: true)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canConvert)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.bar))
        .animation(quick, value: canConvert)
    }

    private var convertLabel: String {
        allOutputs.count > 1 ? "Convert \(allOutputs.count) Outputs" : "Convert"
    }

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

    // MARK: - Estimating

    private func estimate(_ file: StagedFile, _ output: StagedOutput) -> Int64? {
        if let measured = output.measured { return measured }
        let job = job(for: file, output)
        return output.preset.estimatedBytes(duration: FFmpeg.effectiveDuration(job),
                                            sourceBytes: file.probe?.bytes,
                                            sourceDuration: file.probe?.duration)
    }

    private func measure(_ fileID: UUID, _ outputID: UUID) {
        guard let f = staged.firstIndex(where: { $0.id == fileID }),
              let o = staged[f].outputs.firstIndex(where: { $0.id == outputID }) else { return }
        staged[f].outputs[o].measuring = true
        let job = job(for: staged[f], staged[f].outputs[o])
        Task {
            let bytes = await FFmpeg.sampleBytes(for: job)
            guard let f = staged.firstIndex(where: { $0.id == fileID }),
                  let o = staged[f].outputs.firstIndex(where: { $0.id == outputID }) else { return }
            staged[f].outputs[o].measuring = false
            staged[f].outputs[o].measured = bytes
        }
    }

    private func job(for file: StagedFile, _ output: StagedOutput) -> ConvertJob {
        var job = ConvertJob(source: file.url, preset: output.preset,
                             sourceDuration: file.probe?.duration, sourceBytes: file.probe?.bytes,
                             destinationDir: convertDir.isEmpty ? nil : convertDir)
        job.trimStart = output.trimStart
        job.trimEnd = output.trimEnd
        return job
    }

    // MARK: - Actions

    private func adopt(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let fresh = urls.map { StagedFile(url: $0, outputs: [StagedOutput(preset: workingPreset)]) }
        withAnimation(settle) { staged += fresh }
        // Duration and dimensions decide every size estimate, so read them right away
        // rather than making the user press Convert to find out what they dropped.
        for file in fresh {
            Task {
                let probe = await FFmpeg.inspect(file.url)
                if let i = staged.firstIndex(where: { $0.id == file.id }) { staged[i].probe = probe }
            }
        }
        return true
    }

    private func addOutput(to fileID: UUID) {
        guard let i = staged.firstIndex(where: { $0.id == fileID }) else { return }
        let output = StagedOutput(preset: workingPreset)
        withAnimation(settle) { staged[i].outputs.append(output) }
        selection = [output.id]
    }

    private func remove(_ outputID: UUID, from fileID: UUID) {
        guard let i = staged.firstIndex(where: { $0.id == fileID }) else { return }
        withAnimation(settle) {
            staged[i].outputs.removeAll { $0.id == outputID }
            // A file with nothing left to produce is just clutter.
            if staged[i].outputs.isEmpty { staged.remove(at: i) }
        }
        selection.remove(outputID)
    }

    private func removeSelected(_ ids: Set<UUID>) {
        withAnimation(settle) {
            for i in staged.indices { staged[i].outputs.removeAll { ids.contains($0.id) } }
            staged.removeAll { $0.outputs.isEmpty }
        }
        selection.subtract(ids)
    }

    private func convert() {
        queue.add(allOutputs.map { job(for: $0.file, $0.output) })
        withAnimation(settle) { staged.removeAll() }
        selection = []
    }

    /// Finished jobs go back to the list with their settings intact, ready to be changed
    /// and run again. Outputs from the same source regroup under one file.
    private func resetFinished() {
        let finished = queue.drainFinished()
        guard !finished.isEmpty else { return }
        withAnimation(settle) {
            for job in finished {
                var output = StagedOutput(preset: job.preset)
                output.trimStart = job.trimStart
                output.trimEnd = job.trimEnd
                if let i = staged.firstIndex(where: { $0.url == job.source }) {
                    staged[i].outputs.append(output)
                } else {
                    staged.append(StagedFile(
                        url: job.source,
                        probe: FFmpeg.MediaProbe(duration: job.sourceDuration,
                                                 bytes: job.sourceBytes ?? 0),
                        outputs: [output]))
                }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent, .movie, .video, .audio]
        guard panel.runModal() == .OK else { return }
        _ = adopt(panel.urls)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { convertDir = url.path }
    }

    private func beginSavePreset() {
        newPresetName = editedPreset.wrappedValue.name + " Copy"
        savingPreset = true
    }

    private func commitPreset() {
        var fresh = editedPreset.wrappedValue
        fresh.id = UUID()
        fresh.name = newPresetName.trimmingCharacters(in: .whitespaces)
        presets.save(fresh)
        pickedPresetID = fresh.id
    }
}

// MARK: - Rows

private struct FileHeader: View {
    let file: StagedFile
    var onAdd: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(file.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .textCase(nil)                       // section headers upper-case by default
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            if !file.caption.isEmpty {
                Text(file.caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Add Output", systemImage: "plus", action: onAdd)
                .help("Convert this file to another format as well")
            Button("Remove File", systemImage: "xmark", action: onRemove)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }
}

private struct OutputRow: View {
    @Binding var output: StagedOutput
    let estimate: Int64?
    var onMeasure: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    /// CRF is the only mode whose size cannot be worked out from the settings, so it is
    /// the only one that gets a Measure button.
    private var needsMeasuring: Bool {
        estimate == nil && output.preset.qualityMode == .crf && !output.preset.isCopyOnly
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(output.preset.name).lineLimit(1)
                Text(output.preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("Trim").font(.caption).foregroundStyle(.secondary)
                    TextField("start", text: $output.trimStart)
                        .frame(width: 64)
                        .onChange(of: output.trimStart) { _, _ in output.measured = nil }
                    Text("to").font(.caption).foregroundStyle(.secondary)
                    TextField("end", text: $output.trimEnd)
                        .frame(width: 64)
                        .onChange(of: output.trimEnd) { _, _ in output.measured = nil }
                    if !output.trimIsValid {
                        Label("Use 1:23", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .monospacedDigit()
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if output.measuring {
                    ProgressView().controlSize(.small)
                } else if let estimate {
                    Text((output.measured != nil ? "≈ " : "") + ByteCount.string(estimate))
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.primary)
                } else if needsMeasuring {
                    Button("Measure", action: onMeasure)
                        .controlSize(.small)
                        .help("Encodes a few seconds and scales it up — CRF size cannot be calculated")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
                if output.measured != nil {
                    Text("sampled").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 88, alignment: .trailing)

            Button("Remove", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 3)
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
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
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
            Button("Show Original") { NSWorkspace.shared.activateFileViewerSelecting([job.source]) }
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
        [job.progress > 0 ? "\(Int(job.progress * 100))%" : "", job.outputSize, job.speed]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    private var status: String {
        switch job.state {
        case .done:
            [fileURL?.lastPathComponent, job.outputSize.isEmpty ? nil : job.outputSize]
                .compactMap { $0 }.joined(separator: "  ·  ")
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
                Button("Try Again", systemImage: "arrow.clockwise") { queue.retry(job.id) }
            case .done:
                Button("Convert Again", systemImage: "arrow.clockwise") { queue.retry(job.id) }
                    .help("Run this again with the same settings")
                Button("Show in Finder", systemImage: "folder") { reveal() }
            }
            Button("Remove", systemImage: "trash") { queue.remove(job.id) }
        }
        .labelStyle(.iconOnly)
        .adaptiveGlass()
        .controlSize(.small)
        .frame(width: 92, alignment: .trailing)
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
    let scope: String
    @FocusState private var editingFlags: Bool

    private static let heights = [(0, "Keep original"), (2160, "2160p"), (1440, "1440p"),
                                  (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p")]
    private static let rates: [(Double, String)] = [(0, "Keep original"), (60, "60"), (30, "30"),
                                                    (25, "25"), (24, "24"), (15, "15")]

    var body: some View {
        Form {
            Section {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                        Picker("Bitrate", selection: $preset.audioKbps) {
                            ForEach([320, 256, 192, 160, 128, 96], id: \.self) {
                                Text("\($0) kbps").tag($0)
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
        let modes = preset.availableQualityModes
        if !modes.isEmpty {
            Picker("Set by", selection: $preset.qualityMode) {
                ForEach(modes) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch preset.qualityMode {
            case .targetSize:
                LabeledContent("Target") {
                    HStack(spacing: 4) {
                        TextField("Target", value: $preset.targetSizeMB,
                                  format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .frame(width: 58)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Text("MB")
                    }
                }
                Text("The bitrate is worked out per file from its length, and peaks are capped so a busy scene can't overshoot.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .bitrate:
                LabeledContent("Video") {
                    HStack(spacing: 4) {
                        TextField("Video bitrate", value: $preset.videoKbps, format: .number)
                            .labelsHidden()
                            .frame(width: 66)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Text("kbps")
                    }
                }
                Picker("Common", selection: $preset.videoKbps) {
                    ForEach([20000, 12000, 8000, 5000, 3000, 1500, 800], id: \.self) {
                        Text(ConvertPreset.rateLabel($0)).tag($0)
                    }
                }

            case .crf:
                // Lower is better is the opposite of every other quality slider people
                // meet, so the number and its direction are both spelled out.
                let range = Encoders.video(preset.videoCodec)?.crfRange ?? 0...51
                LabeledContent("Quality") { Text("CRF \(preset.crf)").monospacedDigit() }
                Slider(value: Binding(get: { Double(preset.crf) },
                                      set: { preset.crf = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Best").font(.caption2)
                } maximumValueLabel: {
                    Text("Smallest").font(.caption2)
                }
                Text("Constant quality: every file looks the same, but the size depends on the footage. Press Measure on a row for a real figure.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if preset.includeVideo, Encoders.video(preset.videoCodec)?.quality == .prores {
            Picker("Profile", selection: $preset.proresProfile) {
                ForEach(Encoders.proresProfiles, id: \.0) { Text($0.1).tag($0.0) }
            }
        }
    }
}
