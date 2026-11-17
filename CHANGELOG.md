# Changelog

All notable changes to CodeEditorTreeSitter are documented in this file.

The `0.1.0` entry below deliberately keeps the name `CodeEditorPlugin` — that is
what the dependency was called when `0.1.0` shipped.

## [0.2.2] - 2026-11-17

### Fixed

- Highlight caching and scheduling distinguish canonically equivalent spellings
  with different UTF-16 offsets.

## [0.2.1] - 2026-11-13

This release remediates the 2026-11-12 full review.

### Changed

- **Documents over the highlight limit now fall back to the editor's
  built-in highlighter instead of showing no highlighting.** Over the limit
  (5,000 lines with the standard limits), `highlights(in:of:)` throws
  CodeEditorKit's `HighlightProviderDeclined` without queueing or parsing, so
  the editor uses its own highlighter for that document. The editor keeps
  asking, so a document edited back under the limit returns to Tree-sitter.
  Before, the provider returned no tokens and the document stayed unhighlighted.
- **Highlight colours are corrected wherever the highlight queries use
  predicates.** TreeSitterKit `0.3.1` evaluates highlight-query predicates
  (`#eq?`, `#match?` and the like) that were previously ignored. For example, a
  Swift type name in type position (`let x: Foo`) is now coloured only as a
  type, and Python identifiers are no longer coloured as keywords.
- `highlights(in:of:)` can now throw `CancellationError` when a request is
  dropped (see Scheduling below). CodeEditorKit `0.1.0-beta.15` re-queries the
  range rather than marking it failed.
- `invalidate(for:in:)` no longer empties the token cache.

### Added

- `TreeSitterHighlightProvider.exceedsHighlightLimits(_:)` (public,
  `nonisolated`): answers up front whether a document is over the limits the
  provider would decline. Additive; no existing signature changed.

### Fixed

- **Scheduling.** Concurrent requests for the same text share one parse, and
  parses run one at a time in request order. A request from an
  already-cancelled task, or one cancelled while its parse is queued, does not
  parse; a queued parse whose text an edit has superseded is dropped.
- **Caching.** The token cache holds the eight most recently used texts, so
  two documents of one language sharing a provider no longer evict each other
  on every request.

### Dependencies

- Requires CodeEditorKit `.upToNextMinor(from: "0.1.0-beta.15")` (was
  `0.1.0-beta.6`), the first tag with `HighlightProviderDeclined` and the
  editor's re-query of a provider's `CancellationError`.
- Requires TreeSitterKit `.upToNextMinor(from: "0.3.1")` (was `0.3.0`), the
  first tag that evaluates highlight-query predicates.
- LanguageKit is unchanged (`.upToNextMinor(from: "0.2.0")`).
- Through CodeEditorKit `0.1.0-beta.15` a graph now also needs DesignKit
  `3.0.1`, ProcessKit `0.1.0-beta.6` and WorkspaceKit `0.1.0-beta.11` or later.

### Known limitation

- Two documents with byte-identical text sharing one provider can drop each
  other's queued request when one of them is edited, because supersession is
  keyed by text. The dropped request is re-queried, so it costs one more round
  trip, not a lost highlight. Closing this fully needs a document identity in
  CodeEditorKit's `HighlightDocumentSnapshot`.

## [0.2.0] - 2026-07-25

### Changed

- **BREAKING (platforms):** the macOS floor is now 27.0 (was 26.0) and the
  iOS 26.0 declaration is removed, because CodeEditorKit `0.1.0-beta.7` no
  longer declares iOS.
- TreeSitterKit moves to `.upToNextMinor(from: "0.3.0")` and LanguageKit to
  `.upToNextMinor(from: "0.2.0")`.

## [0.1.1] - 2026-07-25

### Changed

- **BREAKING (resolution): the `CodeEditorPlugin` dependency is now
  `CodeEditorKit`.** Upstream renamed the package, its SwiftPM identity and its
  repository, so this manifest's dependency URL becomes
  `https://github.com/ajmcclary/CodeEditorKit.git` and both
  `.product(name: "CodeEditorHighlightingCore", package:)` labels become
  `package: "CodeEditorKit"`. The consumed product
  (`CodeEditorHighlightingCore`) and this package's own API are unchanged.
  A graph that reaches both the old and the new URL resolves two distinct
  SwiftPM identities exporting the same products and fails to build, so
  dependents must move to a tag containing this change. The dependency's
  lower bound moves to `0.1.0-beta.6`, the first tag published under the
  new name and identity.

## [0.1.0] - 2026-07-14

First tagged release.

- `TreeSitterHighlightProvider`: a Tree-sitter-backed implementation of
  CodeEditorPlugin's view-free `HighlightRangeProviding` contract
  (`CodeEditorHighlightingCore`), covering TreeSitterKit's 14 standard
  languages via `.standard(languageID:)`, with custom-parser injection via
  `init(languageID:parser:)`.
- Pairs with the public external-highlight injection seam released in
  CodeEditorPlugin 0.1.0-beta.3
  (`CodeEditorView.setExternalHighlightProvider(_:)`,
  `EditorController.setExternalHighlightProvider(_:)`,
  `.codeEditorHighlightProvider(_:)`).
- All dependencies resolve by version: CodeEditorPlugin
  `.upToNextMinor(from: "0.1.0-beta.3")`, TreeSitterKit
  `.upToNextMinor(from: "0.2.0")`, LanguageKit
  `.upToNextMinor(from: "0.1.0")`.
- Platform floor: macOS 26.0 / iOS 26.0 (mirrors CodeEditorPlugin).
