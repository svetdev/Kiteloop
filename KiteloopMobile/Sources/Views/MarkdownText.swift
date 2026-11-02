import SwiftUI

/// One block of a reply read as Markdown: a heading, a list item, a quote, a
/// fenced code block or a paragraph, in the order the reply has them.
struct MarkdownBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case bullet
        case numbered(marker: String)
        case quote
        case code
        case paragraph
    }

    let kind: Kind
    let text: String
}

/// The block structure of an agent's reply. Inline styling is left to
/// `AttributedString(markdown:)`, which reads only inline syntax; the blocks
/// it would flatten are split out here first.
enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var reader = Reader()
        for line in text.components(separatedBy: "\n") { reader.read(line) }
        return reader.finish()
    }

    /// The reply read line by line: the blocks so far, the paragraph being
    /// gathered, and the code block being gathered while a fence is open.
    private struct Reader {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        mutating func read(_ line: String) {
            if code != nil { return readCode(line) }
            if MarkdownBlocks.isFence(line) {
                flushParagraph()
                code = []
            } else if let block = MarkdownBlocks.lineBlock(line) {
                flushParagraph()
                blocks.append(block)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }

        private mutating func readCode(_ line: String) {
            guard MarkdownBlocks.isFence(line) else { code?.append(line); return }
            closeCode()
        }

        private mutating func closeCode() {
            if let open = code { blocks.append(MarkdownBlock(kind: .code, text: open.joined(separator: "\n"))) }
            code = nil
        }

        private mutating func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(MarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        /// A fence the reply never closed — a reply still streaming — is code so far.
        mutating func finish() -> [MarkdownBlock] {
            flushParagraph()
            closeCode()
            return blocks
        }
    }

    fileprivate static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// A line that is a block on its own: a heading, a list item or a quote.
    fileprivate static func lineBlock(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let heading = heading(trimmed) { return heading }
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return MarkdownBlock(kind: .bullet, text: String(trimmed.dropFirst(2)))
        }
        if let numbered = numbered(trimmed) { return numbered }
        if trimmed.hasPrefix(">") {
            return MarkdownBlock(kind: .quote, text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
        return MarkdownBlock(kind: .heading(level: level), text: trimmed.dropFirst(level + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func numbered(_ trimmed: String) -> MarkdownBlock? {
        let digits = trimmed.prefix(while: \.isNumber)
        let rest = trimmed.dropFirst(digits.count)
        guard !digits.isEmpty, let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return MarkdownBlock(kind: .numbered(marker: digits + "."), text: String(rest.dropFirst(2)))
    }

    /// Bold, italic, code and links styled; text that is not valid inline
    /// Markdown comes back as written rather than not at all.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// An agent's reply drawn as the Markdown it is written in.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(MarkdownBlocks.inline(block.text)).font(level <= 2 ? .headline : .subheadline.bold())
        case .bullet:
            listRow("•", block.text)
        case .numbered(let marker):
            listRow(marker, block.text)
        case .quote:
            Text(MarkdownBlocks.inline(block.text)).font(.callout).foregroundStyle(.secondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text).font(.system(.caption, design: .monospaced)).padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .paragraph:
            Text(MarkdownBlocks.inline(block.text)).font(.callout)
        }
    }

    private func listRow(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text(MarkdownBlocks.inline(text)).font(.callout)
        }
    }
}
