import XCTest

final class ReceiverInterfaceTests: XCTestCase {
    @MainActor
    func testLaunchPresentsNativeSourcePicker() {
        let app = XCUIApplication()
        app.launchEnvironment["OMT_UNIT_TESTS"] = "1"
        XCUIRemote.shared.press(.home)
        app.launch()
        XCTAssertTrue(app.buttons["manual-address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["OMT Receiver"].exists)
        XCTAssertFalse(app.buttons["disconnect"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "OMT source picker"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testPrivacyAndLicencesAreReadableWithRemoteAndReturnToControls() {
        let app = XCUIApplication()
        app.launchEnvironment["OMT_UNIT_TESTS"] = "1"
        app.launch()
        let about = app.buttons["about"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        let remote = XCUIRemote.shared
        for _ in 0..<8 {
            if about.hasFocus { break }
            remote.press(.down)
        }
        XCTAssertTrue(about.hasFocus, "Remote navigation must reach About.")
        guard about.hasFocus else { return }
        remote.press(.select)
        // A native tvOS List focuses its cell, not the NavigationLink's
        // accessibility button inside it.
        let privacy = app.cells.containing(.button, identifier: "information-privacy").firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if privacy.hasFocus { break }
            remote.press(.down)
        }
        if !privacy.hasFocus {
            print("Information focus tree: \(app.debugDescription)")
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "Information focus failure"
            failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertTrue(privacy.hasFocus)
        guard privacy.hasFocus else { return }
        remote.press(.select)
        let document = app.descendants(matching: .any).matching(identifier: "information-privacy-document").firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        let paragraph = app.staticTexts["information-privacy-paragraph-7"]
        XCTAssertFalse(paragraph.isHittable, "The policy footer starts below the visible page.")
        for _ in 0..<12 {
            if paragraph.hasFocus { break }
            remote.press(.down)
        }
        XCTAssertTrue(paragraph.hasFocus, "Remote navigation must scroll to the policy footer.")
        XCTAssertTrue(paragraph.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Readable privacy policy"
        shot.lifetime = .keepAlways
        add(shot)
        remote.press(.menu)
        let licences = app.cells.containing(.button, identifier: "information-licences").firstMatch
        XCTAssertTrue(licences.waitForExistence(timeout: 5), "Back should pop to the information list.")
        for _ in 0..<6 {
            if licences.hasFocus { break }
            remote.press(.down)
        }
        XCTAssertTrue(licences.hasFocus)
        guard licences.hasFocus else { return }
        remote.press(.select)
        let notice = app.descendants(matching: .any).matching(identifier: "information-licences-document").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "MIT License")).firstMatch.exists)
        remote.press(.menu)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        XCTAssertTrue(about.hasFocus, "Dismissing information should restore focus to About.")
        XCTAssertTrue(app.buttons["manual-address"].exists)
        XCTAssertFalse(app.buttons["disconnect"].exists)
    }

    /// Opt-in test with the SDK fixture's genuine interlaced pattern. The normal
    /// scheme has no external sender dependency and skips this check.
    @MainActor
    func testInterlacedPlaybackFieldOrderIsOperableWithTheRemote() throws {
        guard ProcessInfo.processInfo.environment["OMT_RUN_INTEROP"] == "1",
              ProcessInfo.processInfo.environment["OMT_RUN_INTERLACED_INTEROP"] == "1" else {
            throw XCTSkip("Run the interop scheme with OMT_RUN_INTERLACED_INTEROP=1 and an interlaced SDK fixture.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["OMT_UNIT_TESTS"] = "0"
        app.launch()
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OMTReceiver Test Pattern")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 25))
        let remote = XCUIRemote.shared
        for _ in 0..<10 {
            if source.hasFocus { break }
            remote.press(.up)
        }
        XCTAssertTrue(source.hasFocus)
        guard source.hasFocus else { return }
        remote.press(.select)
        let fullscreen = app.descendants(matching: .any).matching(identifier: "fullscreen-video").firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20))
        remote.press(.menu)
        openSettingsFromSwitcher(app)
        let order = app.descendants(matching: .any).matching(identifier: "interlaced-field-order").firstMatch
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        print("Interlaced controls focus tree: \(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Interlaced playback controls"
        shot.lifetime = .keepAlways
        add(shot)
        let top = app.buttons["Top first"]
        let bottom = app.buttons["Bottom first"]
        remote.press(.right)
        for _ in 0..<8 {
            if top.hasFocus { break }
            remote.press(.down)
        }
        XCTAssertTrue(top.hasFocus, "Remote must reach the field-order choices.")
        guard top.hasFocus else { return }
        // Native segmented pickers select on Left/Right. Changing this value
        // reconnects immediately, so focus belongs to the new playback view.
        remote.press(.right)
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20), "Changing order must reconnect and return to playback.")
        remote.press(.menu)
        openSettingsFromSwitcher(app)
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        XCTAssertTrue(bottom.isSelected, "The reconnected source must retain the selected field order.")
        let statistics = app.switches["Show statistics"]
        let reconnect = app.buttons["Reconnect"]
        let disconnect = app.buttons["disconnect"]
        XCTAssertTrue(statistics.isHittable)
        XCTAssertTrue(reconnect.isHittable)
        XCTAssertTrue(disconnect.isHittable)
        // Start at the top, then enter the Playback column. This also checks
        // that the added picker has not pushed existing controls off screen.
        for _ in 0..<8 { remote.press(.up) }
        remote.press(.right)
        for _ in 0..<10 {
            if statistics.hasFocus { break }
            remote.press(.down)
        }
        XCTAssertTrue(statistics.hasFocus, "Statistics must remain reachable with the remote.")
        guard statistics.hasFocus else { return }
        remote.press(.select)
        remote.press(.down)
        if disconnect.hasFocus { remote.press(.left) }
        XCTAssertTrue(reconnect.hasFocus)
        guard reconnect.hasFocus else { return }
        remote.press(.select)
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20))
        remote.press(.menu)
        openSettingsFromSwitcher(app)
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        XCTAssertTrue(bottom.isSelected)
        for _ in 0..<8 { remote.press(.up) }
        remote.press(.right)
        for _ in 0..<10 {
            if reconnect.hasFocus || disconnect.hasFocus { break }
            remote.press(.down)
        }
        if reconnect.hasFocus { remote.press(.right) }
        XCTAssertTrue(disconnect.hasFocus, "Disconnect must remain reachable with the remote.")
        guard disconnect.hasFocus else { return }
        remote.press(.select)
        XCTAssertTrue(app.buttons["manual-address"].waitForExistence(timeout: 5))
        XCTAssertFalse(disconnect.exists)
        XCTAssertFalse(order.exists)
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
        XCTAssertTrue(app.buttons["switcher-settings"].waitForExistence(timeout: 5), "Back must open the source strip from full screen.")
        XCTAssertFalse(app.buttons["disconnect"].exists, "Playback settings stay separate from source browsing.")
        remote.press(.menu)
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5), "Back must return to full screen while playing.")
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["switcher-settings"].waitForExistence(timeout: 5), "Play/Pause must also open the source strip.")
        openSettingsFromSwitcher(app)
        XCTAssertTrue(app.buttons["disconnect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["receiver-statistics"].exists)
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "Official OMT playback controls and statistics"
        controls.lifetime = .keepAlways
        add(controls)
    }

    /// Two isolated SDK sources; cycles can be increased for an unattended
    /// hardware run. Browsing uses only remote focus, never coordinate taps.
    @MainActor
    func testQuickSwitcherChangesSourcesAndKeepsBrowsingSeparateFromSelection() throws {
        guard ProcessInfo.processInfo.environment["OMT_RUN_INTEROP"] == "1",
              ProcessInfo.processInfo.environment["OMT_RUN_SWITCHER_INTEROP"] == "1" else {
            throw XCTSkip("Requires the two isolated SDK switcher sources.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["OMT_UNIT_TESTS"] = "0"
        // A paired physical TV can answer CoreDevice while its foreground
        // system is asleep. Wake it through the remote before launching.
        XCUIRemote.shared.press(.home)
        app.launch()
        let remote = XCUIRemote.shared
        let firstName = "OMTReceiver Test Pattern", secondName = "OMTReceiver Switcher Second"
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", firstName)).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secondName)).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        XCTAssertTrue(second.waitForExistence(timeout: 25))
        for _ in 0..<12 {
            if first.hasFocus { break }
            remote.press(.up)
        }
        XCTAssertTrue(first.hasFocus)
        guard first.hasFocus else { return }
        remote.press(.select)
        let fullscreen = app.descendants(matching: .any).matching(identifier: "fullscreen-video").firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20))
        let cycles = min(200, max(1, Int(ProcessInfo.processInfo.environment["OMT_SWITCHER_CYCLES"] ?? "") ?? 5))
        var activeName = firstName
        for cycle in 0..<cycles {
            remote.press(.menu)
            let current = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", activeName)).firstMatch
            XCTAssertTrue(current.waitForExistence(timeout: 5))
            XCTAssertTrue(current.hasFocus, "Reopening must focus the current source (cycle \(cycle)).")
            guard current.hasFocus else { return }
            let targetName = activeName == firstName ? secondName : firstName
            let target = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", targetName)).firstMatch
            let move: XCUIRemote.Button = activeName.localizedStandardCompare(targetName) == .orderedAscending ? .right : .left
            remote.press(move)
            XCTAssertTrue(target.hasFocus, "The other source must be reachable (cycle \(cycle)).")
            XCTAssertTrue((current.value as? String)?.contains("Current source") == true,
                          "Moving focus must not select the browsed source.")
            guard target.hasFocus else { return }
            // Cancel browsing once, then prove focus returns to the source
            // actually playing and that re-selection needs no new connection.
            if cycle == 0 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "Quick source strip while browsing"
                shot.lifetime = .keepAlways
                add(shot)
                remote.press(.menu)
                XCTAssertTrue(fullscreen.waitForExistence(timeout: 3))
                remote.press(.menu)
                XCTAssertTrue(current.hasFocus)
                remote.press(.select)
                XCTAssertTrue(fullscreen.waitForExistence(timeout: 3))
                remote.press(.menu)
                remote.press(move)
                XCTAssertTrue(target.hasFocus)
            }
            remote.press(.select)
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 20), "Source switch must reach decoded playback (cycle \(cycle)).")
            guard fullscreen.exists else { return }
            activeName = targetName
        }
        remote.press(.menu)
        let favourite = app.buttons["favourite-current-source"]
        let oldFavouriteLabel = favourite.label
        activateSwitcherControl("favourite-current-source", app: app)
        XCTAssertNotEqual(favourite.label, oldFavouriteLabel)
        remote.press(.menu)
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3))
        remote.press(.menu)
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", activeName)).firstMatch
        XCTAssertTrue(current.hasFocus, "Favouriting must preserve focus on the playing source when reopening.")
        activateSwitcherControl("favourite-current-source", app: app)
        XCTAssertEqual(favourite.label, oldFavouriteLabel, "Restore the original favourite preference after testing.")
        openSettingsFromSwitcher(app)
        XCTAssertTrue(app.buttons["disconnect"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openSettingsFromSwitcher(_ app: XCUIApplication) {
        activateSwitcherControl("switcher-settings", app: app)
    }

    @MainActor
    private func activateSwitcherControl(_ identifier: String, app: XCUIApplication) {
        let settings = app.buttons[identifier]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let remote = XCUIRemote.shared
        remote.press(.up)
        for _ in 0..<5 {
            if settings.hasFocus { break }
            remote.press(.right)
        }
        if !settings.hasFocus {
            for _ in 0..<5 {
                if settings.hasFocus { break }
                remote.press(.left)
            }
        }
        XCTAssertTrue(settings.hasFocus, "Source strip actions must be reachable with the remote: \(identifier).")
        if settings.hasFocus { remote.press(.select) }
    }
}
