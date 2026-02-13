import AppKit
import SwiftUI

private let imageRefPattern = #"!\[image\]\(alfred://image/([^\)\?]+)(?:\?w=(\d+))?\)"#
private let imageKeyAttribute = NSAttributedString.Key("InlineImageKey")
private let imageWidthAttribute = NSAttributedString.Key("InlineImageWidth")
private let dividerMarkerAttribute = NSAttributedString.Key("EditorDividerMarker")
private let dividerLinePattern = #"(?m)^[ \t]*---[ \t]*$"#
private let styleTokenPattern = #"\[\[b\]\]|\[\[/b\]\]|\[\[fs=(\d+(?:\.\d+)?)\]\]|\[\[/fs\]\]"#
private let boldStyleOpenToken = "[[b]]"
private let boldStyleCloseToken = "[[/b]]"
private let fontSizeStyleOpenPrefix = "[[fs="
private let fontSizeStyleCloseToken = "[[/fs]]"
private let editorDefaultFontSize: CGFloat = 15
private let editorTextColor = NSColor.labelColor
private let resizeHandleSize: CGFloat = 24
private let minImageWidth: CGFloat = 140
private let maxImageWidth: CGFloat = 1200
private let inlineStyleMinFontSize: CGFloat = 11
private let inlineStyleMaxFontSize: CGFloat = 40
private let minimapWidth: CGFloat = 80
private let minimapPadding: CGFloat = 4
private let dividerLineThickness: CGFloat = 1

// MARK: - Minimap Colors (adaptive for light/dark mode)
private var minimapBackgroundColor: NSColor {
    NSColor.systemGray.withAlphaComponent(0.08)
}

private var minimapTextColor: NSColor {
    NSColor.labelColor.withAlphaComponent(0.25)
}

private var minimapSearchHighlightColor: NSColor {
    NSColor.systemYellow.withAlphaComponent(0.8)
}

private var minimapViewportBorderColor: NSColor {
    NSColor.separatorColor
}

private protocol EditorCommandDelegate: AnyObject {
    func increaseDocumentFontSize()
    func decreaseDocumentFontSize()
    func currentSearchQuery() -> String
    func areSearchHighlightsEnabled() -> Bool
}

private func editorFont(for fontSize: CGFloat) -> NSFont {
    NSFont.systemFont(ofSize: fontSize)
}

private func editorBaseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    [
        .font: editorFont(for: fontSize),
        .foregroundColor: editorTextColor,
    ]
}

    // MARK: - Resize drag state

    private struct ImageResizeDragState {
        let attachmentCharIndex: Int
        let imageKey: String
        let originalWidth: CGFloat
        let originalAspectRatio: CGFloat
        let originalImageData: Data
        let mouseDownPoint: NSPoint
        var currentWidth: CGFloat
        let initialRectInView: NSRect
    }

    // MARK: - Resizable NSTextView subclass

    private struct ImageMoveDragState {
        let attachmentCharIndex: Int
        let imageKey: String
        let mouseDownPoint: NSPoint
        var didStartDrag: Bool
    }

    private final class ResizableImageTextView: NSTextView {
        weak var resizeDelegate: ImageResizeDelegate?
        weak var commandDelegate: EditorCommandDelegate?

        private var dragState: ImageResizeDragState?
        private var moveDragState: ImageMoveDragState?
        private var cursorState: CursorOverlay = .none
        private let moveDragThreshold: CGFloat = 5
        
        // MARK: - First Responder
        
        override var acceptsFirstResponder: Bool {
            return true
        }
        
        override func becomeFirstResponder() -> Bool {
            return super.becomeFirstResponder()
        }
        
        // MARK: - Paste Handling (Normalize to Plain Text)
        
        override func paste(_ sender: Any?) {
            // Normalize pasted content to plain text, stripping HTML/tables/formatting
            if let plainText = normalizedPlainTextFromPasteboard() {
                insertNormalizedText(plainText)
            } else {
                super.paste(sender)
            }
        }
        
        override func pasteAsPlainText(_ sender: Any?) {
            if let plainText = normalizedPlainTextFromPasteboard() {
                insertNormalizedText(plainText)
            } else {
                super.pasteAsPlainText(sender)
            }
        }
        
        override func pasteAsRichText(_ sender: Any?) {
            // Force paste as plain text even when rich text is requested
            pasteAsPlainText(sender)
        }

        override func keyDown(with event: NSEvent) {
            if handleEditorShortcut(event) {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if handleEditorShortcut(event) {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        @objc func toggleBoldface(_ sender: Any?) {
            _ = toggleBoldForSelection()
        }

        @objc func makeTextLarger(_ sender: Any?) {
            _ = adjustFontSize(delta: 1)
        }

        @objc func makeTextSmaller(_ sender: Any?) {
            _ = adjustFontSize(delta: -1)
        }

        override func changeFont(_ sender: Any?) {
            guard let manager = sender as? NSFontManager else {
                return
            }
            applyFontTransform { current in
                manager.convert(current)
            }
        }

        private func handleEditorShortcut(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])

            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "b" {
                return toggleBoldForSelection()
            }

            if modifiers == [.command] || modifiers == [.command, .shift] {
                if isIncreaseFontShortcut(event) {
                    return adjustFontSize(delta: 1)
                }
                if isDecreaseFontShortcut(event) {
                    return adjustFontSize(delta: -1)
                }
            }
            
            // Option+Up/Down to navigate to previous/next search match
            if modifiers == [.option] {
                if event.keyCode == 126 { // Up arrow
                    return navigateToSearchMatch(direction: .previous)
                }
                if event.keyCode == 125 { // Down arrow
                    return navigateToSearchMatch(direction: .next)
                }
            }

            return false
        }
        
        /// Read content from pasteboard and extract plain text
        private func normalizedPlainTextFromPasteboard() -> String? {
            let pasteboard = NSPasteboard.general
            
            // First try to get plain string directly
            if let plainString = pasteboard.string(forType: .string), !plainString.isEmpty {
                return normalizePastedText(plainString)
            }
            
            // If only attributed string is available, extract plain text
            if let attributedString = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString {
                let plainText = attributedString.string
                return plainText.isEmpty ? nil : normalizePastedText(plainText)
            }
            
            return nil
        }
        
        /// Insert normalized text safely, preserving undo stack
        private func insertNormalizedText(_ text: String) {
            guard !text.isEmpty else { return }
            
            // Use standard insertText which respects the selected range and undo manager
            // We wrap this in an undo grouping for cleaner undo behavior
            let range = selectedRange()
            
            // Check if we should break undo coalescing
            if range.length > 0 {
                // Replacing selection - break coalescing
                breakUndoCoalescing()
            }
            
            insertText(text, replacementRange: range)
        }

        private func isIncreaseFontShortcut(_ event: NSEvent) -> Bool {
            if event.keyCode == 24 || event.keyCode == 69 {
                return true
            }

            guard let chars = event.charactersIgnoringModifiers else {
                return false
            }
            return chars == "=" || chars == "+"
        }

        private func isDecreaseFontShortcut(_ event: NSEvent) -> Bool {
            if event.keyCode == 27 || event.keyCode == 78 {
                return true
            }

            guard let chars = event.charactersIgnoringModifiers else {
                return false
            }
            return chars == "-"
        }

        private func toggleBoldForSelection() -> Bool {
            let range = selectedRange()
            guard let storage = textStorage else {
                return true
            }

            if range.length == 0 {
                let currentFont = (typingAttributes[.font] as? NSFont) ?? font ?? editorFont(for: editorDefaultFontSize)
                let nextFont = fontBySettingBold(currentFont, enabled: !fontIsBold(currentFont))
                typingAttributes[.font] = nextFont
                typingAttributes[.foregroundColor] = editorTextColor
                return true
            }

            let shouldApplyBold = !selectionIsFullyBold(in: range, storage: storage)
            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { attrs, attrRange, _ in
                if attrs[.attachment] != nil {
                    return
                }

                let currentFont = (attrs[.font] as? NSFont) ?? self.font ?? editorFont(for: editorDefaultFontSize)
                let nextFont = fontBySettingBold(currentFont, enabled: shouldApplyBold)
                storage.addAttribute(.font, value: nextFont, range: attrRange)
                storage.addAttribute(.foregroundColor, value: editorTextColor, range: attrRange)
            }
            storage.endEditing()
            didChangeText()
            return true
        }

        private func selectionIsFullyBold(in range: NSRange, storage: NSTextStorage) -> Bool {
            var sawText = false
            var allBold = true
            storage.enumerateAttributes(in: range, options: []) { attrs, _, stop in
                if attrs[.attachment] != nil {
                    return
                }
                sawText = true
                let currentFont = (attrs[.font] as? NSFont) ?? self.font ?? editorFont(for: editorDefaultFontSize)
                if !fontIsBold(currentFont) {
                    allBold = false
                    stop.pointee = true
                }
            }
            return sawText && allBold
        }

        private func adjustFontSize(delta: CGFloat) -> Bool {
            let range = selectedRange()
            if range.length == 0 {
                if delta > 0 {
                    commandDelegate?.increaseDocumentFontSize()
                } else {
                    commandDelegate?.decreaseDocumentFontSize()
                }
                return true
            }

            applyFontTransform { currentFont in
                let nextSize = min(max(currentFont.pointSize + delta, inlineStyleMinFontSize), inlineStyleMaxFontSize)
                return NSFont(descriptor: currentFont.fontDescriptor, size: nextSize)
                    ?? NSFont.systemFont(ofSize: nextSize, weight: fontIsBold(currentFont) ? .bold : .regular)
            }
            return true
        }

        private func applyFontTransform(_ transform: (NSFont) -> NSFont) {
            guard let storage = textStorage else {
                return
            }

            let range = selectedRange()
            if range.length == 0 {
                let currentFont = (typingAttributes[.font] as? NSFont) ?? font ?? editorFont(for: editorDefaultFontSize)
                let nextFont = transform(currentFont)
                typingAttributes[.font] = nextFont
                typingAttributes[.foregroundColor] = editorTextColor
                return
            }

            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { attrs, attrRange, _ in
                if attrs[.attachment] != nil {
                    return
                }

                let currentFont = (attrs[.font] as? NSFont) ?? self.font ?? editorFont(for: editorDefaultFontSize)
                let nextFont = transform(currentFont)
                storage.addAttribute(.font, value: nextFont, range: attrRange)
                storage.addAttribute(.foregroundColor, value: editorTextColor, range: attrRange)
            }
            storage.endEditing()
            didChangeText()
        }
        
        /// Normalize pasted text: strip formatting, normalize whitespace, remove HTML artifacts
        private func normalizePastedText(_ text: String) -> String {
            var result = text
            
            // Step 1: Remove common HTML/XML tags and their content (like tables, scripts)
            result = stripHTMLTags(result)
            
            // Step 2: Decode common HTML entities
            result = decodeHTMLEntities(result)
            
            // Step 3: Normalize whitespace
            result = normalizeWhitespace(result)
            
            // Step 4: Remove control characters except tab and newline
            result = stripControlCharacters(result)
            
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        /// Strip HTML tags from text
        private func stripHTMLTags(_ text: String) -> String {
            // Remove content within <script>, <style>, <table> tags (including the tags themselves)
            var result = text
            let tagPatterns = [
                "<script[^>]*>.*?</script>",
                "<style[^>]*>.*?</style>",
                "<table[^>]*>.*?</table>",
                "<thead[^>]*>.*?</thead>",
                "<tbody[^>]*>.*?</tbody>",
                "<tfoot[^>]*>.*?</tfoot>",
                "<tr[^>]*>.*?</tr>",
            ]
            
            for pattern in tagPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                    result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "\n")
                }
            }
            
            // Remove remaining HTML tags
            if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
                result = tagRegex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: " ")
            }
            
            return result
        }
        
        /// Decode common HTML entities
        private func decodeHTMLEntities(_ text: String) -> String {
            var result = text
            let entities: [(String, String)] = [
                ("&amp;", "&"),
                ("&lt;", "<"),
                ("&gt;", ">"),
                ("&quot;", "\""),
                ("&#39;", "'"),
                ("&nbsp;", " "),
                ("&#160;", " "),
                ("&#x20;", " "),
                ("&#xA0;", " "),
                ("&#10;", "\n"),
                ("&#13;", ""),
                ("&#x0A;", "\n"),
                ("&#x0D;", ""),
            ]
            
            for (entity, replacement) in entities {
                result = result.replacingOccurrences(of: entity, with: replacement)
            }
            
            // Handle numeric entities like &#123;
            result = decodeNumericEntities(result)
            
            // Handle hex entities like &#x7B;
            result = decodeHexEntities(result)
            
            return result
        }
        
        /// Normalize whitespace: collapse multiple spaces/newlines
        private func normalizeWhitespace(_ text: String) -> String {
            var result = text
            
            // Normalize line endings to \n
            result = result.replacingOccurrences(of: "\r\n", with: "\n")
            result = result.replacingOccurrences(of: "\r", with: "\n")
            
            // Collapse horizontal whitespace (tabs, non-breaking spaces, etc.) to single space
            let horizontalWhitespace = CharacterSet.whitespaces.subtracting(.newlines)
            let components = result.components(separatedBy: horizontalWhitespace)
            result = components.filter { !$0.isEmpty }.joined(separator: " ")
            
            // Collapse multiple spaces
            while result.contains("  ") {
                result = result.replacingOccurrences(of: "  ", with: " ")
            }
            
            // Collapse 3+ consecutive newlines into 2 newlines (preserve paragraph breaks)
            while result.contains("\n\n\n") {
                result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            
            return result
        }
        
        /// Decode numeric HTML entities like &#123;
        private func decodeNumericEntities(_ text: String) -> String {
            var result = text
            let pattern = "&#(\\d+);"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return result
            }
            
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: result.utf16.count))
            // Process matches in reverse order to maintain string indices
            for match in matches.reversed() {
                guard let numberRange = Range(match.range(at: 1), in: result),
                      let code = Int(result[numberRange]),
                      let scalar = UnicodeScalar(code) else {
                    continue
                }
                let replacement = String(Character(scalar))
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: replacement)
                }
            }
            return result
        }
        
        /// Decode hex HTML entities like &#x7B;
        private func decodeHexEntities(_ text: String) -> String {
            var result = text
            let pattern = "&#x([0-9A-Fa-f]+);"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return result
            }
            
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: result.utf16.count))
            // Process matches in reverse order to maintain string indices
            for match in matches.reversed() {
                guard let hexRange = Range(match.range(at: 1), in: result),
                      let code = Int(result[hexRange], radix: 16),
                      let scalar = UnicodeScalar(code) else {
                    continue
                }
                let replacement = String(Character(scalar))
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: replacement)
                }
            }
            return result
        }
        
        /// Remove control characters except tab and newline
        private func stripControlCharacters(_ text: String) -> String {
            var allowed = CharacterSet.whitespacesAndNewlines
            allowed.formUnion(.alphanumerics)
            allowed.formUnion(.punctuationCharacters)
            allowed.formUnion(.symbols)
            allowed.formUnion(.decimalDigits)
            allowed.formUnion(.letters)
            // Include international characters
            allowed.formUnion( CharacterSet(charactersIn: "\u{0080}"..."\u{FFFF}") )
            
            return text.unicodeScalars.filter { scalar in
                if scalar.value < 32 {
                    // Allow tab (9) and newline (10)
                    return scalar.value == 9 || scalar.value == 10
                }
                return allowed.contains(scalar)
            }.map(String.init).joined()
        }

        private enum CursorOverlay {
            case none
            case resizeHandle
            case imageBody
        }

        // MARK: Drawing Override for Resize Overlay

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            if let state = dragState {
                let currentWidth = state.currentWidth
                let height = currentWidth / state.originalAspectRatio
                
                // Calculate new rect maintaining top-left origin
                let newRect = NSRect(
                    origin: state.initialRectInView.origin,
                    size: NSSize(width: currentWidth, height: height)
                )

                // Draw resize border (hollow square)
                let path = NSBezierPath(rect: newRect)
                path.lineWidth = 1.5
                
                // Use a high-contrast color depending on appearance
                let overlayColor = NSColor.controlAccentColor
                overlayColor.setStroke()
                
                // Dash pattern for visibility
                let dashPattern: [CGFloat] = [6.0, 4.0]
                path.setLineDash(dashPattern, count: 2, phase: 0.0)
                path.stroke()

                // Draw resize handle at bottom-right of the new rect
                let handleSize: CGFloat = 10
                let handleRect = NSRect(
                    x: newRect.maxX - handleSize,
                    y: newRect.maxY - handleSize,
                    width: handleSize,
                    height: handleSize
                )
                
                let handlePath = NSBezierPath(rect: handleRect)
                overlayColor.setFill()
                handlePath.fill()
            }
        }

        // MARK: Hit-testing helpers

        /// Checks if the point is on any image attachment and returns its char index and key.
        private func imageAttachmentAt(point: NSPoint) -> (charIndex: Int, imageKey: String)? {
            guard let layoutManager = layoutManager,
                  let textContainer = textContainer,
                  let storage = textStorage
            else {
                return nil
            }

            let charIndex = layoutManager.characterIndex(
                for: point,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            guard charIndex < storage.length else {
                return nil
            }

            let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
            guard let key = attrs[imageKeyAttribute] as? String,
                  attrs[.attachment] is NSTextAttachment
            else {
                return nil
            }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let rectInView = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

            guard rectInView.contains(point) else {
                return nil
            }

            return (charIndex, key)
        }

        /// Returns the character index and attachment rect for an image attachment at the given point, if
        /// the point falls within the resize handle zone (bottom-right corner of the image).
        private func imageResizeHitTest(at point: NSPoint) -> (charIndex: Int, imageKey: String, width: Int, rect: NSRect)? {
            guard let layoutManager = layoutManager,
                  let textContainer = textContainer,
                  let storage = textStorage
            else {
                return nil
            }

            let charIndex = layoutManager.characterIndex(
                for: point,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            guard charIndex < storage.length else {
                return nil
            }

            let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
            guard let key = attrs[imageKeyAttribute] as? String,
                  attrs[.attachment] is NSTextAttachment
            else {
                return nil
            }

            // Use stored width if available, otherwise fall back to rendered width
            let width: Int
            if let stored = attrs[imageWidthAttribute] as? Int {
                width = stored
            } else {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                width = Int(rect.width.rounded())
            }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
            let attachmentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let rectInView = attachmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

            // Check if point is inside the attachment rect
            guard rectInView.contains(point) else {
                return nil
            }

            // Check if point is within the bottom-right corner resize handle
            let handleZone = NSRect(
                x: rectInView.maxX - resizeHandleSize,
                y: rectInView.maxY - resizeHandleSize,
                width: resizeHandleSize,
                height: resizeHandleSize
            )

            guard handleZone.contains(point) else {
                return nil
            }

            return (charIndex, key, width, rectInView)
        }

        // MARK: Mouse events

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)

            if imageResizeHitTest(at: point) != nil {
                if cursorState != .resizeHandle {
                    if cursorState != .none { NSCursor.pop() }
                    cursorState = .resizeHandle
                    NSCursor.crosshair.push() // Or resizeLeftRight if preferred
                }
            } else if imageAttachmentAt(point: point) != nil {
                if cursorState != .imageBody {
                    if cursorState != .none { NSCursor.pop() }
                    cursorState = .imageBody
                    NSCursor.openHand.push()
                }
            } else {
                if cursorState != .none {
                    NSCursor.pop()
                    cursorState = .none
                }
            }

            super.mouseMoved(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)

            // Priority 1: Resize handle click
            if let hit = imageResizeHitTest(at: point),
               let imageData = resizeDelegate?.originalImageData(forKey: hit.imageKey) {
                
                let originalWidth = CGFloat(hit.width)
                // Calculate aspect ratio from current rect
                let ratio = hit.rect.width / max(1, hit.rect.height)
                
                dragState = ImageResizeDragState(
                    attachmentCharIndex: hit.charIndex,
                    imageKey: hit.imageKey,
                    originalWidth: originalWidth,
                    originalAspectRatio: ratio,
                    originalImageData: imageData,
                    mouseDownPoint: point,
                    currentWidth: originalWidth,
                    initialRectInView: hit.rect
                )
                
                // Show resize cursor
                NSCursor.closedHand.push()
                // Trigger redraw to show overlay
                self.needsDisplay = true
                return
            }

            // Priority 2: Image body click → start potential move
            if let hit = imageAttachmentAt(point: point) {
                moveDragState = ImageMoveDragState(
                    attachmentCharIndex: hit.charIndex,
                    imageKey: hit.imageKey,
                    mouseDownPoint: point,
                    didStartDrag: false
                )
                // Select the attachment so it's visually highlighted
                setSelectedRange(NSRange(location: hit.charIndex, length: 1))
                return
            }

            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            // Resize drag
            if var state = dragState {
                let point = convert(event.locationInWindow, from: nil)
                let deltaX = point.x - state.mouseDownPoint.x
                let deltaY = point.y - state.mouseDownPoint.y
                let diagonalDelta = (deltaX + deltaY) / 2.0
                
                let newWidth = min(max(state.originalWidth + diagonalDelta, minImageWidth), maxImageWidth)
                state.currentWidth = newWidth
                dragState = state
                
                // Invalidate display to update overlay
                self.needsDisplay = true
                return
            }

            // Move drag
            if moveDragState != nil {
                let point = convert(event.locationInWindow, from: nil)
                let distance = hypot(point.x - moveDragState!.mouseDownPoint.x, point.y - moveDragState!.mouseDownPoint.y)

                if distance > moveDragThreshold {
                    if !moveDragState!.didStartDrag {
                        moveDragState!.didStartDrag = true
                        NSCursor.closedHand.push()
                    }

                    // Show insertion point at current mouse position
                    guard let layoutManager = layoutManager, let textContainer = textContainer else { return }
                    let adjustedPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
                    let insertIndex = layoutManager.characterIndex(
                        for: adjustedPoint,
                        in: textContainer,
                        fractionOfDistanceBetweenInsertionPoints: nil
                    )
                    let safeIndex = max(0, min(insertIndex, (textStorage?.length ?? 0)))
                    setSelectedRange(NSRange(location: safeIndex, length: 0))
                }
                return
            }

            super.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            // Resize complete
            if let state = dragState {
                // Apply final resize
                updateImageAttachment(state: state, newWidth: state.currentWidth)
                
                dragState = nil
                NSCursor.pop() // Pop the closedHand cursor pushed in mouseDown
                self.needsDisplay = true // Remove overlay
                resizeDelegate?.imageDidResize()
                return
            }

            // Move complete
            if let moveState = moveDragState {
                moveDragState = nil

                if moveState.didStartDrag {
                    NSCursor.pop()

                    let point = convert(event.locationInWindow, from: nil)
                    guard let layoutManager = layoutManager, let textContainer = textContainer else { return }
                    let adjustedPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
                    let dropIndex = layoutManager.characterIndex(
                        for: adjustedPoint,
                        in: textContainer,
                        fractionOfDistanceBetweenInsertionPoints: nil
                    )
                    let safeDropIndex = max(0, min(dropIndex, (textStorage?.length ?? 0)))

                    // Only move if dropped at a different position
                    if safeDropIndex != moveState.attachmentCharIndex && safeDropIndex != moveState.attachmentCharIndex + 1 {
                        moveImageAttachment(from: moveState.attachmentCharIndex, to: safeDropIndex)
                        resizeDelegate?.imageDidResize()
                    }
                }
                return
            }

            super.mouseUp(with: event)
        }

    override func mouseExited(with event: NSEvent) {
        if cursorState != .none {
            NSCursor.pop()
            cursorState = .none
        }
        super.mouseExited(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Add a tracking area covering the whole text view
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: Prevent default attachment drag-and-drop

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Disable the default NSTextView drag-and-drop for attachments
        return []
    }

    // MARK: Image resize

    private func updateImageAttachment(state: ImageResizeDragState, newWidth: CGFloat) {
        guard let storage = textStorage,
              state.attachmentCharIndex < storage.length
        else {
            return
        }

        let attrs = storage.attributes(at: state.attachmentCharIndex, effectiveRange: nil)
        guard attrs[imageKeyAttribute] as? String == state.imageKey else {
            return
        }

        guard let originalImage = NSImage(data: state.originalImageData) else {
            return
        }

        let resized = resizedImage(originalImage, targetWidth: newWidth)
        let framed = imageWithBorder(resized)
        let attachment = NSTextAttachment()
        attachment.image = framed
        attachment.bounds = NSRect(origin: .zero, size: framed.size)

        let range = NSRange(location: state.attachmentCharIndex, length: 1)

        storage.beginEditing()
        let attachmentString = NSMutableAttributedString(attachment: attachment)
        attachmentString.addAttributes([
            imageKeyAttribute: state.imageKey,
            imageWidthAttribute: Int(newWidth.rounded()),
        ], range: NSRange(location: 0, length: attachmentString.length))
        storage.replaceCharacters(in: range, with: attachmentString)
        storage.endEditing()
    }

    // MARK: Image move

    private func moveImageAttachment(from sourceIndex: Int, to rawDestIndex: Int) {
        guard let storage = textStorage,
              sourceIndex < storage.length
        else {
            return
        }

        // Copy the attachment's attributed string (with all custom attributes)
        let attachmentAttrStr = storage.attributedSubstring(from: NSRange(location: sourceIndex, length: 1))

        // Remove the attachment from the old position
        storage.beginEditing()
        storage.deleteCharacters(in: NSRange(location: sourceIndex, length: 1))

        // Adjust destination index since we removed a character
        var destIndex = rawDestIndex
        if destIndex > sourceIndex {
            destIndex -= 1
        }
        destIndex = max(0, min(destIndex, storage.length))

        // Insert at the new position
        storage.insert(attachmentAttrStr, at: destIndex)
        storage.endEditing()

        // Place cursor after the moved image
        let cursorPos = min(destIndex + 1, storage.length)
        setSelectedRange(NSRange(location: cursorPos, length: 0))
    }
    
    // MARK: - Search Navigation
    
    private enum SearchDirection {
        case previous
        case next
    }
    
    /// Navigate to previous or next search match
    private func navigateToSearchMatch(direction: SearchDirection) -> Bool {
        guard let textView = self as NSTextView?,
              let searchQuery = commandDelegate?.currentSearchQuery(),
              !searchQuery.isEmpty else {
            return false
        }
        
        let text = textView.string
        let currentRange = textView.selectedRange()
        let searchLower = searchQuery.lowercased()
        let textLower = text.lowercased()
        
        // Find all match ranges
        var matches: [NSRange] = []
        var searchStart = textLower.startIndex
        
        while let range = textLower.range(of: searchLower, range: searchStart..<textLower.endIndex) {
            let location = textLower.distance(from: textLower.startIndex, to: range.lowerBound)
            let length = searchLower.count
            matches.append(NSRange(location: location, length: length))
            searchStart = range.upperBound
        }
        
        guard !matches.isEmpty else { return false }
        
        // Find the current match index (based on cursor position)
        let cursorPos = currentRange.location
        var currentMatchIndex = 0
        
        for (index, match) in matches.enumerated() {
            if match.location > cursorPos {
                currentMatchIndex = index
                break
            }
            currentMatchIndex = index + 1
        }
        
        // Calculate target match index with cyclic wrapping
        let targetIndex: Int
        switch direction {
        case .next:
            targetIndex = currentMatchIndex % matches.count
        case .previous:
            targetIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        }
        
        let targetMatch = matches[targetIndex]
        
        // Select the match and scroll to it
        textView.setSelectedRange(targetMatch)
        textView.scrollRangeToVisible(targetMatch)
        
        // Provide visual feedback by briefly highlighting when enabled.
        if commandDelegate?.areSearchHighlightsEnabled() ?? true {
            highlightMatchTemporarily(range: targetMatch, in: textView)
        }
        
        return true
    }
    
    /// Briefly highlight a match to show where we navigated to
    private func highlightMatchTemporarily(range: NSRange, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        
        let highlightColor = NSColor.systemYellow.withAlphaComponent(0.3)
        let originalBg = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        
        // Apply highlight
        storage.addAttribute(.backgroundColor, value: highlightColor, range: range)
        
        // Remove highlight after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard self != nil else { return }
            
            // Only remove if the range is still valid
            if range.location + range.length <= storage.length {
                if let originalBg = originalBg {
                    storage.addAttribute(.backgroundColor, value: originalBg, range: range)
                } else {
                    storage.removeAttribute(.backgroundColor, range: range)
                }
            }
        }
    }
}

// MARK: - Minimap View

/// A beautiful mini map that shows document overview with search result highlights
fileprivate final class EditorMinimapView: NSView {
    weak var textView: NSTextView?
    var searchQuery: String = ""
    var highlightSearchMatches: Bool = true
    
    // Cached line data for efficient rendering
    private var lineData: [(y: CGFloat, height: CGFloat, hasSearchMatch: Bool)] = []
    private var lastTextHash: Int = 0
    private var lastQuery: String = ""
    private var lastHighlightSearchMatches = true
    private var lastContainerWidth: CGFloat = 0
    private var viewportDragOffsetFromTop: CGFloat?
    
    // Visual constants
    private let scaleFactor: CGFloat = 0.15
    private let lineSpacing: CGFloat = 1.2
    private let maxRenderedLines = 200
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: 1)
        layer?.shadowRadius = 2
        layer?.shadowOpacity = 0.08
    }
    
    override var isFlipped: Bool {
        return false
    }
    
    /// Update line data when text or search query changes
    func invalidateCache() {
        lastTextHash = 0
        lastQuery = ""
        lastHighlightSearchMatches = true
        lastContainerWidth = 0
        needsDisplay = true
    }
    
    private func updateLineDataIfNeeded() {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }
        
        layoutManager.ensureLayout(for: textContainer)
        
        let text = textView.string
        let currentHash = text.hash
        let queryChanged = searchQuery != lastQuery
        let highlightStateChanged = highlightSearchMatches != lastHighlightSearchMatches
        let containerWidth = textContainer.containerSize.width
        let widthChanged = abs(containerWidth - lastContainerWidth) > 0.5
        
        // Only rebuild if necessary
        guard currentHash != lastTextHash || queryChanged || highlightStateChanged || widthChanged else { return }
        
        lastTextHash = currentHash
        lastQuery = searchQuery
        lastHighlightSearchMatches = highlightSearchMatches
        lastContainerWidth = containerWidth
        
        let fullText = text as NSString
        let searchTerms = highlightSearchMatches ? searchQuery
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty } : []
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        
        var generated: [(y: CGFloat, height: CGFloat, hasSearchMatch: Bool)] = []
        generated.reserveCapacity(min(maxRenderedLines, max(1, glyphRange.length / 8)))
        
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            let lineCharRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            var hasMatch = false
            
            if !searchTerms.isEmpty,
               lineCharRange.length > 0,
               NSMaxRange(lineCharRange) <= fullText.length {
                let lineText = fullText.substring(with: lineCharRange).lowercased()
                hasMatch = searchTerms.contains { lineText.contains($0) }
            }
            
            generated.append((
                y: usedRect.minY,
                height: max(1, usedRect.height),
                hasSearchMatch: hasMatch
            ))
        }
        
        if generated.isEmpty {
            generated.append((y: 0, height: 2, hasSearchMatch: false))
        }
        
        if generated.count > maxRenderedLines {
            let step = Double(generated.count) / Double(maxRenderedLines)
            var sampled: [(y: CGFloat, height: CGFloat, hasSearchMatch: Bool)] = []
            sampled.reserveCapacity(maxRenderedLines + 1)
            
            var cursor = 0.0
            for _ in 0..<maxRenderedLines {
                let idx = min(Int(cursor), generated.count - 1)
                sampled.append(generated[idx])
                cursor += step
            }
            
            if let last = generated.last, sampled.last?.y != last.y {
                sampled.append(last)
            }
            lineData = sampled
        } else {
            lineData = generated
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let _ = NSGraphicsContext.current?.cgContext,
              let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        
        // Update cached data
        updateLineDataIfNeeded()
        
        // Draw background
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        minimapBackgroundColor.setFill()
        bgPath.fill()
        
        // Calculate document proportions
        let documentHeight = max(layoutManager.usedRect(for: textContainer).height, textView.bounds.height)
        let visibleRect = textView.enclosingScrollView?.contentView.documentVisibleRect ?? textView.visibleRect
        let totalContentHeight = max(documentHeight, visibleRect.maxY)
        
        // Scale factor to fit document into minimap
        let heightScale = (bounds.height - minimapPadding * 2) / max(totalContentHeight, 1)
        
        // Draw text lines as tiny bars based on actual text layout positions.
        for line in lineData {
            let y = minimapPadding + line.y * heightScale
            let height = max(1, line.height * heightScale * scaleFactor + lineSpacing)
            
            if y + height < 0 || y > bounds.height {
                continue // Clip lines outside visible area
            }
            
            let rect = CGRect(
                x: minimapPadding,
                y: bounds.height - y - height,
                width: bounds.width - minimapPadding * 2,
                height: height
            )
            
            if line.hasSearchMatch {
                // Draw search match with glow effect
                let glowRect = rect.insetBy(dx: -1, dy: -1)
                let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: 1.5, yRadius: 1.5)
                minimapSearchHighlightColor.withAlphaComponent(0.3).setFill()
                glowPath.fill()
                
                minimapSearchHighlightColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            } else {
                // Draw normal line
                minimapTextColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
        
        // Draw viewport indicator (where user is currently looking)
        let viewportY = visibleRect.origin.y * heightScale
        let viewportHeight = visibleRect.height * heightScale
        let viewportRect = CGRect(
            x: 1,
            y: bounds.height - minimapPadding - viewportY - viewportHeight,
            width: bounds.width - 2,
            height: max(4, viewportHeight)
        )
        
        // Viewport border
        minimapViewportBorderColor.setStroke()
        let viewportPath = NSBezierPath(roundedRect: viewportRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        viewportPath.lineWidth = 1
        viewportPath.stroke()
        
        // Semi-transparent fill for viewport
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: viewportRect, xRadius: 3, yRadius: 3).fill()
    }
    
    // MARK: - Mouse Interaction
    
    override func mouseDown(with event: NSEvent) {
        guard let metrics = minimapInteractionMetrics() else {
            return
        }
        let clickYFromTop = clickYFromTop(for: event)
        let isInsideViewport = clickYFromTop >= metrics.viewportTopFromTop &&
            clickYFromTop <= metrics.viewportTopFromTop + metrics.viewportHeight
        let relativeToViewportTop = clickYFromTop - metrics.viewportTopFromTop
        let dragOffset = min(max(relativeToViewportTop, 0), metrics.viewportHeight)
        viewportDragOffsetFromTop = dragOffset
        // Do not move on initial click when grabbing the viewport; move only on drag.
        if isInsideViewport {
            return
        }
        scrollViewport(toClickYFromTop: clickYFromTop, dragOffsetFromTop: dragOffset, metrics: metrics)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let dragOffset = viewportDragOffsetFromTop,
              let metrics = minimapInteractionMetrics() else {
            return
        }
        scrollViewport(
            toClickYFromTop: clickYFromTop(for: event),
            dragOffsetFromTop: dragOffset,
            metrics: metrics
        )
    }

    override func mouseUp(with event: NSEvent) {
        viewportDragOffsetFromTop = nil
    }

    private struct MinimapInteractionMetrics {
        let clipView: NSClipView
        let scrollView: NSScrollView
        let viewportHeight: CGFloat
        let viewportTopFromTop: CGFloat
        let heightScale: CGFloat
        let maxOffsetY: CGFloat
    }

    private func clickYFromTop(for event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return bounds.height - point.y
    }

    private func minimapInteractionMetrics() -> MinimapInteractionMetrics? {
        guard let textView = textView,
              let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return nil }

        layoutManager.ensureLayout(for: textContainer)

        let documentHeight = max(layoutManager.usedRect(for: textContainer).height, textView.bounds.height)
        let clipView = scrollView.contentView
        let visibleRect = clipView.documentVisibleRect
        let totalContentHeight = max(documentHeight, visibleRect.maxY)
        let heightScale = (bounds.height - minimapPadding * 2) / max(totalContentHeight, 1)
        guard heightScale > 0 else { return nil }

        let viewportHeight = max(4, visibleRect.height * heightScale)
        let viewportTopFromTop = minimapPadding + visibleRect.origin.y * heightScale
        let maxOffsetY = max(0, documentHeight - visibleRect.height)

        return MinimapInteractionMetrics(
            clipView: clipView,
            scrollView: scrollView,
            viewportHeight: viewportHeight,
            viewportTopFromTop: viewportTopFromTop,
            heightScale: heightScale,
            maxOffsetY: maxOffsetY
        )
    }

    private func scrollViewport(
        toClickYFromTop clickYFromTop: CGFloat,
        dragOffsetFromTop: CGFloat,
        metrics: MinimapInteractionMetrics
    ) {
        let rawTopFromTop = clickYFromTop - dragOffsetFromTop
        let minTopFromTop = minimapPadding
        let maxTopFromTop = max(minTopFromTop, bounds.height - minimapPadding - metrics.viewportHeight)
        let clampedTopFromTop = min(max(rawTopFromTop, minTopFromTop), maxTopFromTop)

        let rawDocumentOffset = (clampedTopFromTop - minimapPadding) / metrics.heightScale
        let clampedDocumentOffset = min(max(0, rawDocumentOffset), metrics.maxOffsetY)

        metrics.clipView.scroll(to: NSPoint(x: 0, y: clampedDocumentOffset))
        metrics.scrollView.reflectScrolledClipView(metrics.clipView)
        needsDisplay = true
    }
}

// MARK: - Resize delegate protocol

private protocol ImageResizeDelegate: AnyObject {
    func originalImageData(forKey key: String) -> Data?
    func imageDidResize()
}

struct InlineImageTextEditor: NSViewRepresentable {
    @Binding var text: String
    var imagesByKey: [String: Data]
    var searchQuery: String = ""
    var highlightSearchMatches: Bool = true
    var dividerColor: Color = Color(red: 0.72, green: 0.86, blue: 0.98)
    var dividerTopMargin: CGFloat = 6
    var dividerBottomMargin: CGFloat = 6
    var defaultImageWidth: CGFloat = 360
    var fontSize: CGFloat = editorDefaultFontSize
    var onIncreaseDocumentFontSize: (() -> Void)?
    var onDecreaseDocumentFontSize: (() -> Void)?
    var onSelectionChange: ((Int?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = ResizableImageTextView()
        textView.delegate = context.coordinator
        textView.resizeDelegate = context.coordinator
        textView.commandDelegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        // Note: isRichText is left as default (true) to allow formatting.
        // Paste normalization (see paste(_:) overrides) handles stripping unwanted HTML.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.importsGraphics = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        applyEditorTypingAppearance(to: textView, fontSize: fontSize)
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        
        // Register for plain text paste types only (prevents rich content/HTML pasting)
        textView.registerForDraggedTypes([])  // Disable drag-and-drop of rich content

        scrollView.documentView = textView
        container.addSubview(scrollView)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        
        // Create and configure minimap
        let minimap = EditorMinimapView(frame: NSRect(x: 0, y: 0, width: minimapWidth, height: 0))
        minimap.textView = textView
        minimap.searchQuery = searchQuery
        minimap.highlightSearchMatches = highlightSearchMatches
        minimap.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(minimap)
        
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: minimap.leadingAnchor, constant: -8),

            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimap.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            minimap.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            minimap.widthAnchor.constraint(equalToConstant: minimapWidth),
        ])
        
        // Store minimap reference in coordinator for updates
        context.coordinator.minimapView = minimap
        
        // Setup scroll notification to update minimap viewport indicator
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        
        context.coordinator.renderIfNeeded(force: true)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.renderIfNeeded(force: false)
        
        // Update minimap search query
        context.coordinator.minimapView?.searchQuery = searchQuery
        context.coordinator.minimapView?.highlightSearchMatches = highlightSearchMatches
        context.coordinator.minimapView?.invalidateCache()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        let observedContentView = coordinator.scrollView?.contentView
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: observedContentView
        )
        coordinator.textView = nil
        coordinator.scrollView = nil
        coordinator.minimapView = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate, ImageResizeDelegate, EditorCommandDelegate {
        var parent: InlineImageTextEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        fileprivate weak var minimapView: EditorMinimapView?

        private var isApplyingProgrammaticUpdate = false
        private var lastRenderedText: String = ""
        private var lastRenderedQuery: String = ""
        private var lastImageSignature: Int = 0
        private var lastRenderedFontSize: CGFloat = editorDefaultFontSize
        private var lastRenderedHighlightState = true
        private var lastRenderedDividerStyleSignature: Int = 0
        private var lastRenderedContainerWidth: CGFloat = 0

        init(parent: InlineImageTextEditor) {
            self.parent = parent
        }
        
        // MARK: Scroll Handling
        
        @objc func textViewDidScroll(_ notification: Notification) {
            minimapView?.needsDisplay = true
        }

        // MARK: ImageResizeDelegate

        func originalImageData(forKey key: String) -> Data? {
            parent.imagesByKey[key]
        }

        func increaseDocumentFontSize() {
            parent.onIncreaseDocumentFontSize?()
        }

        func decreaseDocumentFontSize() {
            parent.onDecreaseDocumentFontSize?()
        }
        
        func currentSearchQuery() -> String {
            return parent.searchQuery
        }

        func areSearchHighlightsEnabled() -> Bool {
            parent.highlightSearchMatches
        }

        func imageDidResize() {
            guard let textView else { return }

            isApplyingProgrammaticUpdate = true
            normalizeVisibleTextAttributes(in: textView, fontSize: parent.fontSize)
            applyEditorTypingAppearance(to: textView, fontSize: parent.fontSize)
            applySearchHighlightsTemporarily(
                in: textView,
                query: parent.searchQuery,
                enabled: parent.highlightSearchMatches
            )
            isApplyingProgrammaticUpdate = false

            let plain = makePlainText(from: textView.attributedString(), baseFontSize: parent.fontSize, closeOpenStylesAtEnd: true)
            if plain != parent.text {
                parent.text = plain
                lastRenderedText = plain
            }
            minimapView?.invalidateCache()
        }

        func renderIfNeeded(force: Bool) {
            guard let textView else {
                return
            }
            
            // Auto-focus text view on first render
            if lastRenderedText.isEmpty && !parent.text.isEmpty {
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            }

            let signature = imageSignature(parent.imagesByKey)
            let fontSizeChanged = abs(parent.fontSize - lastRenderedFontSize) > 0.01
            let queryChanged = parent.searchQuery != lastRenderedQuery
            let highlightStateChanged = parent.highlightSearchMatches != lastRenderedHighlightState
            let dividerStyleSignature = dividerStyleSignature(
                color: parent.dividerColor,
                topMargin: parent.dividerTopMargin,
                bottomMargin: parent.dividerBottomMargin
            )
            let dividerStyleChanged = dividerStyleSignature != lastRenderedDividerStyleSignature
            let containerWidth = textView.textContainer?.containerSize.width ?? textView.bounds.width
            let widthChanged = abs(containerWidth - lastRenderedContainerWidth) > 0.5

            guard force || parent.text != lastRenderedText || signature != lastImageSignature || fontSizeChanged || queryChanged || highlightStateChanged || dividerStyleChanged || widthChanged else {
                return
            }

            let oldSelection = textView.selectedRange()
            let oldPlainCursor = plainOffset(fromAttributedLocation: oldSelection.location, in: textView)

            isApplyingProgrammaticUpdate = true
            let attributed = makeAttributedText(
                from: parent.text,
                imagesByKey: parent.imagesByKey,
                searchQuery: parent.searchQuery,
                dividerColor: NSColor(parent.dividerColor),
                dividerTopMargin: parent.dividerTopMargin,
                dividerBottomMargin: parent.dividerBottomMargin,
                contentWidth: containerWidth,
                defaultImageWidth: parent.defaultImageWidth,
                fontSize: parent.fontSize
            )
            textView.textStorage?.setAttributedString(attributed)
            normalizeVisibleTextAttributes(in: textView, fontSize: parent.fontSize)
            applyEditorTypingAppearance(to: textView, fontSize: parent.fontSize)
            applySearchHighlightsTemporarily(
                in: textView,
                query: parent.searchQuery,
                enabled: parent.highlightSearchMatches
            )

            let newCursorAttributedLocation = attributedLocation(fromPlainOffset: oldPlainCursor, in: textView)
            let safeLocation = max(0, min(newCursorAttributedLocation, textView.string.utf16.count))
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            isApplyingProgrammaticUpdate = false

            lastRenderedText = parent.text
            lastImageSignature = signature
            lastRenderedFontSize = parent.fontSize
            lastRenderedQuery = parent.searchQuery
            lastRenderedHighlightState = parent.highlightSearchMatches
            lastRenderedDividerStyleSignature = dividerStyleSignature
            lastRenderedContainerWidth = containerWidth
            publishSelectionIfNeeded()
            minimapView?.invalidateCache()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate, let textView else {
                return
            }
            
            // Defensive: ensure text storage exists
            guard textView.textStorage != nil else {
                return
            }

            isApplyingProgrammaticUpdate = true
            normalizeVisibleTextAttributes(in: textView, fontSize: parent.fontSize)
            applyEditorTypingAppearance(to: textView, fontSize: parent.fontSize)
            applySearchHighlightsTemporarily(
                in: textView,
                query: parent.searchQuery,
                enabled: parent.highlightSearchMatches
            )
            isApplyingProgrammaticUpdate = false

            // Safely extract plain text
            let plain = makePlainText(from: textView.attributedString(), baseFontSize: parent.fontSize, closeOpenStylesAtEnd: true)
            let hasPendingDividerToken = textViewHasPendingDividerToken(textView)

            if plain != parent.text {
                parent.text = plain
                if !hasPendingDividerToken {
                    lastRenderedText = plain
                }
            }

            if hasPendingDividerToken {
                renderIfNeeded(force: true)
            }
            
            // Update minimap when text changes
            minimapView?.invalidateCache()

            publishSelectionIfNeeded()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishSelectionIfNeeded()
        }

        private func publishSelectionIfNeeded() {
            guard let textView else {
                parent.onSelectionChange?(nil)
                return
            }

            let range = textView.selectedRange()
            let location = plainOffset(fromAttributedLocation: range.location, in: textView)
            parent.onSelectionChange?(location)
        }

        private func plainOffset(fromAttributedLocation location: Int, in textView: NSTextView) -> Int {
            let clamped = max(0, min(location, textView.string.utf16.count))
            if clamped == 0 {
                return 0
            }

            let prefix = textView.attributedString().attributedSubstring(from: NSRange(location: 0, length: clamped))
            return makePlainText(from: prefix, baseFontSize: parent.fontSize, closeOpenStylesAtEnd: false).count
        }

        private func attributedLocation(fromPlainOffset plainOffset: Int, in textView: NSTextView) -> Int {
            let attributed = textView.attributedString()
            let totalLength = attributed.length
            var low = 0
            var high = totalLength

            while low < high {
                let mid = (low + high) / 2
                let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: mid))
                let plainCount = makePlainText(from: prefix, baseFontSize: parent.fontSize, closeOpenStylesAtEnd: false).count
                if plainCount < plainOffset {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            return low
        }

        private func imageSignature(_ images: [String: Data]) -> Int {
            images
                .sorted(by: { $0.key < $1.key })
                .reduce(into: Hasher()) { hasher, element in
                    hasher.combine(element.key)
                    hasher.combine(element.value.count)
                }
                .finalize()
        }

        private func textViewHasPendingDividerToken(_ textView: NSTextView) -> Bool {
            let visible = textView.string
            guard visible.contains("---") else {
                return false
            }
            guard let regex = try? NSRegularExpression(pattern: dividerLinePattern) else {
                return false
            }
            let range = NSRange(location: 0, length: (visible as NSString).length)
            return regex.firstMatch(in: visible, range: range) != nil
        }

        private func dividerStyleSignature(color: Color, topMargin: CGFloat, bottomMargin: CGFloat) -> Int {
            let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

            var hasher = Hasher()
            hasher.combine(Int((Double(red) * 1000).rounded()))
            hasher.combine(Int((Double(green) * 1000).rounded()))
            hasher.combine(Int((Double(blue) * 1000).rounded()))
            hasher.combine(Int((Double(alpha) * 1000).rounded()))
            hasher.combine(Int((Double(topMargin) * 10).rounded()))
            hasher.combine(Int((Double(bottomMargin) * 10).rounded()))
            return hasher.finalize()
        }
    }
}

private func makeAttributedText(
    from plainText: String,
    imagesByKey: [String: Data],
    searchQuery: String,
    dividerColor: NSColor,
    dividerTopMargin: CGFloat,
    dividerBottomMargin: CGFloat,
    contentWidth: CGFloat,
    defaultImageWidth: CGFloat,
    fontSize: CGFloat
) -> NSAttributedString {
    let output = NSMutableAttributedString()

    let combinedPattern = "\(imageRefPattern)|\(styleTokenPattern)|\(dividerLinePattern)"
    guard let regex = try? NSRegularExpression(pattern: combinedPattern) else {
        output.append(NSAttributedString(string: plainText, attributes: editorBaseAttributes(fontSize: fontSize)))
        return output
    }

    let fullRange = NSRange(plainText.startIndex..<plainText.endIndex, in: plainText)
    let matches = regex.matches(in: plainText, range: fullRange)

    var cursor = plainText.startIndex
    var boldDepth = 0
    var fontSizeStack: [CGFloat] = []

    func activeAttributes() -> [NSAttributedString.Key: Any] {
        let activeSize = fontSizeStack.last ?? fontSize
        return [
            .font: styledEditorFont(size: activeSize, bold: boldDepth > 0),
            .foregroundColor: editorTextColor,
        ]
    }

    for match in matches {
        guard let matchRange = Range(match.range(at: 0), in: plainText) else {
            continue
        }

        if cursor < matchRange.lowerBound {
            let prefix = plainText[cursor..<matchRange.lowerBound]
            output.append(NSAttributedString(string: String(prefix), attributes: activeAttributes()))
        }

        if let keyRange = Range(match.range(at: 1), in: plainText) {
            let key = String(plainText[keyRange])
            let width = extractedWidth(match: match, from: plainText) ?? Double(defaultImageWidth)

            if let data = imagesByKey[key], let image = NSImage(data: data) {
                let resized = resizedImage(image, targetWidth: CGFloat(width))
                let framed = imageWithBorder(resized)
                let attachment = NSTextAttachment()
                attachment.image = framed
                attachment.bounds = NSRect(origin: .zero, size: framed.size)

                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttributes([
                    imageKeyAttribute: key,
                    imageWidthAttribute: Int(width.rounded()),
                ], range: NSRange(location: 0, length: attachmentString.length))
                output.append(attachmentString)
            } else {
                output.append(NSAttributedString(string: String(plainText[matchRange]), attributes: activeAttributes()))
            }
        } else {
            let token = String(plainText[matchRange])
            if token.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                output.append(
                    makeDividerAttachment(
                        color: dividerColor,
                        topMargin: dividerTopMargin,
                        bottomMargin: dividerBottomMargin,
                        contentWidth: contentWidth
                    )
                )
            } else if token == boldStyleOpenToken {
                boldDepth += 1
            } else if token == boldStyleCloseToken {
                boldDepth = max(0, boldDepth - 1)
            } else if token == fontSizeStyleCloseToken {
                if !fontSizeStack.isEmpty {
                    fontSizeStack.removeLast()
                }
            } else if token.hasPrefix(fontSizeStyleOpenPrefix), token.hasSuffix("]]") {
                let valueStart = token.index(token.startIndex, offsetBy: fontSizeStyleOpenPrefix.count)
                let valueEnd = token.index(token.endIndex, offsetBy: -2)
                if valueStart <= valueEnd,
                   let size = Double(token[valueStart..<valueEnd]) {
                    let parsed = CGFloat(size)
                    fontSizeStack.append(min(max(parsed, inlineStyleMinFontSize), inlineStyleMaxFontSize))
                }
            }
        }

        cursor = matchRange.upperBound
    }

    if cursor < plainText.endIndex {
        output.append(NSAttributedString(string: String(plainText[cursor...]), attributes: activeAttributes()))
    }

    _ = searchQuery

    return output
}

private func makeDividerAttachment(
    color: NSColor,
    topMargin: CGFloat,
    bottomMargin: CGFloat,
    contentWidth: CGFloat
) -> NSAttributedString {
    let safeTop = max(0, topMargin)
    let safeBottom = max(0, bottomMargin)
    let totalHeight = max(1, safeTop + dividerLineThickness + safeBottom)
    let lineWidth = max(40, contentWidth - 6)
    let image = NSImage(size: NSSize(width: lineWidth, height: totalHeight))

    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: image.size).fill()

    let y = safeBottom + max(0, (totalHeight - safeTop - safeBottom - dividerLineThickness) / 2)
    let lineRect = NSRect(x: 0, y: y, width: lineWidth, height: dividerLineThickness)
    color.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: lineRect, xRadius: dividerLineThickness / 2, yRadius: dividerLineThickness / 2).fill()
    image.unlockFocus()

    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(origin: .zero, size: image.size)

    let output = NSMutableAttributedString(attachment: attachment)
    output.addAttribute(dividerMarkerAttribute, value: true, range: NSRange(location: 0, length: output.length))
    return output
}

private func applySearchHighlightsTemporarily(in textView: NSTextView, query: String, enabled: Bool) {
    guard let layoutManager = textView.layoutManager else {
        return
    }

    let fullLength = textView.string.utf16.count
    let fullRange = NSRange(location: 0, length: fullLength)
    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
    guard enabled else { return }

    let terms = query.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    guard !terms.isEmpty else { return }

    let string = textView.string as NSString

    for term in terms {
        var searchRange = fullRange
        while searchRange.location < string.length {
            // Use caseInsensitive search directly on original string to avoid Unicode range mismatches
            let foundRange = string.range(of: term, options: .caseInsensitive, range: searchRange)
            if foundRange.location != NSNotFound {
                // Defensive: ensure range is within bounds
                guard NSMaxRange(foundRange) <= string.length else { break }

                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.4),
                    forCharacterRange: foundRange
                )

                let newLocation = foundRange.upperBound
                searchRange = NSRange(location: newLocation, length: fullRange.length - newLocation)
            } else {
                break
            }
        }
    }
}

private func applyEditorTypingAppearance(to textView: NSTextView, fontSize: CGFloat) {
    textView.insertionPointColor = editorTextColor
    var attributes = textView.typingAttributes
    attributes[.font] = editorFont(for: fontSize)
    attributes[.foregroundColor] = editorTextColor
    attributes.removeValue(forKey: .backgroundColor)
    textView.typingAttributes = attributes
}

private func normalizeVisibleTextAttributes(in textView: NSTextView, fontSize: CGFloat) {
    guard let storage = textView.textStorage else {
        return
    }

    let fullRange = NSRange(location: 0, length: storage.length)
    guard fullRange.length > 0 else {
        return
    }

    storage.beginEditing()
    storage.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
        if attrs[.attachment] != nil {
            return
        }
        var updates: [NSAttributedString.Key: Any] = [:]
        if attrs[.foregroundColor] == nil {
            updates[.foregroundColor] = editorTextColor
        }
        if attrs[.font] == nil {
            updates[.font] = editorFont(for: fontSize)
        }
        if !updates.isEmpty {
            storage.addAttributes(updates, range: range)
        }
    }
    storage.endEditing()
}

private func makePlainText(
    from attributed: NSAttributedString,
    baseFontSize: CGFloat,
    closeOpenStylesAtEnd: Bool
) -> String {
    var output = ""
    let fullRange = NSRange(location: 0, length: attributed.length)
    
    // Defensive: check for valid range
    guard fullRange.length >= 0 else {
        return attributed.string
    }

    var activeBold = false
    var activeFontSize: CGFloat?

    attributed.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
        // Check if this is an image attachment
        if let key = attrs[imageKeyAttribute] as? String {
            let width = attrs[imageWidthAttribute] as? Int
            if let width {
                output += "![image](alfred://image/\(key)?w=\(width))"
            } else {
                output += "![image](alfred://image/\(key))"
            }
            return
        }
        if let isDivider = attrs[dividerMarkerAttribute] as? Bool, isDivider {
            output += "---"
            return
        }

        let runFont = attrs[.font] as? NSFont
        let runBold = runFont.map(fontIsBold) ?? false
        let runSize = runFont?.pointSize
        let runFontSize: CGFloat?
        if let runSize, abs(runSize - baseFontSize) > 0.01 {
            runFontSize = runSize
        } else {
            runFontSize = nil
        }

        output += styleTransitionTokens(
            activeBold: &activeBold,
            activeFontSize: &activeFontSize,
            targetBold: runBold,
            targetFontSize: runFontSize
        )

        // Safely extract text from this range
        let rangeEnd = min(range.location + range.length, attributed.string.utf16.count)
        guard range.location >= 0, range.location < rangeEnd else {
            return
        }
        
        let safeRange = NSRange(location: range.location, length: rangeEnd - range.location)
        guard let swiftRange = Range(safeRange, in: attributed.string) else {
            return
        }
        output += String(attributed.string[swiftRange])
    }

    if closeOpenStylesAtEnd {
        if activeFontSize != nil {
            output += fontSizeStyleCloseToken
        }
        if activeBold {
            output += boldStyleCloseToken
        }
    }

    return output
}

private func styleTransitionTokens(
    activeBold: inout Bool,
    activeFontSize: inout CGFloat?,
    targetBold: Bool,
    targetFontSize: CGFloat?
) -> String {
    var output = ""

    if activeFontSize != targetFontSize, activeFontSize != nil {
        output += fontSizeStyleCloseToken
        activeFontSize = nil
    }
    if activeBold != targetBold, activeBold {
        output += boldStyleCloseToken
        activeBold = false
    }
    if activeBold != targetBold, targetBold {
        output += boldStyleOpenToken
        activeBold = true
    }
    if activeFontSize != targetFontSize, let targetFontSize {
        output += "\(fontSizeStyleOpenPrefix)\(formattedFontSize(targetFontSize))]]"
        activeFontSize = targetFontSize
    }

    return output
}

private func formattedFontSize(_ value: CGFloat) -> String {
    let rounded = value.rounded()
    if abs(value - rounded) < 0.01 {
        return String(Int(rounded))
    }
    return String(Double(value))
}

private func fontIsBold(_ font: NSFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.bold)
}

private func fontBySettingBold(_ font: NSFont, enabled: Bool) -> NSFont {
    let manager = NSFontManager.shared
    let converted = enabled
        ? manager.convert(font, toHaveTrait: .boldFontMask)
        : manager.convert(font, toNotHaveTrait: .boldFontMask)

    let candidate = NSFont(descriptor: converted.fontDescriptor, size: font.pointSize) ?? converted
    if fontIsBold(candidate) == enabled {
        return candidate
    }

    // Some descriptors do not reliably toggle weight traits; force a visible fallback.
    return NSFont.systemFont(ofSize: font.pointSize, weight: enabled ? .bold : .regular)
}

private func styledEditorFont(size: CGFloat, bold: Bool) -> NSFont {
    let clamped = min(max(size, inlineStyleMinFontSize), inlineStyleMaxFontSize)
    let base = editorFont(for: clamped)
    return bold ? fontBySettingBold(base, enabled: true) : fontBySettingBold(base, enabled: false)
}

private func extractedWidth(match: NSTextCheckingResult, from text: String) -> Double? {
    let widthRange = match.range(at: 2)
    guard widthRange.location != NSNotFound,
          let swiftRange = Range(widthRange, in: text)
    else {
        return nil
    }
    return Double(text[swiftRange])
}

private func resizedImage(_ image: NSImage, targetWidth: CGFloat) -> NSImage {
    guard image.size.width > 0, image.size.height > 0 else {
        return image
    }

    let clampedWidth = min(max(targetWidth, minImageWidth), maxImageWidth)
    let ratio = clampedWidth / image.size.width
    let targetHeight = max(1, image.size.height * ratio)
    let targetSize = NSSize(width: clampedWidth, height: targetHeight)

    let newImage = NSImage(size: targetSize)
    newImage.lockFocus()
    defer { newImage.unlockFocus() }

    image.draw(
        in: NSRect(origin: .zero, size: targetSize),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )

    return newImage
}

private func imageWithBorder(_ image: NSImage) -> NSImage {
    let borderWidth: CGFloat = 1
    let framedSize = NSSize(width: image.size.width + borderWidth * 2, height: image.size.height + borderWidth * 2)
    let framed = NSImage(size: framedSize)
    framed.lockFocus()
    defer { framed.unlockFocus() }

    image.draw(
        in: NSRect(x: borderWidth, y: borderWidth, width: image.size.width, height: image.size.height),
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1
    )

    NSColor.separatorColor.setStroke()
    let borderPath = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: framedSize.width - 1, height: framedSize.height - 1))
    borderPath.lineWidth = 1
    borderPath.stroke()

    // Draw resize grip icon at bottom-right corner
    // In NSImage coordinate system, (0,0) is bottom-left

    // Draw a triangular background behind the grip for visibility
    let trianglePath = NSBezierPath()
    let triSize: CGFloat = 20
    trianglePath.move(to: NSPoint(x: framedSize.width, y: 0))
    trianglePath.line(to: NSPoint(x: framedSize.width, y: triSize))
    trianglePath.line(to: NSPoint(x: framedSize.width - triSize, y: 0))
    trianglePath.close()
    NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
    trianglePath.fill()

    // Subtle border on the triangle edge
    NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
    let triEdge = NSBezierPath()
    triEdge.lineWidth = 0.5
    triEdge.move(to: NSPoint(x: framedSize.width, y: triSize))
    triEdge.line(to: NSPoint(x: framedSize.width - triSize, y: 0))
    triEdge.stroke()

    // Draw grip lines on top
    let gripColor = NSColor.secondaryLabelColor
    gripColor.setStroke()

    let gripInset: CGFloat = 4
    let gripLineSpacing: CGFloat = 3.5
    let gripLineCount = 4

    for i in 0..<gripLineCount {
        let offset = CGFloat(i) * gripLineSpacing
        let line = NSBezierPath()
        line.lineWidth = 1.8
        line.lineCapStyle = .round
        // Diagonal lines from bottom-right corner going up-left
        line.move(to: NSPoint(
            x: framedSize.width - gripInset,
            y: gripInset + offset
        ))
        line.line(to: NSPoint(
            x: framedSize.width - gripInset - (CGFloat(gripLineCount - 1) - CGFloat(i)) * gripLineSpacing,
            y: gripInset
        ))
        line.stroke()
    }

    return framed
}
