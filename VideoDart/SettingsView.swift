import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage(Prefs.Key.downloadDir) private var downloadDir = ""
    @AppStorage(Prefs.Key.filenameTemplate) private var filenameTemplate = ""
    @AppStorage(Prefs.Key.maxConcurrent) private var maxConcurrent = 2
    @AppStorage(Prefs.Key.embedMetadata) private var embedMetadata = true
    @AppStorage(Prefs.Key.embedThumbnail) private var embedThumbnail = true
    @AppStorage(Prefs.Key.cookieSource) private var cookieSource = "none"
    @AppStorage(Prefs.Key.cookieProfile) private var cookieProfile = ""
    @AppStorage(Prefs.Key.cookieFile) private var cookieFile = ""
    @AppStorage(Prefs.Key.ytdlpPath) private var ytdlpPath = ""
    @AppStorage(Prefs.Key.subLangs) private var subLangs = "en"
    @AppStorage(Prefs.Key.rateLimit) private var rateLimit = ""
    @AppStorage(Prefs.Key.useArchive) private var useArchive = false
    @AppStorage(Prefs.Key.watchClipboard) private var watchClipboard = true
    @AppStorage(Prefs.Key.betaUpdates) private var betaUpdates = false

    @State private var version = "…"
    // The first text field took focus on open, so Filename sat selected and one stray
    // keystroke replaced the template.
    @FocusState private var focused: Bool
    @State private var archiveCount = 0
    @State private var cookiesBlocked = false
    @State private var browserProfiles: [YTDLP.BrowserProfile] = []

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            account.tabItem { Label("Account", systemImage: "person.badge.key") }
            advanced.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 400)
        .task {
            version = await YTDLP.version()
            archiveCount = Self.countArchive()
        }
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(downloadDir).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { pickFolder() }
                    }
                }
                TextField("Filename", text: $filenameTemplate, prompt: Text(YTDLP.defaultFilenameTemplate))
                    .focused($focused)
                    .help("yt-dlp output template, e.g. %(title)s [%(id)s].%(ext)s")
                Stepper("Simultaneous downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...6)
            }
            Section("Extras") {
                Toggle("Embed title, artist and date", isOn: $embedMetadata)
                Toggle("Embed thumbnail as cover art", isOn: $embedThumbnail)
                TextField("Default subtitle languages", text: $subLangs)
            }
            Section {
                Toggle("Fill the link field from the clipboard", isOn: $watchClipboard)
            } footer: {
                Text("When the app becomes active and you have copied a link, it lands in the field ready to go. Nothing downloads until you press Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Skip videos already downloaded", isOn: $useArchive)
                if useArchive {
                    LabeledContent("Remembered") {
                        HStack {
                            Text("\(archiveCount) video\(archiveCount == 1 ? "" : "s")")
                            Button("Show File") {
                                NSWorkspace.shared.activateFileViewerSelecting(Self.archives.filter {
                                    FileManager.default.fileExists(atPath: $0.path)
                                })
                            }
                            Button("Forget All") {
                                for url in Self.archives { try? FileManager.default.removeItem(at: url) }
                                archiveCount = 0
                            }
                            .disabled(archiveCount == 0)
                        }
                    }
                }
            } footer: {
                Text("Re-adding a playlist or channel then downloads only what is new. Deleting a file from disk does not un-remember it — use Forget All for that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { focused = false }
    }

    /// Audio downloads keep their own record, so "Both, split" can fetch both halves.
    private static let archives = [YTDLP.archiveURL, YTDLP.audioArchiveURL]

    private static func countArchive() -> Int {
        Set(archives.flatMap { url in
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
        }).count
    }

    private var account: some View {
        Form {
            Section {
                Picker("Sign-in cookies", selection: $cookieSource) {
                    Text("None").tag("none")
                    Divider()
                    ForEach(Prefs.browsers, id: \.self) { Text($0.capitalized).tag($0) }
                    Divider()
                    Text("cookies.txt file").tag("file")
                }
                if cookieSource == "file" {
                    LabeledContent("File") {
                        HStack {
                            Text(cookieFile.isEmpty ? "None selected" : cookieFile)
                                .lineLimit(1).truncationMode(.head)
                            Button("Choose…") { pickCookieFile() }
                        }
                    }
                } else if cookieSource != "none" {
                    if browserProfiles.isEmpty {
                        // Firefox, Safari, or a browser whose list can't be read: by hand.
                        TextField("Profile", text: $cookieProfile, prompt: Text("Whichever changed last"))
                            .help("Browser profile folder or path, e.g. \"Profile 1\"")
                    } else {
                        // Names and emails, not "Profile 7": the folder name is what
                        // yt-dlp wants and the one thing nobody knows.
                        Picker("Profile", selection: $cookieProfile) {
                            Text("Whichever changed last").tag("")
                            Divider()
                            ForEach(browserProfiles, id: \.folder) { Text($0.label).tag($0.folder) }
                            if !cookieProfile.isEmpty, !browserProfiles.contains(where: { $0.folder == cookieProfile }) {
                                Text(cookieProfile).tag(cookieProfile)
                            }
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // Said here, before a download fails with the browser's cookies "missing".
                    if cookiesBlocked {
                        Text("macOS isn’t letting VideoDart read \(cookieSource.capitalized)’s cookies. Turn VideoDart on under Full Disk Access.")
                            .foregroundStyle(.orange)
                        Button("Open Privacy Settings…") { NSWorkspace.shared.open(YTDLP.fullDiskAccessSettings) }
                            .controlSize(.small)
                    }
                    Text(accountHelp)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Re-read on every visit too: the grant happens in System Settings, meanwhile.
        .task(id: cookieSource) { readBrowser() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readBrowser()
        }
    }

    private func readBrowser() {
        cookiesBlocked = YTDLP.isCookieFolderBlocked(cookieSource)
        browserProfiles = cookiesBlocked ? [] : YTDLP.profiles(for: cookieSource)
    }

    private var accountHelp: String {
        switch cookieSource {
        case "none":
            "Age-restricted and members-only videos need a signed-in session. Pick the browser you are already logged into YouTube with."
        case "safari":
            "Safari cookies are readable only if this app has Full Disk Access (System Settings ▸ Privacy & Security ▸ Full Disk Access)."
        case "file":
            "Export cookies.txt from a browser extension while signed in to YouTube."
        default:
            "Pick the \(cookieSource.capitalized) profile you're signed in with — left on “Whichever changed last”, a profile that isn't signed in can be used. macOS may ask for Keychain access the first time."
        }
    }

    private var advanced: some View {
        Form {
            Section {
                LabeledContent("yt-dlp") {
                    HStack {
                        Text(YTDLP.executablePath).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { pickBinary() }
                        if !ytdlpPath.isEmpty { Button("Reset") { ytdlpPath = "" } }
                    }
                }
                LabeledContent("Version", value: version)
                TextField("Speed limit", text: $rateLimit, prompt: Text("Unlimited"))
                    .help("e.g. 2M or 500K")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // Unreadable limits are dropped rather than passed on, which failed
                    // every job — so say so, or "2 MB/s" would look applied.
                    if !rateLimit.trimmingCharacters(in: .whitespaces).isEmpty, YTDLP.rateLimit(rateLimit) == nil {
                        Text("Speed limit not understood — use a number with K, M or G, like 500K or 2M. Downloads run unlimited until then.")
                            .foregroundStyle(.orange)
                    }
                    Text(LocalizedStringKey(updateHint + " ffmpeg is required for merging, audio extraction and embedding."))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Get beta versions", isOn: $betaUpdates)
            } footer: {
                Text("Betas arrive sooner and may have rough edges. Turning this off doesn’t move you back to an older version — you stay on the one you have until a newer stable release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// The command that updates the copy in use; `brew upgrade` was named for every copy.
    private var updateHint: String {
        guard let command = YTDLP.updateCommand else {
            return "VideoDart updates its own copy from the banner when a new release is out."
        }
        return "Update with `\(command)`."
    }

    // MARK: - Panels

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadDir)
        if panel.runModal() == .OK, let url = panel.url { downloadDir = url.path }
    }

    private func pickCookieFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { cookieFile = url.path }
    }

    private func pickBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { ytdlpPath = url.path }
    }
}
