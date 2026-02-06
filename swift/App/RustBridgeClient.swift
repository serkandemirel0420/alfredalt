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
}
