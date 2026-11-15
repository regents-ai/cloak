import CloakChat
import Testing

/// How an answer's Markdown splits into the blocks the Answer box draws.
struct MarkdownTests {
    typealias Item = Markdown.Item<String>

    static func bullet(_ text: String, depth: Int = 0) -> Item {
        Item(depth: depth, number: nil, text: text)
    }

    static func numbered(_ number: Int, _ text: String, depth: Int = 0) -> Item {
        Item(depth: depth, number: number, text: text)
    }

    // MARK: Paragraphs and headings

    @Test func paragraphsSplitAtBlankLinesAndKeepTheirLines() {
        #expect(Markdown.blocks("one\ntwo\n\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
    }

    @Test func blankTextHasNoBlocks() {
        #expect(Markdown.blocks("").isEmpty)
        #expect(Markdown.blocks(" \n\t\n").isEmpty)
    }

    @Test func windowsLineEndingsSplitTheSame() {
        #expect(Markdown.blocks("# A\r\n\r\ntext\r\nmore") == [.heading(level: 1, "A"), .paragraph("text\nmore")])
    }

    @Test func headingsByTheirHashes() {
        #expect(Markdown.blocks("# One\n## Two ##\n### Three\n#### Four\ntext") == [
            .heading(level: 1, "One"), .heading(level: 2, "Two"), .heading(level: 3, "Three"),
            .heading(level: 4, "Four"), .paragraph("text"),
        ])
    }

    @Test func hashesWithoutASpaceOrMoreThanSixAreText() {
        #expect(Markdown.blocks("#tag\n####### seven\n# C#") == [
            .paragraph("#tag\n####### seven"), .heading(level: 1, "C#"),
        ])
    }

    @Test func htmlIsAParagraphAsWritten() {
        #expect(Markdown.blocks("<div>\n<b>hi</b>\n</div>") == [.paragraph("<div>\n<b>hi</b>\n</div>")])
    }

    // MARK: Code

    @Test func fencedCodeKeepsItsLinesAndDropsItsLanguage() {
        let text = "```swift\nlet a = 1\n\n# not a heading\n- not a list\n```\nafter"
        #expect(Markdown.blocks(text) == [.code("let a = 1\n\n# not a heading\n- not a list"), .paragraph("after")])
    }

    @Test func anIndentedFenceTakesOnlyItsOwnIndentOffItsLines() {
        #expect(Markdown.blocks("  ~~~\n    two\n  one\n  ~~~") == [.code("  two\none")])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(Markdown.blocks("```\ncode\n\nmore") == [.code("code\n\nmore")])
    }

    @Test func aFenceClosesOnlyOnOneAsLong() {
        #expect(Markdown.blocks("````\n```\n````") == [.code("```")])
    }

    @Test func backticksClosedOnTheirLineAreNoFence() {
        #expect(Markdown.blocks("```inline``` text") == [.paragraph("```inline``` text")])
    }

    // MARK: Lists

    @Test func bulletsAndNumbersCountingFromTheFirst() {
        #expect(Markdown.blocks("- a\n- b\n\n3. x\n4. y\n9. z") == [
            .list([Self.bullet("a"), Self.bullet("b")]),
            .list([Self.numbered(3, "x"), Self.numbered(4, "y"), Self.numbered(5, "z")]),
        ])
    }

    @Test func oneLevelOfNestingNumberedOnItsOwn() {
        #expect(Markdown.blocks("1. one\n   - a\n   - b\n2. two\n   1. x\n   2. y") == [
            .list([
                Self.numbered(1, "one"), Self.bullet("a", depth: 1), Self.bullet("b", depth: 1),
                Self.numbered(2, "two"), Self.numbered(1, "x", depth: 1), Self.numbered(2, "y", depth: 1),
            ])
        ])
    }

    @Test func deeperItemsJoinTheNestedLevel() {
        #expect(Markdown.blocks("- a\n  - b\n    1. c") == [
            .list([Self.bullet("a"), Self.bullet("b", depth: 1), Self.numbered(1, "c", depth: 1)])
        ])
    }

    @Test func indentedLinesContinueTheirItem() {
        #expect(Markdown.blocks("- a\n  more\n\n  again\n- b") == [.list([Self.bullet("a\nmore\n\nagain"), Self.bullet("b")])])
    }

    @Test func aBlankLineBetweenItemsKeepsOneList() {
        #expect(Markdown.blocks("1. a\n\n2. b") == [.list([Self.numbered(1, "a"), Self.numbered(2, "b")])])
    }

    @Test func theOtherKindOfMarkerStartsAnotherList() {
        #expect(Markdown.blocks("- a\n1. b") == [.list([Self.bullet("a")]), .list([Self.numbered(1, "b")])])
    }

    @Test func anUnindentedLineAfterAListIsAParagraph() {
        #expect(Markdown.blocks("- a\nafter") == [.list([Self.bullet("a")]), .paragraph("after")])
    }

    @Test func aListBreaksAParagraphOnlyFromABulletOrOne() {
        #expect(Markdown.blocks("Steps:\n1. a\n- b") == [
            .paragraph("Steps:"), .list([Self.numbered(1, "a")]), .list([Self.bullet("b")]),
        ])
        #expect(Markdown.blocks("In\n2024. it rained") == [.paragraph("In\n2024. it rained")])
    }

    @Test func aFenceUnderAnItemEndsTheListAndTheNextItemKeepsItsNumber() {
        #expect(Markdown.blocks("1. Run:\n   ```sh\n   ls\n   ```\n2. Read") == [
            .list([Self.numbered(1, "Run:")]), .code("ls"), .list([Self.numbered(2, "Read")]),
        ])
    }

    @Test func emphasisAtTheStartOfALineIsNoBullet() {
        #expect(Markdown.blocks("**bold** start\n*it* too") == [.paragraph("**bold** start\n*it* too")])
    }

    // MARK: Quotes and rules

    @Test func aQuoteHoldsBlocks() {
        #expect(Markdown.blocks("> # Title\n> text\n>\n> - item\nafter") == [
            .quote([.heading(level: 1, "Title"), .paragraph("text"), .list([Self.bullet("item")])]),
            .paragraph("after"),
        ])
    }

    @Test func quotesNestThreeDeepThenShowTheirMarks() {
        #expect(Markdown.blocks(">>>> deep") == [.quote([.quote([.quote([.paragraph("> deep")])])])])
    }

    @Test func aVeryDeepQuoteStillSplits() {
        let blocks = Markdown.blocks(String(repeating: ">", count: 100_000) + " x")
        #expect(blocks == [.quote([.quote([.quote([.paragraph(String(repeating: ">", count: 99_997) + " x")])])])])
    }

    @Test func rulesOfDashesStarsOrUnderscores() {
        #expect(Markdown.blocks("a\n\n---\n* * *\n___\nb") == [.paragraph("a"), .rule, .rule, .rule, .paragraph("b")])
    }

    // MARK: Tables

    @Test func aPipeTableWithShortRowsFilled() {
        #expect(Markdown.blocks("| A | B |\n|---|:-:|\n| 1 | 2 |\n| 3 |\nafter") == [
            .table(header: ["A", "B"], rows: [["1", "2"], ["3", ""]]), .paragraph("after"),
        ])
    }

    @Test func outerPipesAreOptionalAndAnEscapedPipeIsText() {
        #expect(Markdown.blocks("A | B\n--- | ---\na \\| b | c") == [.table(header: ["A", "B"], rows: [["a | b", "c"]])])
    }

    @Test func aDelimiterRowOfAnotherWidthMakesNoTable() {
        let text = "| A | B |\n|---|\n| 1 | 2 |"
        #expect(Markdown.blocks(text) == [.paragraph(text)])
    }

    @Test func aRowWiderThanTheHeaderMakesTheTableAParagraph() {
        let text = "| A | B |\n|---|---|\n| 1 | 2 | 3 |"
        #expect(Markdown.blocks(text + "\n\nafter") == [.paragraph(text), .paragraph("after")])
    }

    // MARK: Spans

    @Test func mapChangesEverySpanAndKeepsTheShape() {
        let blocks = Markdown.blocks("# h\n- i\n> q\n\n| a |\n|---|\n| b |\n\n```\nc\n```\n***")
        #expect(blocks.map { $0.map(\.count) } == [
            .heading(level: 1, 1), .list([Markdown.Item(depth: 0, number: nil, text: 1)]), .quote([.paragraph(1)]),
            .table(header: [1], rows: [[1]]), .code("c"), .rule,
        ])
    }
}
