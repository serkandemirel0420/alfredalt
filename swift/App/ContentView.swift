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
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedIndex = 0
    @State private var measuredShellHeight: CGFloat = launcherEmptyHeight
    @State private var resultsScrollProxy: ScrollViewProxy?
    @State private var actionMenuTarget: SearchResultRecord?
    @State private var actionMenuSelectedIndex = 0
    @State private var actionMenuFilter = ""
    @State private var savedQueryForActionMenu = ""

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
        VStack(spacing: 0) {
            launcherShell(width: launcherWindowWidth)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LauncherShellHeightPreferenceKey.self,
                            value: ceil(proxy.size.height)
                        )
                    }
                )
        }
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
        }
    }

    private func launcherShell(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(
                    actionMenuTarget != nil ? "Filter actions..." : "Type to search...",
                    text: Binding(
                        get: { actionMenuTarget != nil ? actionMenuFilter : viewModel.query },
                        set: { newValue in
                            if actionMenuTarget != nil {
                                actionMenuFilter = newValue
                            } else {
                                viewModel.query = newValue
                            }
                        }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .regular))
                .focused($searchFieldFocused)
                .onSubmit {
                    if let target = actionMenuTarget {
                        let actions = filteredActions
                        if actions.indices.contains(actionMenuSelectedIndex) {
                            executeAction(actions[actionMenuSelectedIndex], on: target)
                        }
                    } else {
                        activateCurrentSelection()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255, opacity: 252 / 255))
            .overlay(
                RoundedRectangle(cornerRadius: launcherSearchFieldCornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: launcherSearchFieldCornerRadius, style: .continuous))

            if let errorMessage = viewModel.errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
                    .padding(.top, 6)
            }

            let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let showResults = !trimmedQuery.isEmpty
            Group {
                if let target = actionMenuTarget {
                    actionMenuView(for: target)
                } else if showResults {
                    if viewModel.results.isEmpty {
                        Text("No matching results. Press Enter to add this as a new entry.")
                            .font(.system(size: 13))
                            .italic()
                            .foregroundStyle(Color(white: 95 / 255))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { idx, item in
                                        let isSelected = idx == selectedIndex
                                        ResultRow(
                                            item: item,
                                            isSelected: isSelected,
                                            onActivate: {
                                                selectedIndex = idx
                                                activateResult(at: idx)
                                            }
                                        )
                                        .equatable()
                                        .id(item.id)

                                        if idx + 1 < viewModel.results.count {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .onAppear {
                                resultsScrollProxy = proxy
                                if selectedIndex > 0 {
                                    scrollSelectionIntoView(using: proxy, animated: false)
                                }
                            }
                            .onDisappear {
                                if resultsScrollProxy != nil {
                                    resultsScrollProxy = nil
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, showResults || actionMenuTarget != nil ? 8 : 0)
            .frame(
                maxWidth: .infinity,
                minHeight: showResults || actionMenuTarget != nil ? resultsViewportHeight : 0,
                maxHeight: showResults || actionMenuTarget != nil ? resultsViewportHeight : 0,
                alignment: .top
            )
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: launcherResultsCornerRadius, style: .continuous))
        }
        .padding(launcherShellPadding)
        .frame(width: width)
        .background(Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255))
        .overlay(
            RoundedRectangle(cornerRadius: launcherShellCornerRadius, style: .continuous)
                .stroke(Color.black.opacity(35 / 255), lineWidth: 1)
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

        let target = viewModel.results[selectedIndex]
        savedQueryForActionMenu = viewModel.query
        actionMenuTarget = target
        actionMenuSelectedIndex = 0
        actionMenuFilter = ""
        viewModel.query = ""
        searchFieldFocused = true
    }

    private func dismissActionMenu() {
        actionMenuTarget = nil
        actionMenuSelectedIndex = 0
        actionMenuFilter = ""
        viewModel.query = savedQueryForActionMenu
        savedQueryForActionMenu = ""
        searchFieldFocused = true
    }

    private func actionMenuView(for target: SearchResultRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(white: 100 / 255))
                Text(target.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(white: 50 / 255))
                    .lineLimit(1)
                Spacer()
                Text("⌘ to go back")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 140 / 255))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(white: 240 / 255))

            Divider()

            let actions = filteredActions
            if actions.isEmpty {
                Text("No matching actions")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(Color(white: 95 / 255))
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
                                .foregroundStyle(action.isDestructive ? Color.red : Color(white: 60 / 255))
                            Text(action.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(action.isDestructive ? Color.red : Color(white: 30 / 255))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Color(red: 230 / 255, green: 236 / 255, blue: 245 / 255) : Color.clear)
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
        let savedQuery = savedQueryForActionMenu
        actionMenuTarget = nil
        actionMenuSelectedIndex = 0
        actionMenuFilter = ""
        viewModel.query = savedQuery
        savedQueryForActionMenu = ""
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
        .background(Color(nsColor: NSColor.windowBackgroundColor))
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

private struct SettingsSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))

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
                    .foregroundStyle(.red)
            }

            if let settingsSuccessMessage = viewModel.settingsSuccessMessage {
                Text(settingsSuccessMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemGreen))
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

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 720)
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
                    .foregroundStyle(isSelected ? Color(white: 20 / 255) : Color(white: 35 / 255))

                if let snippetSegments = visibleSnippetSegments {
                    highlightedSnippetText(from: snippetSegments)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color(red: 230 / 255, green: 236 / 255, blue: 245 / 255) : Color.clear)
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

    private func highlightedSnippetText(from segments: [SnippetSegment]) -> Text {
        var attributed = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            part.font = .system(size: 12, weight: .regular)
            part.foregroundColor = segment.isHighlighted
                ? Color(white: 20 / 255)
                : Color(white: 70 / 255)

            if segment.isHighlighted {
                part.backgroundColor = Color.yellow.opacity(0.55)
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

private struct EditorSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editorCursorCharIndex: Int?
    @State private var isClosingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.selectedItem?.title ?? "Editor")
                .font(.system(size: 20, weight: .semibold))

            InlineImageTextEditor(
                text: $viewModel.editorText,
                imagesByKey: Dictionary(uniqueKeysWithValues: (viewModel.selectedItem?.images ?? []).map { ($0.imageKey, $0.bytes) }),
                defaultImageWidth: 360,
                fontSize: viewModel.editorFontSize
            ) { cursorIndex in
                editorCursorCharIndex = cursorIndex
            }
            .padding(10)
            .background(Color(nsColor: NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 500)
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
