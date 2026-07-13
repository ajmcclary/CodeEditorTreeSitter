import Foundation
import LanguageKit

/// Errors thrown while constructing a ``TreeSitterHighlightProvider``.
public enum TreeSitterHighlightProviderError: Error, Hashable, Sendable, LocalizedError {
    /// The requested language has no tree-sitter highlight support in the
    /// backing parser (no registration, or a registration without a highlight
    /// query). Thrown from the provider initializers so an unsupported
    /// language fails fast at construction rather than silently producing no
    /// highlights at query time.
    case unsupportedLanguage(LanguageID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language):
            return "No tree-sitter highlight support for language: \(language.rawValue)"
        }
    }
}
