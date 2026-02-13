import Foundation

enum RustBridgeClient {
    static func version() -> String {
        backendVersion()
    }

    static func search(query: String, limit: UInt32 = 8) throws -> [SearchResultRecord] {
        try searchItems(query: query, limit: limit)
    }

    static func create(title: String) throws -> Int64 {
        try createItem(title: title)
    }

    static func fetch(itemId: Int64) throws -> EditableItemRecord {
        try getItem(itemId: itemId)
    }

    static func save(itemId: Int64, note: String, images: [NoteImageRecord]) throws {
        try saveItem(itemId: itemId, note: note, images: images)
    }

    static func rename(itemId: Int64, title: String) throws {
        try renameItem(itemId: itemId, title: title)
    }

    static func loadJsonStorageDirectoryPath() throws -> String {
        try loadJsonStoragePath()
    }

    static func saveJsonStorageDirectoryPath(_ path: String) throws {
        try saveJsonStoragePath(path: path)
    }

    static func delete(itemId: Int64) throws {
        try deleteItem(itemId: itemId)
    }

    static func getJsonPath(itemId: Int64) throws -> String {
        try getItemJsonPath(itemId: itemId)
    }
}
