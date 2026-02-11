import AppKit
import SwiftUI
import Combine

// MARK: - Theme Definition

struct AppTheme: Identifiable, Hashable, Equatable {
    let id: String
    let name: String
    let colors: ThemeColors
    let isCustom: Bool
    
    static func == (lhs: AppTheme, rhs: AppTheme) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ThemeColors: Equatable {
    // Launcher window colors
    var launcherBackground: Color
    var searchFieldBackground: Color
    var searchFieldBorder: Color
    var launcherBorder: Color
    var resultsBackground: Color
    
    // Search placeholder text
    var placeholderText: Color
    
    // Unselected list item colors
    var itemBackground: Color
    var itemTitleText: Color
    var itemSubtitleText: Color
    
    // Selected list item colors
    var selectedItemBackground: Color
    var selectedItemTitleText: Color
    var selectedItemSubtitleText: Color
    
    // Search highlight (matched text)
    var highlightBackground: Color
    
    // Action menu colors
    var actionMenuHeaderBackground: Color
    var actionMenuHeaderText: Color
    var destructiveAction: Color
    
    // Editor colors
    var editorBackground: Color
    var editorTextBackground: Color
    
    // Accent colors
    var accentColor: Color
    var successColor: Color
    var errorColor: Color
}

// MARK: - Color Codable Support

private struct ColorComponents: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double
    
    init(color: Color) {
        let nsColor = NSColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.opacity = Double(a)
    }
    
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}

private struct ThemeColorsData: Codable {
    let launcherBackground: ColorComponents
    let searchFieldBackground: ColorComponents
    let searchFieldBorder: ColorComponents
    let launcherBorder: ColorComponents
    let resultsBackground: ColorComponents
    let placeholderText: ColorComponents
    let itemBackground: ColorComponents
    let itemTitleText: ColorComponents
    let itemSubtitleText: ColorComponents
    let selectedItemBackground: ColorComponents
    let selectedItemTitleText: ColorComponents
    let selectedItemSubtitleText: ColorComponents
    let highlightBackground: ColorComponents
    let actionMenuHeaderBackground: ColorComponents
    let actionMenuHeaderText: ColorComponents
    let destructiveAction: ColorComponents
    let editorBackground: ColorComponents
    let editorTextBackground: ColorComponents
    let accentColor: ColorComponents
    let successColor: ColorComponents
    let errorColor: ColorComponents
    
    init(colors: ThemeColors) {
        self.launcherBackground = ColorComponents(color: colors.launcherBackground)
        self.searchFieldBackground = ColorComponents(color: colors.searchFieldBackground)
        self.searchFieldBorder = ColorComponents(color: colors.searchFieldBorder)
        self.launcherBorder = ColorComponents(color: colors.launcherBorder)
        self.resultsBackground = ColorComponents(color: colors.resultsBackground)
        self.placeholderText = ColorComponents(color: colors.placeholderText)
        self.itemBackground = ColorComponents(color: colors.itemBackground)
        self.itemTitleText = ColorComponents(color: colors.itemTitleText)
        self.itemSubtitleText = ColorComponents(color: colors.itemSubtitleText)
        self.selectedItemBackground = ColorComponents(color: colors.selectedItemBackground)
        self.selectedItemTitleText = ColorComponents(color: colors.selectedItemTitleText)
        self.selectedItemSubtitleText = ColorComponents(color: colors.selectedItemSubtitleText)
        self.highlightBackground = ColorComponents(color: colors.highlightBackground)
        self.actionMenuHeaderBackground = ColorComponents(color: colors.actionMenuHeaderBackground)
        self.actionMenuHeaderText = ColorComponents(color: colors.actionMenuHeaderText)
        self.destructiveAction = ColorComponents(color: colors.destructiveAction)
        self.editorBackground = ColorComponents(color: colors.editorBackground)
        self.editorTextBackground = ColorComponents(color: colors.editorTextBackground)
        self.accentColor = ColorComponents(color: colors.accentColor)
        self.successColor = ColorComponents(color: colors.successColor)
        self.errorColor = ColorComponents(color: colors.errorColor)
    }
    
    var colors: ThemeColors {
        ThemeColors(
            launcherBackground: launcherBackground.color,
            searchFieldBackground: searchFieldBackground.color,
            searchFieldBorder: searchFieldBorder.color,
            launcherBorder: launcherBorder.color,
            resultsBackground: resultsBackground.color,
            placeholderText: placeholderText.color,
            itemBackground: itemBackground.color,
            itemTitleText: itemTitleText.color,
            itemSubtitleText: itemSubtitleText.color,
            selectedItemBackground: selectedItemBackground.color,
            selectedItemTitleText: selectedItemTitleText.color,
            selectedItemSubtitleText: selectedItemSubtitleText.color,
            highlightBackground: highlightBackground.color,
            actionMenuHeaderBackground: actionMenuHeaderBackground.color,
            actionMenuHeaderText: actionMenuHeaderText.color,
            destructiveAction: destructiveAction.color,
            editorBackground: editorBackground.color,
            editorTextBackground: editorTextBackground.color,
            accentColor: accentColor.color,
            successColor: successColor.color,
            errorColor: errorColor.color
        )
    }
}

// MARK: - Predefined Themes

extension AppTheme {
    // MARK: Default (Light)
    static let `default` = AppTheme(
        id: "default",
        name: "Default",
        colors: ThemeColors(
            launcherBackground: Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255),
            searchFieldBackground: Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255, opacity: 252 / 255),
            searchFieldBorder: Color.black.opacity(0.12),
            launcherBorder: Color.black.opacity(35 / 255),
            resultsBackground: Color.clear,
            placeholderText: Color(white: 150 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(white: 35 / 255),
            itemSubtitleText: Color(white: 70 / 255),
            selectedItemBackground: Color(red: 230 / 255, green: 236 / 255, blue: 245 / 255),
            selectedItemTitleText: Color(white: 20 / 255),
            selectedItemSubtitleText: Color(white: 70 / 255),
            highlightBackground: Color.yellow.opacity(0.55),
            actionMenuHeaderBackground: Color(white: 240 / 255),
            actionMenuHeaderText: Color(white: 50 / 255),
            destructiveAction: Color.red,
            editorBackground: Color(nsColor: .windowBackgroundColor),
            editorTextBackground: Color(nsColor: .textBackgroundColor),
            accentColor: Color(nsColor: .systemBlue),
            successColor: Color(nsColor: .systemGreen),
            errorColor: Color(nsColor: .systemRed)
        ),
        isCustom: false
    )
    
    // MARK: Dark
    static let dark = AppTheme(
        id: "dark",
        name: "Dark",
        colors: ThemeColors(
            launcherBackground: Color(red: 30 / 255, green: 30 / 255, blue: 32 / 255),
            searchFieldBackground: Color(red: 45 / 255, green: 45 / 255, blue: 48 / 255),
            searchFieldBorder: Color.white.opacity(0.15),
            launcherBorder: Color.white.opacity(0.2),
            resultsBackground: Color.clear,
            placeholderText: Color(white: 100 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(white: 230 / 255),
            itemSubtitleText: Color(white: 160 / 255),
            selectedItemBackground: Color(red: 45 / 255, green: 85 / 255, blue: 145 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(white: 200 / 255),
            highlightBackground: Color.orange.opacity(0.6),
            actionMenuHeaderBackground: Color(red: 45 / 255, green: 45 / 255, blue: 48 / 255),
            actionMenuHeaderText: Color(white: 200 / 255),
            destructiveAction: Color(red: 255 / 255, green: 100 / 255, blue: 100 / 255),
            editorBackground: Color(red: 35 / 255, green: 35 / 255, blue: 38 / 255),
            editorTextBackground: Color(red: 45 / 255, green: 45 / 255, blue: 48 / 255),
            accentColor: Color(red: 100 / 255, green: 170 / 255, blue: 255 / 255),
            successColor: Color(red: 100 / 255, green: 210 / 255, blue: 130 / 255),
            errorColor: Color(red: 255 / 255, green: 100 / 255, blue: 100 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Midnight Blue
    static let midnightBlue = AppTheme(
        id: "midnightBlue",
        name: "Midnight Blue",
        colors: ThemeColors(
            launcherBackground: Color(red: 20 / 255, green: 25 / 255, blue: 40 / 255),
            searchFieldBackground: Color(red: 30 / 255, green: 38 / 255, blue: 60 / 255),
            searchFieldBorder: Color(red: 70 / 255, green: 100 / 255, blue: 150 / 255).opacity(0.4),
            launcherBorder: Color(red: 70 / 255, green: 100 / 255, blue: 150 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 100 / 255, green: 120 / 255, blue: 150 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 220 / 255, green: 230 / 255, blue: 245 / 255),
            itemSubtitleText: Color(red: 150 / 255, green: 170 / 255, blue: 200 / 255),
            selectedItemBackground: Color(red: 50 / 255, green: 100 / 255, blue: 170 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 200 / 255, green: 220 / 255, blue: 245 / 255),
            highlightBackground: Color.cyan.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 30 / 255, green: 38 / 255, blue: 60 / 255),
            actionMenuHeaderText: Color(red: 180 / 255, green: 200 / 255, blue: 230 / 255),
            destructiveAction: Color(red: 255 / 255, green: 120 / 255, blue: 120 / 255),
            editorBackground: Color(red: 18 / 255, green: 23 / 255, blue: 38 / 255),
            editorTextBackground: Color(red: 28 / 255, green: 35 / 255, blue: 55 / 255),
            accentColor: Color(red: 100 / 255, green: 180 / 255, blue: 255 / 255),
            successColor: Color(red: 100 / 255, green: 220 / 255, blue: 150 / 255),
            errorColor: Color(red: 255 / 255, green: 120 / 255, blue: 120 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Forest Green
    static let forestGreen = AppTheme(
        id: "forestGreen",
        name: "Forest Green",
        colors: ThemeColors(
            launcherBackground: Color(red: 28 / 255, green: 38 / 255, blue: 30 / 255),
            searchFieldBackground: Color(red: 38 / 255, green: 52 / 255, blue: 42 / 255),
            searchFieldBorder: Color(red: 80 / 255, green: 140 / 255, blue: 100 / 255).opacity(0.4),
            launcherBorder: Color(red: 80 / 255, green: 140 / 255, blue: 100 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 100 / 255, green: 140 / 255, blue: 120 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 230 / 255, green: 240 / 255, blue: 235 / 255),
            itemSubtitleText: Color(red: 160 / 255, green: 190 / 255, blue: 170 / 255),
            selectedItemBackground: Color(red: 60 / 255, green: 130 / 255, blue: 90 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 200 / 255, green: 230 / 255, blue: 210 / 255),
            highlightBackground: Color.green.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 38 / 255, green: 52 / 255, blue: 42 / 255),
            actionMenuHeaderText: Color(red: 180 / 255, green: 210 / 255, blue: 190 / 255),
            destructiveAction: Color(red: 255 / 255, green: 120 / 255, blue: 120 / 255),
            editorBackground: Color(red: 24 / 255, green: 34 / 255, blue: 28 / 255),
            editorTextBackground: Color(red: 34 / 255, green: 48 / 255, blue: 40 / 255),
            accentColor: Color(red: 120 / 255, green: 200 / 255, blue: 140 / 255),
            successColor: Color(red: 100 / 255, green: 220 / 255, blue: 140 / 255),
            errorColor: Color(red: 255 / 255, green: 120 / 255, blue: 120 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Warm Amber
    static let warmAmber = AppTheme(
        id: "warmAmber",
        name: "Warm Amber",
        colors: ThemeColors(
            launcherBackground: Color(red: 42 / 255, green: 35 / 255, blue: 28 / 255),
            searchFieldBackground: Color(red: 55 / 255, green: 46 / 255, blue: 36 / 255),
            searchFieldBorder: Color(red: 180 / 255, green: 140 / 255, blue: 80 / 255).opacity(0.4),
            launcherBorder: Color(red: 180 / 255, green: 140 / 255, blue: 80 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 140 / 255, green: 120 / 255, blue: 100 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 250 / 255, green: 245 / 255, blue: 235 / 255),
            itemSubtitleText: Color(red: 200 / 255, green: 180 / 255, blue: 150 / 255),
            selectedItemBackground: Color(red: 180 / 255, green: 130 / 255, blue: 60 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 245 / 255, green: 230 / 255, blue: 200 / 255),
            highlightBackground: Color.orange.opacity(0.6),
            actionMenuHeaderBackground: Color(red: 55 / 255, green: 46 / 255, blue: 36 / 255),
            actionMenuHeaderText: Color(red: 220 / 255, green: 200 / 255, blue: 170 / 255),
            destructiveAction: Color(red: 255 / 255, green: 120 / 255, blue: 120 / 255),
            editorBackground: Color(red: 38 / 255, green: 32 / 255, blue: 26 / 255),
            editorTextBackground: Color(red: 50 / 255, green: 42 / 255, blue: 34 / 255),
            accentColor: Color(red: 255 / 255, green: 180 / 255, blue: 80 / 255),
            successColor: Color(red: 140 / 255, green: 220 / 255, blue: 120 / 255),
            errorColor: Color(red: 255 / 255, green: 120 / 255, blue: 120 / 255)
        ),
        isCustom: false
    )
    
    // MARK: High Contrast (Accessibility)
    static let highContrast = AppTheme(
        id: "highContrast",
        name: "High Contrast",
        colors: ThemeColors(
            launcherBackground: Color.black,
            searchFieldBackground: Color.black,
            searchFieldBorder: Color.white,
            launcherBorder: Color.white,
            resultsBackground: Color.clear,
            placeholderText: Color(white: 150 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color.white,
            itemSubtitleText: Color(white: 200 / 255),
            selectedItemBackground: Color.yellow,
            selectedItemTitleText: Color.black,
            selectedItemSubtitleText: Color(white: 30 / 255),
            highlightBackground: Color.cyan,
            actionMenuHeaderBackground: Color(white: 30 / 255),
            actionMenuHeaderText: Color.white,
            destructiveAction: Color(red: 255 / 255, green: 100 / 255, blue: 100 / 255),
            editorBackground: Color.black,
            editorTextBackground: Color(white: 15 / 255),
            accentColor: Color.cyan,
            successColor: Color.green,
            errorColor: Color.red
        ),
        isCustom: false
    )
    
    // MARK: Custom Theme (user-defined)
    static let defaultCustomColors = ThemeColors(
        launcherBackground: Color(red: 40 / 255, green: 40 / 255, blue: 45 / 255),
        searchFieldBackground: Color(red: 55 / 255, green: 55 / 255, blue: 60 / 255),
        searchFieldBorder: Color.white.opacity(0.2),
        launcherBorder: Color.white.opacity(0.25),
        resultsBackground: Color.clear,
        placeholderText: Color(white: 110 / 255),
        itemBackground: Color.clear,
        itemTitleText: Color(white: 240 / 255),
        itemSubtitleText: Color(white: 170 / 255),
        selectedItemBackground: Color(red: 60 / 255, green: 120 / 255, blue: 200 / 255),
        selectedItemTitleText: Color.white,
        selectedItemSubtitleText: Color(white: 220 / 255),
        highlightBackground: Color.yellow.opacity(0.5),
        actionMenuHeaderBackground: Color(red: 55 / 255, green: 55 / 255, blue: 60 / 255),
        actionMenuHeaderText: Color(white: 210 / 255),
        destructiveAction: Color(red: 255 / 255, green: 100 / 255, blue: 100 / 255),
        editorBackground: Color(red: 35 / 255, green: 35 / 255, blue: 40 / 255),
        editorTextBackground: Color(red: 50 / 255, green: 50 / 255, blue: 55 / 255),
        accentColor: Color(red: 100 / 255, green: 170 / 255, blue: 255 / 255),
        successColor: Color(red: 100 / 255, green: 210 / 255, blue: 130 / 255),
        errorColor: Color(red: 255 / 255, green: 100 / 255, blue: 100 / 255)
    )
    
    static let custom = AppTheme(
        id: "custom",
        name: "Custom",
        colors: defaultCustomColors,
        isCustom: true
    )
    
    static let allThemes: [AppTheme] = [.default, .dark, .midnightBlue, .forestGreen, .warmAmber, .highContrast, .custom]
}

// MARK: - Theme Manager

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    static let themeChangedNotification = Notification.Name("ThemeManager.themeChanged")
    static let customColorsKey = "customThemeColors"
    
    private let selectedThemeKey = "selectedThemeId"
    
    @Published var currentTheme: AppTheme
    @Published var customColors: ThemeColors
    
    var colors: ThemeColors {
        currentTheme.isCustom ? customColors : currentTheme.colors
    }
    
    private init() {
        // Load custom colors first
        let loadedColors: ThemeColors
        if let data = UserDefaults.standard.data(forKey: ThemeManager.customColorsKey) {
            do {
                let decoded = try JSONDecoder().decode(ThemeColorsData.self, from: data)
                loadedColors = decoded.colors
                print("[ThemeManager] Loaded custom colors from UserDefaults")
            } catch {
                print("[ThemeManager] Failed to decode custom colors: \(error)")
                loadedColors = AppTheme.defaultCustomColors
            }
        } else {
            print("[ThemeManager] No saved custom colors found, using defaults")
            loadedColors = AppTheme.defaultCustomColors
        }
        
        // Load selected theme
        let savedId = UserDefaults.standard.string(forKey: selectedThemeKey)
        let loadedTheme: AppTheme
        if let savedId = savedId {
            if savedId == "custom" {
                loadedTheme = AppTheme(
                    id: "custom",
                    name: "Custom",
                    colors: loadedColors,
                    isCustom: true
                )
                print("[ThemeManager] Loaded custom theme")
            } else if let theme = AppTheme.allThemes.first(where: { $0.id == savedId }) {
                loadedTheme = theme
                print("[ThemeManager] Loaded theme: \(savedId)")
            } else {
                loadedTheme = .default
                print("[ThemeManager] Unknown theme id, using default")
            }
        } else {
            loadedTheme = .default
            print("[ThemeManager] No saved theme, using default")
        }
        
        // Initialize stored properties
        currentTheme = loadedTheme
        customColors = loadedColors
    }
    
    func updateCustomColors(_ newColors: ThemeColors) {
        customColors = newColors
        saveCustomColors()
        if currentTheme.isCustom {
            // Update current theme if we're using custom
            currentTheme = AppTheme(
                id: "custom",
                name: "Custom",
                colors: customColors,
                isCustom: true
            )
            NotificationCenter.default.post(name: Self.themeChangedNotification, object: nil)
        }
    }
    
    func setTheme(_ theme: AppTheme) {
        if theme.isCustom {
            // Use our saved custom colors
            currentTheme = AppTheme(
                id: "custom",
                name: "Custom",
                colors: customColors,
                isCustom: true
            )
        } else {
            currentTheme = theme
        }
        saveThemePreference()
        NotificationCenter.default.post(name: Self.themeChangedNotification, object: nil)
    }
    
    func setTheme(byId id: String) {
        if id == "custom" {
            currentTheme = AppTheme(
                id: "custom",
                name: "Custom",
                colors: customColors,
                isCustom: true
            )
        } else if let theme = AppTheme.allThemes.first(where: { $0.id == id }) {
            currentTheme = theme
        }
        saveThemePreference()
        NotificationCenter.default.post(name: Self.themeChangedNotification, object: nil)
    }
    
    func updateCustomColor(_ color: Color, for keyPath: WritableKeyPath<ThemeColors, Color>) {
        var updatedColors = customColors
        updatedColors[keyPath: keyPath] = color
        updateCustomColors(updatedColors)
    }
    
    func saveThemePreference() {
        UserDefaults.standard.set(currentTheme.id, forKey: selectedThemeKey)
        UserDefaults.standard.synchronize()
        print("[ThemeManager] Saved theme preference: \(currentTheme.id)")
    }
    
    func saveCustomColors() {
        let data = ThemeColorsData(colors: customColors)
        do {
            let encoded = try JSONEncoder().encode(data)
            UserDefaults.standard.set(encoded, forKey: ThemeManager.customColorsKey)
            UserDefaults.standard.synchronize()
            print("[ThemeManager] Saved custom colors")
        } catch {
            print("[ThemeManager] Failed to encode custom colors: \(error)")
        }
    }
}

// MARK: - Environment Key

private struct ThemeManagerKey: EnvironmentKey {
    static let defaultValue = ThemeManager.shared
}

extension EnvironmentValues {
    var themeManager: ThemeManager {
        get { self[ThemeManagerKey.self] }
        set { }
    }
}

// MARK: - View Modifiers

struct ThemedBackgroundModifier: ViewModifier {
    @EnvironmentObject var themeManager: ThemeManager
    var color: (ThemeColors) -> Color
    
    func body(content: Content) -> some View {
        content.background(color(themeManager.colors))
    }
}

struct ThemedForegroundModifier: ViewModifier {
    @EnvironmentObject var themeManager: ThemeManager
    var color: (ThemeColors) -> Color
    
    func body(content: Content) -> some View {
        content.foregroundStyle(color(themeManager.colors))
    }
}

extension View {
    func themedBackground(_ color: @escaping (ThemeColors) -> Color) -> some View {
        self.modifier(ThemedBackgroundModifier(color: color))
    }
    
    func themedForeground(_ color: @escaping (ThemeColors) -> Color) -> some View {
        self.modifier(ThemedForegroundModifier(color: color))
    }
}
