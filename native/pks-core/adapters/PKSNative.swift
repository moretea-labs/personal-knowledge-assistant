import Foundation
import PKSCore

public enum PKSNativeError: Error {
    case openFailed
    case searchFailed
}

public enum PKSNative {
    public static func search(database: URL, request: Data) throws -> Data {
        guard let handle = database.path.withCString({ pks_open($0) }) else {
            throw PKSNativeError.openFailed
        }
        defer { pks_close(handle) }

        guard let json = String(data: request, encoding: .utf8),
              !json.contains("\0"),
              let result = json.withCString({ pks_search_json(handle, $0) }) else {
            throw PKSNativeError.searchFailed
        }
        defer { pks_string_free(result) }
        return Data(String(cString: result).utf8)
    }
}
