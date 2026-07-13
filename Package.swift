// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

/// CodeEditorTreeSitter Package Configuration
///
/// A Tree-sitter-backed syntax-highlighting provider for CodeEditorPlugin's
/// view-free `CodeEditorHighlightingCore` contracts.
///
/// ## Why a separate package
///
/// `TreeSitterHighlightProvider` implements `HighlightRangeProviding` on top of
/// TreeSitterKit's grammar graph (SwiftTreeSitter + ~14 pinned C grammars).
/// Keeping it out of CodeEditorPlugin means ordinary CodeEditor consumers do
/// not resolve or compile that grammar dependency graph — only apps that opt
/// into tree-sitter highlighting depend on this package.
///
/// ## Requirements
///
/// - **Swift**: 6.3 or later (Swift 6 language mode, strict concurrency).
/// - **Platforms** (mirrors CodeEditorPlugin): macOS 26.3+, iOS 26.3+.
///
/// ## Dependency pinning (deliberate — see README)
///
/// - `CodeEditorPlugin` is consumed by **branch** (`main`): it cannot be
///   consumed by version because SwiftPM rejects stable-version deps on a
///   package that itself has branch/revision-pinned dependencies.
/// - `TreeSitterKit` is consumed by **exact revision** (the commit tag `0.1.0`
///   points at): its grammar dependencies are exact revisions, so it likewise
///   cannot be resolved through a stable-version dep.
/// - `LanguageKit` is a normal semver dep.
///
/// Everything is consumed by URL — no `.package(path:)` — so the package
/// builds standalone from a fresh clone.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "CodeEditorTreeSitter",
    platforms: [.macOS("26.3"), .iOS("26.3")],
    products: [
        .library(
            name: "CodeEditorTreeSitter",
            targets: ["CodeEditorTreeSitter"]
        )
    ],
    dependencies: [
        // Consumed by branch: CodeEditorPlugin has branch/revision-pinned
        // dependencies (a swift-snapshot-testing fork), so SwiftPM will not
        // resolve it via a stable-version requirement.
        .package(url: "https://github.com/ajmcclary/CodeEditorPlugin.git", branch: "main"),
        // Consumed by exact revision: the commit tag 0.1.0 points at. Its
        // grammar pins are exact revisions, so it must be consumed by
        // revision, never by version (documented in TreeSitterKit's README).
        .package(
            url: "https://github.com/ajmcclary/TreeSitterKit.git",
            revision: "b6f181766b48c7416d50874ae0a84af333ad0097"
        ),
        .package(url: "https://github.com/ajmcclary/LanguageKit.git", .upToNextMinor(from: "0.1.0"))
    ],
    targets: [
        .target(
            name: "CodeEditorTreeSitter",
            dependencies: [
                .product(name: "CodeEditorHighlightingCore", package: "CodeEditorPlugin"),
                .product(name: "TreeSitterCore", package: "TreeSitterKit"),
                .product(name: "TreeSitterStandardLanguages", package: "TreeSitterKit"),
                .product(name: "LanguageKit", package: "LanguageKit")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CodeEditorTreeSitterTests",
            dependencies: [
                "CodeEditorTreeSitter",
                .product(name: "CodeEditorHighlightingCore", package: "CodeEditorPlugin"),
                .product(name: "TreeSitterCore", package: "TreeSitterKit"),
                .product(name: "TreeSitterStandardLanguages", package: "TreeSitterKit"),
                .product(name: "TreeSitterTestSupport", package: "TreeSitterKit"),
                .product(name: "LanguageKit", package: "LanguageKit")
            ],
            swiftSettings: swiftSettings
        )
    ]
)
