import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    let desiredHeight: CGFloat

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
        }
    }

    private func configure(window: NSWindow, coordinator: Coordinator) {
        if !coordinator.configured {
            coordinator.configured = true
            window.minSize = NSSize(width: 620, height: 200)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)
            window.hasShadow = true
            window.level = .floating
            window.styleMask.insert(.fullSizeContentView)

            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }

        let targetSize = NSSize(width: 1100, height: desiredHeight)
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
