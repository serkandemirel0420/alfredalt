import AppKit
import SwiftUI

private let imageRefPattern = #"!\[image\]\(alfred://image/([^\)\?]+)(?:\?w=(\d+))?\)"#
private let imageKeyAttribute = NSAttributedString.Key("InlineImageKey")
private let imageWidthAttribute = NSAttributedString.Key("InlineImageWidth")
private let editorDefaultFontSize: CGFloat = 15
private let editorTextColor = NSColor.labelColor
private let resizeHandleSize: CGFloat = 24
private let minImageWidth: CGFloat = 140
private let maxImageWidth: CGFloat = 1200

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

        private var dragState: ImageResizeDragState?
        private var moveDragState: ImageMoveDragState?
        private var cursorState: CursorOverlay = .none
        private let moveDragThreshold: CGFloat = 5

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
    var defaultImageWidth: CGFloat = 360
    var fontSize: CGFloat = editorDefaultFontSize
    var onSelectionChange: ((Int?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = ResizableImageTextView()
        textView.delegate = context.coordinator
        textView.resizeDelegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
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

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.renderIfNeeded(force: true)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.renderIfNeeded(force: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, ImageResizeDelegate {
        var parent: InlineImageTextEditor
        weak var textView: NSTextView?

        private var isApplyingProgrammaticUpdate = false
        private var lastRenderedText: String = ""
        private var lastRenderedQuery: String = ""
        private var lastImageSignature: Int = 0
        private var lastRenderedFontSize: CGFloat = editorDefaultFontSize

        init(parent: InlineImageTextEditor) {
            self.parent = parent
        }

        // MARK: ImageResizeDelegate

        func originalImageData(forKey key: String) -> Data? {
            parent.imagesByKey[key]
        }

        func imageDidResize() {
            guard let textView else { return }

            isApplyingProgrammaticUpdate = true
            normalizeVisibleTextAttributes(in: textView, fontSize: parent.fontSize)
            applyEditorTypingAppearance(to: textView, fontSize: parent.fontSize)
            isApplyingProgrammaticUpdate = false

            let plain = makePlainText(from: textView.attributedString())
            if plain != parent.text {
                parent.text = plain
                lastRenderedText = plain
            }
        }

        func renderIfNeeded(force: Bool) {
            guard let textView else {
                return
            }

            let signature = imageSignature(parent.imagesByKey)
            let fontSizeChanged = abs(parent.fontSize - lastRenderedFontSize) > 0.01
            let queryChanged = parent.searchQuery != lastRenderedQuery
            guard force || parent.text != lastRenderedText || signature != lastImageSignature || fontSizeChanged || queryChanged else {
                return
            }

            let oldSelection = textView.selectedRange()
            let oldPlainCursor = plainOffset(fromAttributedLocation: oldSelection.location, in: textView)

            isApplyingProgrammaticUpdate = true
            let attributed = makeAttributedText(
                from: parent.text,
                imagesByKey: parent.imagesByKey,
                searchQuery: parent.searchQuery,
                defaultImageWidth: parent.defaultImageWidth,
                fontSize: parent.fontSize
            )
            textView.textStorage?.setAttributedString(attributed)
            normalizeVisibleTextAttributes(in: textView, fontSize: parent.fontSize)
            applyEditorTypingAppearance(to: textView, fontSize: parent.fontSize)

            let newCursorAttributedLocation = attributedLocation(fromPlainOffset: oldPlainCursor, in: textView)
            let safeLocation = max(0, min(newCursorAttributedLocation, textView.string.utf16.count))
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            isApplyingProgrammaticUpdate = false

            lastRenderedText = parent.text
            lastImageSignature = signature
            lastRenderedFontSize = parent.fontSize
            lastRenderedQuery = parent.searchQuery
            publishSelectionIfNeeded()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate, let textView else {
                return
            }

            isApplyingProgrammaticUpdate = true
            normalizeVisibleTextAttributes(in: textView, fontSize: parent.fontSize)
            applyEditorTypingAppearance(to: textView, fontSize: parent.fontSize)
            isApplyingProgrammaticUpdate = false

            let plain = makePlainText(from: textView.attributedString())
            if plain != parent.text {
                parent.text = plain
                lastRenderedText = plain
            }

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
            return makePlainText(from: prefix).count
        }

        private func attributedLocation(fromPlainOffset plainOffset: Int, in textView: NSTextView) -> Int {
            let attributed = textView.attributedString()
            let totalLength = attributed.length
            var low = 0
            var high = totalLength

            while low < high {
                let mid = (low + high) / 2
                let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: mid))
                let plainCount = makePlainText(from: prefix).count
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
    }
}

private func makeAttributedText(
    from plainText: String,
    imagesByKey: [String: Data],
    searchQuery: String,
    defaultImageWidth: CGFloat,
    fontSize: CGFloat
) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let baseAttributes = editorBaseAttributes(fontSize: fontSize)

    guard let regex = try? NSRegularExpression(pattern: imageRefPattern) else {
        output.append(NSAttributedString(string: plainText, attributes: baseAttributes))
        return output
    }

    let fullRange = NSRange(plainText.startIndex..<plainText.endIndex, in: plainText)
    let matches = regex.matches(in: plainText, range: fullRange)

    var cursor = plainText.startIndex

    for match in matches {
        guard let matchRange = Range(match.range(at: 0), in: plainText),
              let keyRange = Range(match.range(at: 1), in: plainText)
        else {
            continue
        }

        if cursor < matchRange.lowerBound {
            let prefix = plainText[cursor..<matchRange.lowerBound]
            output.append(NSAttributedString(string: String(prefix), attributes: baseAttributes))
        }

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
            output.append(NSAttributedString(string: String(plainText[matchRange]), attributes: baseAttributes))
        }

        cursor = matchRange.upperBound
    }

    if cursor < plainText.endIndex {
        output.append(NSAttributedString(string: String(plainText[cursor...]), attributes: baseAttributes))
    }

    if !searchQuery.isEmpty {
        highlightSearchTerms(in: output, query: searchQuery)
    }

    return output
}

private func highlightSearchTerms(in attributedString: NSMutableAttributedString, query: String) {
    let terms = query.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    guard !terms.isEmpty else { return }

    let string = attributedString.string
    let text = string.lowercased() as NSString
    let fullRange = NSRange(location: 0, length: text.length)

    for term in terms {
        var searchRange = fullRange
        while searchRange.location < text.length {
            let foundRange = text.range(of: term, options: [], range: searchRange)
            if foundRange.location != NSNotFound {
                attributedString.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: foundRange)
                attributedString.addAttribute(.foregroundColor, value: NSColor.black, range: foundRange)

                let newLocation = foundRange.upperBound
                searchRange = NSRange(location: newLocation, length: fullRange.length - newLocation)
            } else {
                break
            }
        }
    }
}

private func applyEditorTypingAppearance(to textView: NSTextView, fontSize: CGFloat) {
    textView.font = editorFont(for: fontSize)
    textView.textColor = editorTextColor
    textView.insertionPointColor = editorTextColor
    textView.typingAttributes = editorBaseAttributes(fontSize: fontSize)
}

private func normalizeVisibleTextAttributes(in textView: NSTextView, fontSize: CGFloat) {
    guard let storage = textView.textStorage else {
        return
    }

    let fullRange = NSRange(location: 0, length: storage.length)
    guard fullRange.length > 0 else {
        return
    }

    var plainTextRanges: [NSRange] = []
    storage.enumerateAttribute(.attachment, in: fullRange, options: []) { attachment, range, _ in
        if attachment == nil {
            plainTextRanges.append(range)
        }
    }

    guard !plainTextRanges.isEmpty else {
        return
    }

    storage.beginEditing()
    for range in plainTextRanges {
        storage.addAttributes(editorBaseAttributes(fontSize: fontSize), range: range)
    }
    storage.endEditing()
}

private func makePlainText(from attributed: NSAttributedString) -> String {
    var output = ""
    let fullRange = NSRange(location: 0, length: attributed.length)

    attributed.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
        if let key = attrs[imageKeyAttribute] as? String {
            let width = (attrs[imageWidthAttribute] as? Int)
            if let width {
                output += "![image](alfred://image/\(key)?w=\(width))"
            } else {
                output += "![image](alfred://image/\(key))"
            }
            return
        }

        if let subrange = Range(range, in: attributed.string) {
            output += String(attributed.string[subrange])
        }
    }

    return output
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
