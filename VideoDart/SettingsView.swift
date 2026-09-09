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

    @State private var version = "…"
    @State private var archiveCount = 0

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
                TextField("Filename", text: $filenameTemplate)
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
                                NSWorkspace.shared.activateFileViewerSelecting([YTDLP.archiveURL])
                            }
                            Button("Forget All") {
                                try? FileManager.default.removeItem(at: YTDLP.archiveURL)
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
    }

    private static func countArchive() -> Int {
        guard let text = try? String(contentsOf: YTDLP.archiveURL, encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).count
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
                    TextField("Profile", text: $cookieProfile, prompt: Text("Default"))
                        .help("Browser profile name or path, e.g. \"Profile 1\"")
                }
            } footer: {
                Text(accountHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var accountHelp: String {
        switch cookieSource {
        case "none":
            "Age-restricted and members-only videos need a signed-in session. Pick the browser you are already logged into YouTube with."
        case "safari":
            "Safari cookies are readable only if this app has Full Disk Access (System Settings ▸ Privacy & Security ▸ Full Disk Access). Quit the browser first."
        case "file":
            "Export cookies.txt from a browser extension while signed in to YouTube."
        default:
            "Quit \(cookieSource.capitalized) before downloading — it locks its cookie database while running. macOS may ask for Keychain access the first time."
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
                Text("Update with `brew upgrade yt-dlp`. ffmpeg is required for merging, audio extraction and embedding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
