import XCTest

final class VoltlineMissionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMissionBoardFitsAndStartsTunnelRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-mission"]
        app.launch()

        let board = element("missionBoard", in: app)
        XCTAssertTrue(board.waitForExistence(timeout: 15))

        let routeButton = element("missionStartButton-tunnel-line", in: app)
        XCTAssertTrue(routeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(routeButton.isHittable)
        attachScreenshot(name: "07-mission-board")

        routeButton.tap()
        XCTAssertFalse(board.waitForExistence(timeout: 5))
        XCTAssertTrue(element("missionHUD", in: app).waitForExistence(timeout: 5))
        attachScreenshot(name: "08-mission-hud")
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
