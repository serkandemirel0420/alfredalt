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
            window.maxSize = NSSize(width: 10_000, height: 10_000)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)

            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        window.minSize = desiredSize
        window.maxSize = desiredSize

        let targetSize = desiredSize
        if abs(window.frame.size.width - targetSize.width) <= 0.5,
           abs(window.frame.size.height - targetSize.height) <= 0.5 {
            return
        }

        var frame = window.frame
        frame.origin.y += frame.height - targetSize.height
        frame.size = targetSize
        window.setFrame(frame, display: true, animate: true)
    }
}
