import CodeEditorHighlightingCore
import Foundation
import LanguageKit
import Testing
import TreeSitterCore
import TreeSitterStandardLanguages
import TreeSitterTestSupport
@testable import CodeEditorTreeSitter

@Suite struct TreeSitterHighlightProviderTests {
    // MARK: - Helpers

    private func snapshot(_ language: LanguageID) throws -> HighlightDocumentSnapshot {
        let text = try #require(SyntaxTestFixtures.snippet(for: language))
        return HighlightDocumentSnapshot(text: text, languageID: language.rawValue)
    }

    private func fullRange(_ document: HighlightDocumentSnapshot) -> HighlightRange {
        HighlightRange(location: 0, length: document.utf16Length)
    }

    private func tokenTypes(_ tokens: [HighlightToken]) -> Set<String> {
        Set(tokens.map(\.tokenType))
    }

    // MARK: - Contract conformance

    @Test func conformsToHighlightRangeProviding() throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let asProtocol: any HighlightRangeProviding = provider
        _ = asProtocol // compile-time proof of conformance
    }

    // MARK: - Unsupported language

    @Test func standardFactoryRejectsUnsupportedLanguage() {
        // Markdown has no tree-sitter registration in the standard set.
        #expect(throws: TreeSitterHighlightProviderError.unsupportedLanguage(LanguageID("markdown"))) {
            _ = try TreeSitterHighlightProvider.standard(languageID: LanguageID("markdown"))
        }
    }

    @Test func initRejectsLanguageWithoutHighlightSupport() throws {
        let parser = try SyntaxParser.standard()
        #expect(throws: TreeSitterHighlightProviderError.unsupportedLanguage(LanguageID("json"))) {
            _ = try TreeSitterHighlightProvider(languageID: LanguageID("json"), parser: parser)
        }
    }

    // MARK: - End-to-end parses (>= 3 languages)

    @Test func swiftHighlightsProduceExpectedCategories() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let document = try snapshot(.swift)
        await provider.prepare(for: document)
        let tokens = try await provider.highlights(in: fullRange(document), of: document)

        #expect(!tokens.isEmpty)
        let types = tokenTypes(tokens)
        #expect(types.contains("keyword"))  // import / struct / func / let / return
        #expect(types.contains("string"))   // "hello " + name
        #expect(types.contains("comment"))  // /// A greeter.
    }

    @Test func pythonHighlightsProduceKeywords() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .python)
        let document = try snapshot(.python)
        await provider.prepare(for: document)
        let tokens = try await provider.highlights(in: fullRange(document), of: document)

        #expect(!tokens.isEmpty)
        #expect(tokenTypes(tokens).contains("keyword")) // import / class / def / return
    }

    @Test func javascriptHighlightsProduceKeywordsAndComments() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .javascript)
        let document = try snapshot(.javascript)
        await provider.prepare(for: document)
        let tokens = try await provider.highlights(in: fullRange(document), of: document)

        #expect(!tokens.isEmpty)
        let types = tokenTypes(tokens)
        #expect(types.contains("keyword"))  // class / function / return
        #expect(types.contains("comment"))  // // point
    }

    // MARK: - Token integrity

    @Test func tokenRangesAndTextAreConsistentWithDocument() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let document = try snapshot(.swift)
        let tokens = try await provider.highlights(in: fullRange(document), of: document)
        let nsText = document.text as NSString

        for token in tokens {
            let range = token.range
            #expect(range.length > 0)
            #expect(range.location >= 0)
            #expect(range.upperBound <= nsText.length)
            // The carried text is exactly the substring the range covers.
            #expect(nsText.substring(with: range.nsRange) == token.text)
        }
    }

    // MARK: - Range filtering

    @Test func highlightsOnlyReturnsTokensIntersectingQueryRange() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let document = try snapshot(.swift)
        // Query the first 12 UTF-16 units ("import Found…").
        let query = HighlightRange(location: 0, length: 12)
        let tokens = try await provider.highlights(in: query, of: document)

        #expect(!tokens.isEmpty)
        for token in tokens {
            let intersects = token.range.location < query.upperBound
                && token.range.upperBound > query.location
            #expect(intersects, "token \(token) does not intersect \(query)")
        }
    }

    @Test func emptyDocumentProducesNoTokens() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let document = HighlightDocumentSnapshot(text: "", languageID: "swift")
        let tokens = try await provider.highlights(
            in: HighlightRange(location: 0, length: 0),
            of: document
        )
        #expect(tokens.isEmpty)
    }

    // MARK: - Invalidation semantics

    @Test func invalidateReportsWholeDocumentForNonEmptyText() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let document = try snapshot(.swift)
        let edit = HighlightTextEdit(
            editedRange: HighlightRange(location: 0, length: 1),
            changeInLength: 1
        )
        let invalidation = await provider.invalidate(for: edit, in: document)
        #expect(invalidation == .everything(length: document.utf16Length))
        #expect(!invalidation.isEmpty)
        #expect(invalidation.ranges == [HighlightRange(location: 0, length: document.utf16Length)])
    }

    @Test func invalidateReportsEmptyForEmptyDocument() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let document = HighlightDocumentSnapshot(text: "", languageID: "swift")
        let edit = HighlightTextEdit(
            editedRange: HighlightRange(location: 0, length: 0),
            changeInLength: 0
        )
        let invalidation = await provider.invalidate(for: edit, in: document)
        #expect(invalidation.isEmpty)
    }

    /// After an edit the cache is dropped and the next query reflects the new
    /// text. Also exercises the memoization path (same text queried twice).
    @Test func highlightsReflectChangedTextAfterInvalidate() async throws {
        let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)

        let first = HighlightDocumentSnapshot(text: "let x = 1", languageID: "swift")
        let firstTokens = try await provider.highlights(in: fullRange(first), of: first)
        // Re-query identical text (served from cache) — same result.
        let firstAgain = try await provider.highlights(in: fullRange(first), of: first)
        #expect(firstTokens == firstAgain)

        let edit = HighlightTextEdit(
            editedRange: HighlightRange(location: 9, length: 0),
            changeInLength: 25,
            previousText: first.text
        )
        _ = await provider.invalidate(for: edit, in: first)

        let second = HighlightDocumentSnapshot(
            text: "let x = 1\nfunc greet() -> Int { 2 }",
            languageID: "swift"
        )
        let secondTokens = try await provider.highlights(in: fullRange(second), of: second)
        #expect(!secondTokens.isEmpty)
        // The new text contains a function declaration the first did not.
        #expect(tokenTypes(secondTokens).contains("function"))
    }
}
