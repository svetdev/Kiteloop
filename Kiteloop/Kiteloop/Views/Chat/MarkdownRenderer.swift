import AppKit
import Highlightr

struct MarkdownRenderer {
    /// The one syntax-highlighting engine, built on first use and reused.
    /// Each `Highlightr` carries its own JavaScriptCore context with highlight.js
    /// loaded into it, so building one per code block per redraw costs a whole
    /// engine per frame while a reply streams. Internal so a test can assert the
    /// identity holds across renders.
    @MainActor static let sharedHighlighter: Highlightr? = Highlightr()

    /// Carried by every character of a rendered fenced code block; its value is the
    /// block's plain code — no fence lines, no language tag, no list indent.
    static let codeBlockKey = NSAttributedString.Key("kiteloop.codeBlock")

    /// The code of the fenced block rendered at `index`, or nil outside one.
    static func codeBlock(in rendered: NSAttributedString, at index: Int) -> String? {
        guard index >= 0, index < rendered.length else { return nil }
        return rendered.attribute(codeBlockKey, at: index, effectiveRange: nil) as? String
    }

    @MainActor
    static func render(_ markdown: String, isDark: Bool) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 14)
        let textColor = NSColor.labelColor
        let result = NSMutableAttributedString()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 6

        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Markdown table block
            if isTableRow(line) {
                var tableLines: [String] = []
                while i < lines.count && isTableRow(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }
                result.append(renderTable(tableLines, isDark: isDark))
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
                continue
            }

            // Fenced code block, at column zero or indented under a list item
            if let fence = fenceMarker(line) {
                var codeLines: [String] = []
                i += 1
                while i < lines.count, fenceMarker(lines[i]) == nil {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }

                let code = stripping(fence.indent, from: codeLines).joined(separator: "\n")
                result.append(highlightCode(code, language: fence.language.isEmpty ? nil : fence.language, isDark: isDark))
                result.append(NSAttributedString(string: "\n\n"))
                continue
            }

            // Empty line → paragraph break
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
                i += 1
                continue
            }

            let parsed = parseLine(line, baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle, isDark: isDark)
            result.append(parsed)
            result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            i += 1
        }

        // Trim trailing newlines
        while result.length > 0 {
            let last = result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1)).string
            if last == "\n" {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            } else {
                break
            }
        }

        return result
    }

    private static func parseLine(_ line: String, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle, isDark: Bool) -> NSAttributedString {
        if let (level, text) = headingMarker(line) {
            return heading(text, level: level, textColor: textColor)
        }
        if let (depth, text) = quoteMarker(line) {
            return quote(text, depth: depth, baseFont: baseFont)
        }
        // Before the list marker, or `* * *` is read as a bullet.
        if isRuleLine(line) {
            return rule(paragraphStyle: paragraphStyle)
        }

        guard let marker = listMarker(line) else {
            return parseInline(line, baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        }

        let prefix = NSAttributedString(string: marker.prefix, attributes: [
            .font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraphStyle
        ])
        let result = NSMutableAttributedString(attributedString: prefix)
        result.append(parseInline(marker.content, baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle))
        result.addAttribute(.paragraphStyle, value: hangingIndent(paragraphStyle, under: prefix),
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    /// A copy of `paragraphStyle` whose wrapped lines start under the item's text
    /// rather than back at the margin: the head indent is the drawn width of the
    /// item's prefix, the first line is left where the prefix already puts it.
    private static func hangingIndent(_ paragraphStyle: NSParagraphStyle, under prefix: NSAttributedString) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(paragraphStyle)
        style.firstLineHeadIndent = 0
        style.headIndent = prefix.size().width
        return style
    }

    /// The heading level a line opens with, and the text after its marker — nil for
    /// any other line. Kept out of `parseLine` so six levels cost one arm, not six.
    private static func headingMarker(_ line: String) -> (level: Int, text: String)? {
        for level in 1...6 {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                return (level, String(line.dropFirst(marker.count)))
            }
        }
        return nil
    }

    /// The depth a quote line opens with, and the text after its markers — nil for
    /// any other line, so a sentence that merely carries a `>` is untouched. Read
    /// after the leading whitespace the way `fenceMarker` reads it: a run of `>`,
    /// each allowed one space after it, so `>text`, the bare `>` between two quoted
    /// paragraphs, a quote written under a list item and `> > reply` are all quotes.
    private static func quoteMarker(_ line: String) -> (depth: Int, text: String)? {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        var depth = 0
        while rest.hasPrefix(">") {
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            depth += 1
        }
        guard depth > 0 else { return nil }
        return (depth, String(rest))
    }

    /// The fence a line opens or closes, read after its leading whitespace the way
    /// `listMarker` reads indentation: the indent it carries, and the info string
    /// after its backticks. A code sample nested under a list item is indented, so
    /// a fence test at column zero alone leaves its backticks in the prose and
    /// parses the code between them as markdown.
    private static func fenceMarker(_ line: String) -> (indent: String, language: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = line[indent.endIndex...]
        guard body.hasPrefix("```") else { return nil }
        return (String(indent), body.dropFirst(3).trimmingCharacters(in: .whitespaces))
    }

    /// The box a task-list item opens with, and the text after it — nil for an
    /// ordinary bullet, so `- [not a box] text` keeps its brackets. Read from the
    /// text after a `- ` or `* ` marker: `[ ]`, `[x]` or `[X]`, then the end of the
    /// line or a space.
    private static func checkboxMarker(_ item: String) -> (box: String, text: String)? {
        var rest = Substring(item)
        guard rest.hasPrefix("["), rest.count >= 3 else { return nil }
        let state = rest[rest.index(after: rest.startIndex)]
        guard " xX".contains(state), rest[rest.index(rest.startIndex, offsetBy: 2)] == "]" else { return nil }
        rest = rest.dropFirst(3)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (state == " " ? "\u{2610}" : "\u{2611}", String(rest.dropFirst(rest.isEmpty ? 0 : 1)))
    }

    /// The captured lines with the opening fence's own indentation taken off each,
    /// so a block written under a list item is not drawn with that indent baked
    /// into every row.
    private static func stripping(_ indent: String, from lines: [String]) -> [String] {
        guard !indent.isEmpty else { return lines }
        return lines.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }
    }

    /// Whether a line is nothing but three or more of one of `-`, `*` or `_`,
    /// whitespace aside — a section break asked for in punctuation.
    private static func isRuleLine(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// The thin line a rule line is drawn as, in place of its characters.
    private static func rule(paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: String(repeating: "\u{2500}", count: 24), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.separatorColor,
            .paragraphStyle: paragraphStyle
        ])
    }

    /// The prefix a list line is drawn with, and the text after its marker — nil for
    /// any other line, so prose that merely starts with spaces invents no bullet.
    /// Leading whitespace is a level of nesting per two spaces (a tab counts as two),
    /// and the prefix widens by that much, so `  - sub` is a bullet one step in
    /// rather than a dash printed as text.
    private static func listMarker(_ line: String) -> (prefix: String, content: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = String(line[indent.endIndex...])
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let pad = String(repeating: "  ", count: depth + 1)
        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            let item = String(body.dropFirst(2))
            if let box = checkboxMarker(item) {
                return (pad + box.box + " ", box.text)
            }
            return (pad + "\u{2022} ", item)
        }
        if let match = body.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return (pad + String(body[body.startIndex..<match.upperBound]), String(body[match.upperBound...]))
        }
        return nil
    }

    /// A quote line: the markers gone, the body indented one step per level and
    /// secondary, its inline markup still parsed. A body left empty by its markers —
    /// the bare `>` between two quoted paragraphs — is drawn as a single space, so
    /// the blank line inside the quote carries the quote's indent rather than
    /// collapsing to an unstyled paragraph.
    private static func quote(_ text: String, depth: Int, baseFont: NSFont) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 6
        style.firstLineHeadIndent = 16 * CGFloat(depth)
        style.headIndent = 16 * CGFloat(depth)
        return quotedBody(text.isEmpty ? " " : text, baseFont: baseFont, paragraphStyle: style)
    }

    /// A quote's body with its own block marker read the way `parseLine` reads a
    /// line's: a heading drawn at its heading size, a bullet drawn as a bullet —
    /// both in the quote's colour and under the quote's indent, so a checklist an
    /// agent quotes back is a list rather than a dash printed on every line. The
    /// per-level pad `listMarker` returns carries the list's own nesting on top of
    /// the quote's. A rule line is read before the list marker, the way `parseLine`
    /// reads it, so a quoted `* * *` is not a bullet — it keeps printing its
    /// characters as prose, since a rule inside a quote is not drawn. Anything else
    /// is inline prose.
    private static func quotedBody(_ text: String, baseFont: NSFont, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        if let (level, heading) = headingMarker(text) {
            return parseInline(heading, baseFont: headingFont(level: level),
                               textColor: .secondaryLabelColor, paragraphStyle: paragraphStyle)
        }
        guard !isRuleLine(text), let marker = listMarker(text) else {
            return parseInline(text, baseFont: baseFont, textColor: .secondaryLabelColor, paragraphStyle: paragraphStyle)
        }
        let result = NSMutableAttributedString(string: marker.prefix, attributes: [
            .font: baseFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraphStyle
        ])
        result.append(parseInline(marker.content, baseFont: baseFont,
                                  textColor: .secondaryLabelColor, paragraphStyle: paragraphStyle))
        return result
    }

    /// The font a heading of a given level is drawn in, so a heading written inside
    /// a quote is sized from the same table as one at the left margin.
    private static func headingFont(level: Int) -> NSFont {
        let sizes: [Int: CGFloat] = [1: 22, 2: 19, 3: 16, 4: 15, 5: 14, 6: 13]
        return NSFont.systemFont(ofSize: sizes[level] ?? 14, weight: .semibold)
    }

    private static func heading(_ text: String, level: Int, textColor: NSColor) -> NSAttributedString {
        let font = headingFont(level: level)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = level == 1 ? 12 : 8
        style.paragraphSpacing = 4
        return parseInline(text, baseFont: font, textColor: textColor, paragraphStyle: style)
    }

    /// What one inline arm consumed: the run it produced, and where the scan resumes.
    private typealias InlineSpan = (text: NSAttributedString, next: String.Index)

    private static func parseInline(_ text: String, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraphStyle
        ]
        // The escape arm is tried first, so `\*x\*` is consumed as two literal
        // asterisks before emphasis can open on one. Bold is tried before
        // emphasis, so `**x**` is never read as two empty italic spans; the
        // underscore spellings keep the same order for `__x__`.
        // `imageSpan` is tried before `linkSpan`, so the bracket after an image's
        // exclamation mark is never claimed as an ordinary link first.
        let arms = [escapeSpan, codeSpan, boldSpan, italicSpan, underscoreBoldSpan, underscoreItalicSpan, strikeSpan, imageSpan, linkSpan, autolinkSpan]

        var pos = text.startIndex

        while pos < text.endIndex {
            let span = arms.lazy.compactMap {
                $0(text, pos, baseFont, textColor, paragraphStyle)
            }.first
            if let span {
                result.append(span.text)
                pos = span.next
                continue
            }

            // Plain text until next special char
            let specialChars: [Character] = ["\\", "`", "*", "_", "~", "[", "!", "h"]
            var end = text.index(after: pos)
            while end < text.endIndex && !specialChars.contains(text[end]) {
                end = text.index(after: end)
            }
            result.append(NSAttributedString(string: String(text[pos..<end]), attributes: baseAttrs))
            pos = end
        }

        return result
    }

    /// A backslash in front of one of the characters this renderer reads as inline
    /// markup: the character is drawn as itself and the backslash is not drawn at
    /// all, so `\*not italic\*` opens no emphasis. A backslash in front of anything
    /// else — a Windows path, a regex — is ordinary text and left to the plain run.
    private static func escapeSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos] == "\\" else { return nil }
        let after = text.index(after: pos)
        let escapable: Set<Character> = ["\\", "`", "*", "~", "[", "]"]
        guard after < text.endIndex, escapable.contains(text[after]) else { return nil }
        let run = NSAttributedString(string: String(text[after]), attributes: [
            .font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraphStyle
        ])
        return (run, text.index(after: after))
    }

    /// Inline code `` `...` `` — monospaced, on its own background.
    private static func codeSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos...].hasPrefix("`") else { return nil }
        let after = text.index(after: pos)
        guard let end = text[after...].firstIndex(of: "`") else { return nil }
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let run = NSAttributedString(string: String(text[after..<end]), attributes: [
            .font: codeFont,
            .foregroundColor: textColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: paragraphStyle
        ])
        return (run, text.index(after: end))
    }

    /// Bold `**...**`.
    private static func boldSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos...].hasPrefix("**") else { return nil }
        let after = text.index(pos, offsetBy: 2)
        guard let range = text[after...].range(of: "**") else { return nil }
        let body = parseInline(String(text[after..<range.lowerBound]), baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        let run = wrapped(body, restyling: semibold)
        return (run, range.upperBound)
    }

    /// The semibold face of `font`, keeping its design and slant. The monospaced
    /// system font's descriptor carries a font name, and a name outranks an added
    /// weight trait — the table font and a code run inside bold came back regular —
    /// so a fixed-pitch font is rebuilt from the semibold monospaced face instead.
    private static func semibold(_ font: NSFont) -> NSFont {
        guard font.isFixedPitch else {
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]
            ])
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        let traits = font.fontDescriptor.symbolicTraits.union(.bold)
        return NSFont(descriptor: mono.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? mono
    }

    /// Emphasis `*...*`. It opens only on a `*` whose next character is neither
    /// whitespace nor another `*`, so `2 * 3 * 4` and an unclosed `**` are left
    /// to the plain run.
    private static func italicSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos...].hasPrefix("*") else { return nil }
        let after = text.index(after: pos)
        guard after < text.endIndex, !text[after].isWhitespace, text[after] != "*" else { return nil }
        guard let end = text[after...].firstIndex(of: "*") else { return nil }
        let body = parseInline(String(text[after..<end]), baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        let run = wrapped(body) { font in
            NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        }
        return (run, text.index(after: end))
    }

    /// Bold `__...__`, opening and closing only at a word's edge (`underscoreSpan`).
    /// A Python dunder name such as `__init__` is shaped exactly like `__never__`,
    /// so one in `dunderNames` is left to the plain run with its underscores.
    private static func underscoreBoldSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard let span = underscoreSpan(text, at: pos, delimiter: "__"), !dunderNames.contains(span.body) else { return nil }
        let body = parseInline(span.body, baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        return (wrapped(body, restyling: semibold), span.next)
    }

    /// The bodies of Python's well-known dunder names, which a reply writes bare.
    private static let dunderNames: Set<String> = [
        "init", "new", "del", "repr", "str", "bytes", "format", "hash", "bool",
        "name", "main", "file", "doc", "dict", "module", "class", "slots", "all",
        "call", "len", "iter", "next", "getitem", "setitem", "delitem", "contains",
        "enter", "exit", "aenter", "aexit", "await", "aiter", "anext",
        "eq", "ne", "lt", "le", "gt", "ge", "add", "sub", "mul", "truediv",
        "getattr", "setattr", "delattr", "getattribute", "post_init", "init_subclass",
        "qualname", "annotations", "package", "spec", "version", "future", "builtins"
    ]

    /// Emphasis `_..._`, opening and closing only at a word's edge (`underscoreSpan`).
    private static func underscoreItalicSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard let span = underscoreSpan(text, at: pos, delimiter: "_") else { return nil }
        let body = parseInline(span.body, baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        let run = wrapped(body) { font in
            NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        }
        return (run, span.next)
    }

    /// The body between an underscore `delimiter` that opens a word and the first one
    /// that closes a word, and where the scan resumes after it. It opens only with
    /// nothing or whitespace before it and a character after it that is neither
    /// whitespace nor `_`; it closes only after a non-space and before nothing,
    /// whitespace or closing punctuation. So `snake_case_name`, `some_file.swift`,
    /// `self.__init__` and `__init__()` match neither and keep their underscores.
    private static func underscoreSpan(_ text: String, at pos: String.Index, delimiter: String) -> (body: String, next: String.Index)? {
        guard text[pos...].hasPrefix(delimiter),
              pos == text.startIndex || text[text.index(before: pos)].isWhitespace else { return nil }
        let after = text.index(pos, offsetBy: delimiter.count)
        guard after < text.endIndex, !text[after].isWhitespace, text[after] != "_" else { return nil }
        var search = after
        while let closer = text[search...].range(of: delimiter) {
            if closesWord(text, at: closer) { return (String(text[after..<closer.lowerBound]), closer.upperBound) }
            search = text.index(after: closer.lowerBound)
        }
        return nil
    }

    /// Whether the underscores at `closer` end a word: a non-space before them, and
    /// nothing, whitespace or closing punctuation after.
    private static func closesWord(_ text: String, at closer: Range<String.Index>) -> Bool {
        guard !text[text.index(before: closer.lowerBound)].isWhitespace else { return false }
        guard closer.upperBound < text.endIndex else { return true }
        let next = text[closer.upperBound]
        return next.isWhitespace || ".,;:!?)]}'\"".contains(next)
    }

    /// Strikethrough `~~...~~`. It opens only on a `~~` with a closing `~~` on the
    /// same line, so a lone tilde and an unclosed pair are left to the plain run.
    private static func strikeSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos...].hasPrefix("~~") else { return nil }
        let after = text.index(pos, offsetBy: 2)
        guard let range = text[after...].range(of: "~~") else { return nil }
        let body = parseInline(String(text[after..<range.lowerBound]), baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        let run = wrapped(body, adding: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        return (run, range.upperBound)
    }

    /// The run the three wrapping arms emit: their body already parsed as markup in
    /// its own right, with the span's own trait laid over it. `restyling` is applied
    /// to each font the body carries rather than to the whole span, so a nested code
    /// or link run keeps its own face, size and colour while taking the wrapper's
    /// weight or slant; `attributes` carries a trait that is not a font, such as the
    /// strikethrough.
    private static func wrapped(
        _ body: NSAttributedString,
        adding attributes: [NSAttributedString.Key: Any] = [:],
        restyling: (NSFont) -> NSFont = { $0 }
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: body)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            result.addAttribute(.font, value: restyling(font), range: range)
        }
        if !attributes.isEmpty {
            result.addAttributes(attributes, range: full)
        }
        return result
    }

    /// A written link `[text](url)`.
    private static func linkSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos...].hasPrefix("[") else { return nil }
        let after = text.index(after: pos)
        guard let closeBracket = text[after...].firstIndex(of: "]") else { return nil }
        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex, text[afterBracket] == "(" else { return nil }
        let afterParen = text.index(after: afterBracket)
        guard let closeParen = text[afterParen...].firstIndex(of: ")") else { return nil }
        guard let url = URL(string: String(text[afterParen..<closeParen])) else { return nil }
        let run = link(String(text[after..<closeBracket]), url: url, baseFont: baseFont, paragraphStyle: paragraphStyle)
        return (run, text.index(after: closeParen))
    }

    /// A written image `![alt](url)` — the exclamation mark never reaches the page
    /// and the alt text is drawn once, behind an image marker, as the one run the
    /// reader can act on. The body is whatever `linkSpan` already accepts, so an
    /// exclamation mark in front of anything else is left to the plain run; an image
    /// written with no alt text has no run to mark and is left there too.
    private static func imageSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        guard text[pos] == "!" else { return nil }
        let after = text.index(after: pos)
        guard after < text.endIndex,
              let span = linkSpan(text, at: after, baseFont: baseFont, textColor: textColor, paragraphStyle: paragraphStyle)
        else { return nil }
        var url: URL?
        span.text.enumerateAttribute(.link, in: NSRange(location: 0, length: span.text.length)) { value, _, stop in
            url = value as? URL
            stop.pointee = true
        }
        guard let url else { return nil }
        let run = link("\u{1F5BC} " + span.text.string, url: url, baseFont: baseFont, paragraphStyle: paragraphStyle)
        return (run, span.next)
    }

    /// A bare `http://` or `https://` URL an agent pasted: clickable over itself,
    /// with a trailing sentence mark left in the text rather than in the URL.
    private static func autolinkSpan(_ text: String, at pos: String.Index, baseFont: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> InlineSpan? {
        let remaining = text[pos...]
        guard remaining.hasPrefix("https://") || remaining.hasPrefix("http://") else { return nil }
        let sentenceMarks: Set<Character> = [".", ",", ";", ":", ")", "]"]
        var end = remaining.firstIndex(where: \.isWhitespace) ?? text.endIndex
        while end > pos, sentenceMarks.contains(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        let matched = String(text[pos..<end])
        guard let url = URL(string: matched), url.host?.isEmpty == false else { return nil }
        return (link(matched, url: url, baseFont: baseFont, paragraphStyle: paragraphStyle), end)
    }

    /// The run both link arms emit: link-coloured text carrying the URL.
    private static func link(_ text: String, url: URL, baseFont: NSFont, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.linkColor,
            .link: url,
            .paragraphStyle: paragraphStyle
        ])
    }

    @MainActor
    private static func highlightCode(_ code: String, language: String?, isDark: Bool) -> NSAttributedString {
        let bgColor = isDark ? NSColor(white: 0.15, alpha: 1.0) : NSColor(white: 0.95, alpha: 1.0)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let highlightr = sharedHighlighter
        highlightr?.setTheme(to: isDark ? "atom-one-dark" : "atom-one-light")

        let highlighted: NSAttributedString
        if let highlightr, let h = highlightr.highlight(code, as: language) {
            highlighted = h
        } else {
            highlighted = NSAttributedString(string: code, attributes: [
                .font: codeFont, .foregroundColor: NSColor.labelColor
            ])
        }

        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.backgroundColor, value: bgColor, range: fullRange)
        mutable.addAttribute(codeBlockKey, value: code, range: fullRange)
        // The highlighter gives colour only. Its fonts would italicize an untagged
        // block it guesses is Markdown, so `_careful_` came back as emphasis.
        mutable.addAttribute(.font, value: codeFont, range: fullRange)
        return mutable
    }

    // MARK: - Table Rendering

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2
    }

    /// The cells between a row's leading and trailing pipes, reading `\|` as a
    /// literal pipe inside the cell it sits in rather than a cell boundary.
    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderTable(_ lines: [String], isDark: Bool) -> NSAttributedString {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldMonoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let textColor = NSColor.labelColor
        let bgColor = isDark ? NSColor(white: 0.15, alpha: 1.0) : NSColor(white: 0.96, alpha: 1.0)
        let separatorColor = isDark ? NSColor(white: 0.3, alpha: 1.0) : NSColor(white: 0.8, alpha: 1.0)

        let rows: [[String]] = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !isSeparatorRow(trimmed) else { return nil }
            return tableCells(trimmed)
        }

        guard !rows.isEmpty else { return NSAttributedString() }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2

        let colCount = rows.map(\.count).max() ?? 0
        let colWidths = columnWidths(rows, colCount: colCount, font: monoFont, textColor: textColor, paragraphStyle: style)

        let result = NSMutableAttributedString()
        for (rowIdx, row) in rows.enumerated() {
            let isHeader = rowIdx == 0
            let font = isHeader ? boldMonoFont : monoFont
            let lineText = renderRow(row, widths: colWidths, font: font, textColor: textColor, paragraphStyle: style)
            lineText.addAttribute(.backgroundColor, value: bgColor, range: NSRange(location: 0, length: lineText.length))
            result.append(lineText)
            result.append(NSAttributedString(string: "\n", attributes: [.font: monoFont]))

            if isHeader {
                let divider = String(repeating: "\u{2500}", count: lineText.length)
                result.append(NSAttributedString(string: divider, attributes: [
                    .font: monoFont,
                    .foregroundColor: separatorColor,
                    .backgroundColor: bgColor,
                    .paragraphStyle: style
                ]))
                result.append(NSAttributedString(string: "\n", attributes: [.font: monoFont]))
            }
        }

        return result
    }

    /// How wide each column has to be drawn: the longest cell in it *as the
    /// reader sees it*, so a cell's `**` and backticks do not pad the column
    /// out by their own length.
    private static func columnWidths(_ rows: [[String]], colCount: Int, font: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> [Int] {
        var widths = Array(repeating: 0, count: colCount)
        for row in rows {
            for (col, cell) in row.enumerated() where col < colCount {
                let rendered = parseInline(cell, baseFont: font, textColor: textColor, paragraphStyle: paragraphStyle)
                widths[col] = max(widths[col], rendered.length)
            }
        }
        return widths
    }

    /// One row, each cell run through the same inline parse an ordinary line
    /// gets, then padded on what it renders to.
    private static func renderRow(_ row: [String], widths: [Int], font: NSFont, textColor: NSColor, paragraphStyle: NSParagraphStyle) -> NSMutableAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle
        ]
        let line = NSMutableAttributedString(string: " ", attributes: attrs)
        for (col, width) in widths.enumerated() {
            if col > 0 {
                line.append(NSAttributedString(string: " \u{2502} ", attributes: attrs))
            }
            let cell = parseInline(col < row.count ? row[col] : "", baseFont: font, textColor: textColor, paragraphStyle: paragraphStyle)
            line.append(cell)
            let padding = max(0, width - cell.length)
            line.append(NSAttributedString(string: String(repeating: " ", count: padding), attributes: attrs))
        }
        line.append(NSAttributedString(string: " ", attributes: attrs))
        return line
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty
    }
}
