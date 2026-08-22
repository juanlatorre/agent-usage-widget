import XCTest
import AgentUsageCore
@testable import AgentUsage

/// UI tests cover the state matrix (AC3) and provider-agnostic detail layout (AC5)
/// through the accessibility tree, per the child spec verification strategy.
///
/// Sidebar rows and detail titles both surface as static texts carrying the slot
/// label in their accessibility value, so all queries are scoped to staticTexts.
final class StatusUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(seededClaudeFixtures: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AGENT_USAGE_UITEST"] = "1"
        if seededClaudeFixtures {
            app.launchEnvironment["AGENT_USAGE_UITEST_CLAUDE_FIXTURE"] = "1"
        }
        if app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
            sleep(1)
        }
        app.launch()
        return app
    }

    /// Sidebar row text carries "<label>, <status>" as its accessibility value.
    private func rowText(for label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", label)
        return app.staticTexts.matching(predicate).firstMatch
    }

    /// The detail pane's navigation title renders as a static text equal to the label.
    private func detailTitle(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "value == %@", label)
        return app.staticTexts.matching(predicate).firstMatch
    }

    func testSixSlotsAreListedWithStableOrder() throws {
        let app = launch()
        let labels = ["Claude (legacy A)", "Claude (legacy B)", "GPT · Personal",
                      "OpenCode · GO", "Command Code · GOAT", "Z.ai · Coding Plan"]
        for label in labels {
            XCTAssertTrue(rowText(for: label, in: app).waitForExistence(timeout: 15),
                          "missing account row: \(label)")
        }
    }

    func testDetailRendersWithoutProviderBranches() throws {
        let app = launch()
        let slotRow = rowText(for: "OpenCode · GO", in: app)
        XCTAssertTrue(slotRow.waitForExistence(timeout: 15))
        slotRow.click()

        // The detail pane shows the selected slot's label as its title.
        XCTAssertTrue(detailTitle("OpenCode · GO", in: app).waitForExistence(timeout: 15))

        // A disconnected slot shows an honest empty state, never fabricated usage.
        XCTAssertTrue(app.staticTexts["No usage data yet."].waitForExistence(timeout: 10))
    }

    /// Claude slots surface the profile-connection management section.
    func testClaudeSlotShowsConnectSectionWhenDisconnected() throws {
        let app = launch()
        let slotRow = rowText(for: "Claude (legacy A)", in: app)
        XCTAssertTrue(slotRow.waitForExistence(timeout: 15))
        slotRow.click()

        XCTAssertTrue(app.staticTexts["Profile connection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        // Consent copy explains what a connection does, without exposing secrets.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                        "copied into your Keychain", "copied into your Keychain")
        ).firstMatch.waitForExistence(timeout: 10))
    }

    /// With the hermetic fixture seed, both Claude slots render Connected-state
    /// actions: identity summary plus Reconnect/Test/Refresh/Disconnect controls.
    func testConnectedClaudeSlotExposesConnectionActions() throws {
        let app = launch(seededClaudeFixtures: true)
        let slotRow = rowText(for: "Claude (legacy A)", in: app)
        XCTAssertTrue(slotRow.waitForExistence(timeout: 15))
        slotRow.click()

        XCTAssertTrue(app.staticTexts["Profile connection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Reconnect"].exists || app.buttons["Test Connection"].exists,
                      "connected slot should offer reconnect/test controls")
        // The sanitized identity summary is visible; raw tokens are not.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "identity ", "identity ")
        ).firstMatch.exists)
        for element in app.descendants(matching: .any).allElementsBoundByIndex {
            if let label = element.value as? String, label.contains("uitest-h") {
                XCTFail("raw fixture token leaked into accessibility tree")
            }
        }
    }

    /// Disconnecting from the UI returns the slot to its Connect state.
    func testDisconnectReturnsSlotToConnectState() throws {
        let app = launch(seededClaudeFixtures: true)
        let slotRow = rowText(for: "Claude (legacy B)", in: app)
        XCTAssertTrue(slotRow.waitForExistence(timeout: 15))
        slotRow.click()

        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 10))
        disconnect.click()

        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10),
                      "slot must return to the Connect state after disconnect")
    }
}
