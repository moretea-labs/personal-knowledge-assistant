import Foundation
import SwiftUI
import MarkdownUI

/// Parsed once per committed preview revision, never once per SwiftUI body evaluation.
struct ParsedMarkdownSection: Identifiable {
    let source: MarkdownSection
    let content: MarkdownContent
    var id: Int { source.id }
}

enum MarkdownPreviewParsing {
    static func prepare(_ text: String, match: SearchHit?) -> [ParsedMarkdownSection] {
        // Preserve whole-document references/footnotes unless a search match needs section navigation.
        let parts = match == nil
            ? [MarkdownSection(id: 0, heading: nil, markdown: text)]
            : MarkdownSection.sections(in: text)
        return parts.map { ParsedMarkdownSection(source: $0, content: MarkdownContent($0.markdown)) }
    }
}

/// View-local parsed snapshot. The NotesModel is still the sole authority for Markdown text.
struct MarkdownPreviewPane: View {
    @EnvironmentObject private var model: NotesModel
    let source: String
    let live: Bool

    private struct DocumentKey: Hashable {
        let source: String
        let matchID: String?
    }

    private struct RenderKey: Hashable {
        let document: DocumentKey
        let live: Bool
    }

    @State private var rendered: [ParsedMarkdownSection] = []
    @State private var renderedDocument: DocumentKey?
    @State private var renderedRevision = 0

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if rendered.isEmpty {
                    ProgressView("Preparing Markdown preview…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(rendered) { part in
                            Markdown(part.content)
                                .markdownTheme(.gitHub)
                                .markdownImageProvider(LocalMarkdownImageProvider(note: model.selected, root: model.root))
                                .environment(\.openURL, OpenURLAction { url in
                                    if url.scheme == nil || url.isFileURL {
                                        if !model.openInternalLink(url) {
                                            model.message = "Link target not available in this workspace."
                                        }
                                        return .handled
                                    }
                                    return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                                        ? .systemAction : .discarded
                                })
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .id(part.id)
                        }
                    }
                    .frame(maxWidth: 820, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 26)
                }
            }
            .onChange(of: renderedRevision) { _, _ in
                jumpToMatch(scroll)
            }
            .onChange(of: model.matchJumpSequence) { _, _ in
                jumpToMatch(scroll)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("pks-markdown-preview")
        .task(id: RenderKey(document: DocumentKey(source: source, matchID: model.activeMatch?.id),
                            live: live)) {
            let document = DocumentKey(source: source, matchID: model.activeMatch?.id)
            // Switching Split -> Read reuses already-parsed content when it is up to date.
            guard renderedDocument != document else { return }
            // Split coalesces even initial rapid typing; Read flushes to the latest text.
            if live {
                do { try await Task.sleep(for: .milliseconds(320)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let match = model.activeMatch
            let parser = Task.detached(priority: .userInitiated) {
                MarkdownPreviewParsing.prepare(document.source, match: match)
            }
            defer { parser.cancel() }
            let result = await parser.value
            guard !Task.isCancelled else { return }
            rendered = result
            renderedDocument = document
            renderedRevision &+= 1
        }
    }

    private func jumpToMatch(_ scroll: ScrollViewProxy) {
        guard let hit = model.activeMatch,
              let target = MarkdownSection.targetIndex(
                  in: rendered.map(\.source), headingPath: hit.headingPath,
                  snippet: hit.snippet, query: model.matchedQuery
              ) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            scroll.scrollTo(target, anchor: .top)
        }
    }
}
