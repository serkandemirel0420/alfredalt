import AppKit
import SwiftUI

private let imageRefPattern = #"!\[image\]\(alfred://image/([^\)\?]+)(?:\?w=(\d+))?\)"#
private let imageKeyAttribute = NSAttributedString.Key("InlineImageKey")
private let imageWidthAttribute = NSAttributedString.Key("InlineImageWidth")

struct InlineImageTextEditor: NSViewRepresentable {
    @Binding var text: String
    var imagesByKey: [String: Data]
    var defaultImageWidth: CGFloat = 360
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
        textView.importsGraphics = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.backgroundColor = .clear
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        textView.textContainerInset = NSSize(width: 0, height: 6)
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

        init(parent: InlineImageTextEditor) {
            self.parent = parent
        }

        func renderIfNeeded(force: Bool) {
            guard let textView else {
                return
            }

            let signature = imageSignature(parent.imagesByKey)
            guard force || parent.text != lastRenderedText || signature != lastImageSignature else {
                return
            }

            let oldSelection = textView.selectedRange()
            let oldPlainCursor = plainOffset(fromAttributedLocation: oldSelection.location, in: textView)

            isApplyingProgrammaticUpdate = true
            let attributed = makeAttributedText(from: parent.text, imagesByKey: parent.imagesByKey, defaultImageWidth: parent.defaultImageWidth)
            textView.textStorage?.setAttributedString(attributed)

            let newCursorAttributedLocation = attributedLocation(fromPlainOffset: oldPlainCursor, in: textView)
            let safeLocation = max(0, min(newCursorAttributedLocation, textView.string.utf16.count))
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            isApplyingProgrammaticUpdate = false

            lastRenderedText = parent.text
            lastImageSignature = signature
            publishSelectionIfNeeded()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate, let textView else {
                return
            }

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
    defaultImageWidth: CGFloat
) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
    ]

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
            let attachment = NSTextAttachment()
            attachment.image = resized

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
