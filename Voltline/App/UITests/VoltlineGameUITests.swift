import XCTest

final class VoltlineGameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRideHUDAndControlsExist() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich"]
        app.launch()

        XCTAssertTrue(app.buttons["phoneButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["garageButton"].exists)
        XCTAssertTrue(element("throttlePedal", in: app).exists)
        XCTAssertTrue(element("brakePedal", in: app).exists)
        XCTAssertTrue(element("steeringPad", in: app).exists)
        attachScreenshot(name: "01-ride-hud")
    }

    func testGarageFixture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-garage"]
        app.launch()

        XCTAssertTrue(app.buttons["closeGarageButton"].waitForExistence(timeout: 20))
        attachScreenshot(name: "02-garage")
    }

    func testPhoneAndBankFixture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-bank"]
        app.launch()

        XCTAssertTrue(app.buttons["closePhoneButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(element("bankPhoneApp", in: app).waitForExistence(timeout: 5))
        attachScreenshot(name: "03-phone-bank")
    }

    func testVESCFixtureAndWriteButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-vesc"]
        app.launch()

        XCTAssertTrue(app.buttons["closePhoneButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["writeVESCButton"].waitForExistence(timeout: 5))
        attachScreenshot(name: "04-phone-vesc")
    }

    func testCrashFixtureCanReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-crash"]
        app.launch()

        let reset = app.buttons["resetCrashButton"]
        XCTAssertTrue(reset.waitForExistence(timeout: 20))
        attachScreenshot(name: "05-crash")
        reset.tap()
        XCTAssertFalse(reset.waitForExistence(timeout: 3))
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
