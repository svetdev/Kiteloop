import AppKit
import XCTest
@testable import Kiteloop

/// Coverage for the syntax highlighter behind a fenced code block: that one engine
/// is built and reused across renders, that reuse does not freeze the theme at
/// whichever appearance rendered first, and that a language the engine cannot parse
/// still comes back as readable code.
@MainActor
final class MarkdownRendererTests: XCTestCase {

    private let swiftBlock = """
        ```swift
        // greet
        let name = "world"
        func greet() -> String { "hi \\(name)" }
        ```
        """

    /// Every foreground colour the rendered string carries, as comparable strings —
    /// what the theme actually painted onto the code.
    private func foregroundColours(of rendered: NSAttributedString) -> Set<String> {
        var colours: Set<String> = []
        let full = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.foregroundColor, in: full) { value, _, _ in
            if let colour = value as? NSColor {
                colours.insert("\(colour)")
            }
        }
        return colours
    }

    /// The font the first character of a render carries — the size a heading line
    /// was drawn at.
    private func firstFontSize(_ rendered: NSAttributedString) -> CGFloat {
        (rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    /// The head indent the first character's paragraph style carries.
    private func firstHeadIndent(_ rendered: NSAttributedString) -> CGFloat {
        (rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
    }

    // MARK: - One engine, reused

    /// A `Highlightr` is a JavaScriptCore context with highlight.js loaded into it.
    /// Rendering a code block must not build a second one — the bubble re-renders on
    /// every streamed update, so a per-call engine is an engine per frame.
    func testRenderingACodeBlockTwiceReusesTheSameHighlighter() throws {
        _ = MarkdownRenderer.render(swiftBlock, isDark: true)
        let first = try XCTUnwrap(MarkdownRenderer.sharedHighlighter)

        _ = MarkdownRenderer.render(swiftBlock, isDark: true)
        let second = try XCTUnwrap(MarkdownRenderer.sharedHighlighter)

        XCTAssertTrue(first === second, "Each render should reuse the one highlighter, not build another")
    }

    // MARK: - The theme still follows the call

    /// Sharing the engine must not freeze its theme at whichever appearance rendered
    /// first: the same block in dark and in light has to come back painted differently.
    func testThemeFollowsEachCallRatherThanTheFirst() {
        let dark = MarkdownRenderer.render(swiftBlock, isDark: true)
        let light = MarkdownRenderer.render(swiftBlock, isDark: false)

        XCTAssertNotEqual(
            foregroundColours(of: dark),
            foregroundColours(of: light),
            "Dark and light renders should differ in at least one highlighted foreground colour"
        )
    }

    // MARK: - Blocks the engine cannot parse

    /// A tag highlight.js does not know still has to show its code, not an empty run.
    func testUnknownLanguageStillCarriesTheCode() {
        let rendered = MarkdownRenderer.render("```wingdings\nlet x = 1\n```", isDark: true)

        XCTAssertTrue(rendered.string.contains("let x = 1"), "Got: \(rendered.string)")
    }

    /// An untagged fence — the common case for pasted output — likewise.
    func testUntaggedFenceStillCarriesTheCode() {
        let rendered = MarkdownRenderer.render("```\nplain text here\n```", isDark: false)

        XCTAssertTrue(rendered.string.contains("plain text here"), "Got: \(rendered.string)")
    }

    // MARK: - Headings below level 3

    /// `#### Findings` is a heading, not the four hashes an agent typed: the marker
    /// goes, and the text lands between body size and the level above it.
    func testLevelFourHeadingLosesItsMarkerAndSitsBelowLevelThree() {
        let rendered = MarkdownRenderer.render("#### Findings", isDark: false)

        XCTAssertEqual(rendered.string, "Findings")
        let size = firstFontSize(rendered)
        XCTAssertGreaterThan(size, 14, "Level 4 should still read larger than body text")
        XCTAssertLessThan(size, firstFontSize(MarkdownRenderer.render("### Findings", isDark: false)))
    }

    /// Levels 5 and 6 likewise, each no larger than the level above it.
    func testLevelsFiveAndSixLoseTheirMarkersAndKeepDescending() {
        let five = MarkdownRenderer.render("##### Deeper", isDark: false)
        let six = MarkdownRenderer.render("###### Deepest", isDark: false)

        XCTAssertEqual(five.string, "Deeper")
        XCTAssertEqual(six.string, "Deepest")
        let sizes = [4, 5, 6].map { level in
            firstFontSize(MarkdownRenderer.render(String(repeating: "#", count: level) + " H", isDark: false))
        }
        XCTAssertGreaterThanOrEqual(sizes[0], sizes[1])
        XCTAssertGreaterThanOrEqual(sizes[1], sizes[2])
    }

    // MARK: - Inline markup inside a heading

    /// A heading goes through the inline parser like a quote body does, so a bold
    /// word in it is bold rather than two pairs of asterisks.
    func testBoldInsideAHeadingLosesItsAsterisksAndIsBold() throws {
        let rendered = MarkdownRenderer.render("## Use **the** cache", isDark: false)

        XCTAssertEqual(rendered.string, "Use the cache")
        XCTAssertTrue(try traits(of: rendered, at: "the").contains(.bold))
    }

    /// The bold run inherits the heading's size, so it is not dropped back to body
    /// size in the middle of a level-1 heading.
    func testBoldInsideALevelOneHeadingKeepsTheHeadingSize() throws {
        let rendered = MarkdownRenderer.render("# Use **the** cache", isDark: false)

        XCTAssertEqual(try font(of: rendered, at: "the").pointSize, 22)
    }

    /// A link in a heading is a link: no brackets, no parentheses, and the word
    /// carries the URL.
    func testLinkInsideAHeadingRendersAsALink() throws {
        let rendered = MarkdownRenderer.render("### see [docs](https://example.com)", isDark: false)

        XCTAssertEqual(rendered.string, "see docs")
        let offset = rendered.string.distance(
            from: rendered.string.startIndex,
            to: try XCTUnwrap(rendered.string.range(of: "docs")).lowerBound
        )
        XCTAssertEqual(
            rendered.attribute(.link, at: offset, effectiveRange: nil) as? URL,
            URL(string: "https://example.com")
        )
    }

    /// A heading with no inline markup keeps the size and the spacing it had before
    /// the inline parser was put under it.
    func testHeadingsWithoutMarkupKeepTheirSizesAndSpacing() throws {
        let sizes: [CGFloat] = [22, 19, 16, 15, 14, 13]
        for (index, size) in sizes.enumerated() {
            let level = index + 1
            let rendered = MarkdownRenderer.render(String(repeating: "#", count: level) + " H", isDark: false)
            XCTAssertEqual(firstFontSize(rendered), size, "Level \(level) should still be \(size)pt")
            let style = try XCTUnwrap(
                rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            )
            XCTAssertEqual(style.paragraphSpacingBefore, level == 1 ? 12 : 8)
            XCTAssertEqual(style.paragraphSpacing, 4)
        }
    }

    // MARK: - Inline markup inside bold, italic and strikethrough

    /// The weight the run under the first occurrence of `substring` is drawn at.
    private func weight(of rendered: NSAttributedString, at substring: String) throws -> NSFont.Weight {
        let traits = try font(of: rendered, at: substring)
            .fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return NSFont.Weight(try XCTUnwrap(traits?[.weight] as? CGFloat))
    }

    /// A link inside bold is a link: the URL rides the word, the brackets are gone,
    /// and the word is still drawn bold.
    func testLinkInsideBoldIsALinkAndStaysBold() throws {
        let rendered = MarkdownRenderer.render("**see [the runbook](https://example.com)**", isDark: false)

        XCTAssertEqual(rendered.string, "see the runbook")
        XCTAssertEqual(
            links(in: rendered).map(\.text),
            ["the runbook"],
            "The link text should carry the URL on its own"
        )
        XCTAssertEqual(links(in: rendered).first?.url, URL(string: "https://example.com"))
        XCTAssertEqual(try weight(of: rendered, at: "the runbook"), .semibold)
        XCTAssertTrue(try traits(of: rendered, at: "the runbook").contains(.bold))
    }

    /// Inline code inside emphasis keeps its monospaced face while the line around
    /// it stays italic, and no backtick is printed.
    func testCodeInsideEmphasisStaysMonospacedInsideAnItalicLine() throws {
        let rendered = MarkdownRenderer.render("*a `flag` matters*", isDark: false)

        XCTAssertEqual(rendered.string, "a flag matters")
        XCTAssertTrue(try font(of: rendered, at: "flag").isFixedPitch, "The code run should stay monospaced")
        XCTAssertTrue(try traits(of: rendered, at: "flag").contains(.italic))
        XCTAssertTrue(try traits(of: rendered, at: "matters").contains(.italic))
        XCTAssertFalse(try font(of: rendered, at: "matters").isFixedPitch)
    }

    /// Bold inside a struck span: the whole span is struck and the bolded word is
    /// drawn bold, with neither tildes nor asterisks left in the text.
    func testBoldInsideStrikethroughIsBoldAndTheWholeSpanIsStruck() throws {
        let rendered = MarkdownRenderer.render("~~a **hard** no~~", isDark: false)

        XCTAssertEqual(rendered.string, "a hard no")
        XCTAssertEqual(struckText(in: rendered), "a hard no")
        XCTAssertEqual(try weight(of: rendered, at: "hard"), .semibold)
        XCTAssertTrue(try traits(of: rendered, at: "hard").contains(.bold))
    }

    // MARK: - Block quotes

    /// `> ` is an indented, secondary line — not a greater-than sign in the body.
    func testQuoteLosesItsMarkerAndIsIndented() {
        let rendered = MarkdownRenderer.render("> the run said no", isDark: false)

        XCTAssertEqual(rendered.string, "the run said no")
        XCTAssertGreaterThan(
            firstHeadIndent(rendered),
            firstHeadIndent(MarkdownRenderer.render("the run said no", isDark: false)),
            "A quote should be indented further than a plain paragraph"
        )
    }

    /// The quote body goes through the inline parser, so what it quotes keeps its
    /// bold, its inline code and its links.
    func testInlineMarkupInsideAQuoteIsStillFormatted() throws {
        let rendered = MarkdownRenderer.render(
            "> **bold** and `code` and [text](https://example.com)",
            isDark: false
        )

        XCTAssertEqual(rendered.string, "bold and code and text")
        let link = rendered.attribute(.link, at: rendered.string.distance(
            from: rendered.string.startIndex,
            to: try XCTUnwrap(rendered.string.range(of: "text")).lowerBound
        ), effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com"))
        XCTAssertTrue(
            (0..<rendered.length).contains { index in
                let font = rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                return font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            },
            "The **bold** inside the quote should still be bold"
        )
        XCTAssertTrue(
            (0..<rendered.length).contains { index in
                rendered.attribute(.backgroundColor, at: index, effectiveRange: nil) != nil
            },
            "The `code` inside the quote should still carry the inline-code background"
        )
    }

    /// A quote written without the space after its marker is the common shape, and
    /// was printed with its angle bracket: it is the same quote as `> note`.
    func testQuoteWithoutASpaceAfterItsMarkerIsStillAQuote() {
        let rendered = MarkdownRenderer.render(">note", isDark: false)

        XCTAssertEqual(rendered.string, "note")
        XCTAssertEqual(firstHeadIndent(rendered), firstHeadIndent(MarkdownRenderer.render("> note", isDark: false)))
    }

    /// The bare `>` that separates two quoted paragraphs is an empty quoted line,
    /// not a stray angle bracket in the middle of the quote — and it keeps the
    /// quote's indent.
    func testBareQuoteMarkerBetweenParagraphsIsAnEmptyQuotedLine() throws {
        let rendered = MarkdownRenderer.render("> first\n>\n> second", isDark: false)

        XCTAssertFalse(rendered.string.contains(">"), "Got: \(rendered.string)")
        XCTAssertEqual(rendered.string.components(separatedBy: "\n").count, 3, "Got: \(rendered.string)")
        let firstBreak = try XCTUnwrap(rendered.string.range(of: "\n"))
        let blank = rendered.string.distance(from: rendered.string.startIndex, to: firstBreak.upperBound)
        let style = rendered.attribute(.paragraphStyle, at: blank, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, firstHeadIndent(rendered), "The empty line should keep the quote's indent")
    }

    /// A quoted reply: the inner marker is consumed too, so the body is drawn once
    /// and sits one step further in than a single-level quote.
    func testNestedQuoteLosesBothMarkersAndIsIndentedFurther() {
        let rendered = MarkdownRenderer.render("> > reply", isDark: false)

        XCTAssertEqual(rendered.string, "reply")
        XCTAssertGreaterThan(
            firstHeadIndent(rendered),
            firstHeadIndent(MarkdownRenderer.render("> reply", isDark: false)),
            "A nested quote should be indented further than a single-level one"
        )
    }

    /// A quote written indented under a list item — the way an indented fence is
    /// still a fence — is still a quote, not prose opening with an angle bracket.
    func testQuoteIndentedUnderAListItemIsStillAQuote() {
        let rendered = MarkdownRenderer.render("  > indented under a list item", isDark: false)

        XCTAssertEqual(rendered.string, "indented under a list item")
        XCTAssertGreaterThan(
            firstHeadIndent(rendered),
            firstHeadIndent(MarkdownRenderer.render("indented under a list item", isDark: false))
        )
    }

    /// The body of a spaceless quote goes through the inline parser like any other
    /// quote body.
    func testInlineMarkupInsideASpacelessQuoteIsStillFormatted() throws {
        let rendered = MarkdownRenderer.render(">a **bold** word", isDark: false)

        XCTAssertEqual(rendered.string, "a bold word")
        XCTAssertEqual(try weight(of: rendered, at: "bold"), .semibold)
    }

    // MARK: - Blocks written inside a quote

    /// A quoted checklist is a list: the dash goes, a bullet takes its place, and
    /// the item still sits inside the quote rather than at the left margin.
    func testQuotedListItemIsDrawnAsABulletInsideTheQuote() {
        let rendered = MarkdownRenderer.render("> - one", isDark: false)

        XCTAssertFalse(rendered.string.contains("-"), "Got: \(rendered.string)")
        XCTAssertTrue(rendered.string.contains("\u{2022} one"), "Got: \(rendered.string)")
        XCTAssertGreaterThanOrEqual(
            firstHeadIndent(rendered),
            firstHeadIndent(MarkdownRenderer.render("> one", isDark: false)),
            "A quoted bullet should sit at least as far in as a plain quoted line"
        )
    }

    /// A heading written inside a quote is drawn at its heading size, not printed
    /// with its hashes.
    func testQuotedHeadingIsDrawnAtItsHeadingSize() {
        let rendered = MarkdownRenderer.render("> ## Notes", isDark: false)

        XCTAssertEqual(rendered.string, "Notes")
        XCTAssertEqual(firstFontSize(rendered), firstFontSize(MarkdownRenderer.render("## Notes", isDark: false)))
    }

    /// A quoted item written one level in keeps the quote's own indent and takes
    /// the list's further step on top of it.
    func testQuotedNestedListItemKeepsBothTheQuoteIndentAndItsOwnStep() {
        let rendered = MarkdownRenderer.render(">   - sub", isDark: false)

        let flat = MarkdownRenderer.render("> - sub", isDark: false)
        XCTAssertEqual(firstHeadIndent(rendered), firstHeadIndent(flat), "The quote's indent should be unchanged")
        XCTAssertGreaterThan(
            rendered.string.prefix { $0 == " " }.count,
            flat.string.prefix { $0 == " " }.count,
            "The nested item should carry the list's own further step: \(rendered.string)"
        )
    }

    /// The body of a quoted list item still goes through the inline parser.
    func testInlineMarkupInsideAQuotedListItemIsStillFormatted() throws {
        let rendered = MarkdownRenderer.render("> - **bold** and `code`", isDark: false)

        XCTAssertTrue(rendered.string.hasSuffix("bold and code"), "Got: \(rendered.string)")
        XCTAssertEqual(try weight(of: rendered, at: "bold"), .semibold)
        XCTAssertTrue(
            (0..<rendered.length).contains { rendered.attribute(.backgroundColor, at: $0, effectiveRange: nil) != nil },
            "The `code` inside the quoted item should still carry the inline-code background"
        )
    }

    /// A dash inside a quoted sentence is punctuation, not a bullet, and a plain
    /// quoted line is drawn exactly as it was before.
    func testQuotedSentenceWithADashInventsNoBullet() {
        let rendered = MarkdownRenderer.render("> the run - eventually - said no", isDark: false)

        XCTAssertEqual(rendered.string, "the run - eventually - said no")
        XCTAssertFalse(rendered.string.contains("\u{2022}"), "Got: \(rendered.string)")
    }

    /// A rule line inside a quote is read before the list marker, as it is outside
    /// one, so a quoted `* * *` keeps printing its characters rather than turning
    /// into a bullet.
    func testQuotedRuleLineIsNotDrawnAsABullet() {
        let rendered = MarkdownRenderer.render("> * * *", isDark: false)

        XCTAssertEqual(rendered.string, "* * *")
    }

    /// An angle bracket in the middle of a sentence opens no quote — only a line
    /// that begins with one is quoted.
    func testAngleBracketMidSentenceIsNotAQuote() {
        XCTAssertEqual(MarkdownRenderer.render("a -> b", isDark: false).string, "a -> b")
        XCTAssertEqual(MarkdownRenderer.render("x > y", isDark: false).string, "x > y")
    }

    // MARK: - Inside a fence, markers are code

    /// A fence claims its lines first, so a heading marker or a quote marker written
    /// inside one is still shown verbatim.
    func testDeepHeadingAndQuoteInsideAFenceStayCode() {
        let rendered = MarkdownRenderer.render("```\n#### Findings\n> the run said no\n```", isDark: false)

        XCTAssertTrue(rendered.string.contains("#### Findings"), "Got: \(rendered.string)")
        XCTAssertTrue(rendered.string.contains("> the run said no"), "Got: \(rendered.string)")
    }

    /// A fence written under a list item carries the list's indentation. It is still
    /// a fence: the backticks never reach the reader, and a `# ` line between them is
    /// monospaced code rather than a heading.
    func testIndentedFenceUnderAListItemRendersItsBodyAsCode() throws {
        let reply = """
            - step one:

              ```
              # not a heading
              ```
            """
        let rendered = MarkdownRenderer.render(reply, isDark: false)

        XCTAssertFalse(rendered.string.contains("`"), "Got: \(rendered.string)")
        XCTAssertTrue(rendered.string.contains("# not a heading"), "Got: \(rendered.string)")
        XCTAssertTrue(
            try font(of: rendered, at: "# not a heading").isFixedPitch,
            "The line inside the fence should be code, not a heading-sized run"
        )
    }

    /// The list's indentation is not baked into the captured code: the first code
    /// line starts where it would had the fence been written at column zero.
    func testIndentedFenceDropsTheListIndentFromItsCode() {
        let reply = """
            1. run it:

                ```swift
                let x = 1
                ```
            """
        let rendered = MarkdownRenderer.render(reply, isDark: false)
        let codeLine = rendered.string.components(separatedBy: "\n").first { $0.contains("let x = 1") }

        XCTAssertEqual(codeLine, "let x = 1", "Got: \(rendered.string)")
    }

    /// A fence opened at column zero is closed by an indented fence, so the prose
    /// after it is prose and not the rest of the message swallowed as code.
    func testAnIndentedClosingFenceEndsTheBlock() throws {
        let reply = """
            ```
            let x = 1
              ```
            and then prose
            """
        let rendered = MarkdownRenderer.render(reply, isDark: false)

        XCTAssertFalse(rendered.string.contains("`"), "Got: \(rendered.string)")
        XCTAssertFalse(
            try font(of: rendered, at: "and then prose").isFixedPitch,
            "Prose after the closing fence should not be drawn as code"
        )
    }

    // MARK: - Emphasis and bare URLs

    /// Every `.link` run a render carries: the text it covers and the URL it points at.
    private func links(in rendered: NSAttributedString) -> [(text: String, url: URL)] {
        var found: [(text: String, url: URL)] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if let url = value as? URL {
                found.append((rendered.attributedSubstring(from: range).string, url))
            }
        }
        return found
    }

    /// The font traits the run under the first occurrence of `substring` carries.
    private func traits(
        of rendered: NSAttributedString,
        at substring: String
    ) throws -> NSFontDescriptor.SymbolicTraits {
        let range = try XCTUnwrap(rendered.string.range(of: substring))
        let offset = rendered.string.distance(from: rendered.string.startIndex, to: range.lowerBound)
        let font = try XCTUnwrap(rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        return font.fontDescriptor.symbolicTraits
    }

    /// `*emphasis*` is italic text, with the asterisks gone.
    func testEmphasisIsItalicAndLosesItsAsterisks() throws {
        let rendered = MarkdownRenderer.render("*just so*", isDark: false)

        XCTAssertEqual(rendered.string, "just so")
        XCTAssertTrue(
            try traits(of: rendered, at: "just so").contains(.italic),
            "Emphasis should carry the italic trait"
        )
    }

    /// Bold keeps its precedence: `**x**` is one bold run, not two empty italic spans
    /// around one.
    func testBoldIsStillBoldAndOpensNoItalicSpan() throws {
        let rendered = MarkdownRenderer.render("**bold** tail", isDark: false)

        XCTAssertEqual(rendered.string, "bold tail")
        XCTAssertTrue(try traits(of: rendered, at: "bold").contains(.bold))
        XCTAssertFalse(
            (0..<rendered.length).contains { index in
                let font = rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                return font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
            },
            "No part of a bold line should come back italic"
        )
    }

    /// An asterisk followed by whitespace opens nothing, and an unmatched one is
    /// printed as itself — arithmetic and bullets are left alone.
    func testAsterisksThatOpenNoEmphasisArePrinted() {
        XCTAssertEqual(MarkdownRenderer.render("2 * 3 * 4", isDark: false).string, "2 * 3 * 4")
        XCTAssertEqual(MarkdownRenderer.render("a lone * here", isDark: false).string, "a lone * here")
        XCTAssertEqual(MarkdownRenderer.render("*unclosed", isDark: false).string, "*unclosed")
        XCTAssertEqual(MarkdownRenderer.render("* item", isDark: false).string, "  \u{2022} item")
    }

    /// `_emphasis_` is italic text with the underscores gone, as `*emphasis*` is,
    /// and a closer before punctuation still closes.
    func testUnderscoreEmphasisIsItalicAndLosesItsUnderscores() throws {
        let rendered = MarkdownRenderer.render("Be _careful_, here", isDark: false)

        XCTAssertEqual(rendered.string, "Be careful, here")
        XCTAssertTrue(try traits(of: rendered, at: "careful").contains(.italic))
        XCTAssertFalse(try traits(of: rendered, at: "Be").contains(.italic))
        XCTAssertFalse(try traits(of: rendered, at: ", here").contains(.italic))
    }

    /// `__x__` is one bold run, not two empty italic spans around one.
    func testUnderscoreBoldIsBoldAndOpensNoItalicSpan() throws {
        let rendered = MarkdownRenderer.render("I __never__ do that", isDark: false)

        XCTAssertEqual(rendered.string, "I never do that")
        XCTAssertTrue(try traits(of: rendered, at: "never").contains(.bold))
        XCTAssertEqual(try weight(of: rendered, at: "never"), .semibold)
        XCTAssertFalse(try traits(of: rendered, at: " do").contains(.bold))
        XCTAssertFalse(italicRunExists(in: rendered), "No part of a bold line should come back italic")
    }

    /// Both spellings of both traits on one line, each losing its markers.
    func testUnderscoreAndAsteriskSpellingsMixOnOneLine() throws {
        // `traits(of:at:)` reads the first match, so no marked letter appears in "and".
        let rendered = MarkdownRenderer.render("**w** and _x_ and __y__ and *z*", isDark: false)

        XCTAssertEqual(rendered.string, "w and x and y and z")
        XCTAssertTrue(try traits(of: rendered, at: "w").contains(.bold))
        XCTAssertTrue(try traits(of: rendered, at: "x").contains(.italic))
        XCTAssertTrue(try traits(of: rendered, at: "y").contains(.bold))
        XCTAssertTrue(try traits(of: rendered, at: "z").contains(.italic))
    }

    /// Underscores inside a word open nothing, so identifiers and file names keep
    /// every underscore — and so does a Python dunder name, even written bare.
    func testIdentifiersKeepTheirUnderscores() {
        for identifier in [
            "snake_case_name", "open some_file.swift now", "call self.__init__ first",
            "def __init__(self):", "__init__()", "__init__", "call __init__ first",
            #"if __name__ == "__main__":"#, "MAX_RETRY_COUNT", "a_b_c_d"
        ] {
            let rendered = MarkdownRenderer.render(identifier, isDark: false)
            XCTAssertEqual(rendered.string, identifier)
            XCTAssertFalse(italicRunExists(in: rendered), "\(identifier) came back italic")
            XCTAssertFalse(boldRunExists(in: rendered), "\(identifier) came back bold")
        }
    }

    /// An underscore that opens nothing — unclosed, followed by a space, alone — is
    /// printed as itself, and the rest of the line stays upright.
    func testUnderscoresThatOpenNoEmphasisArePrinted() {
        for text in ["an _unclosed opener and more text", "an __unclosed bold", "a _ b _ c", "x _ y", "trailing _"] {
            let rendered = MarkdownRenderer.render(text, isDark: false)
            XCTAssertEqual(rendered.string, text)
            XCTAssertFalse(italicRunExists(in: rendered), "\(text) came back italic")
            XCTAssertFalse(boldRunExists(in: rendered), "\(text) came back bold")
        }
    }

    /// The code arms still win: underscores inside an inline code span and a
    /// fenced block are printed as typed, in the code font, with no emphasis.
    func testUnderscoresInCodeAreUntouched() throws {
        let inline = MarkdownRenderer.render("use `_x_` and `__y__` here", isDark: false)
        XCTAssertEqual(inline.string, "use _x_ and __y__ here")
        XCTAssertTrue(try font(of: inline, at: "_x_").isFixedPitch)
        XCTAssertFalse(italicRunExists(in: inline))
        XCTAssertFalse(boldRunExists(in: inline))

        let fenced = MarkdownRenderer.render("```\n_careful_\n__never__\nsnake_case_name\n```", isDark: false)
        for line in ["_careful_", "__never__", "snake_case_name"] {
            XCTAssertTrue(fenced.string.contains(line), "Got: \(fenced.string)")
            XCTAssertFalse(try traits(of: fenced, at: line).contains(.italic), "\(line) came back italic")
        }
    }

    private func italicRunExists(in rendered: NSAttributedString) -> Bool {
        runExists(in: rendered, with: .italic)
    }

    private func boldRunExists(in rendered: NSAttributedString) -> Bool {
        runExists(in: rendered, with: .bold)
    }

    private func runExists(in rendered: NSAttributedString, with trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        (0..<rendered.length).contains { index in
            let font = rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            return font?.fontDescriptor.symbolicTraits.contains(trait) ?? false
        }
    }

    /// A backslash-escaped asterisk is printed as itself, opens no emphasis, and
    /// leaves no backslash behind.
    func testEscapedAsterisksArePrintedAndOpenNoEmphasis() {
        let rendered = MarkdownRenderer.render(#"\*not italic\*"#, isDark: false)

        XCTAssertEqual(rendered.string, "*not italic*")
        XCTAssertFalse(
            (0..<rendered.length).contains { index in
                let font = rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                return font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
            },
            "An escaped asterisk should leave no italic run"
        )
    }

    /// An escaped backtick is a backtick in the text, and no part of the line is
    /// drawn as inline code.
    func testEscapedBacktickIsPrintedAndOpensNoCodeSpan() {
        let rendered = MarkdownRenderer.render(#"a \` here"#, isDark: false)

        XCTAssertEqual(rendered.string, "a ` here")
        XCTAssertFalse(
            (0..<rendered.length).contains { index in
                let font = rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                return font?.isFixedPitch ?? false
            },
            "An escaped backtick should leave no monospaced run"
        )
    }

    /// An escaped tilde pair is printed rather than struck through.
    func testEscapedTildesArePrintedAndOpenNoStrikethrough() {
        let rendered = MarkdownRenderer.render(#"\~\~kept\~\~"#, isDark: false)

        XCTAssertEqual(rendered.string, "~~kept~~")
        XCTAssertNil(struckText(in: rendered))
    }

    /// A backslash before a character this renderer reads as nothing in particular
    /// still prints both, and a line ending in a lone backslash keeps it.
    func testBackslashBeforeOrdinaryTextIsPrintedAsItself() {
        XCTAssertEqual(
            MarkdownRenderer.render(#"C:\Users\pat"#, isDark: false).string,
            #"C:\Users\pat"#
        )
        XCTAssertEqual(
            MarkdownRenderer.render(#"a line ending in a slash \"#, isDark: false).string,
            #"a line ending in a slash \"#
        )
    }

    /// A bare URL an agent pastes is clickable over itself and no further.
    func testBareURLIsALinkOverItsOwnText() {
        let rendered = MarkdownRenderer.render("see https://example.com/docs for more", isDark: false)

        XCTAssertEqual(rendered.string, "see https://example.com/docs for more")
        let found = links(in: rendered)
        XCTAssertEqual(found.count, 1, "Got: \(found)")
        XCTAssertEqual(found.first?.text, "https://example.com/docs")
        XCTAssertEqual(found.first?.url, URL(string: "https://example.com/docs"))
    }

    /// The full stop that ends the sentence is text, not part of the URL.
    func testURLAtTheEndOfASentenceKeepsTheFullStopOutOfTheLink() {
        let rendered = MarkdownRenderer.render("docs at https://example.com/docs.", isDark: false)

        XCTAssertEqual(rendered.string, "docs at https://example.com/docs.")
        XCTAssertEqual(links(in: rendered).first?.url, URL(string: "https://example.com/docs"))
        XCTAssertEqual(links(in: rendered).first?.text, "https://example.com/docs")
    }

    /// A URL inside backticks is code, and a written link is still exactly one link
    /// over its own text.
    func testURLInCodeStaysCodeAndAWrittenLinkIsStillOneLink() {
        let rendered = MarkdownRenderer.render(
            "`https://example.com` and [text](https://example.org)",
            isDark: false
        )

        XCTAssertEqual(rendered.string, "https://example.com and text")
        let found = links(in: rendered)
        XCTAssertEqual(found.count, 1, "Got: \(found)")
        XCTAssertEqual(found.first?.text, "text")
        XCTAssertEqual(found.first?.url, URL(string: "https://example.org"))
    }

    // MARK: - Images

    /// An image an agent writes is one run the reader can act on: no exclamation
    /// mark on the page, the alt text once, behind an image marker, carrying the
    /// image's URL.
    func testImageIsOneMarkedRunCarryingItsURL() {
        let rendered = MarkdownRenderer.render(
            "see ![diagram](https://example.com/a.png) here",
            isDark: false
        )

        XCTAssertFalse(rendered.string.contains("!"), "Got: \(rendered.string)")
        XCTAssertEqual(rendered.string, "see \u{1F5BC} diagram here")
        let found = links(in: rendered)
        XCTAssertEqual(found.count, 1, "Got: \(found)")
        XCTAssertEqual(found.first?.text, "\u{1F5BC} diagram")
        XCTAssertEqual(found.first?.url, URL(string: "https://example.com/a.png"))
    }

    /// An escaped bracket after an exclamation mark opens no image: both characters
    /// are printed as themselves and the line carries no link at all.
    func testEscapedBracketAfterExclamationMarkIsNoImage() {
        let rendered = MarkdownRenderer.render(
            #"!\[diagram](a.png)"#,
            isDark: false
        )

        XCTAssertEqual(rendered.string, "![diagram](a.png)")
        XCTAssertTrue(links(in: rendered).isEmpty, "Got: \(links(in: rendered))")
    }

    /// A written link with no exclamation mark in front of it is drawn exactly as
    /// it was before: the label alone, unmarked, carrying the URL.
    func testWrittenLinkIsUnchangedByTheImageArm() {
        let rendered = MarkdownRenderer.render("see [docs](https://example.com) here", isDark: false)

        XCTAssertEqual(rendered.string, "see docs here")
        XCTAssertEqual(links(in: rendered).count, 1, "Got: \(links(in: rendered))")
        XCTAssertEqual(links(in: rendered).first?.text, "docs")
        XCTAssertEqual(links(in: rendered).first?.url, URL(string: "https://example.com"))
    }

    /// An exclamation mark in prose is drawn as itself, whether it ends a sentence
    /// or merely sits in front of a word.
    func testExclamationMarkInProseIsPrintedAsItself() {
        let rendered = MarkdownRenderer.render("done! and !not an image at all", isDark: false)

        XCTAssertEqual(rendered.string, "done! and !not an image at all")
        XCTAssertTrue(links(in: rendered).isEmpty, "Got: \(links(in: rendered))")
    }

    // MARK: - Nested lists

    /// An indented sub-bullet is a bullet one step in, not a dash and two spaces
    /// printed as text.
    func testIndentedBulletIsABulletFurtherIn() {
        let rendered = MarkdownRenderer.render("- one\n  - two", isDark: false)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2, "Got: \(rendered.string)")
        XCTAssertTrue(lines[0].contains("\u{2022} one"), "Got: \(lines[0])")
        XCTAssertTrue(lines[1].contains("\u{2022} two"), "Got: \(lines[1])")
        XCTAssertFalse(lines[1].contains("-"), "The sub-bullet's dash should be gone: \(lines[1])")
        let firstIndent = lines[0].prefix { $0 == " " }.count
        let secondIndent = lines[1].prefix { $0 == " " }.count
        XCTAssertGreaterThan(secondIndent, firstIndent, "The sub-bullet should sit further in")
    }

    // MARK: - Task lists

    /// An unticked task-list item is an empty box, with no brackets or bullet left
    /// in the line.
    func testUntickedTaskItemIsAnEmptyBox() {
        let rendered = MarkdownRenderer.render("- [ ] wire the endpoint", isDark: false)

        XCTAssertEqual(rendered.string, "  \u{2610} wire the endpoint")
    }

    /// A ticked item is a ticked box, in either spelling of the tick.
    func testTickedTaskItemIsATickedBoxInEitherCase() {
        for line in ["- [x] add the test", "- [X] add the test"] {
            let rendered = MarkdownRenderer.render(line, isDark: false)
            XCTAssertEqual(rendered.string, "  \u{2611} add the test", "Got: \(rendered.string) for \(line)")
        }
    }

    /// A checkbox nested under a bullet sits one step further in, the same step a
    /// plain sub-bullet does.
    func testNestedTaskItemIsIndentedOneFurtherStep() {
        let rendered = MarkdownRenderer.render("- [ ] top\n  - [ ] nested", isDark: false)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2, "Got: \(rendered.string)")
        let plain = MarkdownRenderer.render("- one\n  - two", isDark: false)
            .string.components(separatedBy: "\n")
        let step = plain[1].prefix { $0 == " " }.count - plain[0].prefix { $0 == " " }.count
        let taskStep = lines[1].prefix { $0 == " " }.count - lines[0].prefix { $0 == " " }.count
        XCTAssertEqual(taskStep, step, "Got: \(lines)")
    }

    /// Brackets that are not a checkbox stay text, and the three ordinary list
    /// markers render exactly as they did before task lists.
    func testOrdinaryListItemsAreUnchangedByTaskLists() {
        XCTAssertEqual(MarkdownRenderer.render("- item", isDark: false).string, "  \u{2022} item")
        XCTAssertEqual(MarkdownRenderer.render("* item", isDark: false).string, "  \u{2022} item")
        XCTAssertEqual(MarkdownRenderer.render("1. item", isDark: false).string, "  1. item")
        XCTAssertEqual(
            MarkdownRenderer.render("- [not a box] text", isDark: false).string,
            "  \u{2022} [not a box] text"
        )
    }

    /// An indented numbered item keeps its number — the digits are not eaten by the
    /// indent, and it too sits further in.
    func testIndentedNumberedItemKeepsItsNumber() {
        let rendered = MarkdownRenderer.render("1. one\n  12. two", isDark: false)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2, "Got: \(rendered.string)")
        XCTAssertEqual(lines[0], "  1. one")
        XCTAssertEqual(lines[1], "    12. two")
    }

    /// Prose that merely begins with spaces is left exactly as written — no bullet is
    /// invented for it.
    func testIndentedProseIsNotTurnedIntoAList() {
        XCTAssertEqual(
            MarkdownRenderer.render("  just indented prose", isDark: false).string,
            "  just indented prose"
        )
    }

    // MARK: - Hanging indent on list items

    /// The paragraph style the rendered line carries at the first character of `text`.
    private func paragraphStyle(of rendered: NSAttributedString, at text: String) throws -> NSParagraphStyle {
        let range = try XCTUnwrap(rendered.string.range(of: text))
        let offset = rendered.string.distance(from: rendered.string.startIndex, to: range.lowerBound)
        return try XCTUnwrap(rendered.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
    }

    /// A long bullet wraps under its own text: the head indent is the drawn width of
    /// the bullet prefix, and the first line is not pushed in any further.
    func testBulletWrapsUnderItsOwnText() throws {
        let rendered = MarkdownRenderer.render("- item", isDark: false)
        let style = try paragraphStyle(of: rendered, at: "item")
        let prefixWidth = NSAttributedString(
            string: "  \u{2022} ", attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ).size().width

        XCTAssertGreaterThan(style.headIndent, 0)
        XCTAssertEqual(style.headIndent, prefixWidth, accuracy: 0.001)
        XCTAssertEqual(style.firstLineHeadIndent, 0)
        XCTAssertEqual(firstHeadIndent(rendered), style.headIndent, "The prefix carries the same style")
    }

    /// Inline markup inside the item carries the hanging indent too.
    func testBoldInsideABulletCarriesTheHangingIndent() throws {
        let rendered = MarkdownRenderer.render("- plain **bold** `code`", isDark: false)

        let plain = try paragraphStyle(of: rendered, at: "plain").headIndent
        XCTAssertGreaterThan(plain, 0)
        XCTAssertEqual(try paragraphStyle(of: rendered, at: "bold").headIndent, plain)
        XCTAssertEqual(try paragraphStyle(of: rendered, at: "code").headIndent, plain)
    }

    /// A sub-bullet wraps at its own text, further in than a top-level bullet's.
    func testNestedBulletHangsFurtherInThanATopLevelOne() throws {
        let rendered = MarkdownRenderer.render("- top\n  - sub", isDark: false)

        let top = try paragraphStyle(of: rendered, at: "top").headIndent
        let sub = try paragraphStyle(of: rendered, at: "sub").headIndent
        XCTAssertGreaterThan(sub, top)
    }

    /// Numbered and task-list items hang the same way a bullet does.
    func testNumberedAndTaskItemsHangUnderTheirText() throws {
        let numbered = MarkdownRenderer.render("1. item", isDark: false)
        let task = MarkdownRenderer.render("- [ ] task", isDark: false)

        XCTAssertGreaterThan(try paragraphStyle(of: numbered, at: "item").headIndent, 0)
        XCTAssertGreaterThan(try paragraphStyle(of: task, at: "task").headIndent, 0)
    }

    /// A line that is not a list item keeps no hanging indent.
    func testProseLineHasNoHangingIndent() throws {
        let rendered = MarkdownRenderer.render("just a sentence", isDark: false)

        XCTAssertEqual(try paragraphStyle(of: rendered, at: "sentence").headIndent, 0)
        XCTAssertEqual(firstHeadIndent(MarkdownRenderer.render("## Heading", isDark: false)), 0)
    }

    // MARK: - What was already rendering

    /// Levels 1–3, bullets and numbered lists are untouched by the deeper arms.
    func testShallowHeadingsAndListsRenderAsBefore() {
        XCTAssertEqual(MarkdownRenderer.render("# One", isDark: false).string, "One")
        XCTAssertEqual(firstFontSize(MarkdownRenderer.render("# One", isDark: false)), 22)
        XCTAssertEqual(firstFontSize(MarkdownRenderer.render("## Two", isDark: false)), 19)
        XCTAssertEqual(firstFontSize(MarkdownRenderer.render("### Three", isDark: false)), 16)
        XCTAssertEqual(MarkdownRenderer.render("- item", isDark: false).string, "  \u{2022} item")
        XCTAssertEqual(MarkdownRenderer.render("1. item", isDark: false).string, "  1. item")
    }

    // MARK: - Inline markup inside a table cell

    /// The font the run under the first occurrence of `substring` carries.
    private func font(of rendered: NSAttributedString, at substring: String) throws -> NSFont {
        let range = try XCTUnwrap(rendered.string.range(of: substring))
        let offset = rendered.string.distance(from: rendered.string.startIndex, to: range.lowerBound)
        return try XCTUnwrap(rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
    }

    private let markupTable = """
        | flag | on |
        |---|---|
        | `--json` | **yes** |
        """

    /// A bolded body cell shows the reader "yes", not "**yes**".
    func testBoldCellLosesItsAsterisksAndIsBold() throws {
        let rendered = MarkdownRenderer.render(markupTable, isDark: false)

        XCTAssertFalse(rendered.string.contains("*"), "A bold cell should not print its asterisks")
        XCTAssertTrue(try traits(of: rendered, at: "yes").contains(.bold))
    }

    /// An inline-code cell drops its backticks and is drawn monospaced.
    func testCodeCellLosesItsBackticksAndIsMonospaced() throws {
        let rendered = MarkdownRenderer.render(markupTable, isDark: false)

        XCTAssertFalse(rendered.string.contains("`"), "A code cell should not print its backticks")
        XCTAssertEqual(
            try font(of: rendered, at: "--json"),
            NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        )
    }

    /// Padding is measured on what the reader sees, so a bolded cell and a plain
    /// cell of the same rendered width leave their rows the same length — the
    /// divider still lines up under the header.
    func testMarkupDoesNotShiftItsColumn() {
        let table = """
            | on |
            |---|
            | **yes** |
            | yes\u{00A0}\u{00A0} |
            """
        let lines = MarkdownRenderer.render(table, isDark: false).string
            .components(separatedBy: "\n")

        XCTAssertEqual(lines[2].count, lines[3].count, "Markup must not widen the row it sits in")
        XCTAssertEqual(lines[1].count, lines[2].count, "The divider must match the rows it divides")
        XCTAssertEqual(lines[2].count, 5, "The column is as wide as the three characters the reader sees")
    }

    // MARK: - Strikethrough and rules

    /// The range of the first run carrying a non-zero `.strikethroughStyle`, and the
    /// text under it — what the reader actually sees struck out.
    private func struckText(in rendered: NSAttributedString) -> String? {
        var found: String?
        let full = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.strikethroughStyle, in: full) { value, range, stop in
            if let style = value as? Int, style != 0 {
                found = rendered.attributedSubstring(from: range).string
                stop.pointee = true
            }
        }
        return found
    }

    /// `~~x~~` loses its tildes and comes back struck through over exactly its text.
    func testStrikethroughLosesItsTildes() {
        let rendered = MarkdownRenderer.render("~~gone~~", isDark: false)

        XCTAssertEqual(rendered.string, "gone")
        XCTAssertEqual(struckText(in: rendered), "gone")
    }

    /// A lone tilde and an unclosed pair open nothing and are printed as typed.
    func testTildesThatOpenNoStrikethroughArePrinted() {
        XCTAssertEqual(MarkdownRenderer.render("a ~ here", isDark: false).string, "a ~ here")

        let unclosed = MarkdownRenderer.render("~~still here", isDark: false)
        XCTAssertEqual(unclosed.string, "~~still here")
        XCTAssertNil(struckText(in: unclosed))
    }

    /// A line that is only rule characters is drawn as a thin line rather than as
    /// those characters — and `* * *` is a rule, not a bullet.
    func testRuleLineIsDrawnAsARule() {
        for line in ["---", "***", "___", "* * *"] {
            let rendered = MarkdownRenderer.render(line, isDark: false).string
            XCTAssertFalse(
                rendered.contains(where: { "-*_".contains($0) }),
                "\(line) should leave none of its characters. Got: \(rendered)"
            )
            XCTAssertFalse(rendered.contains("\u{2022}"), "\(line) is a rule, not a bullet")
            XCTAssertTrue(rendered.contains("\u{2500}"), "\(line) should draw a rule. Got: \(rendered)")
        }
    }

    /// Inside a fence, a struck phrase and a rule line stay the characters they were
    /// written with.
    func testStrikethroughAndRuleInsideAFenceStayCode() {
        let rendered = MarkdownRenderer.render("```\n~~x~~\n---\n```", isDark: false)

        XCTAssertTrue(rendered.string.contains("~~x~~"), "Got: \(rendered.string)")
        XCTAssertTrue(rendered.string.contains("---"), "Got: \(rendered.string)")
    }

    /// A struck cell loses its tildes without widening the column it sits in.
    func testStruckCellDoesNotShiftItsColumn() {
        let table = """
            | on |
            |---|
            | ~~yes~~ |
            | yes\u{00A0}\u{00A0} |
            """
        let rendered = MarkdownRenderer.render(table, isDark: false)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertFalse(rendered.string.contains("~"), "Got: \(rendered.string)")
        XCTAssertEqual(struckText(in: rendered), "yes")
        XCTAssertEqual(lines[2].count, lines[3].count, "Markup must not widen the row it sits in")
        XCTAssertEqual(lines[2].count, 5, "The column is as wide as the three characters the reader sees")
    }

    /// The header stays bold and the separator row still draws no row of its own.
    func testHeaderIsBoldAndSeparatorRowDrawsNoTextRow() throws {
        let rendered = MarkdownRenderer.render(markupTable, isDark: false)

        XCTAssertEqual(
            try font(of: rendered, at: "flag"),
            NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        )
        XCTAssertFalse(rendered.string.contains("---"))
        // Header, divider and one body row; `render` trims the trailing newlines.
        XCTAssertEqual(rendered.string.components(separatedBy: "\n").count, 3)
    }

    // MARK: - An escaped pipe inside a table cell

    private let escapedPipeTable = """
        | command | what |
        |---|---|
        | grep foo \\| wc -l | count lines |
        """

    /// `\|` is the pipe the author meant, not a cell boundary: the cell keeps its
    /// one pipe, drops the backslash, and the row still has the header's two columns.
    func testEscapedPipeStaysInsideItsCell() {
        let rendered = MarkdownRenderer.render(escapedPipeTable, isDark: false)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertTrue(lines[2].contains("grep foo | wc -l"), "Got: \(lines[2])")
        XCTAssertFalse(rendered.string.contains("\\"), "Got: \(rendered.string)")
        XCTAssertEqual(
            lines[2].filter { $0 == "\u{2502}" }.count, 1,
            "The row keeps the header's two columns. Got: \(lines[2])"
        )
        XCTAssertEqual(lines[0].filter { $0 == "\u{2502}" }.count, 1, "Got: \(lines[0])")
    }

    /// The escaped pipe widens no column of its own, so the divider still lines up
    /// under the header and over the body row.
    func testEscapedPipeRowKeepsTheDividerAligned() {
        let lines = MarkdownRenderer.render(escapedPipeTable, isDark: false).string
            .components(separatedBy: "\n")

        XCTAssertEqual(lines[0].count, lines[1].count, "The divider must match the header")
        XCTAssertEqual(lines[1].count, lines[2].count, "The divider must match the row it divides")
    }

    /// A table with no escaped pipe is drawn exactly as it was before: one cell per
    /// bare pipe, padded to the widest cell in the column.
    func testTableWithoutAnEscapedPipeIsUnchanged() {
        let table = """
            | flag | on |
            |---|---|
            | --json | yes |
            """
        let lines = MarkdownRenderer.render(table, isDark: false).string
            .components(separatedBy: "\n")
        let expected = " flag   \u{2502} on  \n"
            + String(repeating: "\u{2500}", count: 14)
            + "\n --json \u{2502} yes "

        XCTAssertEqual(lines.prefix(3).joined(separator: "\n"), expected)
    }

    /// A cell that is only `\|` is a cell holding one pipe — not an empty cell, and
    /// not two cells.
    func testCellThatIsOnlyAnEscapedPipeRendersAsOnePipe() {
        let table = """
            | sep |
            |---|
            | \\| |
            """
        let lines = MarkdownRenderer.render(table, isDark: false).string
            .components(separatedBy: "\n")

        XCTAssertEqual(lines[2], " |   ", "Got: \(lines[2])")
        XCTAssertFalse(lines[2].contains("\u{2502}"), "The table has one column, not two")
    }

    /// Inline markup still renders in a cell that also holds an escaped pipe, and
    /// neither the markup nor the backslash pads the column out.
    func testMarkupRendersInACellWithAnEscapedPipe() throws {
        let table = """
            | on |
            |---|
            | **a** \\| b |
            """
        let rendered = MarkdownRenderer.render(table, isDark: false)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertFalse(rendered.string.contains("*"), "Got: \(rendered.string)")
        XCTAssertTrue(try traits(of: rendered, at: "a").contains(.bold))
        XCTAssertEqual(lines[2], " a | b ", "Got: \(lines[2])")
        XCTAssertEqual(lines[1].count, lines[2].count, "The divider must match the row it divides")
    }

    // MARK: - Copying one code block on its own

    /// Every index `needle` covers in the rendered string.
    private func indices(of needle: String, in rendered: NSAttributedString) -> Range<Int> {
        let range = (rendered.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) was not rendered")
        return range.location..<(range.location + range.length)
    }

    func testCodeBlockLookupReturnsTheBlocksCodeWithoutFenceOrLanguage() {
        let markdown = "Run this:\n```swift\nlet a = 1\nprint(a)\n```\nThen check."
        let rendered = MarkdownRenderer.render(markdown, isDark: true)

        for index in indices(of: "let a = 1\nprint(a)", in: rendered) {
            XCTAssertEqual(MarkdownRenderer.codeBlock(in: rendered, at: index), "let a = 1\nprint(a)", "at \(index)")
        }
    }

    func testCodeBlockLookupIsNilInTheProseAroundTheBlock() {
        let markdown = "Run this:\n```swift\nlet a = 1\nprint(a)\n```\nThen check."
        let rendered = MarkdownRenderer.render(markdown, isDark: true)

        for index in indices(of: "Run this:", in: rendered) {
            XCTAssertNil(MarkdownRenderer.codeBlock(in: rendered, at: index), "before, at \(index)")
        }
        for index in indices(of: "Then check.", in: rendered) {
            XCTAssertNil(MarkdownRenderer.codeBlock(in: rendered, at: index), "after, at \(index)")
        }
    }

    func testCodeBlockUnderAListItemIsReturnedWithoutTheListIndent() {
        let markdown = "- Step one:\n  ```sh\n  cd app\n  make\n  ```"
        let rendered = MarkdownRenderer.render(markdown, isDark: true)

        let index = indices(of: "cd app", in: rendered).lowerBound
        XCTAssertEqual(MarkdownRenderer.codeBlock(in: rendered, at: index), "cd app\nmake")
    }

    func testEachOfTwoCodeBlocksReturnsItsOwnCode() {
        let markdown = "First:\n```\nalpha()\n```\nSecond:\n```python\nbeta()\n```"
        let rendered = MarkdownRenderer.render(markdown, isDark: false)

        let first = indices(of: "alpha()", in: rendered).lowerBound
        let second = indices(of: "beta()", in: rendered).lowerBound
        XCTAssertEqual(MarkdownRenderer.codeBlock(in: rendered, at: first), "alpha()")
        XCTAssertEqual(MarkdownRenderer.codeBlock(in: rendered, at: second), "beta()")
    }

    // MARK: - The right-click menu over a rendered reply

    /// A rendered reply laid out in a window, and a right-click over the first
    /// character of `needle` — the event a user's click delivers.
    private func rightClick(on needle: String, in markdown: String) throws -> (NonScrollingTextView, NSEvent) {
        let storage = NSTextStorage(attributedString: MarkdownRenderer.render(markdown, isDark: true))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = NonScrollingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                            textContainer: container)
        textView.isEditable = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        layoutManager.ensureLayout(for: container)

        let character = indices(of: needle, in: storage).lowerBound
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: character, length: 1),
                                              actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + textView.textContainerOrigin.x,
                            y: rect.midY + textView.textContainerOrigin.y)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: textView.convert(point, to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        return (textView, try XCTUnwrap(event))
    }

    func testRightClickInsideACodeBlockOffersCopyCodeFirstWithJustTheBlocksCode() throws {
        let (textView, event) = try rightClick(on: "print(a)",
                                           in: "Run this:\n```swift\nlet a = 1\nprint(a)\n```\nThen check.")

        let menu = try XCTUnwrap(textView.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Copy Code")
        XCTAssertEqual(menu.items.first?.representedObject as? String, "let a = 1\nprint(a)")
        XCTAssertGreaterThan(menu.items.count, 2, "the standard text menu is still there below it")
        XCTAssertTrue(menu.items[1].isSeparatorItem, "Copy Code is set apart from the standard items")
    }

    func testRightClickOnProseLeavesTheMenuWithoutCopyCode() throws {
        let (textView, event) = try rightClick(on: "Then check.",
                                           in: "Run this:\n```swift\nlet a = 1\n```\nThen check.")

        let titles = textView.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertFalse(titles.contains("Copy Code"))
    }

    func testRightClickOnProseOffersBranchFromHereThatCallsTheActionOnce() throws {
        let (textView, event) = try rightClick(on: "Then check.",
                                           in: "Run this:\n```swift\nlet a = 1\n```\nThen check.")
        var calls = 0
        textView.onBranchFromHere = { calls += 1 }

        let menu = try XCTUnwrap(textView.menu(for: event))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Branch from Here" })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(menu.items.map(\.title).contains("Copy Code"))
    }

    func testRightClickInsideACodeBlockKeepsCopyCodeFirstAndOffersBranchFromHere() throws {
        let (textView, event) = try rightClick(on: "print(a)",
                                           in: "Run this:\n```swift\nlet a = 1\nprint(a)\n```\nThen check.")
        textView.onBranchFromHere = {}

        let titles = try XCTUnwrap(textView.menu(for: event)).items.map(\.title)
        XCTAssertEqual(titles.first, "Copy Code")
        XCTAssertTrue(titles.contains("Branch from Here"))
    }

    func testRightClickWithoutABranchActionOffersNoBranchFromHere() throws {
        let (textView, event) = try rightClick(on: "Then check.",
                                               in: "Run this:\n```swift\nlet a = 1\n```\nThen check.")

        let titles = textView.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertFalse(titles.contains("Branch from Here"))
    }
}
