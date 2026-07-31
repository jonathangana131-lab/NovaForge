import XCTest

final class VoltlineGameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstRunOnboardingFitsAndStarts() throws {
        let app = launch(arguments: ["--qa-onboarding"])

        let onboarding = element("onboardingOverlay", in: app)
        let startButton = element("startRidingButton", in: app)
        XCTAssertTrue(onboarding.waitForExistence(timeout: 15))
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertTrue(startButton.isHittable)
        attachScreenshot(name: "00-onboarding")

        startButton.tap()
        XCTAssertFalse(onboarding.waitForExistence(timeout: 5))
        XCTAssertTrue(element("scooterDashboard", in: app).waitForExistence(timeout: 10))
    }

    func testRideHUDAndControlsExist() throws {
        let app = launch(arguments: ["--qa-rich"])

        XCTAssertTrue(element("scooterDashboard", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("phoneButton", in: app).exists)
        XCTAssertTrue(element("garageButton", in: app).exists)
        XCTAssertTrue(element("throttlePedal", in: app).exists)
        XCTAssertTrue(element("brakePedal", in: app).exists)
        XCTAssertTrue(element("steeringPad", in: app).exists)
        attachScreenshot(name: "01-ride-hud")
    }

    func testSettingsFixtureCanOpenAndClose() throws {
        let app = launch(arguments: ["--qa-rich"])

        let settingsButton = element("settingsButton", in: app)
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()

        let overlay = element("settingsOverlay", in: app)
        let closeButton = element("closeSettingsButton", in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(closeButton.exists)
        attachScreenshot(name: "06-settings")
        closeButton.tap()
        XCTAssertFalse(overlay.waitForExistence(timeout: 3))
    }

    func testGarageFixture() throws {
        let app = launch(arguments: ["--qa-rich", "--qa-garage"])

        XCTAssertTrue(element("garageOverlay", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("closeGarageButton", in: app).exists)
        attachScreenshot(name: "02-garage")
    }

    func testPhoneAndBankFixture() throws {
        let app = launch(arguments: ["--qa-rich", "--qa-bank"])

        XCTAssertTrue(element("phoneOS", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("bankPhoneApp", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("closePhoneButton", in: app).exists)
        attachScreenshot(name: "03-phone-bank")
    }

    func testVESCFixtureAndWriteButton() throws {
        let app = launch(arguments: ["--qa-rich", "--qa-vesc"])

        XCTAssertTrue(element("phoneOS", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("vescPhoneApp", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("writeVESCButton", in: app).exists)
        attachScreenshot(name: "04-phone-vesc")
    }

    func testCrashFixtureCanReset() throws {
        let app = launch(arguments: ["--qa-crash"])

        let reset = element("resetCrashButton", in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 15))
        attachScreenshot(name: "05-crash")
        reset.tap()
        XCTAssertFalse(reset.waitForExistence(timeout: 3))
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// SwiftUI can expose the same accessibility identifier as a button,
    /// container, or generic element depending on view composition and SDK.
    /// Querying all descendants keeps tests tied to the identifier rather than
    /// an implementation-specific accessibility element type.
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
