# CodeEditorTreeSitter

A Tree-sitter-backed syntax-highlighting provider for
[CodeEditorPlugin](https://github.com/ajmcclary/CodeEditorPlugin)'s view-free
`CodeEditorHighlightingCore` contracts.

`TreeSitterHighlightProvider` conforms to CodeEditorPlugin's
`HighlightRangeProviding` protocol and produces `HighlightToken`s by parsing a
document with [TreeSitterKit](https://github.com/ajmcclary/TreeSitterKit)'s
`SyntaxParser`, running the language's highlight query, and mapping tree-sitter
capture names to the editor's token-type vocabulary.

## Why a separate package

`HighlightRangeProviding` was deliberately designed as a Sendable, view-free,
value-oriented seam so that an external tree-sitter adapter could implement it
without depending on the editor surface. TreeSitterKit pulls in SwiftTreeSitter
and ~14 pinned C grammar packages. Keeping this adapter in its own package means
ordinary CodeEditor consumers never resolve or compile that grammar dependency
graph — only apps that opt into tree-sitter highlighting depend on
`CodeEditorTreeSitter`.

## Requirements

- Swift 6.3+ (Swift 6 language mode, strict concurrency)
- macOS 26.3+, iOS 26.3+ (mirrors CodeEditorPlugin)

## CI status

The dependency repositories (CodeEditorPlugin, TreeSitterKit, LanguageKit,
DesignKit) are private, and the runner's default `GITHUB_TOKEN` is scoped
to this repository only — so the workflow authenticates SwiftPM's git
clones with a read-scoped fine-grained PAT stored as the
`WORKSPACE_READ_PAT` repository secret (an `insteadOf` rewrite for
`github.com/ajmcclary`). If that secret is missing (e.g. on a fork), the
dependency clones fail; local `swift build` / `swift test` are unaffected
because your own git credentials have access.

## Installation

Add to your `Package.swift`. Note the deliberate, non-semver pins:

```swift
dependencies: [
    .package(url: "https://github.com/ajmcclary/CodeEditorTreeSitter.git", branch: "main")
]
```

`CodeEditorTreeSitter` itself consumes its dependencies as follows (and any
package depending on it inherits these resolution rules):

```swift
// CodeEditorPlugin: by version — its former branch-pinned swift-snapshot-testing
// fork dependency was replaced by an upstream version pin, so SwiftPM resolves it
// by a stable-version requirement.
.package(url: "https://github.com/ajmcclary/CodeEditorPlugin.git", .upToNextMinor(from: "0.1.0-beta.2")),

// TreeSitterKit: by exact revision (the commit tag 0.1.0 points at) — its
// grammar pins are exact revisions, so it must be consumed by revision.
.package(
    url: "https://github.com/ajmcclary/TreeSitterKit.git",
    revision: "b6f181766b48c7416d50874ae0a84af333ad0097"
),

// LanguageKit: ordinary semver.
.package(url: "https://github.com/ajmcclary/LanguageKit.git", .upToNextMinor(from: "0.1.0"))
```

## Usage

```swift
import CodeEditorTreeSitter
import CodeEditorHighlightingCore
import LanguageKit

// Build a provider for a language backed by the standard grammar set.
let provider = try TreeSitterHighlightProvider.standard(languageID: .swift)

// The editor drives the HighlightRangeProviding pull loop:
let document = HighlightDocumentSnapshot(text: sourceText, languageID: "swift")
await provider.prepare(for: document)

let tokens = try await provider.highlights(
    in: HighlightRange(location: 0, length: document.utf16Length),
    of: document
)
// -> [HighlightToken(range:, tokenType: "keyword" | "string" | ..., text:)]

// After an edit, ask which regions went stale:
let invalidation = await provider.invalidate(for: edit, in: newDocument)
```

The 14 supported languages are TreeSitterKit's standard set: `swift`, `python`,
`javascript`, `typescript`, `tsx`, `c`, `cpp`, `csharp`, `go`, `java`, `rust`,
`dart`, `php`, `ruby`. Constructing a provider for any other language throws
`TreeSitterHighlightProviderError.unsupportedLanguage`.

To back a provider with a custom parser (custom input-size limits or a subset
of languages), use `init(languageID:parser:)` with your own
`SyntaxParser`.

## Token-type mapping

`HighlightToken.tokenType` is a raw string. The provider emits the raw values of
CodeEditorPlugin's internal `TokenType` enum, so the editor's highlight bridge
(`TokenType(rawValue:) ?? .identifier`) styles the tokens directly. The mapping
(`HighlightCaptureMapping.tokenType(forCapture:)`) is total:

| Tree-sitter capture (base or full)                          | Token type    |
|-------------------------------------------------------------|---------------|
| `keyword`, `conditional`, `repeat`, `include`, `label`, `boolean`, `constant*` | `keyword`     |
| `comment*`                                                  | `comment`     |
| `string*`, `escape*`, `character`                           | `string`      |
| `number`, `float`                                           | `number`      |
| `type*`, `constructor`, `module`, `namespace`, `reference*`, `definition.class/interface/module` | `type` |
| `function*`, `method`, `definition.function/method`         | `function`    |
| `property*`, `field`                                        | `property`    |
| `operator`, `keyword.operator`                              | `operator`    |
| `punctuation*`, `delimiter`, `bracket`                      | `punctuation` |
| `attribute*`, `preprocessor`                                | `preprocessor`|
| `variable*`, `parameter`, `identifier*`, `local*`, `embedded` | `identifier`  |
| **any unrecognized name**                                   | `identifier` (fallback) |
| `none`, `spell`                                             | *dropped (no token)* |

`@none` and `@spell` are dropped because they carry no syntax-color intent
(`@none` is tree-sitter's "no highlight" marker; `@spell` marks prose for
spell-checking). Every other unrecognized capture falls back to `identifier` —
the same fallback the editor bridge uses — so nothing is silently lost.

## Invalidation semantics

`invalidate(for:in:)` returns a whole-document invalidation
(`HighlightInvalidation.everything(length:)`) and drops the internal token
cache. This is the simplest correct behavior the contract supports: after any
edit, the next parse re-tokenizes the whole document. The contract lets the
editor re-query only the intersection of the invalidation with the visible
viewport, so over-reporting is safe. Incremental tree-editing (re-highlighting
only the edited span) is intentionally out of scope for v1.

## License

MIT.
