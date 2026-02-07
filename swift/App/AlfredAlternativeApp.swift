import AppKit
import SwiftUI

final class AlfredAlternativeAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: LauncherViewModel?
    private var hotKeyMonitor: GlobalHotKeyMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = GlobalHotKeyMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.viewModel?.toggleLauncherVisibilityFromHotKey()
            }
        }
        if !monitor.registerCommandSpace() {
            NSLog("Failed to register global hotkey Command+Space.")
        }
        hotKeyMonitor = monitor
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        viewModel?.revealLauncherIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        viewModel?.revealLauncherIfNeeded()
    }

    func applicationDidResignActive(_ notification: Notification) {
        viewModel?.dismissLauncher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyMonitor?.unregister()
        hotKeyMonitor = nil
    }
}

@main
struct AlfredAlternativeApp: App {
    @NSApplicationDelegateAdaptor(AlfredAlternativeAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = LauncherViewModel()

    var body: some Scene {
        Window("Launcher", id: "launcher") {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 220)

        Window("Editor", id: "editor") {
            EditorWindowView()
                .environmentObject(viewModel)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 980, height: 720)
    }
}
