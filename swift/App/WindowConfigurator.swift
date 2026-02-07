import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    let desiredSize: NSSize
    let onWindowResolved: ((NSWindow) -> Void)?

    final class Coordinator {
        var configured = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }

            configure(window: window, coordinator: context.coordinator)
            onWindowResolved?(window)
        }
    }

    private func configure(window: NSWindow, coordinator: Coordinator) {
        if !coordinator.configured {
            coordinator.configured = true
            window.minSize = desiredSize
            window.maxSize = desiredSize
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            window.toolbar = nil

            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
                contentView.layer?.masksToBounds = true
            }

            if let superview = window.contentView?.superview {
                superview.wantsLayer = true
                superview.layer?.backgroundColor = NSColor.clear.cgColor
                superview.layer?.masksToBounds = true
            }
        }

        window.minSize = desiredSize
        window.maxSize = desiredSize
        window.hasShadow = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear

        let targetSize = desiredSize
        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetSize)).size
        let currentFrameSize = window.frame.size
        if abs(currentFrameSize.width - targetFrameSize.width) <= 0.5,
           abs(currentFrameSize.height - targetFrameSize.height) <= 0.5 {
            return
        }

        var frame = window.frame
        let currentMaxY = frame.maxY
        frame.size = targetFrameSize
        frame.origin.y = currentMaxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }
}
