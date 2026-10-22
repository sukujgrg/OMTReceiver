import XCTest

final class ReceiverInterfaceTests: XCTestCase {
    @MainActor
    func testLaunchPresentsNativeSourcePicker() {
        let app = XCUIApplication()
        app.launchEnvironment["OMT_UNIT_TESTS"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["manual-address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["OMT Receiver"].exists)
        XCTAssertFalse(app.buttons["disconnect"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "OMT source picker"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Run with an independent official-SDK sender already publishing the test
    /// source. This is an opt-in runtime interoperability and remote-focus check.
    @MainActor
    func testOfficialSourcePlaysFullscreenAndRemoteReturnsToControls() throws {
        guard ProcessInfo.processInfo.environment["OMT_RUN_INTEROP"] == "1" else {
            throw XCTSkip("Use the OMTReceiverInterop scheme with the official SDK fixture publishing OMTReceiver Test Pattern.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["OMT_UNIT_TESTS"] = "0"
        app.launch()
        let predicate = NSPredicate(format: "label CONTAINS %@", "OMTReceiver Test Pattern")
        let source = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 25), "The official sender must be discovered through Bonjour.")
        let remote = XCUIRemote.shared
        // Discovery can finish after initial focus lands on Enter Address.
        // The source list is immediately above that button in the native layout.
        for _ in 0..<8 {
            if source.hasFocus { break }
            remote.press(.up)
        }
        XCTAssertTrue(source.hasFocus, "Remote navigation must reach the source row.")
        guard source.hasFocus else { return }
        remote.press(.select)
        let fullscreen = app.descendants(matching: .any).matching(identifier: "fullscreen-video").firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20), "Real decoded video must reach the display renderer and controls must hide.")
        guard fullscreen.exists else { return }
        XCTAssertFalse(app.buttons["disconnect"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Official OMT stream full screen"
        shot.lifetime = .keepAlways
        add(shot)
        remote.press(.menu)
        XCTAssertTrue(app.buttons["disconnect"].waitForExistence(timeout: 5), "Back must restore operable controls from full screen.")
        remote.press(.menu)
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5), "Back must return to full screen while playing.")
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["disconnect"].waitForExistence(timeout: 5), "Play/Pause must also restore controls.")
        XCTAssertTrue(app.staticTexts["receiver-statistics"].exists)
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "Official OMT playback controls and statistics"
        controls.lifetime = .keepAlways
        add(controls)
    }
}
