import Foundation

/// Translates TreeSitterKit highlight-query capture names into the raw token
/// type strings a ``CodeEditorHighlightingCore/HighlightToken`` carries.
///
/// ## Vocabulary
///
/// The emitted strings are the raw values of CodeEditorPlugin's internal
/// `TokenType` enum (`keyword`, `identifier`, `string`, `number`, `comment`,
/// `type`, `function`, `property`, `operator`, `punctuation`, `whitespace`,
/// `preprocessor`, `unknown`). CodeEditorPlugin's editor bridge maps a
/// ``HighlightToken/tokenType`` back to that enum with
/// `TokenType(rawValue:) ?? .identifier`, so emitting these exact strings lets
/// the editor style tree-sitter tokens with no extra adapter. We do **not**
/// import the enum (it lives in a UI-heavy product); the strings are pinned by
/// the `TokenTypeRawValue` constants below and by the package's tests.
///
/// ## Totality
///
/// The mapping is total. Tree-sitter capture names are dotted, hierarchical
/// (`function.builtin`, `string.escape`, `keyword.return`). Resolution order:
///
/// 1. A small set of full-name overrides (where the dotted suffix changes the
///    category, e.g. `keyword.operator` → `operator`).
/// 2. The capture's base segment (text before the first `.`) looked up in
///    ``baseCategories``.
/// 3. The documented fallback ``fallbackTokenType`` (`identifier`) — the same
///    fallback CodeEditorPlugin's bridge uses for unrecognized raw values, so
///    an unknown capture is styled as a plain identifier rather than dropped.
///
/// Two capture names are deliberately dropped (mapped to `nil`): `none` and
/// `spell`. `@none` is tree-sitter's explicit "apply no highlight" marker and
/// `@spell` marks prose regions for spell-checking, not syntax coloring;
/// emitting a styled token for either would miscolor the text.
public enum HighlightCaptureMapping {
    /// Raw token type strings, mirroring CodeEditorPlugin's `TokenType`
    /// raw values. Pinned so a rename on either side is caught by tests.
    public enum TokenTypeRawValue {
        public static let keyword = "keyword"
        public static let identifier = "identifier"
        public static let string = "string"
        public static let number = "number"
        public static let comment = "comment"
        public static let type = "type"
        public static let function = "function"
        public static let property = "property"
        public static let `operator` = "operator"
        public static let punctuation = "punctuation"
        public static let preprocessor = "preprocessor"
    }

    /// The token type used for a capture whose name (and base segment) is not
    /// otherwise recognized. Matches the editor bridge's own fallback.
    public static let fallbackTokenType = TokenTypeRawValue.identifier

    /// Capture names that intentionally produce no token.
    ///
    /// `@none` is the explicit "no highlight" capture; `@spell` marks prose for
    /// spell-checking rather than syntax coloring.
    static let droppedCaptures: Set<String> = ["none", "spell"]

    /// Full capture names whose category differs from their base segment.
    static let fullNameOverrides: [String: String] = [
        // A word operator (`and`, `or`, `in`, `is`) is an operator, not a keyword.
        "keyword.operator": TokenTypeRawValue.operator,
        // `@definition.*` / `@reference.*` locals captures: split type-like from
        // function-like so they land on a sensible category.
        "definition.function": TokenTypeRawValue.function,
        "definition.method": TokenTypeRawValue.function,
        "definition.class": TokenTypeRawValue.type,
        "definition.interface": TokenTypeRawValue.type,
        "definition.module": TokenTypeRawValue.type
    ]

    /// Base capture segment (text before the first `.`) → token type.
    ///
    /// Covers every base segment observed across the bundled standard-language
    /// highlight queries. Anything not listed here falls through to
    /// ``fallbackTokenType``.
    static let baseCategories: [String: String] = [
        // Keywords and keyword-like control words / literals.
        "keyword": TokenTypeRawValue.keyword,
        "conditional": TokenTypeRawValue.keyword,
        "repeat": TokenTypeRawValue.keyword,
        "include": TokenTypeRawValue.keyword,
        "label": TokenTypeRawValue.keyword,
        "boolean": TokenTypeRawValue.keyword,
        "constant": TokenTypeRawValue.keyword,

        // Comments.
        "comment": TokenTypeRawValue.comment,

        // Strings, escapes, and character literals.
        "string": TokenTypeRawValue.string,
        "escape": TokenTypeRawValue.string,
        "character": TokenTypeRawValue.string,

        // Numeric literals.
        "number": TokenTypeRawValue.number,
        "float": TokenTypeRawValue.number,

        // Types, modules, and constructors.
        "type": TokenTypeRawValue.type,
        "constructor": TokenTypeRawValue.type,
        "module": TokenTypeRawValue.type,
        "namespace": TokenTypeRawValue.type,
        "reference": TokenTypeRawValue.type,

        // Functions and methods.
        "function": TokenTypeRawValue.function,
        "method": TokenTypeRawValue.function,

        // Members / fields.
        "property": TokenTypeRawValue.property,
        "field": TokenTypeRawValue.property,

        // Operators.
        "operator": TokenTypeRawValue.operator,

        // Punctuation / delimiters.
        "punctuation": TokenTypeRawValue.punctuation,
        "delimiter": TokenTypeRawValue.punctuation,
        "bracket": TokenTypeRawValue.punctuation,

        // Preprocessor / annotations / decorators / embedded directives.
        "attribute": TokenTypeRawValue.preprocessor,
        "preprocessor": TokenTypeRawValue.preprocessor,

        // Variables, parameters, and locals resolve to identifier — the same
        // as the fallback, but listed for clarity/auditability.
        "variable": TokenTypeRawValue.identifier,
        "parameter": TokenTypeRawValue.identifier,
        "identifier": TokenTypeRawValue.identifier,
        "local": TokenTypeRawValue.identifier,
        "embedded": TokenTypeRawValue.identifier
    ]

    /// Resolves a tree-sitter capture name to a token type raw string.
    ///
    /// - Parameter capture: A capture name **without** the leading `@` (as
    ///   ``TreeSitterCore/SyntaxCapture/name`` provides it), e.g. `"keyword"`,
    ///   `"function.builtin"`, `"string.escape"`.
    /// - Returns: The token type raw string, or `nil` for the deliberately
    ///   dropped captures (`none`, `spell`). Never returns `nil` for any other
    ///   input — unrecognized names resolve to ``fallbackTokenType``.
    public static func tokenType(forCapture capture: String) -> String? {
        if droppedCaptures.contains(capture) {
            return nil
        }
        if let override = fullNameOverrides[capture] {
            return override
        }
        let base = capture.prefix { $0 != "." }
        if let category = baseCategories[String(base)] {
            return category
        }
        return fallbackTokenType
    }
}
