import SwiftUI
import AppKit

struct AddSheet: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    let url: String

    @State private var info: MediaInfo?
    @State private var failure: String?
    @State private var selected: Set<String> = []

    @State private var choice: AddChoice = .videoAudio
    @State private var quality = "best"
    @State private var videoContainer = "mp4"
    @State private var audioFormat = "m4a"
    @State private var subs: SubsOption = .off
    @State private var subLangs = "en"
    @State private var destination = Prefs.string(Prefs.Key.downloadDir)
    @AppStorage(Prefs.Key.cookieSource) private var cookieSource = "none"
    @State private var alreadyQueued = false

    private static let qualities = ["best", "2160", "1440", "1080", "720", "480", "360"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let info {
                content(info)
            } else if let failure {
                errorView(failure)
            } else {
                ProgressView("Reading link…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: 320, maxHeight: (info?.isPlaylist ?? false) ? 620 : 520)
        .task { await probe() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            AsyncImage(url: info?.entries.first?.thumbnail.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 104, height: 59)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(info?.title ?? (failure == nil ? "Loading…" : "Couldn’t read this link"))
                    .font(.headline)
                    .lineLimit(2)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var caption: String {
        guard let info else { return url }
        if info.isPlaylist { return "Playlist · \(info.entries.count) videos" }
        let e = info.entries.first
        return [e?.uploader ?? "", e?.duration?.asDuration ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ info: MediaInfo) -> some View {
        if info.isPlaylist {
            ScrollView {
                VStack(spacing: 0) {
                    playlistPicker(info)
                    options
                }
            }
        } else {
            // Hugging the content instead of filling a fixed height is what removes the
            // band of dead space above the buttons.
            options.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func playlistPicker(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Videos").font(.subheadline.weight(.semibold))
                Spacer()
                Button(selected.count == info.entries.count ? "Deselect All" : "Select All") {
                    selected = selected.count == info.entries.count ? [] : Set(info.entries.map(\.id))
                }
                .buttonStyle(.link)
            }
            ForEach(info.entries) { entry in
                Toggle(isOn: Binding(
                    get: { selected.contains(entry.id) },
                    set: { on in if on { selected.insert(entry.id) } else { selected.remove(entry.id) } }
                )) {
                    HStack {
                        Text(entry.title).lineLimit(1)
                        Spacer()
                        if let d = entry.duration {
                            Text(d.asDuration).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: 240)
    }

    private var options: some View {
        Form {
            Section {
                Picker("Download", selection: $choice) {
                    ForEach(AddChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if choice != .audio {
                    Picker("Quality", selection: $quality) {
                        ForEach(Self.qualities, id: \.self) {
                            Text($0 == "best" ? "Best available" : "\($0)p").tag($0)
                        }
                    }
                    Picker("Video format", selection: $videoContainer) {
                        Text("MP4").tag("mp4")
                        Text("MKV").tag("mkv")
                        Text("Keep original").tag("original")
                    }
                }
                if choice == .audio || choice == .both {
                    Picker("Audio format", selection: $audioFormat) {
                        Text("M4A").tag("m4a")
                        Text("MP3").tag("mp3")
                        Text("Opus").tag("opus")
                        Text("FLAC").tag("flac")
                        Text("Keep original").tag("original")
                    }
                }

                if choice != .audio {
                    Picker("Subtitles", selection: $subs) {
                        ForEach(SubsOption.allCases) { Text($0.label).tag($0) }
                    }
                    if subs != .off {
                        TextField("Languages", text: $subLangs)
                            .help("Comma separated, e.g. en,es — or \"all\"")
                    }
                }
            }

            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(URL(fileURLWithPath: destination).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…", action: chooseDestination)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        let needsSignIn = YTDLP.isAuthError(message)
        VStack(spacing: 12) {
            Image(systemName: needsSignIn ? "person.badge.key" : "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(needsSignIn ? "Sign-In Required" : "Could Not Read That Link")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if needsSignIn {
                Picker("Use cookies from", selection: $cookieSource) {
                    Text("None").tag("none")
                    Divider()
                    ForEach(Prefs.browsers, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .frame(width: 280)
                .padding(.top, 4)

                Text(cookieSource == "none"
                     ? "Pick the browser you are signed into that site with."
                     : "Quit \(cookieSource.capitalized) first — it locks its cookie database while running.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack {
                if needsSignIn { SettingsLink { Text("More Options…") } }
                Button("Try Again") { Task { await probe() } }
                    .adaptiveGlass(prominent: true)
                    .disabled(needsSignIn && cookieSource == "none")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            if alreadyQueued {
                Label("Already in the queue", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(addLabel) { addToQueue() }
                .adaptiveGlass(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil || selected.isEmpty)
        }
        .padding(14)
    }

    private var addLabel: String {
        let n = selected.count * choice.kinds.count
        return n > 1 ? "Add \(n) Downloads" : "Add Download"
    }

    // MARK: - Actions

    private func probe() async {
        info = nil
        failure = nil
        subLangs = Prefs.string(Prefs.Key.subLangs)
        do {
            let result = try await YTDLP.probe(url)
            info = result
            selected = Set(result.entries.map(\.id))
        } catch {
            failure = error.localizedDescription
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: destination)
        if panel.runModal() == .OK, let picked = panel.url { destination = picked.path }
    }

    private func addToQueue() {
        guard let info else { return }
        let picked = info.entries.filter { selected.contains($0.id) }
        var new: [DownloadJob] = []
        for entry in picked {
            for kind in choice.kinds {
                new.append(DownloadJob(
                    url: entry.url,
                    title: entry.title,
                    uploader: entry.uploader,
                    thumbnail: entry.thumbnail,
                    duration: entry.duration,
                    kind: kind,
                    quality: quality,
                    container: kind == .audio ? audioFormat : videoContainer,
                    subs: kind == .audio ? .off : subs,
                    subLangs: subLangs,
                    destination: destination
                ))
            }
        }
        let skipped = queue.add(new)
        guard skipped < new.count else { alreadyQueued = true; return }
        dismiss()
    }
}
