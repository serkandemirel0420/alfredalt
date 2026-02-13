import AppKit
import SwiftUI

struct KeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    var onCmdTap: (() -> Void)? = nil

    final class Coordinator {
        var keyMonitor: Any?
        var flagsMonitor: Any?
        weak var window: NSWindow?
        var onKeyDown: (NSEvent) -> Bool = { _ in false }
        var onCmdTap: (() -> Void)?
        var cmdPressedClean = false
        var isActive = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.onCmdTap = onCmdTap
        context.coordinator.isActive = true

        DispatchQueue.main.async {
            context.coordinator.window = view.window
        }

        // Always create fresh monitors - dismantleNSView will clean up old ones
        context.coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, coordinator.isActive else {
                return event
            }
            guard let monitoredWindow = coordinator.window else {
                return event
            }
            guard event.window === monitoredWindow else {
                return event
            }
            // Any key press while Cmd is held invalidates the Cmd-tap gesture
            coordinator.cmdPressedClean = false
            return coordinator.onKeyDown(event) ? nil : event
        }

        context.coordinator.flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak coordinator = context.coordinator] event in
            guard let coordinator, coordinator.isActive else {
                return event
            }
            guard let monitoredWindow = coordinator.window else {
                return event
            }
            guard event.window === monitoredWindow else {
                return event
            }

            let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])

            if mods == [.command] {
                // Cmd just went down (alone)
                coordinator.cmdPressedClean = true
            } else if mods.isEmpty && coordinator.cmdPressedClean {
                // Cmd just released and no other key was pressed
                coordinator.cmdPressedClean = false
                coordinator.onCmdTap?()
            } else {
                // Some other modifier combination
                coordinator.cmdPressedClean = false
            }

            return event
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.onCmdTap = onCmdTap
        if context.coordinator.window == nil {
            DispatchQueue.main.async {
                context.coordinator.window = nsView.window
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.isActive = false
        if let monitor = coordinator.keyMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.keyMonitor = nil
        }
        if let monitor = coordinator.flagsMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.flagsMonitor = nil
        }
        coordinator.window = nil
    }
}
