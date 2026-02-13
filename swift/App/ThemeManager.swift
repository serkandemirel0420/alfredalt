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
    // MARK: Default (Spotlight Style)
    static let `default` = AppTheme(
        id: "default",
        name: "Default",
        colors: ThemeColors(
            launcherBackground: Color(red: 230 / 255, green: 226 / 255, blue: 235 / 255),
            searchFieldBackground: Color(red: 245 / 255, green: 243 / 255, blue: 247 / 255),
            searchFieldBorder: Color.black.opacity(0.08),
            launcherBorder: Color.black.opacity(0.15),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 120 / 255, green: 120 / 255, blue: 130 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 40 / 255, green: 40 / 255, blue: 45 / 255),
            itemSubtitleText: Color(red: 100 / 255, green: 100 / 255, blue: 110 / 255),
            selectedItemBackground: Color(red: 94 / 255, green: 42 / 255, blue: 126 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 220 / 255, green: 210 / 255, blue: 230 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 220 / 255, green: 216 / 255, blue: 225 / 255),
            actionMenuHeaderText: Color(red: 60 / 255, green: 60 / 255, blue: 65 / 255),
            destructiveAction: Color.red,
            editorBackground: Color(red: 245 / 255, green: 243 / 255, blue: 247 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 94 / 255, green: 42 / 255, blue: 126 / 255),
            successColor: Color(red: 50 / 255, green: 170 / 255, blue: 80 / 255),
            errorColor: Color.red
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
    
    // MARK: Ocean Blue
    static let oceanBlue = AppTheme(
        id: "oceanBlue",
        name: "Ocean Blue",
        colors: ThemeColors(
            launcherBackground: Color(red: 230 / 255, green: 240 / 255, blue: 250 / 255),
            searchFieldBackground: Color(red: 245 / 255, green: 248 / 255, blue: 252 / 255),
            searchFieldBorder: Color(red: 100 / 255, green: 150 / 255, blue: 200 / 255).opacity(0.3),
            launcherBorder: Color(red: 80 / 255, green: 130 / 255, blue: 180 / 255).opacity(0.4),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 100 / 255, green: 130 / 255, blue: 160 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 30 / 255, green: 60 / 255, blue: 100 / 255),
            itemSubtitleText: Color(red: 80 / 255, green: 110 / 255, blue: 140 / 255),
            selectedItemBackground: Color(red: 40 / 255, green: 100 / 255, blue: 160 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 200 / 255, green: 220 / 255, blue: 240 / 255),
            highlightBackground: Color.cyan.opacity(0.4),
            actionMenuHeaderBackground: Color(red: 220 / 255, green: 230 / 255, blue: 240 / 255),
            actionMenuHeaderText: Color(red: 50 / 255, green: 80 / 255, blue: 120 / 255),
            destructiveAction: Color(red: 200 / 255, green: 60 / 255, blue: 60 / 255),
            editorBackground: Color(red: 240 / 255, green: 246 / 255, blue: 252 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 40 / 255, green: 100 / 255, blue: 160 / 255),
            successColor: Color(red: 50 / 255, green: 160 / 255, blue: 90 / 255),
            errorColor: Color(red: 200 / 255, green: 60 / 255, blue: 60 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Cherry Blossom
    static let cherryBlossom = AppTheme(
        id: "cherryBlossom",
        name: "Cherry Blossom",
        colors: ThemeColors(
            launcherBackground: Color(red: 252 / 255, green: 235 / 255, blue: 240 / 255),
            searchFieldBackground: Color(red: 255 / 255, green: 245 / 255, blue: 248 / 255),
            searchFieldBorder: Color(red: 220 / 255, green: 160 / 255, blue: 180 / 255).opacity(0.4),
            launcherBorder: Color(red: 200 / 255, green: 140 / 255, blue: 160 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 160 / 255, green: 120 / 255, blue: 140 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 80 / 255, green: 40 / 255, blue: 60 / 255),
            itemSubtitleText: Color(red: 140 / 255, green: 100 / 255, blue: 120 / 255),
            selectedItemBackground: Color(red: 200 / 255, green: 100 / 255, blue: 140 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 255 / 255, green: 220 / 255, blue: 230 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 245 / 255, green: 225 / 255, blue: 232 / 255),
            actionMenuHeaderText: Color(red: 100 / 255, green: 60 / 255, blue: 80 / 255),
            destructiveAction: Color(red: 180 / 255, green: 50 / 255, blue: 70 / 255),
            editorBackground: Color(red: 255 / 255, green: 245 / 255, blue: 248 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 200 / 255, green: 100 / 255, blue: 140 / 255),
            successColor: Color(red: 80 / 255, green: 160 / 255, blue: 100 / 255),
            errorColor: Color(red: 180 / 255, green: 50 / 255, blue: 70 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Sunset Orange
    static let sunsetOrange = AppTheme(
        id: "sunsetOrange",
        name: "Sunset Orange",
        colors: ThemeColors(
            launcherBackground: Color(red: 255 / 255, green: 240 / 255, blue: 230 / 255),
            searchFieldBackground: Color(red: 255 / 255, green: 248 / 255, blue: 242 / 255),
            searchFieldBorder: Color(red: 230 / 255, green: 140 / 255, blue: 100 / 255).opacity(0.4),
            launcherBorder: Color(red: 220 / 255, green: 120 / 255, blue: 80 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 160 / 255, green: 120 / 255, blue: 100 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 100 / 255, green: 50 / 255, blue: 30 / 255),
            itemSubtitleText: Color(red: 150 / 255, green: 100 / 255, blue: 80 / 255),
            selectedItemBackground: Color(red: 220 / 255, green: 100 / 255, blue: 60 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 255 / 255, green: 220 / 255, blue: 200 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 250 / 255, green: 230 / 255, blue: 220 / 255),
            actionMenuHeaderText: Color(red: 120 / 255, green: 70 / 255, blue: 50 / 255),
            destructiveAction: Color(red: 180 / 255, green: 40 / 255, blue: 60 / 255),
            editorBackground: Color(red: 255 / 255, green: 248 / 255, blue: 242 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 220 / 255, green: 100 / 255, blue: 60 / 255),
            successColor: Color(red: 60 / 255, green: 150 / 255, blue: 80 / 255),
            errorColor: Color(red: 180 / 255, green: 40 / 255, blue: 60 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Slate Gray
    static let slateGray = AppTheme(
        id: "slateGray",
        name: "Slate Gray",
        colors: ThemeColors(
            launcherBackground: Color(red: 220 / 255, green: 225 / 255, blue: 230 / 255),
            searchFieldBackground: Color(red: 235 / 255, green: 238 / 255, blue: 242 / 255),
            searchFieldBorder: Color(red: 120 / 255, green: 130 / 255, blue: 140 / 255).opacity(0.4),
            launcherBorder: Color(red: 100 / 255, green: 110 / 255, blue: 120 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 130 / 255, green: 135 / 255, blue: 140 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 50 / 255, green: 55 / 255, blue: 60 / 255),
            itemSubtitleText: Color(red: 100 / 255, green: 105 / 255, blue: 110 / 255),
            selectedItemBackground: Color(red: 80 / 255, green: 90 / 255, blue: 100 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 210 / 255, green: 215 / 255, blue: 220 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 210 / 255, green: 215 / 255, blue: 220 / 255),
            actionMenuHeaderText: Color(red: 60 / 255, green: 65 / 255, blue: 70 / 255),
            destructiveAction: Color(red: 180 / 255, green: 50 / 255, blue: 60 / 255),
            editorBackground: Color(red: 235 / 255, green: 238 / 255, blue: 242 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 80 / 255, green: 90 / 255, blue: 100 / 255),
            successColor: Color(red: 60 / 255, green: 140 / 255, blue: 80 / 255),
            errorColor: Color(red: 180 / 255, green: 50 / 255, blue: 60 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Mint Green
    static let mintGreen = AppTheme(
        id: "mintGreen",
        name: "Mint Green",
        colors: ThemeColors(
            launcherBackground: Color(red: 230 / 255, green: 248 / 255, blue: 240 / 255),
            searchFieldBackground: Color(red: 242 / 255, green: 252 / 255, blue: 248 / 255),
            searchFieldBorder: Color(red: 120 / 255, green: 200 / 255, blue: 160 / 255).opacity(0.4),
            launcherBorder: Color(red: 100 / 255, green: 180 / 255, blue: 140 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 100 / 255, green: 140 / 255, blue: 120 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 30 / 255, green: 80 / 255, blue: 60 / 255),
            itemSubtitleText: Color(red: 80 / 255, green: 130 / 255, blue: 100 / 255),
            selectedItemBackground: Color(red: 60 / 255, green: 160 / 255, blue: 120 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 210 / 255, green: 245 / 255, blue: 230 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 220 / 255, green: 240 / 255, blue: 232 / 255),
            actionMenuHeaderText: Color(red: 50 / 255, green: 100 / 255, blue: 80 / 255),
            destructiveAction: Color(red: 180 / 255, green: 60 / 255, blue: 70 / 255),
            editorBackground: Color(red: 242 / 255, green: 252 / 255, blue: 248 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 60 / 255, green: 160 / 255, blue: 120 / 255),
            successColor: Color(red: 50 / 255, green: 150 / 255, blue: 80 / 255),
            errorColor: Color(red: 180 / 255, green: 60 / 255, blue: 70 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Coral Reef
    static let coralReef = AppTheme(
        id: "coralReef",
        name: "Coral Reef",
        colors: ThemeColors(
            launcherBackground: Color(red: 255 / 255, green: 235 / 255, blue: 230 / 255),
            searchFieldBackground: Color(red: 255 / 255, green: 245 / 255, blue: 242 / 255),
            searchFieldBorder: Color(red: 240 / 255, green: 140 / 255, blue: 130 / 255).opacity(0.4),
            launcherBorder: Color(red: 230 / 255, green: 120 / 255, blue: 110 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 170 / 255, green: 120 / 255, blue: 110 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 110 / 255, green: 50 / 255, blue: 40 / 255),
            itemSubtitleText: Color(red: 160 / 255, green: 100 / 255, blue: 90 / 255),
            selectedItemBackground: Color(red: 230 / 255, green: 100 / 255, blue: 90 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 255 / 255, green: 220 / 255, blue: 215 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 250 / 255, green: 225 / 255, blue: 220 / 255),
            actionMenuHeaderText: Color(red: 130 / 255, green: 70 / 255, blue: 60 / 255),
            destructiveAction: Color(red: 180 / 255, green: 50 / 255, blue: 70 / 255),
            editorBackground: Color(red: 255 / 255, green: 245 / 255, blue: 242 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 230 / 255, green: 100 / 255, blue: 90 / 255),
            successColor: Color(red: 60 / 255, green: 150 / 255, blue: 100 / 255),
            errorColor: Color(red: 180 / 255, green: 50 / 255, blue: 70 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Deep Space
    static let deepSpace = AppTheme(
        id: "deepSpace",
        name: "Deep Space",
        colors: ThemeColors(
            launcherBackground: Color(red: 15 / 255, green: 15 / 255, blue: 25 / 255),
            searchFieldBackground: Color(red: 30 / 255, green: 30 / 255, blue: 45 / 255),
            searchFieldBorder: Color(red: 80 / 255, green: 80 / 255, blue: 120 / 255).opacity(0.5),
            launcherBorder: Color(red: 60 / 255, green: 60 / 255, blue: 100 / 255).opacity(0.6),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 100 / 255, green: 100 / 255, blue: 130 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 220 / 255, green: 220 / 255, blue: 245 / 255),
            itemSubtitleText: Color(red: 150 / 255, green: 150 / 255, blue: 180 / 255),
            selectedItemBackground: Color(red: 100 / 255, green: 80 / 255, blue: 180 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 200 / 255, green: 190 / 255, blue: 230 / 255),
            highlightBackground: Color(red: 255 / 255, green: 200 / 255, blue: 100 / 255).opacity(0.4),
            actionMenuHeaderBackground: Color(red: 25 / 255, green: 25 / 255, blue: 40 / 255),
            actionMenuHeaderText: Color(red: 180 / 255, green: 180 / 255, blue: 210 / 255),
            destructiveAction: Color(red: 255 / 255, green: 100 / 255, blue: 120 / 255),
            editorBackground: Color(red: 20 / 255, green: 20 / 255, blue: 35 / 255),
            editorTextBackground: Color(red: 35 / 255, green: 35 / 255, blue: 50 / 255),
            accentColor: Color(red: 140 / 255, green: 120 / 255, blue: 220 / 255),
            successColor: Color(red: 100 / 255, green: 220 / 255, blue: 140 / 255),
            errorColor: Color(red: 255 / 255, green: 100 / 255, blue: 120 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Coffee Cream
    static let coffeeCream = AppTheme(
        id: "coffeeCream",
        name: "Coffee Cream",
        colors: ThemeColors(
            launcherBackground: Color(red: 245 / 255, green: 235 / 255, blue: 220 / 255),
            searchFieldBackground: Color(red: 252 / 255, green: 248 / 255, blue: 242 / 255),
            searchFieldBorder: Color(red: 180 / 255, green: 150 / 255, blue: 120 / 255).opacity(0.4),
            launcherBorder: Color(red: 160 / 255, green: 130 / 255, blue: 100 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 140 / 255, green: 120 / 255, blue: 100 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 80 / 255, green: 60 / 255, blue: 40 / 255),
            itemSubtitleText: Color(red: 130 / 255, green: 110 / 255, blue: 90 / 255),
            selectedItemBackground: Color(red: 140 / 255, green: 100 / 255, blue: 60 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 240 / 255, green: 220 / 255, blue: 200 / 255),
            highlightBackground: Color.orange.opacity(0.4),
            actionMenuHeaderBackground: Color(red: 235 / 255, green: 225 / 255, blue: 210 / 255),
            actionMenuHeaderText: Color(red: 100 / 255, green: 80 / 255, blue: 60 / 255),
            destructiveAction: Color(red: 180 / 255, green: 60 / 255, blue: 60 / 255),
            editorBackground: Color(red: 252 / 255, green: 248 / 255, blue: 242 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 140 / 255, green: 100 / 255, blue: 60 / 255),
            successColor: Color(red: 80 / 255, green: 140 / 255, blue: 80 / 255),
            errorColor: Color(red: 180 / 255, green: 60 / 255, blue: 60 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Royal Gold
    static let royalGold = AppTheme(
        id: "royalGold",
        name: "Royal Gold",
        colors: ThemeColors(
            launcherBackground: Color(red: 250 / 255, green: 245 / 255, blue: 230 / 255),
            searchFieldBackground: Color(red: 255 / 255, green: 252 / 255, blue: 245 / 255),
            searchFieldBorder: Color(red: 200 / 255, green: 170 / 255, blue: 100 / 255).opacity(0.4),
            launcherBorder: Color(red: 180 / 255, green: 150 / 255, blue: 80 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 150 / 255, green: 130 / 255, blue: 100 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 100 / 255, green: 80 / 255, blue: 40 / 255),
            itemSubtitleText: Color(red: 150 / 255, green: 130 / 255, blue: 90 / 255),
            selectedItemBackground: Color(red: 180 / 255, green: 140 / 255, blue: 50 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 255 / 255, green: 240 / 255, blue: 210 / 255),
            highlightBackground: Color.yellow.opacity(0.5),
            actionMenuHeaderBackground: Color(red: 240 / 255, green: 235 / 255, blue: 220 / 255),
            actionMenuHeaderText: Color(red: 120 / 255, green: 100 / 255, blue: 60 / 255),
            destructiveAction: Color(red: 180 / 255, green: 60 / 255, blue: 60 / 255),
            editorBackground: Color(red: 255 / 255, green: 252 / 255, blue: 245 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 180 / 255, green: 140 / 255, blue: 50 / 255),
            successColor: Color(red: 80 / 255, green: 150 / 255, blue: 80 / 255),
            errorColor: Color(red: 180 / 255, green: 60 / 255, blue: 60 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Neon Cyberpunk
    static let neonCyberpunk = AppTheme(
        id: "neonCyberpunk",
        name: "Neon Cyberpunk",
        colors: ThemeColors(
            launcherBackground: Color(red: 10 / 255, green: 10 / 255, blue: 20 / 255),
            searchFieldBackground: Color(red: 20 / 255, green: 20 / 255, blue: 35 / 255),
            searchFieldBorder: Color(red: 255 / 255, green: 0 / 255, blue: 255 / 255).opacity(0.6),
            launcherBorder: Color(red: 0 / 255, green: 255 / 255, blue: 255 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 150 / 255, green: 150 / 255, blue: 180 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 255 / 255, green: 255 / 255, blue: 200 / 255),
            itemSubtitleText: Color(red: 180 / 255, green: 180 / 255, blue: 200 / 255),
            selectedItemBackground: Color(red: 255 / 255, green: 0 / 255, blue: 255 / 255),
            selectedItemTitleText: Color.black,
            selectedItemSubtitleText: Color(red: 60 / 255, green: 0 / 255, blue: 60 / 255),
            highlightBackground: Color(red: 0 / 255, green: 255 / 255, blue: 255 / 255).opacity(0.4),
            actionMenuHeaderBackground: Color(red: 20 / 255, green: 20 / 255, blue: 35 / 255),
            actionMenuHeaderText: Color(red: 0 / 255, green: 255 / 255, blue: 255 / 255),
            destructiveAction: Color(red: 255 / 255, green: 50 / 255, blue: 50 / 255),
            editorBackground: Color(red: 15 / 255, green: 15 / 255, blue: 25 / 255),
            editorTextBackground: Color(red: 30 / 255, green: 30 / 255, blue: 45 / 255),
            accentColor: Color(red: 0 / 255, green: 255 / 255, blue: 255 / 255),
            successColor: Color(red: 0 / 255, green: 255 / 255, blue: 100 / 255),
            errorColor: Color(red: 255 / 255, green: 50 / 255, blue: 100 / 255)
        ),
        isCustom: false
    )
    
    // MARK: Lavender Dream
    static let lavenderDream = AppTheme(
        id: "lavenderDream",
        name: "Lavender Dream",
        colors: ThemeColors(
            launcherBackground: Color(red: 240 / 255, green: 235 / 255, blue: 250 / 255),
            searchFieldBackground: Color(red: 248 / 255, green: 245 / 255, blue: 252 / 255),
            searchFieldBorder: Color(red: 160 / 255, green: 140 / 255, blue: 200 / 255).opacity(0.4),
            launcherBorder: Color(red: 140 / 255, green: 120 / 255, blue: 180 / 255).opacity(0.5),
            resultsBackground: Color.clear,
            placeholderText: Color(red: 130 / 255, green: 120 / 255, blue: 150 / 255),
            itemBackground: Color.clear,
            itemTitleText: Color(red: 70 / 255, green: 50 / 255, blue: 100 / 255),
            itemSubtitleText: Color(red: 120 / 255, green: 100 / 255, blue: 150 / 255),
            selectedItemBackground: Color(red: 140 / 255, green: 100 / 255, blue: 200 / 255),
            selectedItemTitleText: Color.white,
            selectedItemSubtitleText: Color(red: 230 / 255, green: 215 / 255, blue: 250 / 255),
            highlightBackground: Color.pink.opacity(0.4),
            actionMenuHeaderBackground: Color(red: 230 / 255, green: 225 / 255, blue: 240 / 255),
            actionMenuHeaderText: Color(red: 90 / 255, green: 70 / 255, blue: 120 / 255),
            destructiveAction: Color(red: 200 / 255, green: 70 / 255, blue: 90 / 255),
            editorBackground: Color(red: 248 / 255, green: 245 / 255, blue: 252 / 255),
            editorTextBackground: Color.white,
            accentColor: Color(red: 140 / 255, green: 100 / 255, blue: 200 / 255),
            successColor: Color(red: 90 / 255, green: 170 / 255, blue: 100 / 255),
            errorColor: Color(red: 200 / 255, green: 70 / 255, blue: 90 / 255)
        ),
        isCustom: false
    )
    
    static let custom = AppTheme(
        id: "custom",
        name: "Custom",
        colors: defaultCustomColors,
        isCustom: true
    )
    
    static let allThemes: [AppTheme] = [.default, .dark, .midnightBlue, .forestGreen, .warmAmber, .oceanBlue, .cherryBlossom, .sunsetOrange, .slateGray, .mintGreen, .coralReef, .deepSpace, .coffeeCream, .royalGold, .neonCyberpunk, .lavenderDream, .highContrast, .custom]
}

// MARK: - Theme Manager

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    static let themeChangedNotification = Notification.Name("ThemeManager.themeChanged")
    private static let settingsFileName = "theme-settings.json"
    private static let legacyCustomColorsKey = "customThemeColors"
    private static let legacyFontSizesKey = "customFontSizes"
    private static let legacySelectedThemeKey = "selectedThemeId"

    private struct PersistedThemeSettings: Codable {
        let selectedThemeId: String
        let customColors: ThemeColorsData
        let fontSizes: [String: Double]
        let editorSearchHighlightsEnabled: Bool?
        let editorDividerColor: ColorComponents?
        let editorDividerTopMargin: Double?
        let editorDividerBottomMargin: Double?
    }
    
    @Published var currentTheme: AppTheme
    @Published var customColors: ThemeColors
    
    // Font sizes
    @Published var searchFieldFontSize: CGFloat {
        didSet {
            if !isApplyingPersistedState {
                saveFontSizes()
            }
        }
    }
    @Published var itemTitleFontSize: CGFloat {
        didSet {
            if !isApplyingPersistedState {
                saveFontSizes()
            }
        }
    }
    @Published var itemSubtitleFontSize: CGFloat {
        didSet {
            if !isApplyingPersistedState {
                saveFontSizes()
            }
        }
    }
    @Published var editorFontSize: CGFloat {
        didSet {
            if !isApplyingPersistedState {
                saveFontSizes()
            }
        }
    }
    @Published var editorSearchHighlightsEnabled: Bool {
        didSet {
            if !isApplyingPersistedState {
                persistAllThemeSettings()
            }
        }
    }
    @Published var editorDividerColor: Color {
        didSet {
            if !isApplyingPersistedState {
                persistAllThemeSettings()
            }
        }
    }
    @Published var editorDividerTopMargin: CGFloat {
        didSet {
            if !isApplyingPersistedState {
                persistAllThemeSettings()
            }
        }
    }
    @Published var editorDividerBottomMargin: CGFloat {
        didSet {
            if !isApplyingPersistedState {
                persistAllThemeSettings()
            }
        }
    }

    private var isApplyingPersistedState = false
    
    var colors: ThemeColors {
        currentTheme.isCustom ? customColors : currentTheme.colors
    }
    
    private init() {
        let persisted = Self.loadPersistedSettings()
        let loadedColors = persisted?.customColors.colors ?? AppTheme.defaultCustomColors
        let loadedTheme = Self.themeForID(persisted?.selectedThemeId, customColors: loadedColors)
        let loadedFontSizes = persisted?.fontSizes ?? [:]

        currentTheme = loadedTheme
        customColors = loadedColors
        searchFieldFontSize = CGFloat(loadedFontSizes["searchField"] ?? 30)
        itemTitleFontSize = CGFloat(loadedFontSizes["itemTitle"] ?? 20)
        itemSubtitleFontSize = CGFloat(loadedFontSizes["itemSubtitle"] ?? 12)
        editorFontSize = CGFloat(loadedFontSizes["editor"] ?? 15)
        editorSearchHighlightsEnabled = persisted?.editorSearchHighlightsEnabled ?? true
        editorDividerColor = persisted?.editorDividerColor?.color ?? Color(red: 0.72, green: 0.86, blue: 0.98)
        editorDividerTopMargin = max(0, CGFloat(persisted?.editorDividerTopMargin ?? 6))
        editorDividerBottomMargin = max(0, CGFloat(persisted?.editorDividerBottomMargin ?? 6))

        if persisted == nil {
            persistAllThemeSettings()
        }
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

    func reloadFromDisk() {
        guard let persisted = Self.loadPersistedSettings() else {
            return
        }

        isApplyingPersistedState = true
        defer { isApplyingPersistedState = false }

        let loadedColors = persisted.customColors.colors
        customColors = loadedColors
        currentTheme = Self.themeForID(persisted.selectedThemeId, customColors: loadedColors)
        searchFieldFontSize = CGFloat(persisted.fontSizes["searchField"] ?? 30)
        itemTitleFontSize = CGFloat(persisted.fontSizes["itemTitle"] ?? 20)
        itemSubtitleFontSize = CGFloat(persisted.fontSizes["itemSubtitle"] ?? 12)
        editorFontSize = CGFloat(persisted.fontSizes["editor"] ?? 15)
        editorSearchHighlightsEnabled = persisted.editorSearchHighlightsEnabled ?? true
        editorDividerColor = persisted.editorDividerColor?.color ?? Color(red: 0.72, green: 0.86, blue: 0.98)
        editorDividerTopMargin = max(0, CGFloat(persisted.editorDividerTopMargin ?? 6))
        editorDividerBottomMargin = max(0, CGFloat(persisted.editorDividerBottomMargin ?? 6))

        NotificationCenter.default.post(name: Self.themeChangedNotification, object: nil)
    }

    func toggleEditorSearchHighlightsEnabled() {
        editorSearchHighlightsEnabled.toggle()
    }

    func resetEditorDividerStyle() {
        editorDividerColor = Color(red: 0.72, green: 0.86, blue: 0.98)
        editorDividerTopMargin = 6
        editorDividerBottomMargin = 6
    }
    
    func saveThemePreference() {
        persistAllThemeSettings()
    }
    
    func saveCustomColors() {
        persistAllThemeSettings()
    }
    
    func saveFontSizes() {
        persistAllThemeSettings()
    }
    
    func resetFontSizes() {
        searchFieldFontSize = 30
        itemTitleFontSize = 20
        itemSubtitleFontSize = 12
        editorFontSize = 15
    }
    
    func increaseEditorFontSize() {
        editorFontSize = min(editorFontSize + 1, 24)
    }
    
    func decreaseEditorFontSize() {
        editorFontSize = max(editorFontSize - 1, 12)
    }

    private func persistAllThemeSettings() {
        let settings = PersistedThemeSettings(
            selectedThemeId: currentTheme.id,
            customColors: ThemeColorsData(colors: customColors),
            fontSizes: [
                "searchField": Double(searchFieldFontSize),
                "itemTitle": Double(itemTitleFontSize),
                "itemSubtitle": Double(itemSubtitleFontSize),
                "editor": Double(editorFontSize)
            ],
            editorSearchHighlightsEnabled: editorSearchHighlightsEnabled,
            editorDividerColor: ColorComponents(color: editorDividerColor),
            editorDividerTopMargin: Double(editorDividerTopMargin),
            editorDividerBottomMargin: Double(editorDividerBottomMargin)
        )
        _ = SettingsStore.shared.saveJSON(settings, fileName: Self.settingsFileName)
    }

    private static func loadPersistedSettings() -> PersistedThemeSettings? {
        if let persisted: PersistedThemeSettings = SettingsStore.shared.loadJSON(
            PersistedThemeSettings.self,
            fileName: settingsFileName
        ) {
            return persisted
        }
        return migrateLegacyUserDefaultsIfNeeded()
    }

    private static func migrateLegacyUserDefaultsIfNeeded() -> PersistedThemeSettings? {
        let defaults = UserDefaults.standard
        let legacyThemeId = defaults.string(forKey: legacySelectedThemeKey)
        let legacyColorsData = defaults.data(forKey: legacyCustomColorsKey)
        let legacyFontSizes = defaults.dictionary(forKey: legacyFontSizesKey)

        guard legacyThemeId != nil || legacyColorsData != nil || legacyFontSizes != nil else {
            return nil
        }

        let loadedColors: ThemeColorsData
        if let legacyColorsData {
            loadedColors = (try? JSONDecoder().decode(ThemeColorsData.self, from: legacyColorsData))
                ?? ThemeColorsData(colors: AppTheme.defaultCustomColors)
        } else {
            loadedColors = ThemeColorsData(colors: AppTheme.defaultCustomColors)
        }

        let fontSizes: [String: Double] = [
            "searchField": numericValue(from: legacyFontSizes?["searchField"]) ?? 30,
            "itemTitle": numericValue(from: legacyFontSizes?["itemTitle"]) ?? 20,
            "itemSubtitle": numericValue(from: legacyFontSizes?["itemSubtitle"]) ?? 12,
            "editor": numericValue(from: legacyFontSizes?["editor"]) ?? 15
        ]

        let migrated = PersistedThemeSettings(
            selectedThemeId: legacyThemeId ?? AppTheme.default.id,
            customColors: loadedColors,
            fontSizes: fontSizes,
            editorSearchHighlightsEnabled: true,
            editorDividerColor: ColorComponents(color: Color(red: 0.72, green: 0.86, blue: 0.98)),
            editorDividerTopMargin: 6,
            editorDividerBottomMargin: 6
        )
        _ = SettingsStore.shared.saveJSON(migrated, fileName: settingsFileName)
        return migrated
    }

    private static func themeForID(_ id: String?, customColors: ThemeColors) -> AppTheme {
        guard let id else {
            return .default
        }

        if id == "custom" {
            return AppTheme(id: "custom", name: "Custom", colors: customColors, isCustom: true)
        }

        return AppTheme.allThemes.first(where: { $0.id == id }) ?? .default
    }

    private static func numericValue(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? CGFloat {
            return Double(value)
        }
        if let value = value as? Float {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        return nil
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
