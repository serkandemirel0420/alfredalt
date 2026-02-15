import AppKit
import Foundation

private let maxNoteImageCount = 24
private let noteImageURLPrefix = "alfred://image/"
private let inlineImageDefaultWidth: Double = 360
private let inlineImageMinWidth: Double = 140
private let inlineImageMaxWidth: Double = 1200
private let inlineImageResizeStep: Double = 80
private let autosaveDebounceNanoseconds: UInt64 = 1_200_000_000
private let editorDefaultFontSize: CGFloat = 15
private let editorMinFontSize: CGFloat = 11
private let editorMaxFontSize: CGFloat = 40
private let editorFontSizeStep: CGFloat = 1
private let defaultSearchLimit: UInt32 = 8
private let listAllSearchLimit: UInt32 = 50

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            guard let searchQuery = effectiveSearchQuery(from: query) else {
                queuedSearchQuery = nil
                if !results.isEmpty {
                    results = []
                }
                if errorMessage != nil {
                    errorMessage = nil
                }
                return
            }
            triggerSearch(for: searchQuery)
        }
    }

    @Published private(set) var results: [SearchResultRecord] = []
    @Published private(set) var selectedItem: EditableItemRecord?
    @Published var editorText: String = "" {
        didSet {
            editorStateRevision &+= 1
        }
    }
    @Published private(set) var editorFontSize: CGFloat = editorDefaultFontSize
    @Published var errorMessage: String?
    @Published private(set) var isEditorPresented: Bool = false
    @Published private(set) var isSettingsPresented: Bool = false
    @Published private(set) var launcherFocusRequestID: UInt64 = 0
    @Published private(set) var editorTitleFocusRequestID: UInt64 = 0
    @Published var settingsStorageDirectoryPath: String = ""
    @Published var settingsErrorMessage: String?
    @Published var settingsSuccessMessage: String?

    private var queuedSearchQuery: String?
    private var isSearchWorkerRunning = false
    private var autosaveTask: Task<Void, Never>?
    private var editorStateRevision: UInt64 = 0
    private var consumedEditorTitleFocusRequestID: UInt64 = 0
    private weak var launcherWindow: NSWindow?
    private weak var editorWindow: NSWindow?
    private weak var settingsWindow: NSWindow?

    var shouldShowResultsForCurrentQuery: Bool {
        effectiveSearchQuery(from: query) != nil
    }

    func initialLoad() async {
        if let searchQuery = effectiveSearchQuery(from: query) {
            triggerSearch(for: searchQuery)
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

    func registerSettingsWindow(_ window: NSWindow) {
        settingsWindow = window
    }

    func requestEditorTitleFocus() {
        editorTitleFocusRequestID &+= 1
    }

    func consumeEditorTitleFocusRequest() -> Bool {
        guard consumedEditorTitleFocusRequestID != editorTitleFocusRequestID else {
            return false
        }
        consumedEditorTitleFocusRequestID = editorTitleFocusRequestID
        return true
    }

    func beginEditorPresentation() {
        isEditorPresented = true
        launcherWindow?.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    func prepareSettings() {
        settingsErrorMessage = nil
        settingsSuccessMessage = nil
        loadSettingsStorageDirectoryPath()
        reloadSettingsFromDisk()
    }

    func settingsDidOpen() {
        isSettingsPresented = true
        launcherWindow?.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true {
            settingsWindow?.deminiaturize(nil)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func settingsDidClose() {
        guard isSettingsPresented else {
            return
        }

        isSettingsPresented = false
        revealLauncherIfNeeded()
    }

    func loadSettingsStorageDirectoryPath() {
        do {
            settingsStorageDirectoryPath = try RustBridgeClient.loadJsonStorageDirectoryPath()
            settingsErrorMessage = nil
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func reloadSettingsFromDisk() {
        ThemeManager.shared.reloadFromDisk()
        HotKeyManager.shared.reloadFromDisk()
    }

    @discardableResult
    func saveSettingsStorageDirectoryPath() -> Bool {
        do {
            try RustBridgeClient.saveJsonStorageDirectoryPath(settingsStorageDirectoryPath)
            settingsStorageDirectoryPath = try RustBridgeClient.loadJsonStorageDirectoryPath()
            settingsErrorMessage = nil
            settingsSuccessMessage = "Saved."
            return true
        } catch {
            settingsErrorMessage = error.localizedDescription
            settingsSuccessMessage = nil
            return false
        }
    }

    func dismissLauncher() {
        guard let launcherWindow else {
            return
        }

        launcherWindow.orderOut(nil)
        if !isEditorPresented {
            NSApp.hide(nil)
        }
    }

    func revealLauncherIfNeeded() {
        guard !isEditorPresented, !isSettingsPresented, let launcherWindow else {
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
    }

    func toggleLauncherVisibilityFromHotKey() {
        guard !isEditorPresented, !isSettingsPresented, let launcherWindow else {
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
            refreshSearchForCurrentQuery()
            return await open(itemId: itemId)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveCurrentItem() async -> Bool {
        guard var item = selectedItem else {
            return true
        }

        let saveRevision = editorStateRevision
        let localTitleAtSaveStart = item.title
        item.note = editorText
        let referenced = referencedImageKeys(in: editorText)
        item.images.removeAll { !referenced.contains($0.imageKey) }
        selectedItem = item
        let itemId = item.id
        let note = editorText
        let images = item.images

        do {
            let refreshed: EditableItemRecord = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try RustBridgeClient.save(itemId: itemId, note: note, images: images)
                        let refreshed = try RustBridgeClient.fetch(itemId: itemId)
                        continuation.resume(returning: refreshed)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // If the user switched items while this save was in-flight, don't overwrite editor state.
            guard selectedItem?.id == itemId else {
                errorMessage = nil
                refreshSearchForCurrentQuery()
                return true
            }

            if var current = selectedItem, current.id == refreshed.id {
                // Preserve local title edits while syncing backend note/images.
                if current.title == localTitleAtSaveStart {
                    current.title = refreshed.title
                }
                current.images = refreshed.images
                if saveRevision == editorStateRevision {
                    current.note = refreshed.note
                    selectedItem = current
                    editorText = refreshed.note
                } else {
                    current.note = editorText
                    selectedItem = current
                }
            }

            errorMessage = nil
            refreshSearchForCurrentQuery()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameCurrentItem(to title: String) async -> Bool {
        guard var current = selectedItem else {
            return false
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "title must not be empty"
            return false
        }

        guard trimmed != current.title else {
            errorMessage = nil
            return true
        }

        let previousTitle = current.title
        current.title = trimmed
        selectedItem = current

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try RustBridgeClient.rename(itemId: current.id, title: trimmed)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            errorMessage = nil
            refreshSearchForCurrentQuery()
            return true
        } catch {
            if var latest = selectedItem, latest.id == current.id, latest.title == trimmed {
                latest.title = previousTitle
                selectedItem = latest
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: autosaveDebounceNanoseconds)
            guard let self, !Task.isCancelled else {
                return
            }
            _ = await self.saveCurrentItem()
        }
    }

    @discardableResult
    func flushAutosave() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        return await saveCurrentItem()
    }

    func increaseEditorFontSize() {
        setEditorFontSize(editorFontSize + editorFontSizeStep)
    }

    func decreaseEditorFontSize() {
        setEditorFontSize(editorFontSize - editorFontSizeStep)
    }

    private func setEditorFontSize(_ value: CGFloat) {
        let clamped = min(max(value, editorMinFontSize), editorMaxFontSize)
        guard abs(clamped - editorFontSize) > 0.01 else {
            return
        }
        editorFontSize = clamped
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
        _ = await saveCurrentItem()
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

    func deleteItem(itemId: Int64) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try RustBridgeClient.delete(itemId: itemId)
            }.value

            if selectedItem?.id == itemId {
                selectedItem = nil
                editorText = ""
                isEditorPresented = false
            }

            refreshSearchForCurrentQuery()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealItemJsonInFinder(itemId: Int64) {
        do {
            let path = try RustBridgeClient.getJsonPath(itemId: itemId)
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyItemTitle(_ title: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(title, forType: .string)
    }

    func persistEditorState() async {
        _ = await saveCurrentItem()
    }

    private func refreshSearchForCurrentQuery() {
        guard let searchQuery = effectiveSearchQuery(from: query) else {
            return
        }
        triggerSearch(for: searchQuery)
    }

    private func triggerSearch(for searchQuery: String) {
        queuedSearchQuery = searchQuery
        guard !isSearchWorkerRunning else {
            return
        }
        isSearchWorkerRunning = true

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.processQueuedSearches()
        }
    }

    private func processQueuedSearches() async {
        while let currentQuery = queuedSearchQuery {
            queuedSearchQuery = nil
            await Task.yield()
            if queuedSearchQuery != nil {
                continue
            }

            do {
                let fetched = try await Task.detached(priority: .userInitiated) {
                    let limit = currentQuery.isEmpty ? listAllSearchLimit : defaultSearchLimit
                    return try RustBridgeClient.search(query: currentQuery, limit: limit)
                }.value

                guard effectiveSearchQuery(from: query) == .some(currentQuery) else {
                    continue
                }

                if results != fetched {
                    results = fetched
                }
                if errorMessage != nil {
                    errorMessage = nil
                }
            } catch {
                guard effectiveSearchQuery(from: query) == .some(currentQuery) else {
                    continue
                }
                let message = error.localizedDescription
                if errorMessage != message {
                    errorMessage = message
                }
            }
        }

        isSearchWorkerRunning = false
    }

    private func effectiveSearchQuery(from rawQuery: String) -> String? {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return rawQuery == "  " ? "" : nil
        }
        return trimmedQuery
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
