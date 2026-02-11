import AppKit
import SwiftUI

private let launcherWindowWidth: CGFloat = 1040
private let launcherEmptyHeight: CGFloat = 96
private let launcherResultRowHeight: CGFloat = 60
private let launcherMaxVisibleRows: CGFloat = 5
private let launcherShellCornerRadius: CGFloat = 24
private let launcherSearchFieldCornerRadius: CGFloat = 12
private let launcherShellPadding: CGFloat = 14
private let launcherResultsCornerRadius: CGFloat = launcherShellCornerRadius - launcherShellPadding
private let keyHandlingModifierMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
private let actionMenuRowHeight: CGFloat = 44

private struct LauncherShellHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = launcherEmptyHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum ItemAction: Int, CaseIterable {
    case openEditor
    case showJsonInFinder
    case copyTitle
    case delete

    var label: String {
        switch self {
        case .openEditor: return "Open in Editor"
        case .showJsonInFinder: return "Show JSON in Finder"
        case .copyTitle: return "Copy Title"
        case .delete: return "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .openEditor: return "doc.text"
        case .showJsonInFinder: return "folder"
        case .copyTitle: return "doc.on.doc"
        case .delete: return "trash"
        }
    }

    var isDestructive: Bool {
        self == .delete
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: LauncherViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedIndex = 0
    @State private var measuredShellHeight: CGFloat = launcherEmptyHeight
    @State private var resultsScrollProxy: ScrollViewProxy?
    @State private var actionMenuTarget: SearchResultRecord?
    @State private var actionMenuSelectedIndex = 0
    @State private var actionMenuFilter = ""

    private var filteredActions: [ItemAction] {
        let filter = actionMenuFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !filter.isEmpty else {
            return ItemAction.allCases
        }
        return ItemAction.allCases.filter { $0.label.lowercased().contains(filter) }
    }

    private var resultsViewportHeight: CGFloat {
        launcherResultRowHeight * launcherMaxVisibleRows
    }

    var body: some View {
        launcherShell(width: launcherWindowWidth)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LauncherShellHeightPreferenceKey.self,
                        value: ceil(proxy.size.height)
                    )
                }
            )
            .frame(width: launcherWindowWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.clear)
        .background(
            WindowConfigurator(
                desiredSize: NSSize(width: launcherWindowWidth, height: measuredShellHeight)
            ) { window in
                viewModel.registerLauncherWindow(window)
            }
        )
        .background(
            KeyEventMonitor(onKeyDown: { event in
                return handleLauncherKeyEvent(event)
            }, onCmdTap: {
                handleCmdTap()
            })
        )
        .onPreferenceChange(LauncherShellHeightPreferenceKey.self) { value in
            if abs(measuredShellHeight - value) > 0.5 {
                measuredShellHeight = value
            }
        }
        .onAppear {
            searchFieldFocused = true
        }
        .onChange(of: viewModel.query) { _, _ in
            if actionMenuTarget == nil {
                if selectedIndex != 0 {
                    selectedIndex = 0
                }
            }
        }
        .onChange(of: actionMenuFilter) { _, _ in
            actionMenuSelectedIndex = 0
        }
        .onChange(of: viewModel.results) { _, _ in
            if viewModel.results.isEmpty {
                selectedIndex = 0
            } else if selectedIndex >= viewModel.results.count {
                selectedIndex = max(0, viewModel.results.count - 1)
            }

            if selectedIndex > 0, let proxy = resultsScrollProxy {
                scrollSelectionIntoView(using: proxy, animated: false)
            }
        }
        .onChange(of: selectedIndex) { oldValue, newValue in
            guard oldValue != newValue, let proxy = resultsScrollProxy else {
                return
            }
            scrollSelectionIntoView(using: proxy, animated: false)
        }
        .onChange(of: viewModel.launcherFocusRequestID) { _, _ in
            searchFieldFocused = true
        }
        .task {
            await viewModel.initialLoad()
        }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsSheet(viewModel: viewModel)
                .environmentObject(themeManager)
        }
    }
    
    private var searchFieldBinding: Binding<String> {
        Binding(
            get: { actionMenuTarget != nil ? actionMenuFilter : viewModel.query },
            set: { newValue in
                if actionMenuTarget != nil {
                    actionMenuFilter = newValue
                } else {
                    viewModel.query = newValue
                }
            }
        )
    }
    
    private var searchFieldPlaceholder: String {
        actionMenuTarget != nil ? "Filter actions..." : "Type to search..."
    }
    
    private func searchFieldView() -> some View {
        let colors = themeManager.colors
        return HStack {
            TextField(searchFieldPlaceholder, text: searchFieldBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(colors.itemTitleText)
                .focused($searchFieldFocused)
                .onSubmit(handleSearchSubmit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colors.searchFieldBackground)
        .overlay(
            RoundedRectangle(cornerRadius: launcherSearchFieldCornerRadius, style: .continuous)
                .stroke(colors.searchFieldBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: launcherSearchFieldCornerRadius, style: .continuous))
    }
    
    private func handleSearchSubmit() {
        if let target = actionMenuTarget {
            let actions = filteredActions
            if actions.indices.contains(actionMenuSelectedIndex) {
                executeAction(actions[actionMenuSelectedIndex], on: target)
            }
        } else {
            activateCurrentSelection()
        }
    }
    
    @ViewBuilder
    private func resultsContentView(showResults: Bool) -> some View {
        if let target = actionMenuTarget {
            actionMenuView(for: target)
        } else if showResults {
            ResultsListView(
                results: viewModel.results,
                selectedIndex: $selectedIndex,
                resultsScrollProxy: $resultsScrollProxy,
                onActivate: { idx in
                    activateResult(at: idx)
                },
                onScrollProxySet: { proxy in
                    resultsScrollProxy = proxy
                },
                onScrollSelection: { proxy, animated in
                    scrollSelectionIntoView(using: proxy, animated: animated)
                }
            )
        }
    }

    private func launcherShell(width: CGFloat) -> some View {
        let colors = themeManager.colors
        let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let showResults = !trimmedQuery.isEmpty
        let hasContent = showResults || actionMenuTarget != nil
        
        return VStack(alignment: .leading, spacing: 0) {
            searchFieldView()
            
            if let errorMessage = viewModel.errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundStyle(colors.errorColor)
                    .font(.system(size: 13))
                    .padding(.top, 6)
            }
            
            resultsContentView(showResults: showResults)
                .padding(.top, hasContent ? 8 : 0)
                .frame(
                    maxWidth: .infinity,
                    minHeight: hasContent ? resultsViewportHeight : 0,
                    maxHeight: hasContent ? resultsViewportHeight : 0,
                    alignment: .top
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: launcherResultsCornerRadius, style: .continuous))
        }
        .padding(launcherShellPadding)
        .frame(width: width)
        .background(colors.launcherBackground)
        .overlay(WindowDragHandle(inset: launcherShellPadding))
        .overlay(
            RoundedRectangle(cornerRadius: launcherShellCornerRadius, style: .continuous)
                .stroke(colors.launcherBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: launcherShellCornerRadius, style: .continuous))
    }

    private func activateCurrentSelection() {
        activateResult(at: selectedIndex)
    }

    private func activateResult(at index: Int) {
        Task {
            let openedEditor = await viewModel.activate(selectedIndex: index)
            if openedEditor {
                viewModel.beginEditorPresentation()
                openWindow(id: "editor")
            }
        }
    }

    private func scrollSelectionIntoView(using proxy: ScrollViewProxy, animated: Bool) {
        guard viewModel.results.indices.contains(selectedIndex) else {
            return
        }

        let targetID = viewModel.results[selectedIndex].id
        let scrollAction = {
            proxy.scrollTo(targetID)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.14)) {
                scrollAction()
            }
        } else {
            scrollAction()
        }
    }

    private func handleCmdTap() {
        if actionMenuTarget != nil {
            dismissActionMenu()
            return
        }

        guard viewModel.results.indices.contains(selectedIndex) else {
            return
        }

        actionMenuTarget = viewModel.results[selectedIndex]
        actionMenuSelectedIndex = 0
        actionMenuFilter = ""
        searchFieldFocused = true
    }

    private func dismissActionMenu() {
        actionMenuTarget = nil
        actionMenuSelectedIndex = 0
        actionMenuFilter = ""
        searchFieldFocused = true
    }

    private func actionMenuView(for target: SearchResultRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(themeManager.colors.itemSubtitleText)
                Text(target.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeManager.colors.actionMenuHeaderText)
                    .lineLimit(1)
                Spacer()
                Text("⌘ to go back")
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.colors.placeholderText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(themeManager.colors.actionMenuHeaderBackground)

            Divider()

            let actions = filteredActions
            if actions.isEmpty {
                Text("No matching actions")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(themeManager.colors.placeholderText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(actions.enumerated()), id: \.element.rawValue) { idx, action in
                    let isSelected = idx == actionMenuSelectedIndex
                    Button {
                        executeAction(action, on: target)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 15))
                                .frame(width: 22)
                                .foregroundStyle(action.isDestructive ? themeManager.colors.destructiveAction : themeManager.colors.itemSubtitleText)
                            Text(action.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(action.isDestructive ? themeManager.colors.destructiveAction : themeManager.colors.itemTitleText)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? themeManager.colors.selectedItemBackground : themeManager.colors.itemBackground)
                    }
                    .buttonStyle(.plain)

                    if idx + 1 < actions.count {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private func executeAction(_ action: ItemAction, on target: SearchResultRecord) {
        actionMenuTarget = nil
        actionMenuSelectedIndex = 0
        actionMenuFilter = ""
        searchFieldFocused = true

        switch action {
        case .openEditor:
            if let idx = viewModel.results.firstIndex(where: { $0.id == target.id }) {
                selectedIndex = idx
                activateResult(at: idx)
            }
        case .showJsonInFinder:
            viewModel.revealItemJsonInFinder(itemId: target.id)
        case .copyTitle:
            viewModel.copyItemTitle(target.title)
        case .delete:
            Task {
                await viewModel.deleteItem(itemId: target.id)
            }
        }
    }

    private func handleLauncherKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(keyHandlingModifierMask)

        // Handle action menu key events
        if actionMenuTarget != nil {
            if !modifiers.isEmpty {
                return false
            }
            switch event.keyCode {
            case 126: // up
                if actionMenuSelectedIndex > 0 {
                    actionMenuSelectedIndex -= 1
                }
                return true
            case 125: // down
                let actions = filteredActions
                if actionMenuSelectedIndex + 1 < actions.count {
                    actionMenuSelectedIndex += 1
                }
                return true
            case 36, 76: // return / enter
                if let target = actionMenuTarget {
                    let actions = filteredActions
                    if actions.indices.contains(actionMenuSelectedIndex) {
                        executeAction(actions[actionMenuSelectedIndex], on: target)
                    }
                }
                return true
            case 53: // escape
                dismissActionMenu()
                return true
            default:
                return false
            }
        }

        if !modifiers.isEmpty {
            return false
        }

        switch event.keyCode {
        case 126: // up
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            searchFieldFocused = true
            return true
        case 125: // down
            if selectedIndex + 1 < viewModel.results.count {
                selectedIndex += 1
            }
            searchFieldFocused = true
            return true
        case 36, 76: // return / enter
            activateCurrentSelection()
            return true
        case 53: // escape
            viewModel.dismissLauncher()
            return true
        default:
            return false
        }
    }
}

struct EditorWindowView: View {
    @EnvironmentObject private var viewModel: LauncherViewModel
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        Group {
            if viewModel.selectedItem == nil {
                VStack(spacing: 10) {
                    Text("No item selected")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Select a result in the launcher and press Enter.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EditorSheet(viewModel: viewModel)
            }
        }
        .background(themeManager.colors.editorBackground)
        .background(
            WindowAccessor { window in
                viewModel.registerEditorWindow(window)
            }
        )
        .onAppear {
            viewModel.beginEditorPresentation()
        }
        .onDisappear {
            viewModel.editorDidClose()
        }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsSheet(viewModel: viewModel)
                .environmentObject(themeManager)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)

        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    let inset: CGFloat

    final class DraggableNSView: NSView {
        var inset: CGFloat = 0
        private var initialMouseLocation: NSPoint?
        private var initialWindowOrigin: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? {
            let innerRect = bounds.insetBy(dx: inset, dy: inset)
            if innerRect.contains(point) {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            initialMouseLocation = NSEvent.mouseLocation
            initialWindowOrigin = window?.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let initialMouseLocation, let initialWindowOrigin, let window else { return }
            let currentLocation = NSEvent.mouseLocation
            let dx = currentLocation.x - initialMouseLocation.x
            let dy = currentLocation.y - initialMouseLocation.y
            window.setFrameOrigin(NSPoint(
                x: initialWindowOrigin.x + dx,
                y: initialWindowOrigin.y + dy
            ))
        }

        override func mouseUp(with event: NSEvent) {
            initialMouseLocation = nil
            initialWindowOrigin = nil
        }
    }

    func makeNSView(context: Context) -> DraggableNSView {
        let view = DraggableNSView(frame: .zero)
        view.inset = inset
        return view
    }

    func updateNSView(_ nsView: DraggableNSView, context: Context) {
        nsView.inset = inset
    }
}

private struct SettingsSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFieldFocused: Bool
    @State private var selectedTab: SettingsTab = .general
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .general: return "gear"
            case .appearance: return "paintbrush"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 12)
            
            // Tab picker
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            
            Divider()
            
            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .appearance:
                    appearanceTab
                }
            }
            .padding(18)
        }
        .frame(minWidth: 800, minHeight: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.loadSettingsStorageDirectoryPath()
            pathFieldFocused = true
        }
        .onChange(of: viewModel.settingsStorageDirectoryPath) { _, _ in
            if viewModel.settingsSuccessMessage != nil {
                viewModel.settingsSuccessMessage = nil
            }
        }
    }
    
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("JSON Storage Folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Folder path", text: $viewModel.settingsStorageDirectoryPath)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($pathFieldFocused)
            }

            if let settingsErrorMessage = viewModel.settingsErrorMessage {
                Text(settingsErrorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.colors.errorColor)
            }

            if let settingsSuccessMessage = viewModel.settingsSuccessMessage {
                Text(settingsSuccessMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.colors.successColor)
            }

            HStack {
                Button("Browse...") {
                    chooseStorageFolder()
                }

                Button("Open in Finder") {
                    openStorageFolder()
                }

                Spacer()

                Button("Save") {
                    _ = viewModel.saveSettingsStorageDirectoryPath()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Version")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(updateChecker.currentVersion)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(themeManager.colors.accentColor)
                        Text("Update available: v\(latest)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let url = updateChecker.downloadURL {
                            Button("Download") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .padding(10)
                    .background(themeManager.colors.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    HStack(spacing: 8) {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for updates...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Up to date")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Check for Updates") {
                                updateChecker.checkForUpdate()
                            }
                        }
                    }
                }
            }
            
            Spacer()
        }
    }
    
    private var appearanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Theme")
                    .font(.system(size: 14, weight: .medium))
                
                Text("Choose a color theme for the app. The theme will be applied immediately.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
                ], spacing: 16) {
                    ForEach(AppTheme.allThemes) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: themeManager.currentTheme.id == theme.id
                        ) {
                            themeManager.setTheme(theme)
                        }
                    }
                }
                
                // Show color pickers for custom theme
                if themeManager.currentTheme.isCustom {
                    Divider()
                        .padding(.vertical, 8)
                    
                    customColorsSection
                }
                
                Spacer(minLength: 20)
            }
            .padding(.bottom, 10)
        }
    }
    
    private var customColorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Colors")
                .font(.system(size: 14, weight: .medium))
            
            Text("Customize the colors for your theme.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                ColorPickerRow(
                    label: "Outer Background",
                    color: Binding(
                        get: { themeManager.customColors.launcherBackground },
                        set: { themeManager.updateCustomColor($0, for: \.launcherBackground) }
                    )
                )
                
                ColorPickerRow(
                    label: "Search Bar Background",
                    color: Binding(
                        get: { themeManager.customColors.searchFieldBackground },
                        set: { themeManager.updateCustomColor($0, for: \.searchFieldBackground) }
                    )
                )
                
                ColorPickerRow(
                    label: "Search Bar Border",
                    color: Binding(
                        get: { themeManager.customColors.searchFieldBorder },
                        set: { themeManager.updateCustomColor($0, for: \.searchFieldBorder) }
                    )
                )
                
                ColorPickerRow(
                    label: "Outer Border",
                    color: Binding(
                        get: { themeManager.customColors.launcherBorder },
                        set: { themeManager.updateCustomColor($0, for: \.launcherBorder) }
                    )
                )
                
                ColorPickerRow(
                    label: "Item Background",
                    color: Binding(
                        get: { themeManager.customColors.itemBackground },
                        set: { themeManager.updateCustomColor($0, for: \.itemBackground) }
                    )
                )
                
                ColorPickerRow(
                    label: "Item Title",
                    color: Binding(
                        get: { themeManager.customColors.itemTitleText },
                        set: { themeManager.updateCustomColor($0, for: \.itemTitleText) }
                    )
                )
                
                ColorPickerRow(
                    label: "Item Subtitle",
                    color: Binding(
                        get: { themeManager.customColors.itemSubtitleText },
                        set: { themeManager.updateCustomColor($0, for: \.itemSubtitleText) }
                    )
                )
                
                ColorPickerRow(
                    label: "Selected Item Background",
                    color: Binding(
                        get: { themeManager.customColors.selectedItemBackground },
                        set: { themeManager.updateCustomColor($0, for: \.selectedItemBackground) }
                    )
                )
                
                ColorPickerRow(
                    label: "Selected Item Title",
                    color: Binding(
                        get: { themeManager.customColors.selectedItemTitleText },
                        set: { themeManager.updateCustomColor($0, for: \.selectedItemTitleText) }
                    )
                )
                
                ColorPickerRow(
                    label: "Selected Item Subtitle",
                    color: Binding(
                        get: { themeManager.customColors.selectedItemSubtitleText },
                        set: { themeManager.updateCustomColor($0, for: \.selectedItemSubtitleText) }
                    )
                )
                
                ColorPickerRow(
                    label: "Accent Color",
                    color: Binding(
                        get: { themeManager.customColors.accentColor },
                        set: { themeManager.updateCustomColor($0, for: \.accentColor) }
                    )
                )
                
                ColorPickerRow(
                    label: "Editor Background",
                    color: Binding(
                        get: { themeManager.customColors.editorBackground },
                        set: { themeManager.updateCustomColor($0, for: \.editorBackground) }
                    )
                )
                
                ColorPickerRow(
                    label: "Editor Text Area",
                    color: Binding(
                        get: { themeManager.customColors.editorTextBackground },
                        set: { themeManager.updateCustomColor($0, for: \.editorTextBackground) }
                    )
                )
                

                
                ColorPickerRow(
                    label: "Highlight Background",
                    color: Binding(
                        get: { themeManager.customColors.highlightBackground },
                        set: { themeManager.updateCustomColor($0, for: \.highlightBackground) }
                    )
                )
            }
            
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    themeManager.customColors = AppTheme.defaultCustomColors
                }
                .font(.system(size: 12))
            }
            .padding(.top, 8)
        }
    }


    private func openStorageFolder() {
        let path = viewModel.settingsStorageDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return
        }
        let expandedPath = (path as NSString).expandingTildeInPath

        let folderURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            return
        }
        NSWorkspace.shared.open(folderURL)
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose JSON Storage Folder"
        panel.message = "JSON files will be written here, with images in an images folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        let currentPath = viewModel.settingsStorageDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentPath.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (currentPath as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }

        if panel.runModal() == .OK, let selectedURL = panel.url {
            viewModel.settingsStorageDirectoryPath = selectedURL.path
            viewModel.settingsErrorMessage = nil
            viewModel.settingsSuccessMessage = nil
        }
    }
}

private struct ResultRow: View, Equatable {
    private struct SnippetSegment {
        let text: String
        let isHighlighted: Bool
    }

    let item: SearchResultRecord
    let isSelected: Bool
    let onActivate: () -> Void
    @EnvironmentObject var themeManager: ThemeManager

    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.item.id == rhs.item.id &&
            lhs.item.title == rhs.item.title &&
            lhs.item.snippet == rhs.item.snippet &&
            lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? themeManager.colors.selectedItemTitleText : themeManager.colors.itemTitleText)

                if let snippetSegments = visibleSnippetSegments {
                    highlightedSnippetText(from: snippetSegments, isSelected: isSelected)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? themeManager.colors.selectedItemBackground : themeManager.colors.itemBackground)
        }
        .buttonStyle(.plain)
    }

    private var visibleSnippetSegments: [SnippetSegment]? {
        guard let snippet = item.snippet else {
            return nil
        }

        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let segments = parseSnippetSegments(trimmed)
        let hasVisibleText = segments.contains { segment in
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasVisibleText else {
            return nil
        }

        return segments
    }

    private func highlightedSnippetText(from segments: [SnippetSegment], isSelected: Bool) -> Text {
        var attributed = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            part.font = .system(size: 12, weight: .regular)
            
            // Use different colors based on selection state
            if segment.isHighlighted {
                part.foregroundColor = isSelected 
                    ? themeManager.colors.selectedItemTitleText  // Highlighted text in selected item
                    : themeManager.colors.itemTitleText           // Highlighted text in unselected item
            } else {
                part.foregroundColor = isSelected
                    ? themeManager.colors.selectedItemSubtitleText  // Normal text in selected item
                    : themeManager.colors.itemSubtitleText          // Normal text in unselected item
            }

            if segment.isHighlighted {
                part.backgroundColor = themeManager.colors.highlightBackground
            }

            attributed.append(part)
        }
        return Text(attributed)
    }

    private func parseSnippetSegments(_ snippet: String) -> [SnippetSegment] {
        var segments: [SnippetSegment] = []
        var buffer = String()
        var isHighlighted = false
        var cursor = snippet.startIndex

        while cursor < snippet.endIndex {
            let next = snippet.index(after: cursor)
            if snippet[cursor] == "*",
               next < snippet.endIndex,
               snippet[next] == "*" {
                if !buffer.isEmpty {
                    segments.append(SnippetSegment(text: buffer, isHighlighted: isHighlighted))
                    buffer.removeAll(keepingCapacity: true)
                }
                isHighlighted.toggle()
                cursor = snippet.index(after: next)
                continue
            }

            buffer.append(snippet[cursor])
            cursor = next
        }

        if !buffer.isEmpty {
            segments.append(SnippetSegment(text: buffer, isHighlighted: isHighlighted))
        }

        return segments
    }

}

private struct ResultsListView: View {
    let results: [SearchResultRecord]
    @Binding var selectedIndex: Int
    @Binding var resultsScrollProxy: ScrollViewProxy?
    let onActivate: (Int) -> Void
    let onScrollProxySet: (ScrollViewProxy) -> Void
    let onScrollSelection: (ScrollViewProxy, Bool) -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        if results.isEmpty {
            emptyResultsView
        } else {
            resultsScrollView
        }
    }
    
    private var emptyResultsView: some View {
        Text("No matching results. Press Enter to add this as a new entry.")
            .font(.system(size: 13))
            .italic()
            .foregroundStyle(themeManager.colors.placeholderText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var resultsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ResultsListItems(
                    results: results,
                    selectedIndex: $selectedIndex,
                    onActivate: onActivate
                )
            }
            .onAppear {
                onScrollProxySet(proxy)
                if selectedIndex > 0 {
                    onScrollSelection(proxy, false)
                }
            }
        }
    }
}

private struct ResultsListItems: View {
    let results: [SearchResultRecord]
    @Binding var selectedIndex: Int
    let onActivate: (Int) -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<results.count, id: \.self) { idx in
                resultsItem(at: idx)
            }
        }
    }
    
    private func resultsItem(at idx: Int) -> some View {
        let item = results[idx]
        let isSelected = idx == selectedIndex
        return Group {
            ResultRow(
                item: item,
                isSelected: isSelected,
                onActivate: {
                    selectedIndex = idx
                    onActivate(idx)
                }
            )
            .environmentObject(themeManager)
            
            if idx + 1 < results.count {
                Divider()
            }
        }
    }
}

private struct TabButton: View {
    let tab: SettingsSheet.SettingsTab
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color(nsColor: .selectedControlColor) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color(nsColor: .selectedControlTextColor) : Color.primary)
    }
}

private struct ColorPickerRow: View {
    let label: String
    @Binding var color: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            ColorPicker("", selection: $color)
                .labelsHidden()
                .frame(width: 50)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    private var displayColors: ThemeColors {
        theme.isCustom ? themeManager.customColors : theme.colors
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Preview area
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(displayColors.launcherBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(displayColors.launcherBorder, lineWidth: 1)
                        )
                    
                    VStack(spacing: 8) {
                        // Search field preview
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(displayColors.searchFieldBackground)
                            .frame(height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(displayColors.searchFieldBorder, lineWidth: 0.5)
                            )
                        
                        // Results preview - shows both selected and unselected items
                        VStack(spacing: 4) {
                            // Selected item
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(displayColors.selectedItemBackground)
                                    .frame(width: 40, height: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(displayColors.selectedItemTitleText.opacity(0.3))
                                        .frame(width: 50, height: 6)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(displayColors.selectedItemSubtitleText.opacity(0.2))
                                        .frame(width: 35, height: 4)
                                }
                            }
                            // Unselected item
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(displayColors.itemBackground)
                                    .frame(width: 40, height: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(displayColors.itemTitleText.opacity(0.3))
                                        .frame(width: 45, height: 6)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(displayColors.itemSubtitleText.opacity(0.2))
                                        .frame(width: 30, height: 4)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(height: 90)
                
                // Name label
                Text(theme.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? themeManager.colors.accentColor : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isSelected ? themeManager.colors.accentColor.opacity(0.1) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? themeManager.colors.accentColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EditorSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var editorCursorCharIndex: Int?
    @State private var isClosingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.selectedItem?.title ?? "Editor")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(themeManager.colors.itemTitleText)

            InlineImageTextEditor(
                text: $viewModel.editorText,
                imagesByKey: Dictionary(uniqueKeysWithValues: (viewModel.selectedItem?.images ?? []).map { ($0.imageKey, $0.bytes) }),
                searchQuery: viewModel.query,
                defaultImageWidth: 360,
                fontSize: viewModel.editorFontSize
            ) { cursorIndex in
                editorCursorCharIndex = cursorIndex
            }
            .padding(10)
            .background(themeManager.colors.editorTextBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 500)
        .background(themeManager.colors.editorBackground)
        .background(
            KeyEventMonitor { event in
                handleEditorKeyEvent(event)
            }
        )
        .onChange(of: viewModel.editorText) { _, _ in
            viewModel.scheduleAutosave()
        }
        .onAppear {
            isClosingEditor = false
        }
        .onDisappear {
            if isClosingEditor {
                return
            }
            Task { await viewModel.flushAutosave() }
        }
    }

    private func handleEditorKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(keyHandlingModifierMask)

        if handleEditorFontSizeShortcut(event, modifiers: modifiers) {
            return true
        }

        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v",
           viewModel.hasImageInClipboard() {
            Task { await viewModel.pasteImageFromClipboard(at: editorCursorCharIndex) }
            return true
        }

        if modifiers.isEmpty, event.keyCode == 53 {
            guard !isClosingEditor else {
                return true
            }

            isClosingEditor = true
            Task { @MainActor in
                _ = await viewModel.flushAutosave()
            }
            dismiss()
            return true
        }

        return false
    }

    private func handleEditorFontSizeShortcut(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers == [.command] || modifiers == [.command, .shift] else {
            return false
        }

        switch event.keyCode {
        case 24, 69: // =/+ and keypad +
            viewModel.increaseEditorFontSize()
            return true
        case 27, 78: // - and keypad -
            viewModel.decreaseEditorFontSize()
            return true
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers else {
            return false
        }

        switch chars {
        case "=", "+":
            viewModel.increaseEditorFontSize()
            return true
        case "-":
            viewModel.decreaseEditorFontSize()
            return true
        default:
            return false
        }
    }
}
