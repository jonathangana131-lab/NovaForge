import XCTest

final class VoltlineGameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRideHUDAndControlsExist() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich"]
        app.launch()

        XCTAssertTrue(app.otherElements["scooterDashboard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["phoneButton"].exists)
        XCTAssertTrue(app.buttons["garageButton"].exists)
        XCTAssertTrue(app.otherElements["throttlePedal"].exists)
        XCTAssertTrue(app.otherElements["brakePedal"].exists)
        XCTAssertTrue(app.otherElements["steeringPad"].exists)
        attachScreenshot(name: "01-ride-hud")
    }

    func testSettingsFixtureCanOpenAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich"]
        app.launch()

        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()
        XCTAssertTrue(app.otherElements["settingsOverlay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeSettingsButton"].exists)
        attachScreenshot(name: "06-settings")
        app.buttons["closeSettingsButton"].tap()
        XCTAssertFalse(app.otherElements["settingsOverlay"].waitForExistence(timeout: 3))
    }

    func testGarageFixture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-garage"]
        app.launch()

        XCTAssertTrue(app.otherElements["garageOverlay"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["closeGarageButton"].exists)
        attachScreenshot(name: "02-garage")
    }

    func testPhoneAndBankFixture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-bank"]
        app.launch()

        XCTAssertTrue(app.otherElements["phoneOS"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["bankPhoneApp"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closePhoneButton"].exists)
        attachScreenshot(name: "03-phone-bank")
    }

    func testVESCFixtureAndWriteButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-rich", "--qa-vesc"]
        app.launch()

        XCTAssertTrue(app.otherElements["phoneOS"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["vescPhoneApp"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["writeVESCButton"].exists)
        attachScreenshot(name: "04-phone-vesc")
    }

    func testCrashFixtureCanReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-crash"]
        app.launch()

        let reset = app.buttons["resetCrashButton"]
        XCTAssertTrue(reset.waitForExistence(timeout: 15))
        attachScreenshot(name: "05-crash")
        reset.tap()
        XCTAssertFalse(reset.waitForExistence(timeout: 3))
    }

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
