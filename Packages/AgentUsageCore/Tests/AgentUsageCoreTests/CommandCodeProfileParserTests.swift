import Testing
import Foundation
@testable import AgentUsageCore

@Suite struct CommandCodeProfileParserTests {

    @Test func parsesApiKeyShape() throws {
        let data = Data(#"{"apiKey":"user_abc","userId":"u1"}"#.utf8)
        let c = try CommandCodeAuthParser.parse(data: data)
        #expect(c.apiKey == "user_abc")
    }

    @Test func parsesSnakeCaseFallback() throws {
        let data = Data(#"{"api_key":"user_xyz"}"#.utf8)
        let c = try CommandCodeAuthParser.parse(data: data)
        #expect(c.apiKey == "user_xyz")
    }

    @Test func trimsWhitespace() throws {
        let data = Data(#"{"apiKey":"  user_trim \n"}"#.utf8)
        let c = try CommandCodeAuthParser.parse(data: data)
        #expect(c.apiKey == "user_trim")
    }

    @Test func rejectsMissingKey() {
        #expect(throws: CommandCodeAuthParser.ParseError.missingAPIKey) {
            _ = try CommandCodeAuthParser.parse(data: Data(#"{"userId":"u1"}"#.utf8))
        }
    }

    @Test func rejectsEmptyOrWhitespaceKey() {
        #expect(throws: (any Error).self) {
            _ = try CommandCodeAuthParser.parse(data: Data(#"{"apiKey":""}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try CommandCodeAuthParser.parse(data: Data(#"{"apiKey":"   "}"#.utf8))
        }
    }

    @Test func rejectsKeyWithInteriorWhitespace() {
        #expect(throws: (any Error).self) {
            _ = try CommandCodeAuthParser.parse(data: Data(#"{"apiKey":"user bad"}"#.utf8))
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: CommandCodeAuthParser.ParseError.invalidJSON) {
            _ = try CommandCodeAuthParser.parse(data: Data("}".utf8))
        }
    }

    @Test func toleratesExtraFields() throws {
        let data = Data(#"{"apiKey":"user_ok","extra":99,"nested":{"a":1}}"#.utf8)
        let c = try CommandCodeAuthParser.parse(data: data)
        #expect(c.apiKey == "user_ok")
    }
}
