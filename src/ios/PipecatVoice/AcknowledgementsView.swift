import SwiftUI

/// The notices and licences of the components the app bundles, from `THIRD_PARTY_NOTICES.md` in
/// the app bundle: its headings, paragraphs, lists and tables, in a scrolling page.
struct AcknowledgementsView: View {
    @State private var blocks: [NoticeBlock] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading(let level):
                        Text(block.text)
                            .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                            .padding(.top, level <= 2 ? 14 : 6)
                            .accessibilityAddTraits(.isHeader)
                    case .paragraph:
                        Text(block.text).font(.footnote)
                    case .row:
                        Text(block.text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard blocks.isEmpty,
                  let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            blocks = NoticeBlock.parse(text)
        }
    }
}

/// A heading, a paragraph or list item, or a table row of the notices' Markdown.
struct NoticeBlock: Identifiable {
    enum Kind { case heading(Int), paragraph, row }

    let id: Int
    let kind: Kind
    let text: AttributedString

    /// The notices' blocks: lines wrapped in the file are joined, list items and table rows are
    /// kept apart, and a table's header and divider rows are dropped.
    static func parse(_ markdown: String) -> [NoticeBlock] {
        var blocks: [NoticeBlock] = []
        var paragraph: [String] = []
        var inTable = false

        func add(_ kind: Kind, _ source: String) {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
            blocks.append(NoticeBlock(id: blocks.count, kind: kind, text: text))
        }
        func flush() {
            if !paragraph.isEmpty { add(.paragraph, paragraph.joined(separator: " ")) }
            paragraph = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                flush()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The first row is the header; the second divides it from the rows.
                defer { inTable = true }
                guard inTable, !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) else { continue }
                add(.row, cells.filter { $0 != "—" }.joined(separator: " · "))
                continue
            }
            inTable = false
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                add(.heading(level), String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                paragraph = ["•  " + line.dropFirst(2)]
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
