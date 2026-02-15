import AppKit
import SwiftUI

final class AlfredAlternativeAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: LauncherViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyManager.shared.setHandler { [weak self] in
            DispatchQueue.main.async {
                self?.viewModel?.toggleLauncherVisibilityFromHotKey()
            }
        }
        if !HotKeyManager.shared.register() {
            NSLog("Failed to register global hotkey.")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if viewModel?.isSettingsPresented == true {
            viewModel?.revealSettingsIfNeeded()
            return true
        }
        if viewModel?.isEditorPresented == true {
            viewModel?.revealEditorIfNeeded()
            return true
        }
        viewModel?.revealLauncherIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if viewModel?.isSettingsPresented == true {
            viewModel?.revealSettingsIfNeeded()
            return
        }
        if viewModel?.isEditorPresented == true {
            viewModel?.revealEditorIfNeeded()
            return
        }

        if NSApp.windows.contains(where: { $0.title == "Settings" && $0.isVisible }) {
            return
        }
        viewModel?.revealLauncherIfNeeded()
    }

    func applicationDidResignActive(_ notification: Notification) {
        viewModel?.dismissLauncher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
    }
}

@main
struct AlfredAlternativeApp: App {
    @NSApplicationDelegateAdaptor(AlfredAlternativeAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = LauncherViewModel()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var autoUpdater = AutoUpdater.shared
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Launcher", id: "launcher") {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(updateChecker)
                .environmentObject(autoUpdater)
                .environmentObject(themeManager)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    updateChecker.checkOncePerSession()
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    viewModel.prepareSettings()
                    openWindow(id: "settings")
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
                .environmentObject(autoUpdater)
                .environmentObject(themeManager)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 980, height: 720)
        
        Window("Settings", id: "settings") {
            SettingsWindowView()
                .environmentObject(viewModel)
                .environmentObject(updateChecker)
                .environmentObject(autoUpdater)
                .environmentObject(themeManager)
        }
        .defaultSize(width: 800, height: 550)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}
