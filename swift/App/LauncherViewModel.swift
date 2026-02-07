import AppKit
import Foundation

private let maxNoteImageCount = 24
private let noteImageURLPrefix = "alfred://image/"
private let inlineImageDefaultWidth: Double = 360
private let inlineImageMinWidth: Double = 140
private let inlineImageMaxWidth: Double = 1200
private let inlineImageResizeStep: Double = 80
private let autosaveDebounceNanoseconds: UInt64 = 1_200_000_000

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingSearchTask?.cancel()
                results = []
                errorMessage = nil
                isSearching = false
                return
            }
            debounceSearch()
        }
    }

    @Published private(set) var results: [SearchResultRecord] = []
    @Published private(set) var selectedItem: EditableItemRecord?
    @Published var editorText: String = ""
    @Published var errorMessage: String?
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var isEditorPresented: Bool = false
    @Published private(set) var launcherFocusRequestID: UInt64 = 0

    private var pendingSearchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var autosaveTask: Task<Void, Never>?
    private weak var launcherWindow: NSWindow?
    private weak var editorWindow: NSWindow?

    func initialLoad() async {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await runSearch()
        }
    }

    func activate(selectedIndex: Int) async -> Bool {
        if results.indices.contains(selectedIndex) {
            return await open(itemId: results[selectedIndex].id)
        }
        return await createItemFromQuery()
    }

    func registerLauncherWindow(_ window: NSWindow) {
        launcherWindow = window
    }

    func registerEditorWindow(_ window: NSWindow) {
        editorWindow = window
    }

    func beginEditorPresentation() {
        isEditorPresented = true
        launcherWindow?.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    func dismissLauncher() {
        guard !isEditorPresented, let launcherWindow else {
            return
        }

        launcherWindow.orderOut(nil)
        NSApp.hide(nil)
    }

    func revealLauncherIfNeeded() {
        guard !isEditorPresented, let launcherWindow else {
            return
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if launcherWindow.isMiniaturized {
            launcherWindow.deminiaturize(nil)
        }
        launcherWindow.makeKeyAndOrderFront(nil)
        launcherWindow.orderFrontRegardless()
        launcherFocusRequestID &+= 1
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.launcherWindow?.makeKeyAndOrderFront(nil)
            self.launcherFocusRequestID &+= 1
        }
    }

    func toggleLauncherVisibilityFromHotKey() {
        guard !isEditorPresented, let launcherWindow else {
            return
        }

        let isEffectivelyVisible = launcherWindow.isVisible && !launcherWindow.isMiniaturized && !NSApp.isHidden
        if isEffectivelyVisible {
            dismissLauncher()
        } else {
            revealLauncherIfNeeded()
        }
    }

    func editorDidClose() {
        guard isEditorPresented else {
            return
        }

        isEditorPresented = false
        NSApp.activate(ignoringOtherApps: true)
        launcherWindow?.makeKeyAndOrderFront(nil)
        launcherWindow?.orderFrontRegardless()
        launcherFocusRequestID &+= 1
    }

    func open(itemId: Int64) async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil

        do {
            let item = try RustBridgeClient.fetch(itemId: itemId)
            selectedItem = item
            editorText = item.note
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createItemFromQuery() async -> Bool {
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return false
        }

        do {
            let itemId = try RustBridgeClient.create(title: title)
            await runSearch()
            return await open(itemId: itemId)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveCurrentItem() async {
        guard var item = selectedItem else {
            return
        }

        item.note = editorText
        let referenced = referencedImageKeys(in: editorText)
        item.images.removeAll { !referenced.contains($0.imageKey) }
        selectedItem = item

        do {
            try RustBridgeClient.save(itemId: item.id, note: editorText, images: item.images)
            let refreshed = try RustBridgeClient.fetch(itemId: item.id)
            selectedItem = refreshed
            editorText = refreshed.note
            errorMessage = nil
            await runSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: autosaveDebounceNanoseconds)
            guard let self, !Task.isCancelled else {
                return
            }
            await self.saveCurrentItem()
        }
    }

    func flushAutosave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await saveCurrentItem()
    }

    func hasImageInClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
            return true
        }
        return !(pasteboard.readObjects(forClasses: [NSImage.self], options: nil) ?? []).isEmpty
    }

    func pasteImageFromClipboard(at cursorCharIndex: Int?) async {
        guard var item = selectedItem else {
            return
        }

        if item.images.count >= maxNoteImageCount {
            errorMessage = "Too many note images (max \(maxNoteImageCount))"
            return
        }

        guard let imageBytes = clipboardImageBytes() else {
            errorMessage = "Clipboard does not contain an image"
            return
        }

        let key = nextImageKey(existing: Set(item.images.map(\.imageKey)))
        item.images.append(NoteImageRecord(imageKey: key, bytes: imageBytes))

        editorText = insertMarkdownImageRef(into: editorText, key: key, cursorCharIndex: cursorCharIndex)
        item.note = editorText
        selectedItem = item
        errorMessage = nil

        await saveCurrentItem()
    }

    func removeImage(imageKey: String) async {
        guard var item = selectedItem else {
            return
        }

        let before = item.images.count
        item.images.removeAll { $0.imageKey == imageKey }
        guard item.images.count != before else {
            return
        }

        editorText = removeMarkdownImageRef(from: editorText, key: imageKey)
        item.note = editorText
        selectedItem = item
        errorMessage = nil

        await saveCurrentItem()
    }

    func imageDisplayWidth(for imageKey: String) -> Double {
        markdownImageWidth(in: editorText, key: imageKey) ?? inlineImageDefaultWidth
    }

    func increaseImageDisplayWidth(imageKey: String) async {
        let next = imageDisplayWidth(for: imageKey) + inlineImageResizeStep
        await setImageDisplayWidth(imageKey: imageKey, width: next)
    }

    func decreaseImageDisplayWidth(imageKey: String) async {
        let next = imageDisplayWidth(for: imageKey) - inlineImageResizeStep
        await setImageDisplayWidth(imageKey: imageKey, width: next)
    }

    func setImageDisplayWidth(imageKey: String, width: Double) async {
        guard setImageDisplayWidthTransient(imageKey: imageKey, width: width) else {
            return
        }
        await saveCurrentItem()
    }

    @discardableResult
    func setImageDisplayWidthTransient(imageKey: String, width: Double) -> Bool {
        guard var item = selectedItem else {
            return false
        }

        let clamped = width.clamped(to: inlineImageMinWidth...inlineImageMaxWidth)
        let nextNote = upsertMarkdownImageRefWidth(in: editorText, key: imageKey, width: Int(clamped.rounded()))
        guard nextNote != editorText else {
            return false
        }

        editorText = nextNote
        item.note = nextNote
        selectedItem = item
        errorMessage = nil
        return true
    }

    func persistEditorState() async {
        await saveCurrentItem()
    }

    private func debounceSearch() {
        pendingSearchTask?.cancel()
        isSearching = true
        pendingSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            await self.runSearch()
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }

        searchGeneration &+= 1
        let generation = searchGeneration
        isSearching = true

        do {
            let fetched = try RustBridgeClient.search(query: trimmed)
            guard generation == searchGeneration,
                  trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return
            }

            results = fetched
            errorMessage = nil
            isSearching = false
        } catch {
            guard generation == searchGeneration else {
                return
            }
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }

    private func clipboardImageBytes() -> Data? {
        let pasteboard = NSPasteboard.general

        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return png
        }

        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiff),
           let png = image.pngData() {
            return png
        }

        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
           let png = image.pngData() {
            return png
        }

        return nil
    }

    private func nextImageKey(existing: Set<String>) -> String {
        while true {
            let timestamp = Int(Date().timeIntervalSince1970)
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let key = "img-\(timestamp)-\(suffix)"
            if !existing.contains(key) {
                return key
            }
        }
    }

    private func appendMarkdownImageRef(to note: String, key: String) -> String {
        insertMarkdownImageRef(into: note, key: key, cursorCharIndex: note.count)
    }

    private func insertMarkdownImageRef(into note: String, key: String, cursorCharIndex: Int?) -> String {
        let ref = "![image](\(noteImageURLPrefix)\(key))"
        let bounded = max(0, min(cursorCharIndex ?? note.count, note.count))
        let insertionIndex = note.index(note.startIndex, offsetBy: bounded)
        var output = note
        let needsLeadingNewline = insertionIndex > note.startIndex && note[note.index(before: insertionIndex)] != "\n"
        let needsTrailingNewline = insertionIndex < note.endIndex ? note[insertionIndex] != "\n" : true

        var insertion = ""
        if needsLeadingNewline {
            insertion += "\n"
        }
        insertion += ref
        if needsTrailingNewline {
            insertion += "\n"
        }

        output.insert(contentsOf: insertion, at: insertionIndex)
        return output
    }

    private func removeMarkdownImageRef(from note: String, key: String) -> String {
        guard let regex = imageRefRegex(for: key) else {
            return note
        }
        let noteRange = NSRange(note.startIndex..<note.endIndex, in: note)
        return regex.stringByReplacingMatches(in: note, options: [], range: noteRange, withTemplate: "")
    }

    private func markdownImageWidth(in note: String, key: String) -> Double? {
        guard let regex = imageRefRegex(for: key) else {
            return nil
        }
        let noteRange = NSRange(note.startIndex..<note.endIndex, in: note)
        guard let match = regex.firstMatch(in: note, options: [], range: noteRange) else {
            return nil
        }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound,
              let captureRange = Range(capture, in: note),
              let value = Double(note[captureRange])
        else {
            return nil
        }
        return value
    }

    private func upsertMarkdownImageRefWidth(in note: String, key: String, width: Int) -> String {
        guard let regex = imageRefRegex(for: key) else {
            return note
        }

        let noteRange = NSRange(note.startIndex..<note.endIndex, in: note)
        let replacement = "![image](\(noteImageURLPrefix)\(key)?w=\(width))"
        let updated = regex.stringByReplacingMatches(
            in: note,
            options: [],
            range: noteRange,
            withTemplate: replacement
        )
        return updated
    }

    private func imageRefRegex(for key: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "!\\[image\\]\\(\(noteImageURLPrefix)\(escaped)(?:\\?w=(\\d+))?\\)"
        return try? NSRegularExpression(pattern: pattern)
    }

    private func referencedImageKeys(in note: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"!\[image\]\(alfred://image/([^\)\?]+)(?:\?w=\d+)?\)"#) else {
            return []
        }

        let range = NSRange(note.startIndex..<note.endIndex, in: note)
        let matches = regex.matches(in: note, range: range)
        var keys = Set<String>()

        for match in matches {
            let capture = match.range(at: 1)
            guard capture.location != NSNotFound,
                  let captureRange = Range(capture, in: note)
            else {
                continue
            }
            keys.insert(String(note[captureRange]))
        }

        return keys
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
