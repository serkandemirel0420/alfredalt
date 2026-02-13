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
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        Window("Launcher", id: "launcher") {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(updateChecker)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    updateChecker.checkOncePerSession()
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    viewModel.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 220)

        Window("Editor", id: "editor") {
            EditorWindowView()
                .environmentObject(viewModel)
                .environmentObject(updateChecker)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 980, height: 720)
    }
}
