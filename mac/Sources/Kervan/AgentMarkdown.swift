import AppKit
import KervanKit
import SwiftUI

/// An agent's answer laid out as it was written: headings, lists with hanging indents, and code blocks
/// with a copy button, instead of one run of text with the markup showing.
struct AgentMarkdown: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, first: index == 0)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            body(text)

        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 16.5 : 14.5, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, first ? 0 : 6)
                .accessibilityAddTraits(.isHeader)

        case .item(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: 14, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                body(text)
            }
            .padding(.leading, CGFloat(depth) * 18)
            // List items sit closer together than paragraphs do.
            .padding(.top, -4)

        case .code(let language, let text):
            CodeBlock(language: language, text: text)

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func body(_ text: String) -> some View {
        Text(Self.inline(text))
            .font(.system(size: 14, design: .rounded))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? L("Code", "Kod"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? Color.kervanOasis : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(.callout.monospaced())
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            // The app's rounded design is set on the window; code is the exception.
            .fontDesign(.monospaced)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}
