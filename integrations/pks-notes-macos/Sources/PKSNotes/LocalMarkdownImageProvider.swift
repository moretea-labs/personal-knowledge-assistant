import AppKit
import Darwin
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
            Label(AppLanguage.current.text("Attachment unavailable"), systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LocalAttachmentImageMetadata: Equatable, Sendable {
    static let maxByteCount = 30_000_000
    static let supportedExtensions = Set(["png", "jpg", "jpeg", "gif", "tif", "tiff", "webp", "heic"])

    let cacheKey: String
    let byteCount: Int

    static func inspect(_ file: URL) -> LocalAttachmentImageMetadata? {
        guard supportedExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        var info = Darwin.stat()
        guard file.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_size >= 0,
              info.st_size <= off_t(maxByteCount) else { return nil }

        let bytes = Int(info.st_size)
        let modified = "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        let changed = "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return LocalAttachmentImageMetadata(
            cacheKey: "\(file.path)#\(bytes)#\(modified)#\(changed)",
            byteCount: bytes
        )
    }
}

@MainActor
private enum LocalAttachmentImageCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(for key: String) -> NSImage? {
        images.object(forKey: key as NSString)
    }

    static func store(_ image: NSImage, key: String, cost: Int) {
        images.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private struct LocalAttachmentImage: View {
    let file: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 760)
                    .accessibilityLabel(file.lastPathComponent)
            } else {
                Label(AppLanguage.current.text("Loading or missing attachment"), systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: file) {
            image = nil
            let url = file
            let metadata = await Task.detached(priority: .utility) {
                LocalAttachmentImageMetadata.inspect(url)
            }.value
            guard !Task.isCancelled, let metadata else { return }

            if let cached = LocalAttachmentImageCache.image(for: metadata.cacheKey) {
                image = cached
                return
            }

            let loaded: Data? = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard !Task.isCancelled,
                  let loaded,
                  loaded.count == metadata.byteCount,
                  let decoded = NSImage(data: loaded) else { return }

            LocalAttachmentImageCache.store(
                decoded,
                key: metadata.cacheKey,
                cost: loaded.count
            )
            image = decoded
        }
    }
}
