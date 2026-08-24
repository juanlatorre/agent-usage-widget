import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct OpenCodeProfileParserTests {

    @Test func parsesPreferredKeyShape() throws {
        let data = Data(#"{"opencode-go":{"type":"api","key":"sk-abc123"}}"#.utf8)
        let credentials = try OpenCodeAuthParser.parse(data: data)
        #expect(credentials.apiKey == "sk-abc123")
    }

    @Test func parsesAlternativeApiKeySpelling() throws {
        let data = Data(#"{"opencode-go":{"apiKey":"sk-alt"}}"#.utf8)
        let credentials = try OpenCodeAuthParser.parse(data: data)
        #expect(credentials.apiKey == "sk-alt")
    }

    @Test func toleratesExtraProviderEntries() throws {
        let data = Data(#"""
        {"zai-coding-plan":{"key":"z"},"opencode-go":{"key":"sk-go"},"openai":{"refresh":"r"}}
        """#.utf8)
        let credentials = try OpenCodeAuthParser.parse(data: data)
        #expect(credentials.apiKey == "sk-go")
    }

    @Test func rejectsMissingOpenCodeGO() {
        let data = Data(#"{"other":{"key":"x"}}"#.utf8)
        #expect(throws: OpenCodeAuthParser.ParseError.missingOpenCodeGO) {
            _ = try OpenCodeAuthParser.parse(data: data)
        }
    }

    @Test func rejectsMissingKeyInsideEntry() {
        let data = Data(#"{"opencode-go":{"type":"api"}}"#.utf8)
        #expect(throws: OpenCodeAuthParser.ParseError.missingAPIKey) {
            _ = try OpenCodeAuthParser.parse(data: data)
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: OpenCodeAuthParser.ParseError.invalidJSON) {
            _ = try OpenCodeAuthParser.parse(data: Data("}".utf8))
        }
    }

    @Test func rejectsWhitespaceOnlyKey() {
        let data = Data(#"{"opencode-go":{"key":"   "}}"#.utf8)
        #expect(throws: OpenCodeAuthParser.ParseError.missingAPIKey) {
            _ = try OpenCodeAuthParser.parse(data: data)
        }
    }

    @Test func rejectsKeyWithInteriorWhitespace() {
        let data = Data(#"{"opencode-go":{"key":"sk abc"}}"#.utf8)
        #expect(throws: OpenCodeAuthParser.ParseError.missingAPIKey) {
            _ = try OpenCodeAuthParser.parse(data: data)
        }
    }

    @Test func trimsNewlinesFromKey() throws {
        let data = Data(#"{"opencode-go":{"key":"  sk-trim \n"}}"#.utf8)
        let credentials = try OpenCodeAuthParser.parse(data: data)
        #expect(credentials.apiKey == "sk-trim")
    }
}
