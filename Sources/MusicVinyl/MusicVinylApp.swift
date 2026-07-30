import AppKit
import SwiftUI

/// The window has no visible close button, so ⌘W would otherwise leave the app
/// running with nothing on screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MusicVinylApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = NowPlayingModel()

    init() {
        PreviewRender.runIfRequested()
    }

    var body: some Scene {
        Window("Music Vinyl", id: "vinyl") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 220, minHeight: 220)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 360, height: 410)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                Button("Play / Pause") { model.playPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next Track") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Toggle("Always on Top", isOn: $model.alwaysOnTop)
                Toggle("Show Track Info", isOn: $model.showTrackInfo)
                Toggle("Look Up Artwork Online", isOn: $model.onlineArtwork)
            }
        }
    }
}
