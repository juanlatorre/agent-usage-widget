import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct ZaiProfileParserTests {

    @Test func parsesOpencodeShape() throws {
        let data = Data(#"{"zai-coding-plan":{"type":"api","key":"tok123"}}"#.utf8)
        let c = try ZaiAuthParser.parse(data: data)
        #expect(c.apiKey == "tok123")
    }

    @Test func parsesApiKeyFallback() throws {
        let data = Data(#"{"zai-coding-plan":{"apiKey":"tok-alt"}}"#.utf8)
        let c = try ZaiAuthParser.parse(data: data)
        #expect(c.apiKey == "tok-alt")
    }

    @Test func parsesStringShape() throws {
        let data = Data(#"{"zai-coding-plan":"tok-str"}"#.utf8)
        let c = try ZaiAuthParser.parse(data: data)
        #expect(c.apiKey == "tok-str")
    }

    @Test func rejectsMissingEntry() {
        #expect(throws: ZaiAuthParser.ParseError.missingZaiEntry) {
            _ = try ZaiAuthParser.parse(data: Data(#"{"other":{}}"#.utf8))
        }
    }

    @Test func rejectsMissingKey() {
        #expect(throws: ZaiAuthParser.ParseError.missingAPIKey) {
            _ = try ZaiAuthParser.parse(data: Data(#"{"zai-coding-plan":{"type":"api"}}"#.utf8))
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: ZaiAuthParser.ParseError.invalidJSON) {
            _ = try ZaiAuthParser.parse(data: Data("}".utf8))
        }
    }

    @Test func rejectsKeyWithInteriorWhitespace() {
        #expect(throws: (any Error).self) {
            _ = try ZaiAuthParser.parse(data: Data(#"{"zai-coding-plan":{"key":"tok bad"}}"#.utf8))
        }
    }

    @Test func toleratesExtraProviders() throws {
        let data = Data(#"{"openai":{"key":"x"},"zai-coding-plan":{"key":"tok-keep"},"opencode-go":{"key":"y"}}"#.utf8)
        let c = try ZaiAuthParser.parse(data: data)
        #expect(c.apiKey == "tok-keep")
    }
}
