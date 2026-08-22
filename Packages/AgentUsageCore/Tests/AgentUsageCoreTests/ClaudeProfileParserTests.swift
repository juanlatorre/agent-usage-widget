import Testing
import Foundation
@testable import AgentUsageCore

/// Parser tests for Claude Code's `claudeAiOauth` credential shape (child spec R2).
@Suite struct ClaudeProfileParserTests {

    @Test func parsesWellFormedCredentials() throws {
        let json = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat01-token",
                           "accountUuid": "11111111-2222-3333-4444-555555555555"},
         "customApiKeyResponses": {}}
        """
        let credentials = try ClaudeCredentialsParser.parse(data: Data(json.utf8))
        #expect(credentials.accessToken == "sk-ant-oat01-token")
        #expect(credentials.accountUUID == "11111111-2222-3333-4444-555555555555")
    }

    @Test func toleratesUnknownKeysAndSnakeCase() throws {
        let json = """
        {"unknownTop": 1,
         "claudeAiOauth": {"access_token": "tok", "account_uuid": "u-1",
                           "refreshToken": "r", "expire": "2030-01-01T00:00:00Z"}}
        """
        let credentials = try ClaudeCredentialsParser.parse(data: Data(json.utf8))
        #expect(credentials.accessToken == "tok")
        #expect(credentials.accountUUID == "u-1")
    }

    @Test func rejectsNonJSONAndMissingOAuthObject() {
        #expect(throws: ClaudeCredentialsParser.ParseError.invalidJSON) {
            _ = try ClaudeCredentialsParser.parse(data: Data("not json".utf8))
        }
        #expect(throws: ClaudeCredentialsParser.ParseError.missingClaudeOAuth) {
            _ = try ClaudeCredentialsParser.parse(data: Data("{\"other\": {}}".utf8))
        }
    }

    @Test func rejectsMissingEmptyWhitespaceTokens() {
        let malformed: [String] = [
            "{}",
            "{\"accessToken\": null}",
            "{\"accessToken\": \"\"}",
            "{\"accessToken\": \"   \"}",
            "{\"accessToken\": \"abc def\"}",
            "{\"accessToken\": 42}"
        ]
        for oauthJSON in malformed {
            let json = "{\"claudeAiOauth\": \(oauthJSON)}"
            #expect(throws: ClaudeCredentialsParser.ParseError.missingAccessToken) {
                _ = try ClaudeCredentialsParser.parse(data: Data(json.utf8))
            }
        }
    }

    @Test func absentIdentityIsToleratedBlankIdentityIsAbsent() throws {
        let withoutUUID = try ClaudeCredentialsParser.parse(
            data: Data("{\"claudeAiOauth\": {\"accessToken\": \"t\"}}".utf8))
        #expect(withoutUUID.accountUUID == nil)

        let blankUUID = try ClaudeCredentialsParser.parse(
            data: Data("{\"claudeAiOauth\": {\"accessToken\": \"t\", \"accountUuid\": \"  \"}}".utf8))
        #expect(blankUUID.accountUUID == nil)
    }
}
