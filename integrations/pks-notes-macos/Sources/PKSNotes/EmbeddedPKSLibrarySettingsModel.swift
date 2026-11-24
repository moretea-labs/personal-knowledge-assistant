import Foundation
import Combine

@MainActor
final class EmbeddedPKSLibrarySettingsModel: ObservableObject {
    @Published private(set) var sources: [EmbeddedPKSLibrarySource] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
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

    @discardableResult
    func add(folder: URL, excludingWorkspace workspace: URL?) async -> Bool {
        statusMessage = nil
        statusIsError = false
        do {
            let source = try await registry.add(folder: folder, excludingWorkspace: workspace)
            sources = await registry.sources()
            do {
                _ = try await refresh(source)
            } catch {
                // Registration succeeded: keep the folder visible and preserve the
                // more specific refresh message (for example, a cloud-only root).
                if statusMessage == nil {
                    statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                        ? "已添加资料库，但索引失败。请点击刷新重试。"
                        : "Library added, but indexing failed. Use Refresh to retry."
                }
                statusIsError = true
            }
            return true
        } catch EmbeddedPKSLibraryError.overlapsWorkspace {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "此文件夹与当前工作区重叠，无需重复建立索引"
                : "This folder overlaps the active workspace and does not need a duplicate index."
        } catch {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "无法添加资料库文件夹"
                : "Unable to add library folder."
        }
        statusIsError = true
        return false
    }

    @discardableResult
    func refresh(_ source: EmbeddedPKSLibrarySource) async throws -> EmbeddedPKSLibraryIndexSummary {
        workingSourceID = source.id
        defer { workingSourceID = nil }
        do {
            let indexer = try ensureIndexer()
            let summary = try await indexer.refresh(source)
            statusMessage = Self.summaryMessage(summary)
            statusIsError = false
            return summary
        } catch EmbeddedPKSLibraryError.datalessPlaceholder {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "资料库文件夹尚未下载。请先在 Finder 中下载，再刷新索引。"
                : "Library folder is not downloaded. Download it in Finder, then refresh."
            statusIsError = true
            throw EmbeddedPKSLibraryError.datalessPlaceholder
        } catch {
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "索引刷新失败，请检查文件夹权限后重试。"
                : "Index refresh failed. Check folder access and try again."
            statusIsError = true
            throw error
        }
    }

    func refreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        statusMessage = nil
        statusIsError = false
        defer { isRefreshingAll = false }

        let current = await registry.sources()
        var totalScanned = 0
        var totalContent = 0
        var totalMetadata = 0
        var totalDeferred = 0
        var totalDeleted = 0
        do {
            for source in current {
                try Task.checkCancellation()
                let summary = try await refresh(source)
                totalScanned += summary.scannedFiles
                totalContent += summary.indexedContentFiles
                totalMetadata += summary.metadataOnlyFiles
                totalDeferred += summary.deferredFiles
                totalDeleted += summary.deletedDocuments
            }
            statusMessage = Self.summaryMessage(EmbeddedPKSLibraryIndexSummary(
                scannedFiles: totalScanned,
                indexedContentFiles: totalContent,
                metadataOnlyFiles: totalMetadata,
                deferredFiles: totalDeferred,
                deletedDocuments: totalDeleted
            ))
        } catch is CancellationError {
            return
        } catch {
            statusIsError = true
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "部分资料库索引刷新失败"
                : "Some library indexes could not be refreshed."
        }
    }

    func remove(_ source: EmbeddedPKSLibrarySource) async {
        statusMessage = nil
        statusIsError = false
        do {
            let core = try ensureCore()
            _ = try await core.finalize(sourceId: source.id, seenURIs: [])
            try await registry.remove(id: source.id)
            sources = await registry.sources()
            statusMessage = AppLanguage.current.resolved == .simplifiedChinese
                ? "已移除资料库并清理索引"
                : "Library folder removed and its index cleared."
        } catch {
            statusIsError = true
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
        let deferred = summary.deferredFiles > 0 ? summary.deferredFiles : nil
        if AppLanguage.current.resolved == .simplifiedChinese {
            let cloud = deferred.map { " · 云端待下载 \($0)" } ?? ""
            return "已扫描 \(summary.scannedFiles) 个文件 · 正文索引 \(summary.indexedContentFiles) · 仅元数据 \(summary.metadataOnlyFiles)\(cloud) · 清理 \(summary.deletedDocuments)"
        }
        let cloud = deferred.map { " · \($0) cloud-only files deferred" } ?? ""
        return "Scanned \(summary.scannedFiles) files · \(summary.indexedContentFiles) content indexed · \(summary.metadataOnlyFiles) metadata only\(cloud) · \(summary.deletedDocuments) removed"
    }
}
