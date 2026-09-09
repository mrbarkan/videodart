import SwiftUI
import Sparkle

/// Sparkle's updater, plus the one piece of state a menu item needs: whether a check is
/// possible right now. ponytail: one small observable instead of Sparkle's sample
/// view-model and view pair.
@MainActor @Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    var canCheck = false

    init() {
        // startingUpdater: true schedules the background check the feed's interval asks
        // for; the menu item is only the manual path.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        // The change payload rather than the updater itself: reading the property back
        // off the main actor is exactly what Swift 6 rejects here.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

@main
struct VideoDartApp: App {
    @State private var queue = DownloadQueue()
    // Owned by the app, not by ConvertView: a Window scene tears its view down when the
    // window closes, which would orphan a running ffmpeg and leak its power assertion.
    @State private var converter = ConvertQueue()
    @State private var presets = PresetStore()
    @State private var updater = Updater()
    @Environment(\.openWindow) private var openWindow

    init() {
        Prefs.register()
        DownloadQueue.requestNotificationPermission()
        #if DEBUG
        SelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(queue)
        }
        .defaultSize(width: 860, height: 580)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            CommandGroup(replacing: .newItem) {
                Button("Convert Files…") { openWindow(id: Self.convertWindowID) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Downloads") {
                Button("Pause All") { queue.pauseAll() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Resume All") { queue.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.hasFinished)
            }
        }

        // A separate window rather than a tab: converting a folder of clips and watching
        // a playlist download are two jobs people run at the same time, and each keeps
        // its own queue alive whether or not the other is on screen.
        Window("Convert", id: Self.convertWindowID) {
            ConvertView()
                .environment(converter)
                .environment(presets)
        }
        .defaultSize(width: 900, height: 560)

        Settings { SettingsView() }
    }

    private static let convertWindowID = "convert"
}
