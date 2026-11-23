import Foundation
import Combine

@MainActor
final class EmbeddedPKSLibrarySettingsModel: ObservableObject {
    @Published private(set) var sources: [EmbeddedPKSLibrarySource] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var workingSourceID: String?
    @Published private(set) var isRefreshingAll = false

    private let registry: EmbeddedPKSLibrarySourceRegistry
    private var core: EmbeddedPKSCore?
    private var indexer: EmbeddedPKSLibraryIndexer?

    init(
        registry: EmbeddedPKSLibrarySourceRegistry = EmbeddedPKSLibrarySourceRegistry(),
        core: EmbeddedPKSCore? = nil
    ) {
        self.registry = registry
        self.core = core
        if let core {
            self.indexer = EmbeddedPKSLibraryIndexer(core: core)
        }
    }

    func reload() async {
        sources = await registry.sources()
    }

    func add(folder: URL, excludingWorkspace workspace: URL?) async {
        statusMessage = nil
        do {
            let source = try await registry.add(folder: folder, excludingWorkspace: workspace)
            sources = await registry.sources()
            _ = try await refresh(source)
        } catch EmbeddedPKSLibraryError.overlapsWorkspace {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "此文件夹与当前工作区重叠，无需重复建立索引"
                : "This folder overlaps the active workspace and does not need a duplicate index."
        } catch {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "无法添加资料库文件夹"
                : "Unable to add library folder."
        }
    }

    @discardableResult
    func refresh(_ source: EmbeddedPKSLibrarySource) async throws -> EmbeddedPKSLibraryIndexSummary {
        workingSourceID = source.id
        defer { workingSourceID = nil }
        let indexer = try ensureIndexer()
        let summary = try await indexer.refresh(source)
        statusMessage = Self.summaryMessage(summary)
        return summary
    }

    func refreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        statusMessage = nil
        defer { isRefreshingAll = false }

        let current = await registry.sources()
        var totalScanned = 0
        var totalContent = 0
        var totalMetadata = 0
        var totalDeleted = 0
        do {
            for source in current {
                try Task.checkCancellation()
                let summary = try await refresh(source)
                totalScanned += summary.scannedFiles
                totalContent += summary.indexedContentFiles
                totalMetadata += summary.metadataOnlyFiles
                totalDeleted += summary.deletedDocuments
            }
            statusMessage = Self.summaryMessage(EmbeddedPKSLibraryIndexSummary(
                scannedFiles: totalScanned,
                indexedContentFiles: totalContent,
                metadataOnlyFiles: totalMetadata,
                deletedDocuments: totalDeleted
            ))
        } catch is CancellationError {
            return
        } catch {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "部分资料库索引刷新失败"
                : "Some library indexes could not be refreshed."
        }
    }

    func remove(_ source: EmbeddedPKSLibrarySource) async {
        statusMessage = nil
        do {
            let core = try ensureCore()
            _ = try await core.finalize(sourceId: source.id, seenURIs: [])
            try await registry.remove(id: source.id)
            sources = await registry.sources()
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "已移除资料库并清理索引"
                : "Library folder removed and its index cleared."
        } catch {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "无法移除资料库文件夹"
                : "Unable to remove library folder."
        }
    }

    private func ensureCore() throws -> EmbeddedPKSCore {
        if let core { return core }
        let url = try EmbeddedPKSCore.defaultDatabaseURL()
        let opened = try EmbeddedPKSCore(databaseURL: url)
        core = opened
        indexer = EmbeddedPKSLibraryIndexer(core: opened)
        return opened
    }

    private func ensureIndexer() throws -> EmbeddedPKSLibraryIndexer {
        if let indexer { return indexer }
        _ = try ensureCore()
        guard let indexer else { throw EmbeddedPKSCoreError.unavailable }
        return indexer
    }

    private static func summaryMessage(_ summary: EmbeddedPKSLibraryIndexSummary) -> String {
        if AppLanguage.current.resolved == .simplifiedChinese {
            return "已扫描 \(summary.scannedFiles) 个文件 · 正文索引 \(summary.indexedContentFiles) · 仅元数据 \(summary.metadataOnlyFiles) · 清理 \(summary.deletedDocuments)"
        }
        return "Scanned \(summary.scannedFiles) files · \(summary.indexedContentFiles) content indexed · \(summary.metadataOnlyFiles) metadata only · \(summary.deletedDocuments) removed"
    }
}
