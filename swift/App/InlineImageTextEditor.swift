import AppKit
import SwiftUI

private let imageRefPattern = #"!\[image\]\(alfred://image/([^\)\?]+)(?:\?w=(\d+))?\)"#
private let imageKeyAttribute = NSAttributedString.Key("InlineImageKey")
private let imageWidthAttribute = NSAttributedString.Key("InlineImageWidth")
private let editorDefaultFontSize: CGFloat = 15
private let editorTextColor = NSColor.labelColor

private func editorFont(for fontSize: CGFloat) -> NSFont {
    NSFont.systemFont(ofSize: fontSize)
}

private func editorBaseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    [
        .font: editorFont(for: fontSize),
        .foregroundColor: editorTextColor,
    ]
}

struct InlineImageTextEditor: NSViewRepresentable {
    @Binding var text: String
    var imagesByKey: [String: Data]
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

        let textView = NSTextView()
        textView.delegate = context.coordinator
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineImageTextEditor
        weak var textView: NSTextView?

        private var isApplyingProgrammaticUpdate = false
        private var lastRenderedText: String = ""
        private var lastImageSignature: Int = 0
        private var lastRenderedFontSize: CGFloat = editorDefaultFontSize

        init(parent: InlineImageTextEditor) {
            self.parent = parent
        }

        func renderIfNeeded(force: Bool) {
            guard let textView else {
                return
            }

            let signature = imageSignature(parent.imagesByKey)
            let fontSizeChanged = abs(parent.fontSize - lastRenderedFontSize) > 0.01
            guard force || parent.text != lastRenderedText || signature != lastImageSignature || fontSizeChanged else {
                return
            }

            let oldSelection = textView.selectedRange()
            let oldPlainCursor = plainOffset(fromAttributedLocation: oldSelection.location, in: textView)

            isApplyingProgrammaticUpdate = true
            let attributed = makeAttributedText(
                from: parent.text,
                imagesByKey: parent.imagesByKey,
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

    return output
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

    let clampedWidth = min(max(targetWidth, 140), 1200)
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

    return framed
}
