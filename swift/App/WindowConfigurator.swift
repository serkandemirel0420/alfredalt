import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    let desiredSize: NSSize
    let onWindowResolved: ((NSWindow) -> Void)?

    final class Coordinator {
        var configured = false
        var appliedSize: NSSize?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else {
            return
        }

        configure(window: window, coordinator: context.coordinator)
        onWindowResolved?(window)
    }

    private func configure(window: NSWindow, coordinator: Coordinator) {
        if !coordinator.configured {
            coordinator.configured = true
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

        let targetSize = desiredSize
        if let appliedSize = coordinator.appliedSize,
           abs(appliedSize.width - targetSize.width) <= 0.5,
           abs(appliedSize.height - targetSize.height) <= 0.5 {
            return
        }
        coordinator.appliedSize = targetSize

        let currentMaxY = window.frame.maxY
        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetSize)).size

        window.minSize = targetSize
        window.maxSize = targetSize

        var frame = window.frame
        frame.size = targetFrameSize
        frame.origin.y = currentMaxY - frame.height

        let currentFrame = window.frame
        if abs(currentFrame.width - frame.width) <= 0.5,
           abs(currentFrame.height - frame.height) <= 0.5,
           abs(currentFrame.origin.y - frame.origin.y) <= 0.5 {
            return
        }
        window.setFrame(frame, display: false, animate: false)
    }
}
