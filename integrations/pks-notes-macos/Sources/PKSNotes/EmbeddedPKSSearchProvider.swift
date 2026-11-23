import Foundation

protocol GlobalLibrarySearchProviding: Sendable {
    func search(
        _ query: String,
        mode: String,
        limit: Int
    ) async throws -> [SearchHit]
}

protocol LibrarySearchProviding: GlobalLibrarySearchProviding {
    func search(
        _ query: String,
        mode: String,
        limit: Int,
        excludeURI: String?
    ) async throws -> [SearchHit]
}

extension LibrarySearchProviding {
    func search(
        _ query: String,
        mode: String,
        limit: Int
    ) async throws -> [SearchHit] {
        try await search(query, mode: mode, limit: limit, excludeURI: nil)
    }
}

actor EmbeddedPKSSearchProvider: LibrarySearchProviding {
    private var core: EmbeddedPKSCore?
    private let databaseURL: URL?

    init(databaseURL: URL? = nil, core: EmbeddedPKSCore? = nil) {
        self.databaseURL = databaseURL
        self.core = core
    }

    func search(
        _ query: String,
        mode: String = "auto",
        limit: Int = 40,
        excludeURI: String? = nil
    ) async throws -> [SearchHit] {
        try Task.checkCancellation()
        let core = try loadedCore()
        let results = try await core.search(
            query,
            mode: mode,
            limit: limit,
            excludeURI: excludeURI
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
