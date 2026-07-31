import XCTest

final class VoltlineAuthenticDisplayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAllPhysicalDisplayAcceptanceStates() throws {
        let fixtures: [(argument: String, identifier: String, screenshot: String)] = [
            ("--qa-display-maxshot-eco", "acceptance-maxshot-v1s-pro", "10-maxshot-eco"),
            ("--qa-display-maxshot-drive", "acceptance-maxshot-v1s-pro", "11-maxshot-drive"),
            ("--qa-display-maxshot-sport", "acceptance-maxshot-v1s-pro", "12-maxshot-sport"),
            ("--qa-display-maxshot-critical", "acceptance-maxshot-v1s-pro", "13-maxshot-critical"),
            ("--qa-display-kukirin", "acceptance-kukirin-g2-master", "14-kukirin-g2-master"),
            ("--qa-display-dualtron", "acceptance-dualtron-thunder-3", "15-dualtron-thunder-3-ey4")
        ]

        for fixture in fixtures {
            let app = launch(arguments: [fixture.argument])
            XCTAssertTrue(element("displayAcceptanceGallery", in: app).waitForExistence(timeout: 15))
            XCTAssertTrue(element(fixture.identifier, in: app).waitForExistence(timeout: 5))
            attachScreenshot(name: fixture.screenshot)
            app.terminate()
        }
    }

    func testDisplaysAreMountedInFirstPersonCockpits() throws {
        let fixtures: [(argument: String, screenshot: String)] = [
            ("--qa-cockpit-maxshot", "16-cockpit-maxshot"),
            ("--qa-cockpit-kukirin", "17-cockpit-kukirin"),
            ("--qa-cockpit-dualtron", "18-cockpit-dualtron")
        ]

        for fixture in fixtures {
            let app = launch(arguments: ["--qa-rich", fixture.argument])
            XCTAssertTrue(element("catalogFirstPersonCockpit", in: app).waitForExistence(timeout: 15))
            XCTAssertTrue(element("throttlePedal", in: app).waitForExistence(timeout: 5))
            attachScreenshot(name: fixture.screenshot)
            app.terminate()
        }
    }

    func testPhoneOS27OpensMinimizesAndRestores() throws {
        let app = launch(arguments: ["--qa-rich"])
        let phoneButton = element("phoneButton", in: app)
        XCTAssertTrue(phoneButton.waitForExistence(timeout: 15))
        phoneButton.tap()

        XCTAssertTrue(element("phoneOS", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("minimizePhoneButton", in: app).waitForExistence(timeout: 5))
        attachScreenshot(name: "19-phoneos27-home")

        element("minimizePhoneButton", in: app).tap()
        let restore = element("restorePhoneButton", in: app)
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        attachScreenshot(name: "20-phoneos27-minimized")

        restore.tap()
        XCTAssertTrue(element("phoneOS", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("closePhoneButton", in: app).waitForExistence(timeout: 5))
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
