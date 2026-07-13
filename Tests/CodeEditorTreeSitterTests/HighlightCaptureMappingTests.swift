import Testing
@testable import CodeEditorTreeSitter

/// Pins the capture-name → token-type mapping table. If a tree-sitter capture
/// name changes category, one of these assertions fails — the mapping is the
/// package's contract with the editor's styling vocabulary.
@Suite struct HighlightCaptureMappingTests {
    typealias Raw = HighlightCaptureMapping.TokenTypeRawValue

    @Test func exactBaseCategories() {
        #expect(HighlightCaptureMapping.tokenType(forCapture: "keyword") == Raw.keyword)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "comment") == Raw.comment)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "string") == Raw.string)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "number") == Raw.number)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "type") == Raw.type)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "function") == Raw.function)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "property") == Raw.property)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "operator") == Raw.operator)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "punctuation") == Raw.punctuation)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "variable") == Raw.identifier)
    }

    @Test func dottedNamesFoldToBaseCategory() {
        #expect(HighlightCaptureMapping.tokenType(forCapture: "keyword.return") == Raw.keyword)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "keyword.function") == Raw.keyword)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "function.builtin") == Raw.function)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "function.call") == Raw.function)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "string.escape") == Raw.string)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "string.regex") == Raw.string)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "comment.documentation") == Raw.comment)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "type.builtin") == Raw.type)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "punctuation.bracket") == Raw.punctuation)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "punctuation.delimiter") == Raw.punctuation)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "variable.parameter") == Raw.identifier)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "constant.builtin") == Raw.keyword)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "boolean") == Raw.keyword)
    }

    @Test func fullNameOverrides() {
        // A word operator is an operator, not a keyword, despite the base.
        #expect(HighlightCaptureMapping.tokenType(forCapture: "keyword.operator") == Raw.operator)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "definition.function") == Raw.function)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "definition.method") == Raw.function)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "definition.class") == Raw.type)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "definition.interface") == Raw.type)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "definition.module") == Raw.type)
    }

    @Test func unknownCapturesFallBackToIdentifier() {
        #expect(HighlightCaptureMapping.tokenType(forCapture: "totally_made_up") == Raw.identifier)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "xyz.abc") == Raw.identifier)
        #expect(HighlightCaptureMapping.fallbackTokenType == Raw.identifier)
    }

    @Test func droppedCapturesMapToNil() {
        #expect(HighlightCaptureMapping.tokenType(forCapture: "none") == nil)
        #expect(HighlightCaptureMapping.tokenType(forCapture: "spell") == nil)
    }

    /// Every base segment observed across the bundled standard-language
    /// highlight queries resolves to a non-nil, non-empty token type (except
    /// the two intentionally dropped ones). Guards against a base falling
    /// through unnoticed.
    @Test func observedCaptureNamesAreTotal() {
        let observed = [
            "attribute", "boolean", "comment", "comment.documentation", "conditional",
            "constant", "constant.builtin", "constant.null", "constructor",
            "definition.class", "definition.function", "definition.interface",
            "definition.method", "definition.module", "delimiter", "embedded", "escape",
            "float", "function", "function.builtin", "function.call", "function.macro",
            "function.method", "function.special", "identifier.constant",
            "identifier.parameter", "include", "keyword", "keyword.function",
            "keyword.operator", "keyword.return", "label", "local.definition", "method",
            "module", "number", "operator", "parameter", "property", "property.definition",
            "punctuation.bracket", "punctuation.delimiter", "punctuation.special",
            "reference.class", "reference.type", "repeat", "string", "string.escape",
            "string.regex", "string.special", "string.special.symbol", "type",
            "type.builtin", "variable", "variable.builtin", "variable.parameter"
        ]
        for name in observed {
            let mapped = HighlightCaptureMapping.tokenType(forCapture: name)
            #expect(mapped != nil, "capture \(name) unexpectedly dropped")
            #expect(mapped?.isEmpty == false, "capture \(name) mapped to empty string")
        }
    }
}
