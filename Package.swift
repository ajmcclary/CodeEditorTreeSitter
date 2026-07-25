// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

/// CodeEditorTreeSitter Package Configuration
///
/// A Tree-sitter-backed syntax-highlighting provider for CodeEditorKit's
/// view-free `CodeEditorHighlightingCore` contracts.
///
/// ## Why a separate package
///
/// `TreeSitterHighlightProvider` implements `HighlightRangeProviding` on top of
/// TreeSitterKit's grammar graph (SwiftTreeSitter + ~14 pinned C grammars).
/// Keeping it out of CodeEditorKit means ordinary CodeEditor consumers do
/// not resolve or compile that grammar dependency graph — only apps that opt
/// into tree-sitter highlighting depend on this package.
///
/// ## Requirements
///
/// - **Swift**: 6.3 or later (Swift 6 language mode, strict concurrency).
/// - **Platforms** (mirrors CodeEditorKit): macOS 26.0+, iOS 26.0+.
///
/// ## Dependency pinning (deliberate — see README)
///
/// - `CodeEditorKit` is consumed by **version**
///   (`.upToNextMinor(from: "0.1.0-beta.6")`): its former branch-pinned
///   swift-snapshot-testing fork dependency was replaced by an upstream
///   version pin, so SwiftPM now resolves it through a stable-version
///   requirement. `0.1.0-beta.6` is the first tag published under the
///   `CodeEditorKit` name and SwiftPM identity (it was `CodeEditorPlugin` /
///   `codeeditorplugin` through `0.1.0-beta.5`), so the lower bound names it
///   explicitly: an older tag would resolve the same products under the old
///   identity and clash with any dependent that already uses the new URL.
/// - `TreeSitterKit` is a normal semver dep since 0.2.0 (its grammars are
///   vendored at documented revisions, so the package no longer carries
///   revision-pinned dependencies).
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
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(
            name: "CodeEditorTreeSitter",
            targets: ["CodeEditorTreeSitter"]
        )
    ],
    dependencies: [
        // Consumed by version: CodeEditorKit's dependencies are all
        // version-pinned (the swift-snapshot-testing fork was replaced by an
        // upstream version pin), so SwiftPM resolves it by a stable-version
        // requirement.
        .package(url: "https://github.com/ajmcclary/CodeEditorKit.git", .upToNextMinor(from: "0.1.0-beta.6")),
        .package(url: "https://github.com/ajmcclary/TreeSitterKit.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/ajmcclary/LanguageKit.git", .upToNextMinor(from: "0.1.0"))
    ],
    targets: [
        .target(
            name: "CodeEditorTreeSitter",
            dependencies: [
                .product(name: "CodeEditorHighlightingCore", package: "CodeEditorKit"),
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
                .product(name: "CodeEditorHighlightingCore", package: "CodeEditorKit"),
                .product(name: "TreeSitterCore", package: "TreeSitterKit"),
                .product(name: "TreeSitterStandardLanguages", package: "TreeSitterKit"),
                .product(name: "TreeSitterTestSupport", package: "TreeSitterKit"),
                .product(name: "LanguageKit", package: "LanguageKit")
            ],
            swiftSettings: swiftSettings
        )
    ]
)
