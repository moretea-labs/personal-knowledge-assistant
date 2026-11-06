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
        // A single giant Markdown view lays out the entire document on the main thread.
        // Large notes without shared reference definitions can be split at headings:
        // LazyVStack then constructs only the nearby section views. Keep whole-document
        // parsing for reference links and footnotes (e.g. [ref]: or [^note]:) because
        // their definitions may be used in another section.
        let lazySections = text.utf8.count >= 24_000 && !text.contains("]:")
        let parts = match != nil || lazySections
            ? MarkdownSection.sections(in: text)
            : [MarkdownSection(id: 0, heading: nil, markdown: text)]
        return parts.map { ParsedMarkdownSection(source: $0, content: MarkdownContent($0.markdown)) }
    }
}

/// One transient, parsed snapshot belongs to the window, surviving Edit / Split / Read
/// transitions. Neither parsed blocks nor theme preferences are Markdown content authorities.
struct MarkdownPreviewSnapshot {
    let identity: String
    let source: String
    let matchID: String?
    let sections: [ParsedMarkdownSection]

    func matches(identity: String, source: String, matchID: String?) -> Bool {
        self.identity == identity && self.source == source && self.matchID == matchID
    }
}

/// Native preview uses a window-owned parsed snapshot, independent of view lifetime.
struct MarkdownPreviewPane: View {
    @EnvironmentObject private var model: NotesModel
    let source: String
    let live: Bool
    let identity: String
    let theme: NotesTheme
    let fontAdjustment: Double
    let lineAdjustment: Double
    let widthAdjustment: Double
    @Binding var cache: MarkdownPreviewSnapshot?

    private struct RenderKey: Hashable {
        let identity: String
        let source: String
        let matchID: String?
        let live: Bool
    }

    @State private var renderedRevision = 0

    private var rendered: [ParsedMarkdownSection] {
        guard let cache,
              cache.matches(identity: identity, source: source, matchID: model.activeMatch?.id)
        else { return [] }
        return cache.sections
    }

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
                                .markdownTheme(.pksReading(theme, fontAdjustment: fontAdjustment,
                                                           lineAdjustment: lineAdjustment))
                                .font(.system(size: theme.typography.bodySize + fontAdjustment,
                                              design: theme.typography.design))
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
                    .frame(maxWidth: theme.typography.pageWidth + widthAdjustment, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 36)
                }
            }
            .onAppear { jumpToMatch(scroll) }
            .onChange(of: renderedRevision) { _, _ in
                jumpToMatch(scroll)
            }
            .onChange(of: model.matchJumpSequence) { _, _ in
                jumpToMatch(scroll)
            }
        }
        .background(theme.canvas)
        .accessibilityIdentifier("pks-markdown-preview")
        .task(id: RenderKey(identity: identity, source: source,
                            matchID: model.activeMatch?.id, live: live)) {
            let match = model.activeMatch
            let matchID = match?.id
            guard cache?.matches(identity: identity, source: source, matchID: matchID) != true
            else { return }

            // Only debounce edits to the *same* open document. First preview has no artificial delay.
            if live, let old = cache, old.identity == identity, old.source != source {
                do { try await Task.sleep(for: .milliseconds(260)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let input = source
            let documentID = identity
            let parser = Task.detached(priority: .userInitiated) {
                MarkdownPreviewParsing.prepare(input, match: match)
            }
            defer { parser.cancel() }
            let sections = await parser.value
            guard !Task.isCancelled else { return }
            cache = MarkdownPreviewSnapshot(identity: documentID, source: input,
                                            matchID: matchID, sections: sections)
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

private extension Theme {
    /// A theme controls typography and block layout, not merely background color.
    /// Parsed MarkdownContent is unchanged when any appearance setting changes.
    static func pksReading(_ theme: NotesTheme, fontAdjustment: Double, lineAdjustment: Double) -> Theme {
        let type = theme.typography
        let bodySize = type.bodySize + fontAdjustment
        let lineHeight = max(0.08, type.lineSpacing + lineAdjustment)
        return Theme.basic
            .text {
                ForegroundColor(theme.ink)
                FontSize(bodySize)
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(theme.linkColor)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(type.headingWeight)
                        FontSize(.em(type.heading1))
                    }
                    .markdownMargin(top: .rem(type.headingSpacing * 1.05),
                                    bottom: .rem(type.paragraphSpacing * 0.9))
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(type.headingWeight)
                        FontSize(.em(type.heading2))
                    }
                    .markdownMargin(top: .rem(type.headingSpacing),
                                    bottom: .rem(type.paragraphSpacing * 0.6))
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(type.heading3))
                    }
                    .markdownMargin(top: .rem(type.headingSpacing * 0.78),
                                    bottom: .rem(type.paragraphSpacing * 0.52))
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(lineHeight))
                    .markdownMargin(top: .zero, bottom: .em(type.paragraphSpacing))
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: type.quoteInset) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.ink.opacity(theme == .midnight ? 0.42 : 0.22))
                        .frame(width: theme == .warm ? 2 : 3)
                    if theme == .warm {
                        configuration.label
                            .italic()
                            .foregroundStyle(theme.ink.opacity(0.82))
                    } else {
                        configuration.label
                            .foregroundStyle(theme.ink.opacity(0.78))
                    }
                }
                .markdownMargin(top: .rem(0.5), bottom: .rem(type.paragraphSpacing))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(theme == .midnight ? 0.98 : 0.88))
                BackgroundColor(theme.codeBackground)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.24))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(theme == .midnight ? 0.94 : 0.85))
                        }
                        .padding(type.codePadding)
                }
                .background(theme.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: type.codeCorner))
                .markdownMargin(top: .rem(0.5), bottom: .rem(type.paragraphSpacing))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(type.listSpacing))
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: theme.ink.opacity(0.14)))
                    .markdownTableBackgroundStyle(.alternatingRows(theme.canvas, theme.codeBackground))
                    .markdownMargin(top: .rem(0.4), bottom: .rem(type.paragraphSpacing))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .relativePadding(.horizontal, length: .em(0.68))
                    .relativePadding(.vertical, length: .em(0.4))
            }
    }
}
