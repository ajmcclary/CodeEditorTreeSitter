import CodeEditorHighlightingCore
import Foundation
import LanguageKit
import Testing
import TreeSitterCore
import TreeSitterStandardLanguages
@testable import CodeEditorTreeSitter

/// Records every text the provider asks the parser to highlight and, while
/// gated, holds each parse until ``open()`` so tests can line requests up
/// behind a running parse.
private actor ParseRecorder {
    private(set) var parsed: [String] = []
    private var isOpen: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(gated: Bool) {
        isOpen = !gated
    }

    func enter(_ text: String) async {
        parsed.append(text)
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = held
        held = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private struct WaitTimedOut: Error {}

@Suite struct TreeSitterHighlightProviderSchedulingTests {
    // MARK: - Helpers

    private func makeProvider(
        recording recorder: ParseRecorder,
        limits: SyntaxInputLimits = .standard
    ) throws -> TreeSitterHighlightProvider {
        let parser = try SyntaxParser.standard(limits: limits)
        return try TreeSitterHighlightProvider(
            languageID: .swift,
            parser: parser,
            captureSource: { text in
                await recorder.enter(text)
                return try await parser.captures(in: text, language: .swift)
            }
        )
    }

    private func document(_ text: String) -> HighlightDocumentSnapshot {
        HighlightDocumentSnapshot(text: text, languageID: "swift")
    }

    private func fullRange(_ document: HighlightDocumentSnapshot) -> HighlightRange {
        HighlightRange(location: 0, length: document.utf16Length)
    }

    private func waitUntil(
        _ condition: @Sendable () async -> Bool,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            guard clock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Shared parses

    @Test func concurrentRequestsForTheSameTextShareOneParse() async throws {
        let recorder = ParseRecorder(gated: true)
        let provider = try makeProvider(recording: recorder)
        let doc = document("let x = 1\nfunc f() -> Int { 2 }")
        let range = fullRange(doc)

        let requests = (0..<5).map { _ in
            Task { try await provider.highlights(in: range, of: doc) }
        }
        try await waitUntil { await provider.waitingRequestCount == 5 }
        await recorder.open()

        var results: [[HighlightToken]] = []
        for request in requests {
            results.append(try await request.value)
        }
        #expect(await recorder.parsed == [doc.text])
        #expect(!results[0].isEmpty)
        #expect(results.allSatisfy { $0 == results[0] })
    }

    // MARK: - Cancellation and supersession

    @Test func cancelledRequestDoesNotParse() async throws {
        let recorder = ParseRecorder(gated: true)
        let provider = try makeProvider(recording: recorder)
        let first = document("let a = 1")
        let second = document("let b = 2")

        let running = Task { try await provider.highlights(in: fullRange(first), of: first) }
        try await waitUntil { await recorder.parsed == [first.text] }

        let queued = Task { try await provider.highlights(in: fullRange(second), of: second) }
        try await waitUntil { await provider.waitingRequestCount == 2 }
        queued.cancel()
        await recorder.open()

        #expect(try await !running.value.isEmpty)
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await recorder.parsed == [first.text])
    }

    @Test func requestFromAnAlreadyCancelledTaskDoesNotParse() async throws {
        let recorder = ParseRecorder(gated: false)
        let provider = try makeProvider(recording: recorder)
        let doc = document("let a = 1")

        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.highlights(in: fullRange(doc), of: doc)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await recorder.parsed.isEmpty)
    }

    /// A queued request whose text an edit has since replaced is dropped: the
    /// edit's `previousText` names the superseded text, and the request for
    /// the post-edit text is the only one of the two that parses.
    @Test func requestForTextSupersededByAnEditDoesNotParse() async throws {
        let recorder = ParseRecorder(gated: true)
        let provider = try makeProvider(recording: recorder)
        let other = document("let other = 0")
        let before = document("let a = 1")
        let after = document("let a = 12")

        let running = Task { try await provider.highlights(in: fullRange(other), of: other) }
        try await waitUntil { await recorder.parsed == [other.text] }

        let stale = Task { try await provider.highlights(in: fullRange(before), of: before) }
        try await waitUntil { await provider.waitingRequestCount == 2 }

        let edit = HighlightTextEdit(
            editedRange: HighlightRange(location: 9, length: 0),
            changeInLength: 1,
            previousText: before.text
        )
        _ = await provider.invalidate(for: edit, in: after)
        let current = Task { try await provider.highlights(in: fullRange(after), of: after) }
        await recorder.open()

        #expect(try await !running.value.isEmpty)
        #expect(try await !current.value.isEmpty)
        await #expect(throws: CancellationError.self) { try await stale.value }
        #expect(await recorder.parsed == [other.text, after.text])
    }

    // MARK: - Cache

    /// One provider serves every document of its language, so two documents
    /// queried in turn, and an edit in one of them, must not evict the other.
    @Test func twoDocumentsOfOneLanguageDoNotEvictEachOther() async throws {
        let recorder = ParseRecorder(gated: false)
        let provider = try makeProvider(recording: recorder)
        let first = document("let a = 1")
        let second = document("let b = 2")

        for doc in [first, second, first, second] {
            _ = try await provider.highlights(in: fullRange(doc), of: doc)
        }
        #expect(await recorder.parsed == [first.text, second.text])

        let edit = HighlightTextEdit(
            editedRange: HighlightRange(location: 9, length: 0),
            changeInLength: 1,
            previousText: first.text
        )
        _ = await provider.invalidate(for: edit, in: document("let a = 12"))
        _ = try await provider.highlights(in: fullRange(second), of: second)
        #expect(await recorder.parsed == [first.text, second.text])
    }

    @Test func tokenCacheIsBoundedAndEvictsTheLeastRecentlyUsedText() async throws {
        let recorder = ParseRecorder(gated: false)
        let provider = try makeProvider(recording: recorder)
        let capacity = TreeSitterHighlightProvider.tokenCacheCapacity
        let docs = (0...capacity).map { document("let v\($0) = \($0)") }

        // Fill to capacity, then touch the oldest so the second-oldest is the
        // least recently used when one more text arrives.
        for doc in docs.dropLast() {
            _ = try await provider.highlights(in: fullRange(doc), of: doc)
        }
        _ = try await provider.highlights(in: fullRange(docs[0]), of: docs[0])
        _ = try await provider.highlights(in: fullRange(docs[capacity]), of: docs[capacity])
        #expect(await recorder.parsed.count == capacity + 1)

        _ = try await provider.highlights(in: fullRange(docs[0]), of: docs[0])
        #expect(await recorder.parsed.count == capacity + 1)

        _ = try await provider.highlights(in: fullRange(docs[1]), of: docs[1])
        #expect(await recorder.parsed.count == capacity + 2)
        #expect(await recorder.parsed.last == docs[1].text)
    }

    // MARK: - Size limit

    private static let smallHighlightLimits = SyntaxInputLimits(
        maxLineCount: SyntaxInputLimits.standard.maxLineCount,
        maxUTF16Length: SyntaxInputLimits.standard.maxUTF16Length,
        maxUTF8ByteCount: SyntaxInputLimits.standard.maxUTF8ByteCount,
        highlightMaxLineCount: 3
    )

    @Test func documentOverTheHighlightLimitIsNotParsed() async throws {
        let recorder = ParseRecorder(gated: false)
        let provider = try makeProvider(recording: recorder, limits: Self.smallHighlightLimits)
        let doc = document(String(repeating: "let a = 1\n", count: 5))

        let tokens = try await provider.highlights(in: fullRange(doc), of: doc)
        #expect(tokens.isEmpty)
        #expect(await recorder.parsed.isEmpty)
    }

    @Test func exceedsHighlightLimitsReportsDocumentsTheProviderCannotHighlight() async throws {
        let recorder = ParseRecorder(gated: false)
        let provider = try makeProvider(recording: recorder, limits: Self.smallHighlightLimits)

        #expect(!provider.exceedsHighlightLimits(document("let a = 1\nlet b = 2\nlet c = 3")))
        #expect(provider.exceedsHighlightLimits(document("let a = 1\nlet b = 2\nlet c = 3\nlet d = 4")))
        // CRLF counts as one line break, as in TreeSitterKit's own guard.
        #expect(!provider.exceedsHighlightLimits(document("a\r\nb\r\nc")))

        let standard = try TreeSitterHighlightProvider.standard(languageID: .swift)
        let limit = SyntaxInputLimits.standard.highlightMaxLineCount
        let atLimit = Array(repeating: "x", count: limit).joined(separator: "\n")
        #expect(!standard.exceedsHighlightLimits(document(atLimit)))
        #expect(standard.exceedsHighlightLimits(document(atLimit + "\nx")))
    }
}
