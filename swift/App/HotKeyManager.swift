import Carbon
import Cocoa
import SwiftUI

enum HotKeyType: String, CaseIterable, Identifiable {
    case doubleOption = "doubleOption"
    case commandSpace = "commandSpace"
    case optionSpace = "optionSpace"
    case controlSpace = "controlSpace"
    case shiftSpace = "shiftSpace"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .doubleOption: return "Double Option (⌥⌥)"
        case .commandSpace: return "Command+Space (⌘␣)"
        case .optionSpace: return "Option+Space (⌥␣)"
        case .controlSpace: return "Control+Space (⌃␣)"
        case .shiftSpace: return "Shift+Space (⇧␣)"
        }
    }
    
    var shortcutDescription: String {
        switch self {
        case .doubleOption: return "⌥ ⌥"
        case .commandSpace: return "⌘ ␣"
        case .optionSpace: return "⌥ ␣"
        case .controlSpace: return "⌃ ␣"
        case .shiftSpace: return "⇧ ␣"
        }
    }
}

@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    private static let settingsFileName = "hotkey-settings.json"
    private static let legacyHotKeyTypeKey = "hotKeyType"
    static let doubleTapInterval: TimeInterval = 0.3

    private struct PersistedHotKeySettings: Codable {
        let hotKeyType: String
    }
    
    @Published var currentHotKey: HotKeyType {
        didSet {
            if currentHotKey != oldValue {
                if !isApplyingPersistedState {
                    saveHotKeyPreference()
                }
                _ = register()
            }
        }
    }
    
    private var handler: () -> Void = {}
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    
    // Double-tap detection state
    private var lastOptionTapTime: Date?
    private var wasOptionPressed = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isApplyingPersistedState = false
    
    private init() {
        currentHotKey = Self.loadPersistedHotKeyType() ?? .doubleOption
    }
    
    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
    
    func register() -> Bool {
        unregister()
        
        switch currentHotKey {
        case .doubleOption:
            return registerDoubleOptionTap()
        case .commandSpace, .optionSpace, .controlSpace, .shiftSpace:
            return registerModifierSpace()
        }
    }
    
    func unregister() {
        stopDoubleOptionMonitoring()
        
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
    
    // MARK: - Double Option Tap
    
    private func registerDoubleOptionTap() -> Bool {
        // Request accessibility permission if needed
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        NSLog("HotKeyManager: Accessibility enabled: \(accessibilityEnabled)")
        
        // Create event tap for flags changed (modifier key state changes)
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // Don't consume events, just listen
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                HotKeyManager.handleCGEvent(proxy: proxy, type: type, event: event, refcon: refcon)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("HotKeyManager: Failed to create event tap")
            return false
        }
        
        self.eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        NSLog("HotKeyManager: Double Option tap registered")
        return true
    }
    
    private func stopDoubleOptionMonitoring() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        lastOptionTapTime = nil
        wasOptionPressed = false
    }
    
    private static func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        guard let refcon else { return Unmanaged.passUnretained(event) }
        
        // Get the manager instance
        let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
        
        // Execute on main actor
        DispatchQueue.main.async {
            manager.processFlagsChanged(event)
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func processFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let isOptionPressed = flags.contains(.maskAlternate)
        
        // Detect Option key press (transition from not pressed to pressed)
        if isOptionPressed && !wasOptionPressed {
            let now = Date()
            
            if let lastTap = lastOptionTapTime,
               now.timeIntervalSince(lastTap) < HotKeyManager.doubleTapInterval {
                // Double tap detected!
                NSLog("HotKeyManager: Double Option tap detected!")
                lastOptionTapTime = nil
                handler()
            } else {
                // First tap
                lastOptionTapTime = now
            }
        }
        
        wasOptionPressed = isOptionPressed
    }
    
    // MARK: - Modifier + Space
    
    private func registerModifierSpace() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleHotKeyEvent(eventRef: eventRef)
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        
        guard installStatus == noErr else {
            NSLog("HotKeyManager: Failed to install event handler")
            return false
        }
        
        let (keyCode, modifiers) = getKeyCodeAndModifiers()
        
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        guard registerStatus == noErr else {
            NSLog("HotKeyManager: Failed to register hotkey, status: \(registerStatus)")
            unregister()
            return false
        }
        
        NSLog("HotKeyManager: Modifier+Space hotkey registered")
        return true
    }
    
    private func handleHotKeyEvent(eventRef: EventRef) -> OSStatus {
        var pressedID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressedID
        )
        
        guard status == noErr else { return status }
        guard pressedID.signature == hotKeyID.signature,
              pressedID.id == hotKeyID.id else { return noErr }
        
        handler()
        return noErr
    }
    
    private var hotKeyID: EventHotKeyID {
        EventHotKeyID(signature: OSType(0x414C5448), id: 1)
    }
    
    private func getKeyCodeAndModifiers() -> (Int, UInt32) {
        switch currentHotKey {
        case .commandSpace:
            return (kVK_Space, UInt32(cmdKey))
        case .optionSpace:
            return (kVK_Space, UInt32(optionKey))
        case .controlSpace:
            return (kVK_Space, UInt32(controlKey))
        case .shiftSpace:
            return (kVK_Space, UInt32(shiftKey))
        case .doubleOption:
            return (0, 0)
        }
    }
    
    func saveHotKeyPreference() {
        let payload = PersistedHotKeySettings(hotKeyType: currentHotKey.rawValue)
        _ = SettingsStore.shared.saveJSON(payload, fileName: Self.settingsFileName)
    }
    
    func setHotKey(_ type: HotKeyType) {
        currentHotKey = type
    }

    func reloadFromDisk() {
        guard let loaded = Self.loadPersistedHotKeyType(), loaded != currentHotKey else {
            return
        }
        isApplyingPersistedState = true
        currentHotKey = loaded
        isApplyingPersistedState = false
    }

    private static func loadPersistedHotKeyType() -> HotKeyType? {
        if let payload: PersistedHotKeySettings = SettingsStore.shared.loadJSON(
            PersistedHotKeySettings.self,
            fileName: settingsFileName
        ), let type = HotKeyType(rawValue: payload.hotKeyType) {
            return type
        }
        return migrateLegacyUserDefaultsIfNeeded()
    }

    private static func migrateLegacyUserDefaultsIfNeeded() -> HotKeyType? {
        guard let savedType = UserDefaults.standard.string(forKey: legacyHotKeyTypeKey),
              let type = HotKeyType(rawValue: savedType) else {
            return nil
        }
        let payload = PersistedHotKeySettings(hotKeyType: type.rawValue)
        _ = SettingsStore.shared.saveJSON(payload, fileName: settingsFileName)
        return type
    }
}
