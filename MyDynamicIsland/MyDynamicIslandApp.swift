import SwiftUI

@main
struct MyDynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: DynamicIsland?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply "Hide from Dock" setting
        let hideFromDock = UserDefaults.standard.bool(forKey: "hideFromDock")
        if hideFromDock {
            NSApp.setActivationPolicy(.accessory)
        }

        island = DynamicIsland()
    }
}
