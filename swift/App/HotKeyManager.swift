import Carbon
import Cocoa
import SwiftUI

struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
}

enum HotKeyApplyResult {
    case success
    case failure(String)
}

@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    private static let settingsFileName = "hotkey-settings.json"
    private static let legacyHotKeyTypeKey = "hotKeyType"
    private static let hotKeyExistsStatus: OSStatus = -9878
    private static let hotKeyInvalidStatus: OSStatus = -9879
    private static let supportedModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private struct PersistedHotKeySettings: Codable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    private struct LegacyPersistedHotKeySettings: Codable {
        let hotKeyType: String
    }

    @Published private(set) var currentShortcut: HotKeyShortcut

    private var handler: () -> Void = {}
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private init() {
        currentShortcut = Self.loadPersistedShortcut() ?? Self.defaultShortcut
    }

    var currentShortcutDescription: String {
        Self.shortcutDescription(currentShortcut)
    }

    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @discardableResult
    func register() -> Bool {
        let status = register(shortcut: currentShortcut)
        if status != noErr {
            NSLog("HotKeyManager: Failed to register persisted hotkey, status: \(status)")
        }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    func shortcut(from event: NSEvent) -> HotKeyShortcut? {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let candidate = HotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers
        )
        guard Self.validationError(for: candidate) == nil else {
            return nil
        }
        return Self.normalize(candidate)
    }

    func applyShortcut(_ candidate: HotKeyShortcut) -> HotKeyApplyResult {
        let normalized = Self.normalize(candidate)
        if let validationError = Self.validationError(for: normalized) {
            return .failure(validationError)
        }

        guard normalized != currentShortcut else {
            return .success
        }

        let previous = currentShortcut
        currentShortcut = normalized

        let status = register(shortcut: normalized)
        guard status == noErr else {
            currentShortcut = previous
            _ = register(shortcut: previous)
            return .failure(Self.registrationErrorMessage(for: status))
        }

        saveShortcutPreference()
        return .success
    }

    func reloadFromDisk() {
        guard let loaded = Self.loadPersistedShortcut() else {
            return
        }
        let normalized = Self.normalize(loaded)
        guard normalized != currentShortcut else {
            return
        }
        currentShortcut = normalized
        _ = register()
    }

    private func register(shortcut: HotKeyShortcut) -> OSStatus {
        unregister()

        if let validationError = Self.validationError(for: shortcut) {
            NSLog("HotKeyManager: Invalid shortcut: \(validationError)")
            return Self.hotKeyInvalidStatus
        }

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
            NSLog("HotKeyManager: Failed to install event handler, status: \(installStatus)")
            return installStatus
        }

        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            NSLog("HotKeyManager: Failed to register hotkey, status: \(registerStatus)")
            unregister()
            return registerStatus
        }

        NSLog("HotKeyManager: Registered hotkey \(Self.shortcutDescription(shortcut))")
        return noErr
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

    private func saveShortcutPreference() {
        let payload = PersistedHotKeySettings(
            keyCode: currentShortcut.keyCode,
            carbonModifiers: currentShortcut.carbonModifiers
        )
        _ = SettingsStore.shared.saveJSON(payload, fileName: Self.settingsFileName)
    }

    private static func loadPersistedShortcut() -> HotKeyShortcut? {
        if let payload: PersistedHotKeySettings = SettingsStore.shared.loadJSON(
            PersistedHotKeySettings.self,
            fileName: settingsFileName
        ) {
            let shortcut = normalize(
                HotKeyShortcut(keyCode: payload.keyCode, carbonModifiers: payload.carbonModifiers)
            )
            if validationError(for: shortcut) == nil {
                return shortcut
            }
        }

        if let payload: LegacyPersistedHotKeySettings = SettingsStore.shared.loadJSON(
            LegacyPersistedHotKeySettings.self,
            fileName: settingsFileName
        ), let migrated = shortcutFromLegacyType(payload.hotKeyType) {
            let normalized = normalize(migrated)
            let rewritten = PersistedHotKeySettings(
                keyCode: normalized.keyCode,
                carbonModifiers: normalized.carbonModifiers
            )
            _ = SettingsStore.shared.saveJSON(rewritten, fileName: settingsFileName)
            return normalized
        }

        return migrateLegacyUserDefaultsIfNeeded()
    }

    private static func migrateLegacyUserDefaultsIfNeeded() -> HotKeyShortcut? {
        guard let savedType = UserDefaults.standard.string(forKey: legacyHotKeyTypeKey),
              let migrated = shortcutFromLegacyType(savedType) else {
            return nil
        }

        let normalized = normalize(migrated)
        let payload = PersistedHotKeySettings(
            keyCode: normalized.keyCode,
            carbonModifiers: normalized.carbonModifiers
        )
        _ = SettingsStore.shared.saveJSON(payload, fileName: settingsFileName)
        UserDefaults.standard.removeObject(forKey: legacyHotKeyTypeKey)
        return normalized
    }

    private static func shortcutFromLegacyType(_ rawValue: String) -> HotKeyShortcut? {
        switch rawValue {
        case "commandSpace":
            return HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))
        case "optionSpace", "doubleOption":
            return HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
        case "controlSpace":
            return HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))
        case "shiftSpace":
            return HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(shiftKey))
        default:
            return nil
        }
    }

    private static func normalize(_ shortcut: HotKeyShortcut) -> HotKeyShortcut {
        HotKeyShortcut(
            keyCode: shortcut.keyCode,
            carbonModifiers: shortcut.carbonModifiers & supportedModifierMask
        )
    }

    private static func validationError(for shortcut: HotKeyShortcut) -> String? {
        guard (shortcut.carbonModifiers & supportedModifierMask) != 0 else {
            return "Shortcut must include Command, Option, Control, or Shift."
        }
        guard !modifierOnlyKeyCodes.contains(shortcut.keyCode) else {
            return "Shortcut must include a non-modifier key."
        }
        return nil
    }

    private static func registrationErrorMessage(for status: OSStatus) -> String {
        switch status {
        case hotKeyExistsStatus:
            return "Shortcut is already in use by macOS or another app."
        case hotKeyInvalidStatus:
            return "Shortcut is not valid for global registration."
        default:
            return "Could not register shortcut (code \(status))."
        }
    }

    private static func shortcutDescription(_ shortcut: HotKeyShortcut) -> String {
        let modifiers = modifierDescription(shortcut.carbonModifiers)
        let keyName = keyDisplayNames[shortcut.keyCode] ?? "Key \(shortcut.keyCode)"
        if modifiers.isEmpty {
            return keyName
        }
        if keyName.count == 1 || keyName == "␣" {
            return "\(modifiers)\(keyName)"
        }
        return "\(modifiers) \(keyName)"
    }

    private static func modifierDescription(_ carbonModifiers: UInt32) -> String {
        var result = ""
        if (carbonModifiers & UInt32(cmdKey)) != 0 {
            result += "⌘"
        }
        if (carbonModifiers & UInt32(optionKey)) != 0 {
            result += "⌥"
        }
        if (carbonModifiers & UInt32(controlKey)) != 0 {
            result += "⌃"
        }
        if (carbonModifiers & UInt32(shiftKey)) != 0 {
            result += "⇧"
        }
        return result
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        var result: UInt32 = 0
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        return result
    }

    private static let defaultShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey)
    )

    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_Shift),
        UInt32(kVK_CapsLock),
        UInt32(kVK_Option),
        UInt32(kVK_Control),
        UInt32(kVK_RightShift),
        UInt32(kVK_RightOption),
        UInt32(kVK_RightControl),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Function)
    ]

    private static let keyDisplayNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "␣",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
        UInt32(kVK_ANSI_Keypad0): "Num 0",
        UInt32(kVK_ANSI_Keypad1): "Num 1",
        UInt32(kVK_ANSI_Keypad2): "Num 2",
        UInt32(kVK_ANSI_Keypad3): "Num 3",
        UInt32(kVK_ANSI_Keypad4): "Num 4",
        UInt32(kVK_ANSI_Keypad5): "Num 5",
        UInt32(kVK_ANSI_Keypad6): "Num 6",
        UInt32(kVK_ANSI_Keypad7): "Num 7",
        UInt32(kVK_ANSI_Keypad8): "Num 8",
        UInt32(kVK_ANSI_Keypad9): "Num 9",
        UInt32(kVK_ANSI_KeypadDecimal): "Num .",
        UInt32(kVK_ANSI_KeypadMultiply): "Num *",
        UInt32(kVK_ANSI_KeypadPlus): "Num +",
        UInt32(kVK_ANSI_KeypadClear): "Num Clear",
        UInt32(kVK_ANSI_KeypadDivide): "Num /",
        UInt32(kVK_ANSI_KeypadEnter): "Num ↩",
        UInt32(kVK_ANSI_KeypadMinus): "Num -",
        UInt32(kVK_ANSI_KeypadEquals): "Num ="
    ]
}
