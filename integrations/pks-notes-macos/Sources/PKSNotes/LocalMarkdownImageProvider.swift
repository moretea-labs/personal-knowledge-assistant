import AppKit
import Foundation
import MarkdownUI
import SwiftUI

/// Reads only attachments within the active Markdown workspace.
struct LocalMarkdownImageProvider: ImageProvider {
    let note: URL?
    let root: URL?

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, let note, let root,
           let localURL = WorkspaceFiles.resolve(url, from: note, in: root) {
            LocalAttachmentImage(file: localURL)
        } else if let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            Label("Attachment unavailable", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LocalAttachmentImage: View {
    let file: URL
    @State private var bytes: Data?

    var body: some View {
        Group {
            if let bytes, let image = NSImage(data: bytes) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 760)
                    .accessibilityLabel(file.lastPathComponent)
            } else {
                Label("Loading or missing attachment", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: file) {
            bytes = nil
            let url = file
            let loaded: Data? = await Task.detached(priority: .utility) {
                guard ["png", "jpg", "jpeg", "gif", "tif", "tiff", "webp", "heic"]
                    .contains(url.pathExtension.lowercased()),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? Int, size <= 30_000_000 else {
                    return nil
                }
                return try? Data(contentsOf: url)
            }.value
            bytes = loaded
        }
    }
}
