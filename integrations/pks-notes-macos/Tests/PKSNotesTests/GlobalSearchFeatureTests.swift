import Carbon.HIToolbox
import XCTest
@testable import PKSNotes

final class GlobalSearchFeatureTests: XCTestCase {
    @MainActor
    func testGlobalSearchStatusDisclosesIncompleteWorkspaceCoverage() {
        var coverage = WorkspaceSearch.Coverage()
        coverage.limited = true
        coverage.skippedFiles = 3

        XCTAssertEqual(
            GlobalSearchResults.makeStatusMessage(
                coverage: coverage,
                libraryUnavailable: true,
                language: .simplifiedChinese
            ),
            "资料库搜索当前不可用 · 工作区搜索结果不完整 · 3 篇笔记正文未参与搜索"
        )
        XCTAssertNil(
            GlobalSearchResults.makeStatusMessage(
                coverage: WorkspaceSearch.Coverage(),
                libraryUnavailable: false,
                language: .english
            )
        )
    }

    func testApplicationRankingIsExactPrefixThenSubstring() {
        let apps = [
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), title: "Visual Studio Code"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Code.app"), title: "Code"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Xcode.app"), title: "Xcode"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Numbers.app"), title: "Numbers")
        ]
        let results = GlobalApplicationCatalog.matches(apps, query: "code")
        XCTAssertEqual(results.map(\.title), ["Code", "Xcode", "Visual Studio Code"])
    }

    func testGlobalSearchQuickLookIsLimitedToFileResults() {
        let file = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Notes/Study.pdf"),
            title: "Study", isFolder: false
        )
        let folder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Notes/Archive", isDirectory: true),
            title: "Archive", isFolder: true
        )
        let app = GlobalSearchItem.application(
            URL(fileURLWithPath: "/Applications/Notes.app"), title: "Notes"
        )

        XCTAssertTrue(file.supportsQuickLook)
        XCTAssertFalse(folder.supportsQuickLook)
        XCTAssertFalse(app.supportsQuickLook)
    }

    func testGlobalSearchCopyNameUsesExactFilesystemLeafName() {
        let file = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/论文/研究 #1?.md"),
            title: "Different display title", isFolder: false
        )
        let folder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Archive", isDirectory: true),
            title: "Archive", isFolder: true
        )

        XCTAssertEqual(file.fileName, "研究 #1?.md")
        XCTAssertEqual(folder.fileName, "Archive")
    }

    func testSpotlightWorkspaceMarkdownAndPDFUseLeafspanOpenPath() {
        let root = URL(fileURLWithPath: "/Users/test/Notes", isDirectory: true)
        let note = GlobalSearchItem.spotlight(
            root.appendingPathComponent("Research.md"), title: "Research.md", isFolder: false
        )
        let pdf = GlobalSearchItem.spotlight(
            root.appendingPathComponent("Source.pdf"), title: "Source.pdf", isFolder: false
        )
        let folder = GlobalSearchItem.spotlight(
            root.appendingPathComponent("Archive", isDirectory: true), title: "Archive", isFolder: true
        )
        let outside = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Desktop/Other.md"), title: "Other.md", isFolder: false
        )
        let other = GlobalSearchItem.spotlight(
            root.appendingPathComponent("Image.png"), title: "Image.png", isFolder: false
        )

        XCTAssertTrue(GlobalSearchItem.isLeafspanWorkspaceDocument(note, in: root))
        XCTAssertTrue(GlobalSearchItem.isLeafspanWorkspaceDocument(pdf, in: root))
        XCTAssertFalse(GlobalSearchItem.isLeafspanWorkspaceDocument(folder, in: root))
        XCTAssertFalse(GlobalSearchItem.isLeafspanWorkspaceDocument(outside, in: root))
        XCTAssertFalse(GlobalSearchItem.isLeafspanWorkspaceDocument(other, in: root))
        XCTAssertFalse(GlobalSearchItem.isLeafspanWorkspaceDocument(note, in: nil))
    }

    func testGlobalSearchAllowsSingleHanCharacterDocumentQueries() {
        XCTAssertTrue(GlobalSearchRanker.shouldStartDocumentSearch(for: "肾"))
        XCTAssertTrue(GlobalSearchRanker.shouldStartDocumentSearch(for: "AB"))
        XCTAssertFalse(GlobalSearchRanker.shouldStartDocumentSearch(for: "a"))
        XCTAssertFalse(GlobalSearchRanker.shouldStartDocumentSearch(for: " "))
    }

    func testSingleHanSpotlightSearchUsesFilenameAndPathOnly() {
        let predicate = GlobalSpotlightLookup.searchPredicate(for: "肾")
        XCTAssertTrue(predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "肾宝宝.md",
            NSMetadataItemPathKey: "/Users/test/肾宝宝.md"
        ]))
        XCTAssertTrue(predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "Study.md",
            NSMetadataItemPathKey: "/Users/test/肾宝宝/Study.md"
        ]))
        XCTAssertFalse(predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "Study.md",
            NSMetadataItemPathKey: "/Users/test/Study.md",
            "kMDItemTextContent": "肾宝宝"
        ]))
    }

    func testSpotlightSnippetUsesCJKContextAndNormalizesWhitespace() {
        let snippet = GlobalSpotlightLookup.contentSnippet(
            "第一段\n\n肾脏计划\t继续", matching: "肾脏"
        )
        XCTAssertEqual(snippet, "第一段 肾脏计划 继续")
    }

    func testSpotlightSnippetMatchesCaseAndDiacriticsWithinBoundedContext() {
        let content = String(repeating: "前", count: 80)
            + " Café " + String(repeating: "后", count: 80)
        let snippet = GlobalSpotlightLookup.contentSnippet(
            content, matching: "cafe", limit: 40
        )
        XCTAssertTrue(snippet?.contains("Café") == true)
        XCTAssertTrue(snippet?.hasPrefix("…") == true)
        XCTAssertTrue(snippet?.hasSuffix("…") == true)
        XCTAssertLessThanOrEqual(snippet?.count ?? 0, 42)
    }

    func testSpotlightSnippetUsesCJKExcerptForPinyinBodyMatch() {
        let content = String(repeating: "前言内容。", count: 80) + "今天练习夜的钢琴曲五。"
        let snippet = GlobalSpotlightLookup.contentSnippet(content, matching: "ye de gang qin qu")
        XCTAssertTrue(snippet?.contains("夜的钢琴曲五") == true)
        XCTAssertNil(GlobalSpotlightLookup.contentSnippet("今天研究历史结构。", matching: "shi jie"))
    }

    func testSpotlightSnippetReturnsNilWhenContentDoesNotContainQuery() {
        XCTAssertNil(GlobalSpotlightLookup.contentSnippet("Unrelated source text", matching: "missing"))
        XCTAssertNil(GlobalSpotlightLookup.contentSnippet(nil, matching: "source"))
    }

    func testSearchFoldIsCaseAndDiacriticInsensitive() {
        let apps = [
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Cafe.app"), title: "Café"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Notes.app"), title: "Notes")
        ]
        XCTAssertEqual(GlobalApplicationCatalog.matches(apps, query: "CAFE").map(\.title), ["Café"])
        XCTAssertTrue(GlobalApplicationCatalog.matches(apps, query: " ").isEmpty)
    }

    func testSearchLimitAndShortcutChoices() {
        let apps = (0..<20).map { index in
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/App\(index).app"), title: "App \(index)")
        }
        XCTAssertEqual(GlobalApplicationCatalog.matches(apps, query: "App", limit: 3).count, 3)
        XCTAssertEqual(GlobalSearchShortcut.optionSpace.keyCode, UInt32(kVK_Space))
        XCTAssertNotEqual(GlobalSearchShortcut.optionSpace.modifiers,
                          GlobalSearchShortcut.controlOptionP.modifiers)
    }

    @MainActor
    func testCancelImmediatelyClearsGlobalSearchLoadingState() {
        let results = GlobalSearchResults()
        results.start()
        results.query = "large workspace search"

        XCTAssertTrue(results.loading)
        results.cancel()

        XCTAssertFalse(results.loading)
        XCTAssertTrue(results.items.isEmpty)
    }

    func testRecordedGlobalShortcutRoundTripsAndLegacyPresetsRemainValid() throws {
        let commandShiftK = try XCTUnwrap(GlobalSearchKeyBinding.make(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey),
            key: "k"
        ))
        XCTAssertEqual(commandShiftK.label, "⇧⌘K")
        XCTAssertEqual(GlobalSearchKeyBinding.resolved(commandShiftK.storedValue), commandShiftK)
        XCTAssertEqual(GlobalSearchKeyBinding.resolved("controlOptionP").label, "⌃⌥P")
        XCTAssertEqual(GlobalSearchKeyBinding.resolved("optionSpace").label, "⌥Space")
        XCTAssertEqual(GlobalSearchKeyBinding.resolved("invalid").label, "⌃⌥P")
    }

    func testRecordingRejectsUnmodifiedAndSingleModifierSystemShortcuts() {
        XCTAssertNil(GlobalSearchKeyBinding.make(
            keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey), key: "Q"
        ))
        XCTAssertNil(GlobalSearchKeyBinding.make(
            keyCode: UInt32(kVK_Space), modifiers: 0, key: " "
        ))
        XCTAssertNil(GlobalSearchKeyBinding.make(
            keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey) | 1, key: "P"
        ))
        XCTAssertNotNil(GlobalSearchKeyBinding.make(
            keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P"
        ))
    }

    func testUnifiedResultsDeduplicateAndPreferFilenames() {
        let path = URL(fileURLWithPath: "/Users/test/Documents/Budget Plan.pdf")
        let application = GlobalSearchItem.application(
            URL(fileURLWithPath: "/Applications/Budget.app"), title: "Budget")
        let document = GlobalSearchItem.spotlight(path, title: "Budget Plan.pdf", isFolder: false)
        let content = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Diary.md"),
            title: "Diary.md", isFolder: false)
        let items = GlobalSearchRanker.merge(
            apps: [application], documents: [content, document],
            spotlight: [document], query: "budget"
        )
        XCTAssertEqual(items.map(\.title), ["Budget", "Budget Plan.pdf", "Diary.md"])
        XCTAssertEqual(items.count, 3)
    }

    func testSystemSpotlightCoversFilenamesAndIndexedDocumentContent() {
        let full = GlobalSpotlightLookup.searchPredicate(for: "OpenClaw")
        XCTAssertTrue(full.evaluate(with: [
            NSMetadataItemFSNameKey: "OpenClaw-guide.pdf",
            "kMDItemTextContent": ""
        ]))
        XCTAssertTrue(full.evaluate(with: [
            NSMetadataItemFSNameKey: "learning.md",
            "kMDItemTextContent": "Notes on OpenClaw commands"
        ]))
        XCTAssertTrue(full.evaluate(with: [
            NSMetadataItemFSNameKey: "learning.md",
            NSMetadataItemPathKey: "/Users/test/OpenClaw Research/learning.md",
            "kMDItemTextContent": "unrelated project"
        ]))
        XCTAssertFalse(full.evaluate(with: [
            NSMetadataItemFSNameKey: "budget.pdf",
            NSMetadataItemPathKey: "/Users/test/Budget/budget.pdf",
            "kMDItemTextContent": "unrelated project"
        ]))
        let short = GlobalSpotlightLookup.searchPredicate(for: "OA")
        XCTAssertFalse(short.evaluate(with: [
            NSMetadataItemFSNameKey: "learning.md",
            "kMDItemTextContent": "OA only in body"
        ]))
        XCTAssertTrue(short.evaluate(with: [
            NSMetadataItemFSNameKey: "learning.md",
            NSMetadataItemPathKey: "/Users/test/OA/learning.md",
            "kMDItemTextContent": ""
        ]))
    }

    func testSpotlightRanksFolderPathMatchesAfterFilenamesAndBeforeBodyMatches() {
        let filename = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Other/Research-plan.md"),
            title: "Research-plan.md", isFolder: false
        )
        let exactFolder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Research/meeting.pdf"),
            title: "meeting.pdf", isFolder: false
        )
        let prefixFolder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Research Archive/notes.pdf"),
            title: "notes.pdf", isFolder: false
        )
        let body = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Other/body.pdf"),
            title: "body.pdf", isFolder: false,
            contentMatch: true, relevance: 0.99
        )

        let spotlight = GlobalSpotlightLookup.rank(
            [body, prefixFolder, exactFolder, filename], for: "Research"
        )
        XCTAssertEqual(
            spotlight.map(\.title),
            ["Research-plan.md", "meeting.pdf", "notes.pdf", "body.pdf"]
        )
        XCTAssertFalse(spotlight[1].spotlightContentMatch)
        XCTAssertFalse(spotlight[2].spotlightContentMatch)
        XCTAssertTrue(spotlight[3].spotlightContentMatch)

        let merged = GlobalSearchRanker.merge(
            apps: [], documents: [], spotlight: [body, prefixFolder, exactFolder, filename],
            query: "Research"
        )
        XCTAssertEqual(
            merged.map(\.title),
            ["Research-plan.md", "meeting.pdf", "notes.pdf", "body.pdf"]
        )
    }

    func testSpotlightMatchRanksAreReusedByMergeAndRecomputedForANewQuery() {
        let direct = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Other/Research-plan.md"),
            title: "Research-plan.md", isFolder: false
        )
        let body = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Other/body.pdf"),
            title: "body.pdf", isFolder: false, contentMatch: true, relevance: 0.99
        )

        let spotlight = GlobalSpotlightLookup.rank([body, direct], for: "Research")
        XCTAssertEqual(spotlight.map(\.title), ["Research-plan.md", "body.pdf"])
        XCTAssertEqual(spotlight[0].searchRanking?.query, "research")
        XCTAssertEqual(spotlight[0].searchRanking?.mergeWeight, 3)
        XCTAssertEqual(spotlight[1].searchRanking?.mergeWeight, 13)
        XCTAssertTrue(spotlight[1].spotlightContentMatch)

        let merged = GlobalSearchRanker.merge(
            apps: [], documents: [], spotlight: spotlight, query: "Research"
        )
        XCTAssertEqual(merged.map(\.title), ["Research-plan.md", "body.pdf"])
        XCTAssertEqual(merged[1].searchRanking?.query, "research")
        XCTAssertTrue(merged[1].spotlightContentMatch)

        // A cached rank is valid only for its normalized query.
        let nextQuery = GlobalSearchRanker.merge(
            apps: [], documents: [], spotlight: spotlight, query: "body"
        )
        XCTAssertEqual(nextQuery.map(\.title), ["body.pdf", "Research-plan.md"])
        XCTAssertEqual(nextQuery[0].searchRanking?.query, "body")
        XCTAssertFalse(nextQuery[0].spotlightContentMatch)
    }

    func testDirectNameMatchesOutrankGlobalSpotlightBodyMatches() {
        let direct = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/OpenClaw-guide.md"),
            title: "OpenClaw-guide.md", isFolder: false
        )
        let body = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/commands.md"),
            title: "commands.md", isFolder: false,
            contentMatch: true, relevance: 0.85
        )
        let weakerBody = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/misc.md"),
            title: "misc.md", isFolder: false,
            contentMatch: true, relevance: 0.3
        )
        let found = GlobalSearchRanker.merge(
            apps: [], documents: [], spotlight: [weakerBody, direct, body],
            query: "OpenClaw"
        )
        XCTAssertEqual(found.map(\.title),
                       ["OpenClaw-guide.md", "commands.md", "misc.md"])
        XCTAssertFalse(found[0].spotlightContentMatch)
        XCTAssertTrue(found[1].spotlightContentMatch)
        XCTAssertEqual(found[1].spotlightRelevance, 0.85)
    }

    func testPinyinFilenameMatchesRankAheadOfBodyOnlySpotlightResults() {
        let chineseName = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/吉他谱/夜的钢琴曲五.pdf"),
            title: "夜的钢琴曲五.pdf", isFolder: false
        )
        let bodyOnly = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/lyrics.pdf"),
            title: "lyrics.pdf", isFolder: false,
            contentMatch: true, relevance: 0.99
        )

        XCTAssertEqual(
            GlobalSpotlightLookup.rank([bodyOnly, chineseName], for: "ye de gang qin qu").map(\.title),
            ["夜的钢琴曲五.pdf", "lyrics.pdf"]
        )
        XCTAssertEqual(
            GlobalSearchRanker.merge(
                apps: [], documents: [chineseName], spotlight: [bodyOnly],
                query: "ye de gang qin qu"
            ).map(\.title),
            ["夜的钢琴曲五.pdf", "lyrics.pdf"]
        )
        XCTAssertFalse(WorkspaceSearch.transliteratedContains("夜的钢琴曲五.pdf", "ye"))
    }

    func testSpotlightBatchRankingSharesOneCJKQueryKeyAcrossOneThousandCandidates() {
        let query = "钢琴曲"
        let entries = (0..<1_000).map { index in
            let folder = index.isMultiple(of: 4) ? "ye-de-gang-qin-qu" : "documents"
            let title = index.isMultiple(of: 2)
                ? "ye-de-gang-qin-qu-\(index).pdf" : "notes-\(index).pdf"
            return GlobalSearchItem.spotlight(
                URL(fileURLWithPath: "/Users/test/\(folder)/\(title)"),
                title: title, isFolder: false
            )
        }
        let clock = ContinuousClock()
        let direct: () -> [String: GlobalSearchRanking] = {
            Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, GlobalSearchRanker.ranking(for: $0, query: query))
            })
        }
        let shared: () -> [String: GlobalSearchRanking] = {
            let key = WorkspaceSearch.queryTransliterationKey(query)
            return Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, GlobalSearchRanker.ranking(for: $0, query: query, queryTransliteration: key))
            })
        }
        func seconds(_ duration: Duration) -> Double {
            let value = duration.components
            return Double(value.seconds) + Double(value.attoseconds) / 1_000_000_000_000_000_000
        }
        func elapsed(_ operation: () -> Void) -> Double {
            let start = clock.now
            operation()
            return seconds(start.duration(to: clock.now))
        }
        var directSamples: [Double] = []
        var sharedSamples: [Double] = []
        var expected: [String: GlobalSearchRanking] = [:]
        var actual: [String: GlobalSearchRanking] = [:]
        for round in 0..<3 {
            if round.isMultiple(of: 2) {
                directSamples.append(elapsed { expected = direct() })
                sharedSamples.append(elapsed { actual = shared() })
            } else {
                sharedSamples.append(elapsed { actual = shared() })
                directSamples.append(elapsed { expected = direct() })
            }
        }
        XCTAssertEqual(actual.count, expected.count)
        for (id, ranking) in expected {
            XCTAssertEqual(actual[id]?.spotlightNameRank, ranking.spotlightNameRank)
            XCTAssertEqual(actual[id]?.spotlightPathRank, ranking.spotlightPathRank)
            XCTAssertEqual(actual[id]?.mergeWeight, ranking.mergeWeight)
            XCTAssertEqual(actual[id]?.contentMatch, ranking.contentMatch)
        }
        let ranked = GlobalSpotlightLookup.rank(entries, for: query, limit: entries.count)
        XCTAssertEqual(ranked.count, entries.count)
        for item in ranked {
            guard let actual = item.searchRanking, let expected = expected[item.id] else {
                XCTFail("Missing Spotlight batch ranking for \(item.id)")
                continue
            }
            XCTAssertEqual(actual.spotlightNameRank, expected.spotlightNameRank)
            XCTAssertEqual(actual.spotlightPathRank, expected.spotlightPathRank)
            XCTAssertEqual(actual.mergeWeight, expected.mergeWeight)
            XCTAssertEqual(actual.contentMatch, expected.contentMatch)
        }
        print("PKS_PERF spotlight_pinyin_rank_1000 direct=\(directSamples.sorted()[1])s shared=\(sharedSamples.sorted()[1])s")
    }

    func testFuzzyFilenameMatchRanksBeforeBodyOnlyResults() {
        let typoMatch = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/night-piano.md"),
            title: "night-piano.md", isFolder: false
        )
        let bodyOnly = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/music.pdf"),
            title: "music.pdf", isFolder: false,
            contentMatch: true, relevance: 0.99
        )

        XCTAssertEqual(
            GlobalSpotlightLookup.rank([bodyOnly, typoMatch], for: "nigjt").map(\.title),
            ["night-piano.md", "music.pdf"]
        )
        XCTAssertEqual(
            GlobalSearchRanker.merge(
                apps: [], documents: [typoMatch], spotlight: [bodyOnly], query: "nigjt"
            ).map(\.title),
            ["night-piano.md", "music.pdf"]
        )
        XCTAssertFalse(WorkspaceSearch.fuzzyContains("night-piano.md", "nigt"))
    }

    func testSpotlightRecoversICloudPathAndRanksPinyinWithoutOpeningFile() {
        // A Spotlight result may have kMDItemPath but no kMDItemURL.
        let path = "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/吉他谱/夜的钢琴曲五.pdf"
        let recovered = GlobalSpotlightLookup.fileURL(metadataURL: nil, metadataPath: path)
        XCTAssertEqual(recovered?.path, path)
        XCTAssertEqual(recovered?.lastPathComponent, "夜的钢琴曲五.pdf")
        XCTAssertTrue(recovered?.isFileURL == true)
        if let recovered {
            let entry = GlobalSearchItem.spotlight(recovered, title: "夜的钢琴曲五.pdf", isFolder: false)
            XCTAssertEqual(GlobalSpotlightLookup.rank([entry], for: "夜的钢琴曲").first?.url, recovered)
            XCTAssertEqual(GlobalSpotlightLookup.rank([entry], for: "ye de gang qin qu").first?.url, recovered)
            XCTAssertFalse(entry.spotlightContentMatch)
        }
        XCTAssertNil(GlobalSpotlightLookup.fileURL(metadataURL: nil, metadataPath: nil))
        XCTAssertNil(GlobalSpotlightLookup.fileURL(metadataURL: nil, metadataPath: "relative/path.pdf"))
        XCTAssertNil(GlobalSpotlightLookup.fileURL(
            metadataURL: URL(string: "https://example.com/unavailable.pdf"), metadataPath: nil
        ))
    }

    func testSpotlightBodyMatchesUseContentRelevanceAfterFilenameMatches() {
        let exact = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/OpenClaw", isDirectory: true),
            title: "OpenClaw", isFolder: true)
        let prefix = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/OpenClaw-guide.md"),
            title: "OpenClaw-guide.md", isFolder: false)
        let highRelevance = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/z-body.pdf"),
            title: "z-body.pdf", isFolder: false, contentMatch: true, relevance: 0.95)
        let lowRelevance = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/a-body.pdf"),
            title: "a-body.pdf", isFolder: false, contentMatch: true, relevance: 0.15)

        let ranked = GlobalSpotlightLookup.rank(
            [lowRelevance, highRelevance, prefix, exact], for: "OpenClaw", limit: 3)

        XCTAssertEqual(ranked.map(\.title), ["OpenClaw", "OpenClaw-guide.md", "z-body.pdf"])
        XCTAssertTrue(ranked.last?.spotlightContentMatch == true)
        XCTAssertEqual(ranked.last?.spotlightRelevance, 0.95)
    }

    func testSpotlightRankingAndFolderClassification() {
        let folder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Study", isDirectory: true),
            title: "Study", isFolder: true)
        let file = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Study-list.pdf"),
            title: "Study-list.pdf", isFolder: false)
        let match = GlobalSpotlightLookup.rank([file, folder], for: "study")
        XCTAssertEqual(match.first?.title, "Study")
        XCTAssertEqual(match.first?.kind, .folder)
    }

    func testPKSFileRetainsHitForLeafspanNavigation() {
        let url = URL(fileURLWithPath: "/Users/test/Documents/Study.md")
        let hit = SearchHit(
            documentId: "doc-123", chunkId: "chunk-456", title: "Study.md",
            uri: url.path, sourceType: "local",
            snippet: "matching paragraph", score: 0.98, headingPath: "Section One"
        )
        let item = GlobalSearchItem.file(hit, url: url)
        XCTAssertEqual(item.sourceHit?.documentId, "doc-123")
        XCTAssertEqual(item.sourceHit?.chunkId, "chunk-456")
        XCTAssertNil(GlobalSearchItem.spotlight(url, title: "Study.md", isFolder: false).sourceHit)
    }

    func testRelatedSuggestionsSkipGenericChineseSearchTerms() {
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("我的文件"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("学习资料"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("相关笔记"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("文件夹搜索"))
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("夜的钢琴曲"))
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("腹膜透析治疗"))
    }

    func testRelatedSuggestionsRankAfterDirectMatches() {
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("kafka"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("my file"))
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("Kafka consumer event"))
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("腹膜透析治疗"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("腹膜"))
        func item(_ name: String, score: Double, related: Bool) -> GlobalSearchItem {
            let url = URL(fileURLWithPath: "/Users/test/Documents/" + name)
            let hit = SearchHit(documentId: name, chunkId: nil, title: name,
                uri: url.path, sourceType: "local", snippet: "matching consumer event",
                score: score, headingPath: nil)
            return GlobalSearchItem.file(hit, url: url, isRelated: related)
        }
        let merged = GlobalSearchRanker.merge(
            apps: [], documents: [item("Kafka.md", score: 0.6, related: false)],
            spotlight: [], related: [
                item("Offset.md", score: 0.4, related: true),
                item("Kafka.md", score: 0.99, related: true),
                item("Consumer.md", score: 0.9, related: true)
            ], query: "Kafka consumer event")
        XCTAssertEqual(merged.map(\.title), ["Kafka.md", "Consumer.md", "Offset.md"])
        XCTAssertFalse(merged[0].isRelated)
        XCTAssertTrue(merged[1].isRelated)
        XCTAssertEqual(merged[1].sourceHit?.score, 0.9)
    }

    func testRelatedSuggestionsRemainVisibleWhenDirectResultsFillTheLimit() {
        func item(_ index: Int, related: Bool) -> GlobalSearchItem {
            let url = URL(fileURLWithPath: "/Users/test/Documents/Study-\(index).md")
            let hit = SearchHit(documentId: "\(index)", chunkId: nil,
                                title: url.lastPathComponent, uri: url.path,
                                sourceType: "local", snippet: "notes about study",
                                score: Double(index) / 100, headingPath: nil)
            return GlobalSearchItem.file(hit, url: url, isRelated: related)
        }
        let direct = (0..<45).map { item($0, related: false) }
        let related = (45..<57).map { item($0, related: true) }
        let results = GlobalSearchRanker.merge(
            apps: [], documents: direct, spotlight: [],
            related: related, query: "学习阅读技巧", limit: 45)
        XCTAssertEqual(results.count, 53)
        XCTAssertTrue(results.prefix(45).allSatisfy { !$0.isRelated })
        XCTAssertTrue(results.suffix(8).allSatisfy(\.isRelated))
        XCTAssertEqual(Set(results.map(\.url)).count, 53)
    }

    func testCrossProviderScoresAreNotComparedAcrossUncalibratedScales() {
        let pksURL = URL(fileURLWithPath: "/Users/test/PKS/notes.md")
        let pksHit = SearchHit(documentId: "pks", chunkId: "pks-chunk", title: "PKS notes.md",
                              uri: pksURL.path, sourceType: "local", snippet: "matching paragraph",
                              score: 0.08, headingPath: nil)
        let pks = GlobalSearchItem.file(pksHit, url: pksURL)
        let spotlightURL = URL(fileURLWithPath: "/Users/test/Spotlight/commands.pdf")
        let spotlight = GlobalSearchItem.spotlight(
            spotlightURL, title: "commands.pdf", isFolder: false, contentMatch: true, relevance: 0.99
        )
        let merged = GlobalSearchRanker.merge(
            apps: [], documents: [pks], spotlight: [spotlight], query: "topic"
        )
        XCTAssertEqual(merged.map(\.url), [pksURL, spotlightURL])
    }

    func testGenericSearchQueriesDoNotRequestRelatedSuggestions() {
        for query in ["search folder", "document search", "how to find a file", "PDF files",
                      "文件在哪里", "请帮我找一下文件"] {
            XCTAssertFalse(GlobalSearchRanker.shouldFindRelated(query), query)
        }
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("Kafka consumer event"))
    }
    func testLocalFileSourceDoesNotInterpretOpaqueURI() {
        let hit = SearchHit(
            documentId: "opaque", chunkId: nil, title: "Notion page",
            uri: "notion://page-1", sourceType: "notion", snippet: nil,
            score: nil, headingPath: nil
        )
        XCTAssertNil(hit.localFileURL)
    }
}

extension GlobalSearchFeatureTests {
    func testGlobalShortcutAndPKSIndexedFolderSearchAreIndependentOptIns() {
        XCTAssertNotEqual(GlobalSearchPreferences.enabledKey,
                          GlobalSearchPreferences.indexedFoldersEnabledKey)
        XCTAssertEqual(GlobalSearchShortcut.defaultChoice, .controlOptionP)
        XCTAssertEqual(GlobalSearchShortcut.defaultChoice.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(GlobalSearchShortcut.defaultChoice.modifiers, UInt32(controlKey | optionKey))
        XCTAssertNotEqual(GlobalSearchShortcut.optionSpace.modifiers,
                          GlobalSearchShortcut.defaultChoice.modifiers)
    }
}


extension GlobalSearchFeatureTests {
    func testUnifiedRankingTrimsQueryWhitespaceBeforeFilenameAndPathRanking() {
        let exact = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Budget"), title: "Budget", isFolder: false
        )
        let prefix = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Budget plan.pdf"),
            title: "Budget plan.pdf", isFolder: false
        )
        let folder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Budget/notes.md"), title: "notes.md", isFolder: false
        )

        let ranked = GlobalSearchRanker.merge(
            apps: [], documents: [], spotlight: [folder, prefix, exact], query: "  budget  "
        )
        XCTAssertEqual(ranked.map(\.title), ["Budget", "Budget plan.pdf", "notes.md"])
    }
}
