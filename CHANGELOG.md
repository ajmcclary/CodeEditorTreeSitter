# Changelog

All notable changes to CodeEditorTreeSitter are documented in this file.

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
