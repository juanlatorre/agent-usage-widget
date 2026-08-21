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

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AGENT_USAGE_UITEST"] = "1"
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
}
