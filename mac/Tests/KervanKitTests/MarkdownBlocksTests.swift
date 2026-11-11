import Testing
@testable import KervanKit

@Suite struct MarkdownBlocksTests {
    @Test func paragraphsSplitOnBlankLines() {
        #expect(MarkdownBlock.parse("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
    }

    @Test func headingsNeedASpace() {
        #expect(MarkdownBlock.parse("## Plan\n#hashtag") == [.heading(level: 2, text: "Plan"), .paragraph("#hashtag")])
    }

    @Test func listsKeepTheirMarkersAndDepth() {
        let blocks = MarkdownBlock.parse("- **a**: first\n  - nested\n2. second\n   wrapped")
        #expect(blocks == [
            .item(marker: "•", depth: 0, text: "**a**: first"),
            .item(marker: "•", depth: 1, text: "nested"),
            .item(marker: "2.", depth: 0, text: "second\nwrapped"),
        ])
    }

    @Test func codeFencesKeepTheirTextAsIs() {
        let blocks = MarkdownBlock.parse("Run:\n```bash\nnpm test\n- not a list\n```\ndone")
        #expect(blocks == [.paragraph("Run:"), .code(language: "bash", text: "npm test\n- not a list"), .paragraph("done")])
    }

    @Test func anOpenFenceIsCodeToTheEnd() {
        #expect(MarkdownBlock.parse("```\nlet a = 1") == [.code(language: nil, text: "let a = 1")])
    }

    @Test func rulesAndNonLists() {
        #expect(MarkdownBlock.parse("---\n-5 degrees\n2024 was long") == [.rule, .paragraph("-5 degrees\n2024 was long")])
    }
}
