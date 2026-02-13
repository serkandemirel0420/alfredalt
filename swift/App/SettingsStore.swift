import Foundation

final class SettingsStore {
    static let shared = SettingsStore()

    private let settingsDirectoryName = "settings"
    private let defaultStorageFolderName = "AlfredAlternativeData"
    private let fileManager = FileManager.default

    private init() {}

    func settingsDirectoryPath() -> String {
        settingsDirectoryURL().path
    }

    func loadJSON<T: Decodable>(_ type: T.Type, fileName: String) -> T? {
        let fileURL = settingsDirectoryURL().appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            NSLog("SettingsStore: Failed to load \(fileURL.path): \(error)")
            return nil
        }
    }

    @discardableResult
    func saveJSON<T: Encodable>(_ value: T, fileName: String) -> Bool {
        let directoryURL = settingsDirectoryURL()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            NSLog("SettingsStore: Failed to save \(fileName): \(error)")
            return false
        }
    }

    private func settingsDirectoryURL() -> URL {
        resolveStorageRootURL().appendingPathComponent(settingsDirectoryName, isDirectory: true)
    }

    private func resolveStorageRootURL() -> URL {
        if let path = try? RustBridgeClient.loadJsonStorageDirectoryPath() {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed, isDirectory: true)
            }
        }

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documentsURL.appendingPathComponent(defaultStorageFolderName, isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultStorageFolderName, isDirectory: true)
    }
}
