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

private struct LauncherShellHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = launcherEmptyHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: LauncherViewModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedIndex = 0
    @State private var measuredShellHeight: CGFloat = launcherEmptyHeight
    @State private var resultsScrollProxy: ScrollViewProxy?

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
            KeyEventMonitor { event in
                if viewModel.isEditorPresented {
                    return false
                }
                return handleLauncherKeyEvent(event)
            }
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
            if selectedIndex != 0 {
                selectedIndex = 0
            }
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

    private func launcherShell(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Type to search...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .regular))
                    .focused($searchFieldFocused)
                    .onSubmit {
                        activateCurrentSelection()
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
                if showResults {
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
            .padding(.top, showResults ? 8 : 0)
            .frame(
                maxWidth: .infinity,
                minHeight: showResults ? resultsViewportHeight : 0,
                maxHeight: showResults ? resultsViewportHeight : 0,
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

    private func handleLauncherKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(keyHandlingModifierMask)
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

private struct ResultRow: View, Equatable {
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

                if let snippet = visibleSnippet {
                    Text(snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 70 / 255))
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

    private var visibleSnippet: String? {
        guard let snippet = item.snippet else {
            return nil
        }

        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let plain = trimmed
            .replacingOccurrences(of: "**", with: "")
        let withoutEllipsis = plain
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutEllipsis.isEmpty else {
            return nil
        }

        return plain
    }

}

private struct EditorSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editorCursorCharIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.selectedItem?.title ?? "Editor")
                .font(.system(size: 20, weight: .semibold))

            InlineImageTextEditor(
                text: $viewModel.editorText,
                imagesByKey: Dictionary(uniqueKeysWithValues: (viewModel.selectedItem?.images ?? []).map { ($0.imageKey, $0.bytes) }),
                defaultImageWidth: 360
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
        .onDisappear {
            Task { await viewModel.flushAutosave() }
        }
    }

    private func handleEditorKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(keyHandlingModifierMask)

        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v",
           viewModel.hasImageInClipboard() {
            Task { await viewModel.pasteImageFromClipboard(at: editorCursorCharIndex) }
            return true
        }

        if modifiers.isEmpty, event.keyCode == 53 {
            Task {
                await viewModel.flushAutosave()
                dismiss()
            }
            return true
        }

        return false
    }
}
