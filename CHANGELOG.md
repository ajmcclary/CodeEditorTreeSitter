# Changelog

All notable changes to CodeEditorTreeSitter are documented in this file.

The `0.1.0` entry below deliberately keeps the name `CodeEditorPlugin` — that is
what the dependency was called when `0.1.0` shipped.

## [Unreleased]

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
