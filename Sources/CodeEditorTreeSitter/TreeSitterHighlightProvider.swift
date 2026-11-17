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
/// would be wasteful, so the provider memoizes full token lists keyed by the
/// document's exact text: the first query for a given document text parses and
/// caches; subsequent queries (other visible ranges of the same text) filter
/// the cached list. The cache is a small least-recently-used set of
/// ``tokenCacheCapacity`` texts, because a host typically shares one provider
/// across every open document of a language and those documents must not
/// evict each other. An edited document's old text is never looked up again
/// and ages out.
///
/// ## Scheduling
///
/// The provider runs one parse at a time, in request order. Concurrent
/// requests for the same text share one parse. Before a queued parse starts,
/// the provider drops it if every request waiting for it has been cancelled,
/// or if an edit has superseded its text (``invalidate(for:in:)`` names the
/// pre-edit text in ``CodeEditorHighlightingCore/HighlightTextEdit/previousText``);
/// those requests throw `CancellationError`. A request from an already
/// cancelled task throws `CancellationError` without queueing. A cancelled
/// request whose parse is already running still receives its result, since
/// the parse costs nothing more by then.
///
/// ## Size limit
///
/// A document over the parser's highlight limits
/// (``TreeSitterCore/SyntaxInputLimits/highlightMaxLineCount`` and the general
/// parse limits) is never parsed: ``highlights(in:of:)`` throws
/// ``CodeEditorHighlightingCore/HighlightProviderDeclined``, and the editor
/// highlights that document with its built-in highlighter instead. The editor
/// keeps asking, so a document edited back under the limit returns to this
/// provider. ``exceedsHighlightLimits(_:)`` answers the same question up
/// front.
///
/// ## Invalidation semantics (v1)
///
/// ``invalidate(for:in:)`` returns a **whole-document** invalidation
/// (``CodeEditorHighlightingCore/HighlightInvalidation/everything(length:)``).
/// This is the simplest correct semantics the
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

    /// Runs the highlight query for a text. Normally `parser.captures`.
    private let captureSource: @Sendable (String) async throws -> [SyntaxCapture]

    /// The highlight limits as one ``TreeSitterCore/SyntaxInputLimits`` whose
    /// line limit is the stricter of the parse and highlight line limits.
    private nonisolated let highlightLimits: SyntaxInputLimits

    /// How many document texts the token cache holds.
    static let tokenCacheCapacity = 8

    /// Memoized token lists, least recently used first.
    private var tokenCache: [(text: String, tokens: [HighlightToken])] = []

    /// One pending or running parse and the requests waiting for its result.
    private final class ParseJob {
        let text: String
        var waiters: [Int: CheckedContinuation<[HighlightToken], any Error>] = [:]

        init(text: String) {
            self.text = text
        }
    }

    /// Parses not yet started, in request order.
    private var queuedJobs: [ParseJob] = []
    private var runningJob: ParseJob?
    private var isDrainingQueue = false
    private var nextWaiterID = 0

    /// Requests currently waiting for a parse, queued or running. Tests read
    /// it to know a request has reached the provider.
    var waitingRequestCount: Int {
        queuedJobs.reduce(runningJob?.waiters.count ?? 0) { $0 + $1.waiters.count }
    }

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
        try self.init(
            languageID: languageID,
            parser: parser,
            captureSource: { text in
                try await parser.captures(in: text, language: languageID)
            }
        )
    }

    /// Creates a provider whose captures come from `captureSource` instead of
    /// calling `parser` directly. Tests use it to count and pace parses.
    init(
        languageID: LanguageID,
        parser: SyntaxParser,
        captureSource: @escaping @Sendable (String) async throws -> [SyntaxCapture]
    ) throws {
        guard parser.supportsHighlighting(languageID) else {
            throw TreeSitterHighlightProviderError.unsupportedLanguage(languageID)
        }
        self.languageID = languageID
        self.parser = parser
        self.captureSource = captureSource
        self.highlightLimits = Self.highlightLimits(from: parser.limits)
    }

    /// Folds `highlightMaxLineCount` into `maxLineCount` so one
    /// ``TreeSitterCore/SyntaxInputLimits/oversizeReason(for:)`` call applies
    /// every check `SyntaxParser.captures` makes. A limit of zero or less is
    /// disabled, as in TreeSitterKit.
    private static func highlightLimits(from limits: SyntaxInputLimits) -> SyntaxInputLimits {
        var folded = limits
        let highlightLines = limits.highlightMaxLineCount
        if highlightLines > 0, limits.maxLineCount <= 0 || highlightLines < limits.maxLineCount {
            folded.maxLineCount = highlightLines
        }
        return folded
    }

    // MARK: - Size limit

    /// Whether `document` is over the parser's highlight limits, in which case
    /// this provider never parses it and ``highlights(in:of:)`` throws
    /// ``CodeEditorHighlightingCore/HighlightProviderDeclined`` for it.
    public nonisolated func exceedsHighlightLimits(_ document: HighlightDocumentSnapshot) -> Bool {
        exceedsHighlightLimits(document.text)
    }

    private nonisolated func exceedsHighlightLimits(_ text: String) -> Bool {
        highlightLimits.oversizeReason(for: text) != nil
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

    /// Reports the whole document as stale, and drops a queued parse of the
    /// pre-edit text when the edit carries it. See the type's "Scheduling" and
    /// "Invalidation semantics" discussions.
    ///
    /// The token cache is left alone: UTF-16 offsets require byte-exact text identity, so the
    /// edited document's next query misses anyway, and other documents
    /// sharing this provider keep their entries.
    public func invalidate(
        for edit: HighlightTextEdit,
        in document: HighlightDocumentSnapshot
    ) async -> HighlightInvalidation {
        if let previousText = edit.previousText, !previousText.utf8.elementsEqual(document.text.utf8) {
            dropQueuedParse(of: previousText)
        }
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
    ///   (e.g. a non-tolerated highlight-query compile failure);
    ///   `CancellationError` when the request was cancelled or its text
    ///   superseded before its parse started (see "Scheduling");
    ///   ``CodeEditorHighlightingCore/HighlightProviderDeclined`` when the
    ///   document is over the highlight limits (see "Size limit").
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

    /// Returns the memoized token list for `text`, or waits for a parse of it:
    /// one already running or queued for the same text, else a new one queued
    /// behind the others.
    private func tokens(for text: String) async throws -> [HighlightToken] {
        if let cached = cachedTokens(for: text) {
            return cached
        }
        if exceedsHighlightLimits(text) {
            throw HighlightProviderDeclined()
        }
        try Task.checkCancellation()

        let job: ParseJob
        if let running = runningJob, running.text.utf8.elementsEqual(text.utf8) {
            job = running
        } else if let queued = queuedJobs.first(where: { $0.text.utf8.elementsEqual(text.utf8) }) {
            job = queued
        } else {
            job = ParseJob(text: text)
            queuedJobs.append(job)
            startDrainingQueue()
        }

        let waiterID = nextWaiterID
        nextWaiterID += 1
        // The waiter is registered before this actor job suspends, so the
        // cancellation hop below (a later job on this actor) always finds it.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelQueuedWaiter(waiterID) }
        }
    }

    /// Looks `text` up in the token cache and marks it most recently used.
    private func cachedTokens(for text: String) -> [HighlightToken]? {
        guard let index = tokenCache.lastIndex(where: { $0.text.utf8.elementsEqual(text.utf8) }) else {
            return nil
        }
        let entry = tokenCache.remove(at: index)
        tokenCache.append(entry)
        return entry.tokens
    }

    private func storeTokens(_ tokens: [HighlightToken], for text: String) {
        tokenCache.removeAll { $0.text.utf8.elementsEqual(text.utf8) }
        tokenCache.append((text: text, tokens: tokens))
        if tokenCache.count > Self.tokenCacheCapacity {
            tokenCache.removeFirst(tokenCache.count - Self.tokenCacheCapacity)
        }
    }

    private func startDrainingQueue() {
        guard !isDrainingQueue else { return }
        isDrainingQueue = true
        // Unstructured on purpose: the drain belongs to the provider, so no
        // single requester's cancellation stops parses others wait for.
        Task { await self.drainQueue() }
    }

    /// Runs queued parses one at a time, skipping any whose waiters have all
    /// gone (cancelled or superseded) before it starts.
    private func drainQueue() async {
        while !queuedJobs.isEmpty {
            let job = queuedJobs.removeFirst()
            guard !job.waiters.isEmpty else { continue }
            runningJob = job
            let result: Result<[HighlightToken], any Error>
            do {
                result = .success(try await computeTokens(for: job.text))
            } catch {
                result = .failure(error)
            }
            runningJob = nil
            if case .success(let tokens) = result {
                storeTokens(tokens, for: job.text)
            }
            let waiters = job.waiters.values
            job.waiters.removeAll()
            for continuation in waiters {
                continuation.resume(with: result)
            }
        }
        isDrainingQueue = false
    }

    /// Fails a cancelled request whose parse has not started, and drops the
    /// parse when no one else waits for it. A request whose parse is running
    /// is left to receive the result.
    private func cancelQueuedWaiter(_ waiterID: Int) {
        guard let index = queuedJobs.firstIndex(where: { $0.waiters[waiterID] != nil }) else {
            return
        }
        let continuation = queuedJobs[index].waiters.removeValue(forKey: waiterID)
        if queuedJobs[index].waiters.isEmpty {
            queuedJobs.remove(at: index)
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// Fails every request waiting for a queued parse of `text` and drops the
    /// parse: an edit has replaced that text.
    private func dropQueuedParse(of text: String) {
        guard let index = queuedJobs.firstIndex(where: { $0.text.utf8.elementsEqual(text.utf8) }) else {
            return
        }
        let job = queuedJobs.remove(at: index)
        let waiters = job.waiters.values
        job.waiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Parses `text`, runs the highlight query, and maps captures to tokens.
    private func computeTokens(for text: String) async throws -> [HighlightToken] {
        let captures = try await captureSource(text)
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
