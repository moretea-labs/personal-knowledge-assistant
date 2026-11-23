import Foundation

protocol GlobalLibrarySearchProviding: Sendable {
    func search(
        _ query: String,
        mode: String,
        limit: Int
    ) async throws -> [SearchHit]
}

actor EmbeddedPKSSearchProvider: GlobalLibrarySearchProviding {
    private var core: EmbeddedPKSCore?
    private let databaseURL: URL?

    init(databaseURL: URL? = nil, core: EmbeddedPKSCore? = nil) {
        self.databaseURL = databaseURL
        self.core = core
    }

    func search(
        _ query: String,
        mode: String = "auto",
        limit: Int = 40
    ) async throws -> [SearchHit] {
        try Task.checkCancellation()
        let core = try loadedCore()
        let results = try await core.search(
            query,
            mode: mode,
            limit: limit
        )
        try Task.checkCancellation()
        return results
    }

    private func loadedCore() throws -> EmbeddedPKSCore {
        if let core { return core }
        let url = try databaseURL ?? EmbeddedPKSCore.defaultDatabaseURL()
        let opened = try EmbeddedPKSCore(databaseURL: url)
        core = opened
        return opened
    }
}
