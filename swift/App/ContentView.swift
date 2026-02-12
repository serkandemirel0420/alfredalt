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
                .font(.system(size: themeManager.searchFieldFontSize, weight: .regular))
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
                    .font(.system(size: themeManager.itemTitleFontSize, weight: .semibold))
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
            part.font = .system(size: themeManager.itemSubtitleFontSize, weight: .regular)
            
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
    let tab: SettingsWindowView.SettingsTab
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
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color(nsColor: .selectedControlTextColor) : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color(nsColor: .selectedControlColor) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
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

private struct FontSizeRow: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultValue: CGFloat
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            
            Spacer()
            
            Text("\(Int(value))pt")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
            
            Stepper("", value: $value, in: range, step: 1)
                .labelsHidden()
                .frame(width: 80)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Settings Window View

struct SettingsWindowView: View {
    @EnvironmentObject var viewModel: LauncherViewModel
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var hotKeyManager = HotKeyManager.shared
    @FocusState private var pathFieldFocused: Bool
    @State private var selectedTab: SettingsTab = .general
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case hotkeys = "Hotkeys"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .general: return "gear"
            case .appearance: return "paintbrush"
            case .hotkeys: return "keyboard"
            }
        }
    }
    
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar area for dragging and focus
            HStack {
                Spacer()
            }
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                WindowDragHandle(inset: 0)
            )
            
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
            .padding(.vertical, 12)
            
            Divider()
            
            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .appearance:
                    appearanceTab
                case .hotkeys:
                    hotkeysTab
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.loadSettingsStorageDirectoryPath()
        }
        .onChange(of: viewModel.settingsStorageDirectoryPath) { _, _ in
            if viewModel.settingsSuccessMessage != nil {
                viewModel.settingsSuccessMessage = nil
            }
        }
        // Handle ESC key to close settings window
        .background(
            SettingsKeyEventMonitor {
                dismissWindow(id: "settings")
            }
        )
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
            
            
            Divider()
            
            // Font Sizes Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Font Sizes")
                    .font(.system(size: 14, weight: .medium))
                
                FontSizeRow(
                    label: "Search Field",
                    value: $themeManager.searchFieldFontSize,
                    range: 20...40,
                    defaultValue: 30
                )
                
                FontSizeRow(
                    label: "Item Title",
                    value: $themeManager.itemTitleFontSize,
                    range: 14...28,
                    defaultValue: 20
                )
                
                FontSizeRow(
                    label: "Item Subtitle",
                    value: $themeManager.itemSubtitleFontSize,
                    range: 10...18,
                    defaultValue: 12
                )
                
                FontSizeRow(
                    label: "Editor",
                    value: $themeManager.editorFontSize,
                    range: 12...24,
                    defaultValue: 15
                )
                
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        themeManager.resetFontSizes()
                    }
                    .font(.system(size: 12))
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
                
                Text("Choose a base theme. You can customize any theme's colors below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
                ], spacing: 16) {
                    // Predefined themes - use static array to avoid recomputation
                    ForEach(predefinedThemes) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: themeManager.currentTheme.id == theme.id && !themeManager.currentTheme.isCustom
                        ) {
                            // Copy the theme's colors to custom colors and switch to custom
                            themeManager.customColors = theme.colors
                            themeManager.setTheme(.custom)
                        }
                    }
                    
                    // Custom theme card (shows current custom colors)
                    ThemeCard(
                        theme: .custom,
                        isSelected: themeManager.currentTheme.isCustom
                    ) {
                        // Just ensure we're on custom theme (colors already shown)
                        themeManager.setTheme(.custom)
                    }
                }
                
                Divider()
                    .padding(.vertical, 8)
                
                customColorsSection
                
                Spacer(minLength: 20)
            }
            .padding(.bottom, 10)
        }
    }
    
    private var customColorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customize Colors")
                .font(.system(size: 14, weight: .medium))
            
            Text("Currently customizing: \(themeManager.currentTheme.isCustom ? "Custom Theme" : themeManager.currentTheme.name)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            // Use a separate view to isolate updates
            CustomColorPickersView(themeManager: themeManager)
            
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
    
    // Separate view to isolate color picker updates from the rest of settings
    private struct CustomColorPickersView: View {
        @ObservedObject var themeManager: ThemeManager
        
        var body: some View {
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
        }
    }
    
    private var hotkeysTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Launcher Hotkey Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Launcher Hotkey")
                        .font(.system(size: 14, weight: .medium))
                    
                    Text("Choose how to show or hide the launcher.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 12) {
                        // Double Option
                        HotkeyOptionRow(
                            title: "Double-Tap Option",
                            subtitle: "Press the Option (⌥) key twice quickly",
                            isSelected: hotKeyManager.currentHotKey == .doubleOption,
                            icon: "option"
                        ) {
                            hotKeyManager.setHotKey(.doubleOption)
                        }
                        
                        // Command + Space
                        HotkeyOptionRow(
                            title: "Command + Space",
                            subtitle: "Classic Spotlight-style shortcut",
                            isSelected: hotKeyManager.currentHotKey == .commandSpace,
                            icon: "command"
                        ) {
                            hotKeyManager.setHotKey(.commandSpace)
                        }
                        
                        // Option + Space
                        HotkeyOptionRow(
                            title: "Option + Space",
                            subtitle: "Alternative modifier shortcut",
                            isSelected: hotKeyManager.currentHotKey == .optionSpace,
                            icon: "option2"
                        ) {
                            hotKeyManager.setHotKey(.optionSpace)
                        }
                        
                        // Control + Space
                        HotkeyOptionRow(
                            title: "Control + Space",
                            subtitle: "Ctrl+Space combination",
                            isSelected: hotKeyManager.currentHotKey == .controlSpace,
                            icon: "control"
                        ) {
                            hotKeyManager.setHotKey(.controlSpace)
                        }
                        
                        // Shift + Space
                        HotkeyOptionRow(
                            title: "Shift + Space",
                            subtitle: "Shift+Space combination",
                            isSelected: hotKeyManager.currentHotKey == .shiftSpace,
                            icon: "shift"
                        ) {
                            hotKeyManager.setHotKey(.shiftSpace)
                        }
                    }
                }
                
                Divider()
                    .padding(.vertical, 8)
                
                // Tips Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tips")
                        .font(.system(size: 14, weight: .medium))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(themeManager.colors.accentColor)
                            Text("Double-tap hotkeys may occasionally conflict with system shortcuts")
                                .font(.system(size: 12))
                        }
                        
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(themeManager.colors.accentColor)
                            Text("Changes take effect immediately")
                                .font(.system(size: 12))
                        }
                    }
                }
                
                Spacer(minLength: 20)
            }
            .padding(.bottom, 10)
        }
    }
    
    private struct HotkeyOptionRow: View {
        let title: String
        let subtitle: String
        let isSelected: Bool
        let icon: String
        let action: () -> Void
        @EnvironmentObject var themeManager: ThemeManager
        
        var iconText: String {
            switch icon {
            case "option": return "⌥"
            case "option2": return "⌥"
            case "command": return "⌘"
            case "control": return "⌃"
            case "shift": return "⇧"
            default: return "⌘"
            }
        }
        
        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? themeManager.colors.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                            .frame(width: 44, height: 44)
                        
                        Text(iconText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSelected ? themeManager.colors.accentColor : .primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? themeManager.colors.accentColor : .primary)
                        
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(themeManager.colors.accentColor)
                            .font(.system(size: 20))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isSelected ? themeManager.colors.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? themeManager.colors.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
    
    private func openStorageFolder() {
        let path = viewModel.settingsStorageDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let expandedPath = (path as NSString).expandingTildeInPath
        
        let folderURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch { return }
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

// MARK: - Settings Key Event Monitor

private struct SettingsKeyEventMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        
        // Add local monitor for key events - only for our window
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator = coordinator else { return event }
            guard let monitoredWindow = coordinator.window else { return event }
            // Only handle events for our window
            guard event.window === monitoredWindow else { return event }
            
            if event.keyCode == 53 { // ESC key
                coordinator.onEscape?()
                return nil // Consume the event
            }
            return event
        }
        
        // Set initial window reference
        DispatchQueue.main.async {
            context.coordinator.window = view.window
            context.coordinator.onEscape = onEscape
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.onEscape = onEscape
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.onEscape = nil
        coordinator.window = nil
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
    
    class Coordinator {
        var monitor: Any?
        weak var window: NSWindow?
        var onEscape: (() -> Void)?
    }
}

// Predefined themes computed once
private let predefinedThemes: [AppTheme] = AppTheme.allThemes.filter { !$0.isCustom }

private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    // Only observe custom colors for the custom theme card to reduce updates
    private var displayColors: ThemeColors {
        theme.isCustom ? themeManager.customColors : theme.colors
    }
    
    // Use a stable ID for the card to prevent unnecessary re-renders
    // Custom theme card needs to update when custom colors change
    private var cardId: String {
        if theme.isCustom {
            // Use a simple string that changes when theme changes
            return "custom-\(themeManager.currentTheme.isCustom)"
        }
        return theme.id
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Preview area - use id to control when view updates
                themePreview
                    .frame(height: 90)
                
                // Name label - only use accent color for selection state, not custom colors
                Text(theme.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(selectionForegroundColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectionBackgroundColor)
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selectionStrokeColor, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .id(cardId)
    }
    
    // Separate computed properties to minimize re-evaluation
    private var selectionForegroundColor: Color {
        isSelected ? themeManager.colors.accentColor : Color.primary
    }
    
    private var selectionBackgroundColor: Color {
        isSelected ? themeManager.colors.accentColor.opacity(0.1) : Color.clear
    }
    
    private var selectionStrokeColor: Color {
        isSelected ? themeManager.colors.accentColor : Color.clear
    }
    
    // Extract preview into separate view to control updates
    private var themePreview: some View {
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
                fontSize: themeManager.editorFontSize
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
            themeManager.increaseEditorFontSize()
            return true
        case 27, 78: // - and keypad -
            themeManager.decreaseEditorFontSize()
            return true
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers else {
            return false
        }

        switch chars {
        case "=", "+":
            themeManager.increaseEditorFontSize()
            return true
        case "-":
            themeManager.decreaseEditorFontSize()
            return true
        default:
            return false
        }
    }
}
