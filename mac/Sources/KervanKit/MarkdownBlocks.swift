import Foundation

/// An agent's answer cut into the blocks a chat can lay out: paragraphs, headings, list items and code.
/// Inline styling (bold, `code`, links) stays in each block's text for the view to render.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    /// `level` 1…6.
    case heading(level: Int, text: String)
    /// `marker` is "•" for a bullet or the item's own number ("3."); `depth` 0 for the outer list.
    case item(marker: String, depth: Int, text: String)
    case code(language: String?, text: String)
    case rule

    /// Tolerant of half-arrived text: a code fence still open at the end is code up to the end.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.lines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fence = (language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.count >= 3, Set(trimmed).count == 1, let only = trimmed.first, "-*_".contains(only) {
                flush()
                blocks.append(.rule)
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }
            if let item = item(line) {
                flush()
                blocks.append(item)
                continue
            }
            // A wrapped line under a list item belongs to that item.
            if paragraph.isEmpty, line.hasPrefix("  "), case .item(let marker, let depth, let text)? = blocks.last {
                blocks[blocks.count - 1] = .item(marker: marker, depth: depth, text: text + "\n" + trimmed)
                continue
            }
            paragraph.append(line)
        }
        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func item(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = min(width / 2, 4)
        let body = line.dropFirst(indent.count)

        if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .item(marker: "•", depth: depth, text: text)
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .item(marker: "\(digits).", depth: depth, text: text)
    }
}
