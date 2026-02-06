import SwiftUI

@main
struct AlfredAlternativeApp: App {
    @StateObject private var viewModel = LauncherViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
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
