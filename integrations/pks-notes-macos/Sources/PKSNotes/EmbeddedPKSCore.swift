import Foundation

struct EmbeddedPKSDocument: Sendable {
    let sourceId: String
    let sourceType: String
    let sourceName: String
    let rootURI: String
    let uri: String
    let title: String
    let text: String?
    let createdAt: String?
    let modifiedAt: String?
    let documentType: String
    let tags: [String]
    let indexStatus: String?

    init(
        sourceId: String,
        sourceType: String = "local",
        sourceName: String,
        rootURI: String,
        uri: String,
        title: String,
        text: String?,
        createdAt: String? = nil,
        modifiedAt: String? = nil,
        documentType: String = "generic",
        tags: [String] = [],
        indexStatus: String? = nil
    ) {
        self.sourceId = sourceId
        self.sourceType = sourceType
        self.sourceName = sourceName
        self.rootURI = rootURI
        self.uri = uri
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.documentType = documentType
        self.tags = tags
        self.indexStatus = indexStatus
    }
}

enum EmbeddedPKSCoreError: Error {
    case unavailable
    case openFailed
    case invalidRequest
    case operationFailed
    case unsupportedContract
}

#if canImport(PKSCore)
import PKSCore

actor EmbeddedPKSCore {
    static let isAvailable = true

    private struct SearchEnvelope: Decodable {
        let contractVersion: Int
        let results: [SearchHit]
    }

    private struct SearchRequest: Encodable {
        let contractVersion = 1
        let query: String
        let mode: String
        let source: String?
        let limit: Int
        let excludeUri: String?
    }

    private struct IndexRequest: Encodable {
        let contractVersion = 1
        let sourceId: String
        let sourceType: String
        let sourceName: String
        let rootUri: String
        let uri: String
        let title: String
        let text: String?
        let createdAt: String?
        let modifiedAt: String?
        let documentType: String
        let tags: [String]
        let indexStatus: String?
    }

    private struct IndexResponse: Decodable {
        let contractVersion: Int
        let documentId: String
        let changed: Bool
        let indexStatus: String
    }

    private struct FinalizeRequest: Encodable {
        let contractVersion = 1
        let sourceId: String
        let seenUris: [String]
    }

    private struct FinalizeResponse: Decodable {
        let contractVersion: Int
        let sourceId: String
        let deleted: Int
    }

    private let handle: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL) throws {
        guard let opened = databaseURL.path.withCString({ pks_open_embedded($0) }) else {
            throw EmbeddedPKSCoreError.openFailed
        }
        handle = opened
    }

    deinit {
        pks_close(handle)
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw EmbeddedPKSCoreError.openFailed
        }
        return applicationSupport
            .appendingPathComponent("Leafspan", isDirectory: true)
            .appendingPathComponent("PKS", isDirectory: true)
            .appendingPathComponent("knowledge.db", isDirectory: false)
    }

    func search(
        _ query: String,
        mode: String = "auto",
        source: String? = nil,
        limit: Int = 40,
        excludeURI: String? = nil
    ) throws -> [SearchHit] {
        let request = SearchRequest(
            query: query,
            mode: mode,
            source: source,
            limit: limit,
            excludeUri: excludeURI
        )
        let data = try encoder.encode(request)
        let response = try call(data, using: pks_search_json)
        let envelope = try decoder.decode(SearchEnvelope.self, from: response)
        guard envelope.contractVersion == 1 else {
            throw EmbeddedPKSCoreError.unsupportedContract
        }
        return envelope.results
    }

    @discardableResult
    func index(_ document: EmbeddedPKSDocument) throws -> Bool {
        let request = IndexRequest(
            sourceId: document.sourceId,
            sourceType: document.sourceType,
            sourceName: document.sourceName,
            rootUri: document.rootURI,
            uri: document.uri,
            title: document.title,
            text: document.text,
            createdAt: document.createdAt,
            modifiedAt: document.modifiedAt,
            documentType: document.documentType,
            tags: document.tags,
            indexStatus: document.indexStatus
        )
        let response = try call(encoder.encode(request), using: pks_index_document_json)
        let result = try decoder.decode(IndexResponse.self, from: response)
        guard result.contractVersion == 1 else {
            throw EmbeddedPKSCoreError.unsupportedContract
        }
        return result.changed
    }

    @discardableResult
    func finalize(sourceId: String, seenURIs: [String]) throws -> Int {
        let request = FinalizeRequest(sourceId: sourceId, seenUris: seenURIs)
        let response = try call(encoder.encode(request), using: pks_finalize_source_json)
        let result = try decoder.decode(FinalizeResponse.self, from: response)
        guard result.contractVersion == 1, result.sourceId == sourceId else {
            throw EmbeddedPKSCoreError.unsupportedContract
        }
        return result.deleted
    }

    private func call(
        _ request: Data,
        using function: (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> Data {
        guard let json = String(data: request, encoding: .utf8), !json.contains("\0") else {
            throw EmbeddedPKSCoreError.invalidRequest
        }
        guard let raw = json.withCString({ function(handle, $0) }) else {
            throw EmbeddedPKSCoreError.operationFailed
        }
        defer { pks_string_free(raw) }
        return Data(String(cString: raw).utf8)
    }
}
#else
actor EmbeddedPKSCore {
    static let isAvailable = false

    init(databaseURL: URL) throws {
        throw EmbeddedPKSCoreError.unavailable
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        throw EmbeddedPKSCoreError.unavailable
    }

    func search(
        _ query: String,
        mode: String = "auto",
        source: String? = nil,
        limit: Int = 40,
        excludeURI: String? = nil
    ) throws -> [SearchHit] {
        throw EmbeddedPKSCoreError.unavailable
    }

    func index(_ document: EmbeddedPKSDocument) throws -> Bool {
        throw EmbeddedPKSCoreError.unavailable
    }

    func finalize(sourceId: String, seenURIs: [String]) throws -> Int {
        throw EmbeddedPKSCoreError.unavailable
    }
}
#endif
