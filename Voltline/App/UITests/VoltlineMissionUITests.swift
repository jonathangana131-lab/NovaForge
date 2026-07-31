import XCTest

final class VoltlineMissionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMissionBoardFitsAndStartsTunnelRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-mission", "--qa-controls"]
        app.launch()

        let board = element("missionBoard", in: app)
        XCTAssertTrue(board.waitForExistence(timeout: 15))

        let routeButton = element("missionStartButton-tunnel-line", in: app)
        XCTAssertTrue(routeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(routeButton.isHittable)
        attachScreenshot(name: "07-mission-board")

        routeButton.tap()
        XCTAssertFalse(board.waitForExistence(timeout: 5))

        let missionHUD = element("missionHUD", in: app)
        let throttle = element("throttlePedal", in: app)
        let speedTelemetry = element("qaSpeedMPH", in: app)
        XCTAssertTrue(missionHUD.waitForExistence(timeout: 5))
        XCTAssertTrue(throttle.waitForExistence(timeout: 5))
        XCTAssertTrue(speedTelemetry.waitForExistence(timeout: 5))

        let highThrottle = throttle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)
        )
        highThrottle.press(forDuration: 1.6)

        let speedRose = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return Double(element.label) ?? 0 > 0.5
        }
        expectation(
            for: speedRose,
            evaluatedWith: speedTelemetry,
            handler: nil
        )
        waitForExpectations(timeout: 8)

        attachScreenshot(name: "08-mission-hud-driving")
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
