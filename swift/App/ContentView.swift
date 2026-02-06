import AppKit
import SwiftUI

private let launcherWindowWidth: CGFloat = 1040
private let launcherEmptyHeight: CGFloat = 220
private let launcherResultRowHeight: CGFloat = 60
private let launcherMaxVisibleRows: CGFloat = 5
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
        .onChange(of: viewModel.results) { _, _ in
            if viewModel.results.isEmpty {
                selectedIndex = 0
            } else if selectedIndex >= viewModel.results.count {
                selectedIndex = max(0, viewModel.results.count - 1)
            }
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        viewModel.isSearching
                            ? Color(red: 70 / 255, green: 130 / 255, blue: 210 / 255, opacity: 0.75)
                            : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .offset(y: viewModel.isSearching ? -4 : 0)
            .scaleEffect(viewModel.isSearching ? 1.01 : 1)
            .shadow(
                color: viewModel.isSearching
                    ? Color(red: 70 / 255, green: 130 / 255, blue: 210 / 255, opacity: 0.32)
                    : .clear,
                radius: viewModel.isSearching ? 10 : 0,
                x: 0,
                y: viewModel.isSearching ? 6 : 0
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.isSearching)

            if let errorMessage = viewModel.errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
                    .padding(.top, 6)
            }

            if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Alfred Update Available")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(white: 20 / 255))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            } else {
                if viewModel.results.isEmpty {
                    Text("No matching results. Press Enter to add this as a new entry.")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(Color(white: 95 / 255))
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { idx, item in
                                let isSelected = idx == selectedIndex
                                ResultRow(
                                    item: item,
                                    isSelected: isSelected,
                                    onHover: {
                                        selectedIndex = idx
                                    },
                                    onActivate: {
                                        selectedIndex = idx
                                        activateCurrentSelection()
                                    }
                                )

                                if idx + 1 < viewModel.results.count {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: launcherResultRowHeight * launcherMaxVisibleRows)
                    .padding(.top, 8)
                }
            }
        }
        .padding(14)
        .frame(width: width)
        .background(Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255, opacity: 252 / 255))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(35 / 255), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(52 / 255), radius: 14, x: 0, y: 6)
    }

    private func activateCurrentSelection() {
        Task {
            let openedEditor = await viewModel.activate(selectedIndex: selectedIndex)
            if openedEditor {
                viewModel.beginEditorPresentation()
                openWindow(id: "editor")
            }
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
            return true
        case 125: // down
            if selectedIndex + 1 < viewModel.results.count {
                selectedIndex += 1
            }
            return true
        case 36, 76: // return / enter
            activateCurrentSelection()
            return true
        case 53: // escape
            NSApp.terminate(nil)
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

private struct ResultRow: View {
    let item: SearchResultRecord
    let isSelected: Bool
    let onHover: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(white: 20 / 255) : Color(white: 35 / 255))

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 85 / 255))
                }

                if let snippet = item.snippet, !snippet.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let source = item.snippetSource {
                            Text("\(source):")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(white: 95 / 255))
                        }

                        Text(attributedSnippet(snippet))
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color(red: 230 / 255, green: 236 / 255, blue: 245 / 255) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                onHover()
            }
        }
    }

    private func attributedSnippet(_ snippet: String) -> AttributedString {
        var result = AttributedString()

        for segment in snippetSegments(snippet) {
            var piece = AttributedString(segment.text)
            if segment.isHighlight {
                piece.foregroundColor = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
                piece.backgroundColor = Color(red: 1.0, green: 238 / 255, blue: 170 / 255)
                piece.font = .system(size: 12, weight: .semibold)
            } else {
                piece.foregroundColor = Color(white: 70 / 255)
                piece.font = .system(size: 12)
            }
            result += piece
        }

        return result
    }

    private func snippetSegments(_ snippet: String) -> [(text: String, isHighlight: Bool)] {
        var segments: [(String, Bool)] = []
        var rest = snippet[...]

        while let start = rest.range(of: "**") {
            if start.lowerBound > rest.startIndex {
                segments.append((String(rest[..<start.lowerBound]), false))
            }

            let highlightStart = start.upperBound
            guard let end = rest[highlightStart...].range(of: "**") else {
                segments.append((String(rest[start.lowerBound...]), false))
                rest = ""
                break
            }

            segments.append((String(rest[highlightStart..<end.lowerBound]), true))
            rest = rest[end.upperBound...]
        }

        if !rest.isEmpty {
            segments.append((String(rest), false))
        }

        return segments
    }
}

private struct EditorSheet: View {
    private struct ResizeDragState {
        let key: String
        let startWidth: Double
    }

    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editorCursorCharIndex: Int?
    @State private var resizeDrag: ResizeDragState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.selectedItem?.title ?? "Editor")
                    .font(.system(size: 20, weight: .semibold))

                Spacer()

                Button("Paste Image") {
                    Task { await viewModel.pasteImageFromClipboard(at: editorCursorCharIndex) }
                }
            }

            InlineImageTextEditor(
                text: $viewModel.editorText,
                imagesByKey: Dictionary(uniqueKeysWithValues: (viewModel.selectedItem?.images ?? []).map { ($0.imageKey, $0.bytes) }),
                defaultImageWidth: 360
            ) { cursorIndex in
                editorCursorCharIndex = cursorIndex
            }
            .padding(10)
            .background(Color(red: 246 / 255, green: 246 / 255, blue: 246 / 255))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let item = viewModel.selectedItem, !item.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(item.images, id: \.imageKey) { image in
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    Group {
                                        if let nsImage = NSImage(data: image.bytes) {
                                            Image(nsImage: nsImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                        } else {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color.gray.opacity(0.2))
                                                .overlay(Text("Image").font(.caption))
                                        }
                                    }
                                    .frame(width: previewWidth(for: image.imageKey), height: 110)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(5)
                                        .background(Color.black.opacity(0.58))
                                        .clipShape(Circle())
                                        .padding(6)
                                        .contentShape(Rectangle())
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    handleResizeDragChanged(for: image.imageKey, value: value)
                                                }
                                                .onEnded { _ in
                                                    handleResizeDragEnded()
                                                }
                                        )
                                }
                                .frame(width: previewWidth(for: image.imageKey), height: 110)

                                HStack {
                                    Text(image.imageKey)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(role: .destructive) {
                                        Task { await viewModel.removeImage(imageKey: image.imageKey) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        Task { await viewModel.decreaseImageDisplayWidth(imageKey: image.imageKey) }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)

                                    Text("\(Int(viewModel.imageDisplayWidth(for: image.imageKey)))px")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color(white: 0.35))

                                    Button {
                                        Task { await viewModel.increaseImageDisplayWidth(imageKey: image.imageKey) }
                                    } label: {
                                        Image(systemName: "plus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(8)
                            .background(Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )
                        }
                    }
                }
                .frame(maxHeight: 170)
            }

            Text("\(viewModel.selectedItem?.images.count ?? 0) image(s)")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.4))
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

    private func previewWidth(for imageKey: String) -> CGFloat {
        let logicalWidth = viewModel.imageDisplayWidth(for: imageKey)
        let scaled = logicalWidth * 0.45
        return CGFloat(min(max(scaled, 140), 360))
    }

    private func handleResizeDragChanged(for imageKey: String, value: DragGesture.Value) {
        if resizeDrag?.key != imageKey {
            resizeDrag = ResizeDragState(key: imageKey, startWidth: viewModel.imageDisplayWidth(for: imageKey))
        }

        guard let drag = resizeDrag else {
            return
        }

        let delta = Double(max(value.translation.width, value.translation.height))
        _ = viewModel.setImageDisplayWidthTransient(imageKey: imageKey, width: drag.startWidth + delta)
    }

    private func handleResizeDragEnded() {
        resizeDrag = nil
        Task { await viewModel.persistEditorState() }
    }
}
