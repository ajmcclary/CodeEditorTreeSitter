import CodeEditorHighlightingCore
import Foundation
import LanguageKit
import TreeSitterCore
import TreeSitterStandardLanguages

/// A Tree-sitter-backed ``CodeEditorHighlightingCore/HighlightRangeProviding``
/// implementation.
///
/// The provider parses a document with TreeSitterKit's ``TreeSitterCore/SyntaxParser``,
/// runs the language's highlight query, and maps each capture to a
/// ``CodeEditorHighlightingCore/HighlightToken`` via ``HighlightCaptureMapping``.
/// It trades only in the view-free value types of `CodeEditorHighlightingCore`,
/// so it can back the editor's highlight seam without any dependency on the
/// editor surface.
///
/// ## Concurrency
///
/// `SyntaxParser` is an `actor`, and `HighlightRangeProviding` is fully `async`,
/// so the provider is itself an `actor`: it awaits the parser directly, with no
/// synchronous cache-and-serve bridge of the kind `LSPSemanticTokenProvider`
/// needs (that provider is `@MainActor` and must hand results to the view
/// synchronously). All parsing runs one document at a time inside the parser
/// actor.
///
/// ## Caching
///
/// The editor drives `HighlightRangeProviding` as a pull loop, calling
/// ``highlights(in:of:)`` once per visible range. Re-parsing on every call
/// would be wasteful, so the provider memoizes the full token list keyed by the
/// document's exact text: the first query for a given document text parses and
/// caches; subsequent queries (other visible ranges of the same text) filter
/// the cached list. An edit resets the cache (see ``invalidate(for:in:)``).
///
/// ## Invalidation semantics (v1)
///
/// ``invalidate(for:in:)`` returns a **whole-document** invalidation
/// (``CodeEditorHighlightingCore/HighlightInvalidation/everything(length:)``)
/// and clears the token cache. This is the simplest correct semantics the
/// contract supports: after any edit the next parse re-tokenizes the whole
/// document. The contract lets the editor re-query only the intersection of the
/// invalidation with the visible viewport, so over-reporting is safe and does
/// not force an off-screen repaint. Incremental tree-editing (translating the
/// edit into old/new byte ranges and re-highlighting only the affected span) is
/// intentionally out of scope for v1.
public actor TreeSitterHighlightProvider: HighlightRangeProviding {
    /// The language this provider highlights. Fixed at construction; the
    /// provider is (re)created by the editor whenever the language changes.
    public let languageID: LanguageID

    private let parser: SyntaxParser

    /// Memoized token list and the exact document text it was computed from.
    private var cachedText: String?
    private var cachedTokens: [HighlightToken]?

    // MARK: - Initialization

    /// Creates a provider backed by an existing parser.
    ///
    /// - Parameters:
    ///   - languageID: The language to highlight. Must be highlight-supported
    ///     by `parser` (``TreeSitterCore/SyntaxParser/supportsHighlighting(_:)``).
    ///   - parser: The parser to run highlight queries against.
    /// - Throws: ``TreeSitterHighlightProviderError/unsupportedLanguage(_:)``
    ///   when the language has no highlight support in `parser`.
    public init(languageID: LanguageID, parser: SyntaxParser) throws {
        guard parser.supportsHighlighting(languageID) else {
            throw TreeSitterHighlightProviderError.unsupportedLanguage(languageID)
        }
        self.languageID = languageID
        self.parser = parser
    }

    /// Creates a provider backed by a parser preloaded with TreeSitterKit's
    /// standard language registrations.
    ///
    /// - Parameters:
    ///   - languageID: The language to highlight. Must be one of the standard
    ///     tree-sitter languages (`swift`, `python`, `javascript`,
    ///     `typescript`, `tsx`, `c`, `cpp`, `csharp`, `go`, `java`, `rust`,
    ///     `dart`, `php`, `ruby`).
    ///   - limits: Input-size thresholds; defaults to
    ///     ``TreeSitterCore/SyntaxInputLimits/standard``.
    /// - Throws: ``TreeSitterHighlightProviderError/unsupportedLanguage(_:)``
    ///   for a non-standard language, or the error thrown by
    ///   ``TreeSitterCore/SyntaxParser/standard(limits:)`` when a bundled query
    ///   resource is missing (a corrupted install).
    public static func standard(
        languageID: LanguageID,
        limits: SyntaxInputLimits = .standard
    ) throws -> TreeSitterHighlightProvider {
        let parser = try SyntaxParser.standard(limits: limits)
        return try TreeSitterHighlightProvider(languageID: languageID, parser: parser)
    }

    // MARK: - HighlightRangeProviding

    /// Warms the token cache for the document, best-effort.
    ///
    /// A parse failure here is swallowed: the cache is simply left unpopulated,
    /// so a later ``highlights(in:of:)`` re-attempts and surfaces any error to
    /// the editor.
    public func prepare(for document: HighlightDocumentSnapshot) async {
        _ = try? await tokens(for: document.text)
    }

    /// Reports the whole document as stale and clears the cache. See the
    /// type's "Invalidation semantics" discussion.
    public func invalidate(
        for _: HighlightTextEdit,
        in document: HighlightDocumentSnapshot
    ) async -> HighlightInvalidation {
        cachedText = nil
        cachedTokens = nil
        return .everything(length: document.utf16Length)
    }

    /// Returns the highlight tokens intersecting `range` in `document`.
    ///
    /// Token ranges are the captures' full document-relative UTF-16 ranges (not
    /// clipped to `range`): a token that straddles the query boundary is
    /// returned whole, so the editor colors the entire token even when only
    /// part of it is visible.
    ///
    /// - Throws: rethrows ``TreeSitterCore/SyntaxParserError`` from the parser
    ///   (e.g. a non-tolerated highlight-query compile failure).
    public func highlights(
        in range: HighlightRange,
        of document: HighlightDocumentSnapshot
    ) async throws -> [HighlightToken] {
        let all = try await tokens(for: document.text)
        guard !all.isEmpty else { return [] }

        let lower = range.location
        let upper = range.upperBound
        return all.filter { token in
            token.range.location < upper && token.range.upperBound > lower
        }
    }

    // MARK: - Internals

    /// Returns the memoized token list for `text`, parsing and caching on a
    /// miss. The cache holds exactly one document's tokens; a different text
    /// replaces it.
    private func tokens(for text: String) async throws -> [HighlightToken] {
        if cachedText == text, let cachedTokens {
            return cachedTokens
        }
        let computed = try await computeTokens(for: text)
        cachedText = text
        cachedTokens = computed
        return computed
    }

    /// Parses `text`, runs the highlight query, and maps captures to tokens.
    private func computeTokens(for text: String) async throws -> [HighlightToken] {
        let captures = try await parser.captures(in: text, language: languageID)
        guard !captures.isEmpty else { return [] }

        // `SyntaxCapture.range` is an NSRange in UTF-16 code units of `text`,
        // so an NSString gives correct, cheap substring extraction.
        let nsText = text as NSString
        let length = nsText.length

        var tokens: [HighlightToken] = []
        tokens.reserveCapacity(captures.count)
        for capture in captures {
            guard let tokenType = HighlightCaptureMapping.tokenType(forCapture: capture.name) else {
                continue
            }
            let captureRange = capture.range
            guard captureRange.length > 0,
                  captureRange.location >= 0,
                  captureRange.location + captureRange.length <= length else {
                continue
            }
            tokens.append(
                HighlightToken(
                    range: HighlightRange(captureRange),
                    tokenType: tokenType,
                    text: nsText.substring(with: captureRange)
                )
            )
        }
        return tokens
    }
}
