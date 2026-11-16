import Foundation
import Darwin
import NaturalLanguage

/// An on-demand read of the existing workspace directory projection. No database,
/// background hydration, or second document authority is introduced.
enum WorkspaceSearch {
    struct Coverage: Sendable {
        var readFiles = 0
        var skippedFiles = 0
        var limited = false
    }

    struct Result: Sendable {
        var hits: [SearchHit] = []
        var coverage = Coverage()
    }

    struct Limits: Sendable {
        var files = 2_000
        var bytesPerFile = 512 * 1_024
        var totalBytes = 32 * 1_024 * 1_024
        var results = 50
    }

    static func search(
        entries: [NoteTreePresentation.QuickOpenEntry], root: URL, query: String,
        draftURL: URL? = nil, draft: String? = nil,
        searchBodies: Bool = true, limits: Limits = Limits()
    ) -> Result {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty, limits.results > 0 else { return Result() }
        let rootPath = root.standardizedFileURL.path
        let canonicalRootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPathPrefixLength = rootPath.count + 1
        let foldedRootPath = fold(rootPath)
        let foldedFolderPrefix = foldedRootPath.hasSuffix("/") ? foldedRootPath : foldedRootPath + "/"
        let foldedQuery = fold(query)
        let foldedTerms = terms.map(fold)
        let fuzzyQueryTerms = terms.map(fuzzyQueryCharacters)
        // Normalize the query once. NaturalLanguage tokenization and pinyin
        // transforms are substantially more expensive than literal path checks.
        let queryTransliteration = transliterationKey(query)
        let canMatchPinyin = queryTransliteration.value.count >= 4
        let rootTransliterationLength = canMatchPinyin
            ? transliterationKey(rootPath).value.count
            : 0
        var result = Result()
        var ranked: [(hit: SearchHit, rank: Int, order: Int)] = []
        var remainingBytes = max(0, limits.totalBytes)
        var attemptedFiles = 0

        for (order, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            let item = entry.item
            let itemPath = item.url.standardizedFileURL.path
            guard WorkspaceFiles.fileStampIfContained(
                item.url, inCanonicalRootPath: canonicalRootPath
            ) != nil else { continue }
            let path = String(itemPath.dropFirst(rootPathPrefixLength))
            // Quick Open already owns normalized folder/name keys for this exact
            // workspace snapshot. Reuse them rather than case/diacritic-folding
            // every path and filename again on each search keystroke.
            let foldedPath: String
            if entry.foldedFolder == foldedRootPath {
                foldedPath = entry.foldedName
            } else if entry.foldedFolder.hasPrefix(foldedFolderPrefix) {
                let relativeFolder = entry.foldedFolder.dropFirst(foldedFolderPrefix.count)
                foldedPath = relativeFolder.isEmpty
                    ? entry.foldedName
                    : String(relativeFolder) + "/" + entry.foldedName
            } else {
                foldedPath = fold(path)
            }
            let rawPathTerms = foldedTerms.allSatisfy { foldedPath.contains($0) }
            var pathFuzzyTokens: [[Character]]?
            let fuzzyPathTerms = terms.indices.allSatisfy { index in
                guard !foldedPath.contains(foldedTerms[index]) else { return true }
                guard let query = fuzzyQueryTerms[index] else { return false }
                if pathFuzzyTokens == nil {
                    pathFuzzyTokens = fuzzyTokens(in: path)
                }
                return fuzzyContains(pathFuzzyTokens ?? [], query: query)
            }
            let pathPinyinMatch = canMatchPinyin && !rawPathTerms
                && matchesTransliteration(
                    entry.pathTransliterationKey,
                    query: queryTransliteration,
                    minimumTokenStart: rootTransliterationLength
                )
            let nameMatch = fuzzyPathTerms || pathPinyinMatch
            var content: String?
            if searchBodies, !nameMatch, item.isMarkdown {
                if item.url == draftURL, let draft {
                    content = draft
                } else if WorkspaceFiles.isDataless(item.url) {
                    result.coverage.skippedFiles += 1
                } else if attemptedFiles >= limits.files || remainingBytes <= 0 {
                    result.coverage.limited = true
                    result.coverage.skippedFiles += 1
                } else {
                    attemptedFiles += 1
                    let budget = min(max(0, limits.bytesPerFile), remainingBytes)
                    if let read = readLocalMarkdown(item.url, maxBytes: budget) {
                        remainingBytes -= read.bytes
                        result.coverage.readFiles += 1
                        content = read.text
                    } else {
                        result.coverage.skippedFiles += 1
                    }
                }
            }
            var contentTransliterationMatch: Range<String.Index>?
            let contentMatch = content.map { body in
                let literalMatch = foldedTerms.indices.allSatisfy { index in
                    foldedPath.contains(foldedTerms[index]) || contains(body, terms[index])
                }
                guard !literalMatch else { return true }
                contentTransliterationMatch = transliteratedMatchRange(
                    in: body, query: queryTransliteration
                )
                return contentTransliterationMatch != nil
            } ?? false
            guard nameMatch || contentMatch else { continue }
            let exactNameMatch = entry.foldedName.contains(foldedQuery)
            let rawNameTerms = foldedTerms.allSatisfy { entry.foldedName.contains($0) }
            var nameFuzzyTokens: [[Character]]?
            let fuzzyNameTerms = terms.indices.allSatisfy { index in
                guard !entry.foldedName.contains(foldedTerms[index]) else { return true }
                guard let query = fuzzyQueryTerms[index] else { return false }
                if nameFuzzyTokens == nil {
                    nameFuzzyTokens = fuzzyTokens(in: item.name)
                }
                return fuzzyContains(nameFuzzyTokens ?? [], query: query)
            }
            let namePinyinMatch = canMatchPinyin
                && !exactNameMatch && !rawNameTerms && !rawPathTerms
                && matchesTransliteration(entry.nameTransliterationKey, query: queryTransliteration)
            let rank: Int
            if exactNameMatch { rank = 0 }
            else if rawNameTerms { rank = 1 }
            else if rawPathTerms { rank = 2 }
            else if namePinyinMatch { rank = 3 }
            else if pathPinyinMatch { rank = 4 }
            else if fuzzyNameTerms { rank = 5 }
            else if fuzzyPathTerms { rank = 6 }
            else { rank = 7 }
            let hit = SearchHit(
                documentId: "workspace:" + item.url.path, chunkId: nil,
                title: item.name, uri: item.url.path, sourceType: "local",
                snippet: content.map { body in
                    if let contentTransliterationMatch {
                        return excerpt(body, matching: contentTransliterationMatch)
                    }
                    return excerpt(body, terms: terms)
                }, score: nil, headingPath: nil
            )
            ranked.append((hit, rank, order))
        }
        ranked.sort { $0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank }
        result.coverage.limited = result.coverage.limited || ranked.count > limits.results
        result.hits = ranked.prefix(limits.results).map(\.hit)
        return result
    }

    static func merging(local: [SearchHit], remote: [SearchHit]) -> [SearchHit] {
        let localPaths = Set(local.map(\.uri))
        let remoteByPath = Dictionary(grouping: remote.compactMap { hit -> SearchHit? in
            guard let path = hit.localFileURL?.path, localPaths.contains(path) else { return nil }
            return hit
        }, by: { $0.localFileURL!.path })
        return local.flatMap { remoteByPath[$0.uri] ?? [$0] }
            + remote.filter { hit in
                guard let path = hit.localFileURL?.path else { return true }
                return !localPaths.contains(path)
            }
    }

    private static func transliterationToken(_ token: String) -> String? {
        NoteTreePresentation.transliterationToken(token)
    }

    /// Returns the source range for a word-start pinyin match in the original text.
    private static func transliteratedMatchRange(
        in text: String,
        query: NoteTreePresentation.TransliterationKey
    ) -> Range<String.Index>? {
        let needle = Array(query.value)
        guard needle.count >= 4 else { return nil }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var key: [Character] = []
        var tokenStarts: [Int] = []
        var tokenEnds: [Int] = []
        var tokenRanges: [Range<String.Index>] = []

        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            let token = String(text[range])
            guard let normalized = transliterationToken(token) else { continue }
            tokenStarts.append(key.count)
            key.append(contentsOf: normalized)
            tokenEnds.append(key.count)
            tokenRanges.append(range)
        }

        for index in tokenStarts.indices {
            let start = tokenStarts[index]
            let targetEnd = start + needle.count
            guard targetEnd <= key.count,
                  key[start..<targetEnd].elementsEqual(needle) else { continue }
            guard let endIndex = tokenEnds.firstIndex(where: { $0 >= targetEnd }) else {
                return nil
            }
            return tokenRanges[index].lowerBound..<tokenRanges[endIndex].upperBound
        }
        return nil
    }

    /// Match transliteration only at word starts. This prevents a query such as
    /// "shi jie" from matching the middle of the different words "历史结构".
    static func transliteratedContains(_ text: String, _ query: String) -> Bool {
        let queryKey = transliterationKey(query)
        guard queryKey.value.count >= 4 else { return false }
        return matchesTransliteration(transliterationKey(text), query: queryKey)
    }

    private static func matchesTransliteration(
        _ candidate: NoteTreePresentation.TransliterationKey,
        query: NoteTreePresentation.TransliterationKey,
        minimumTokenStart: Int = 0
    ) -> Bool {
        guard query.value.count >= 4 else { return false }
        return candidate.tokenStarts.contains { offset in
            guard offset >= minimumTokenStart else { return false }
            let start = candidate.value.index(candidate.value.startIndex, offsetBy: offset)
            return candidate.value[start...].hasPrefix(query.value)
        }
    }

    /// Conservative filename typo tolerance: one edit in a token of at least
    /// five characters. Exact substring matching remains the path for short terms.
    static func fuzzyContains(_ text: String, _ query: String) -> Bool {
        guard let needle = fuzzyQueryCharacters(query) else { return false }
        let tokens = text.split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { token in
            let candidate = Array(String(token).folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            ))
            return fuzzyContains(candidate, query: needle)
        }
    }

    private static func fuzzyQueryCharacters(_ query: String) -> [Character]? {
        let characters = Array(query.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ))
        return characters.count >= 5 ? characters : nil
    }

    private static func fuzzyTokens(in text: String) -> [[Character]] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { token in
            Array(String(token).folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            ))
        }
    }

    private static func fuzzyContains(_ tokens: [[Character]], query: [Character]) -> Bool {
        tokens.contains { fuzzyContains($0, query: query) }
    }

    private static func fuzzyContains(_ candidate: [Character], query: [Character]) -> Bool {
        guard abs(candidate.count - query.count) <= 1 else { return false }
        var left = 0
        var right = 0
        var edits = 0
        while left < candidate.count, right < query.count {
            if candidate[left] == query[right] {
                left += 1
                right += 1
            } else {
                edits += 1
                if edits > 1 { return false }
                if candidate.count > query.count {
                    left += 1
                } else if candidate.count < query.count {
                    right += 1
                } else {
                    left += 1
                    right += 1
                }
            }
        }
        if left < candidate.count || right < query.count { edits += 1 }
        return edits <= 1
    }

    private static func transliterationKey(_ value: String) -> NoteTreePresentation.TransliterationKey {
        NoteTreePresentation.transliterationKey(value)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func excerpt(
        _ text: String,
        matching range: Range<String.Index>
    ) -> String {
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 180, limitedBy: text.endIndex)
            ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end])
            + (end < text.endIndex ? "…" : "")
    }

    private static func excerpt(_ text: String, terms: [String]) -> String {
        let match = terms.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
        }.min() ?? text.startIndex
        let start = text.index(match, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end])
            + (end < text.endIndex ? "…" : "")
    }

    private static func readLocalMarkdown(_ url: URL, maxBytes: Int) -> (text: String, bytes: Int)? {
        guard maxBytes > 0 else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_flags & UInt32(SF_DATALESS) == 0,
              info.st_size <= maxBytes,
              let data = try? file.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, data.count)
    }
}
