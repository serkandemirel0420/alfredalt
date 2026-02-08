import AppKit
import SwiftUI

struct KeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    final class Coordinator {
        var monitor: Any?
        weak var window: NSWindow?
        var onKeyDown: (NSEvent) -> Bool = { _ in false }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.onKeyDown = onKeyDown

        if context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
                guard let coordinator else {
                    return event
                }
                guard let monitoredWindow = coordinator.window else {
                    return event
                }
                guard event.window === monitoredWindow else {
                    return event
                }
                return coordinator.onKeyDown(event) ? nil : event
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
        coordinator.window = nil
    }
}
