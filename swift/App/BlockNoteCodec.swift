import Foundation

private let blockPayloadPrefix = "__AABLK1__"

struct EditorBlock: Identifiable, Codable, Equatable {
    var id: String
    var text: String
    var children: [EditorBlock]
    var isPage: Bool

    init(
        id: String = UUID().uuidString,
        text: String = "",
        children: [EditorBlock] = [],
        isPage: Bool = false
    ) {
        self.id = id
        self.text = text
        self.children = children
        self.isPage = isPage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case children
        case isPage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        children = try container.decodeIfPresent([EditorBlock].self, forKey: .children) ?? []
        isPage = try container.decodeIfPresent(Bool.self, forKey: .isPage) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(children, forKey: .children)
        try container.encode(isPage, forKey: .isPage)
    }
}

enum BlockNoteCodec {
    private struct Payload: Codable {
        let version: Int
        let blocks: [EditorBlock]
    }

    static func decodeBlocks(from note: String) -> [EditorBlock] {
        if let decoded = decodePayloadBlocks(from: note), !decoded.isEmpty {
            return decoded
        }

        let plainText = stripPayload(from: note)
        let paragraphs = parseParagraphBlocks(from: plainText)
        if !paragraphs.isEmpty {
            return paragraphs
        }

        return [EditorBlock()]
    }

    static func encodeNote(from blocks: [EditorBlock]) -> String {
        let plain = flattenedText(from: blocks)

        let payload = Payload(version: 1, blocks: blocks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        guard let encoded = try? encoder.encode(payload) else {
            return plain
        }

        let base64 = encoded.base64EncodedString()
        let payloadLine = blockPayloadPrefix + base64

        if plain.isEmpty {
            return payloadLine
        }

        return plain + "\n" + payloadLine
    }

    static func stripPayload(from note: String) -> String {
        var lines = note.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines.removeAll { $0.hasPrefix(blockPayloadPrefix) }

        // Keep user-authored formatting while removing trailing blank lines introduced by payload storage.
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }

    static func flattenedText(from blocks: [EditorBlock]) -> String {
        var lines: [String] = []
        appendFlattenedText(from: blocks, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func decodePayloadBlocks(from note: String) -> [EditorBlock]? {
        let lines = note.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        guard let payloadLine = lines.reversed().first(where: { $0.hasPrefix(blockPayloadPrefix) }) else {
            return nil
        }

        let base64 = String(payloadLine.dropFirst(blockPayloadPrefix.count))
        guard !base64.isEmpty,
              let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.version == 1
        else {
            return nil
        }

        return payload.blocks
    }

    private static func parseParagraphBlocks(from note: String) -> [EditorBlock] {
        let normalized = note.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var paragraphs: [String] = []
        var current: [String] = []

        func flushCurrent() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                paragraphs.append(joined)
            }
            current.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushCurrent()
            } else {
                current.append(line)
            }
        }

        flushCurrent()

        return paragraphs.map { EditorBlock(text: $0) }
    }

    private static func appendFlattenedText(from blocks: [EditorBlock], into lines: inout [String]) {
        for block in blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(text)
            }
            appendFlattenedText(from: block.children, into: &lines)
        }
    }
}

enum BlockTree {
    static func blocks(at path: [String], in root: [EditorBlock]) -> [EditorBlock] {
        var current = root
        for blockID in path {
            guard let block = current.first(where: { $0.id == blockID }) else {
                return []
            }
            current = block.children
        }
        return current
    }

    static func blockTitles(for path: [String], in root: [EditorBlock]) -> [String] {
        var titles: [String] = []
        var current = root

        for blockID in path {
            guard let block = current.first(where: { $0.id == blockID }) else {
                break
            }

            let title = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            titles.append(title.isEmpty ? "Untitled" : title)
            current = block.children
        }

        return titles
    }

    static func sanitizedPath(_ path: [String], in root: [EditorBlock]) -> [String] {
        var validPath: [String] = []
        var current = root

        for blockID in path {
            guard let block = current.first(where: { $0.id == blockID }) else {
                break
            }
            validPath.append(blockID)
            current = block.children
        }

        return validPath
    }

    static func mutateBlocks(
        at path: [String],
        in root: inout [EditorBlock],
        transform: (inout [EditorBlock]) -> Void
    ) {
        _ = mutateBlocksRecursive(pathSlice: ArraySlice(path), blocks: &root, transform: transform)
    }

    @discardableResult
    private static func mutateBlocksRecursive(
        pathSlice: ArraySlice<String>,
        blocks: inout [EditorBlock],
        transform: (inout [EditorBlock]) -> Void
    ) -> Bool {
        guard let blockID = pathSlice.first else {
            transform(&blocks)
            return true
        }

        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else {
            return false
        }

        return mutateBlocksRecursive(
            pathSlice: pathSlice.dropFirst(),
            blocks: &blocks[idx].children,
            transform: transform
        )
    }
}
