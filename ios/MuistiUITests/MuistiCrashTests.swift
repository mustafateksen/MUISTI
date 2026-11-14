import XCTest

/// End-to-end crash tests on the simulator with MockDeviceKit glasses (no hardware needed).
/// Run: `xcodebuild test -project ios/Muisti.xcodeproj -scheme Muisti -destination 'platform=iOS Simulator,name=iPhone 17'`
/// For the permission paths, reset first: `xcrun simctl privacy booted reset all fi.junction.powerpuffboys.muisti`
@MainActor
final class MuistiCrashTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Taps "Allow"/"OK" on any system permission alert that appears within `seconds`.
    private func acceptSystemAlerts(for seconds: TimeInterval) {
        let labels = ["Allow", "Allow While Using App", "OK", "İzin Ver", "Uygulamayı Kullanırken İzin Ver", "Tamam"]
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 1) {
                // Some alerts have both "Allow" and "Allow Once"; take the first exact match.
                for label in labels {
                    let button = alert.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if button.exists {
                        button.tap()
                        break
                    }
                }
            }
        }
    }

    private func assertAlive(_ app: XCUIApplication, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "App is not running: \(message)", file: file, line: line)
    }

    /// The crash from the field: TCC calls the speech-authorization callback on a background
    /// queue; a main-actor closure there trapped. Press the mic, grant everything, stay alive.
    func testVoiceButtonDoesNotCrash() {
        let app = launch(["--mock-autostart", "--mode=intervalPhoto", "--mock-script=stop@0.5"])
        acceptSystemAlerts(for: 4)
        app.tabBars.buttons["Ask"].tap()

        let mic = app.buttons["Ask by voice"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.tap()
        acceptSystemAlerts(for: 8)   // speech recognition + microphone
        assertAlive(app, "after granting speech/mic permissions")

        // Second press with permissions already granted: listen, then stop.
        if app.buttons["Ask by voice"].firstMatch.waitForExistence(timeout: 20) {
            app.buttons["Ask by voice"].firstMatch.tap()
            sleep(2)
            if app.buttons["Stop listening"].firstMatch.exists { app.buttons["Stop listening"].firstMatch.tap() }
        }
        sleep(3)
        assertAlive(app, "after a second listen cycle")
    }

    /// Capture with simulated glasses through tap / fold / don / low battery / heat while the
    /// user moves between tabs. The preview must show the frame inside its box.
    func testCaptureWithDeviceEventsDoesNotCrash() {
        let app = launch(["--mock-autostart", "--mode=stream",
                          "--mock-script=tap@6,tap@9,fold@12,unfold@15,don@16,battery5@18,hot@19"])
        // Permission alerts first: on a fresh simulator they cover the island.
        acceptSystemAlerts(for: 3)
        // The preview lives in the capture panel, opened from the glasses island.
        openCapturePanel(app)
        // Layout must not move when the first frame arrives: measure the box before and after.
        let box = app.descendants(matching: .any)["previewBox"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 10), "No preview box")
        let before = box.frame
        acceptSystemAlerts(for: 3)
        let framed = NSPredicate(format: "label == %@", "Last captured frame")
        expectation(for: framed, evaluatedWith: box)
        // A frame is in the box. 45 s: on a fresh simulator Vision first warms up on the CPU.
        waitForExpectations(timeout: 45)
        let after = box.frame
        XCTAssertEqual(after.height, before.height, accuracy: 1, "Preview box height changed: \(before) → \(after)")
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "Layout moved when the frame arrived: \(before) → \(after)")
        XCTAssertLessThanOrEqual(after.maxX, app.windows.firstMatch.frame.maxX, "Preview wider than the screen")

        app.buttons["Done"].tap()
        for tab in ["Memory", "Ask", "Memory", "Ask"] {
            app.tabBars.buttons[tab].tap()
            sleep(2)
            assertAlive(app, "on tab \(tab)")
        }
        sleep(8)   // let fold/unfold/don and battery/heat events play out
        assertAlive(app, "after device events")
        // Expected SDK teardown messages must never reach the screen raw.
        app.tabBars.buttons["Ask"].tap()
        openCapturePanel(app)
        for raw in ["unavailable", "ended by device"] {
            let shown = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", raw)).firstMatch
            XCTAssertFalse(shown.exists, "Raw SDK text on screen: \(shown.label)")
        }
    }

    /// Backgrounding ends the glasses session on purpose; coming back must not crash.
    func testBackgroundAndReturn() {
        let app = launch(["--mock-autostart", "--mode=intervalPhoto"])
        acceptSystemAlerts(for: 5)
        sleep(4)
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App did not come back to the foreground")
        acceptSystemAlerts(for: 3)
        sleep(3)
        assertAlive(app, "after returning from background")
    }

    /// Memory episodes (folders) → episode → frame detail. Nothing may be wider than the
    /// screen (the detail page used to grow sideways with a zoomed-in photo).
    /// Needs `Documents/ingest` (see README) in the simulator app container.
    func testEpisodeAndDetailFitScreen() throws {
        let app = launch(["--script-only=wipe@0,ingest@1", "--ingest=ingest"])
        acceptSystemAlerts(for: 3)
        app.tabBars.buttons["Memory"].tap()
        let firstEpisode = app.buttons.matching(identifier: "episodeRow").firstMatch
        guard firstEpisode.waitForExistence(timeout: 120) else {
            throw XCTSkip("No sample photos in Documents/ingest")
        }
        // Wait until all sample frames are in (rows animate in while the ingest runs).
        let all = app.staticTexts["21"]
        _ = all.waitForExistence(timeout: 180)
        sleep(2)
        let width = app.windows.firstMatch.frame.width
        save(app, "memory_list")
        assertFits(app, width: width)
        firstEpisode.tap()
        let firstFrame = app.buttons.matching(identifier: "frameRow").firstMatch
        XCTAssertTrue(firstFrame.waitForExistence(timeout: 10), "Episode has no frames")
        save(app, "episode")
        firstFrame.tap()
        sleep(2)
        save(app, "detail_top")
        assertFits(app, width: width)
        app.swipeUp()
        sleep(1)
        save(app, "detail_bottom")
        assertAlive(app, "on the frame detail")
    }

    /// Visible content must lie within the screen horizontally.
    private func assertFits(_ app: XCUIApplication, width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        // Visible content only: List's own containers ("Other") reach past the edges invisibly.
        for kind in [XCUIElement.ElementType.staticText, .image, .button] {
            for element in app.descendants(matching: kind).allElementsBoundByIndex.prefix(60) where element.exists {
                let frame = element.frame
                // Skip system scroll containers (taller than the screen, partly scrolled away).
                guard !frame.isEmpty, frame.height <= app.windows.firstMatch.frame.height, frame.maxY > 0 else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, -1, "Starts off screen: \(element.debugDescription.prefix(140))", file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxX, width + 1, "Ends off screen: \(element.debugDescription.prefix(140))", file: file, line: line)
            }
        }
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["MUISTI_SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Typed question (no key needed: offline answer path) and the memory list.
    func testTypedQuestionAndMemoryList() {
        let app = launch(["--mock-autostart", "--mode=intervalPhoto", "--mock-script=stop@0.5"])
        acceptSystemAlerts(for: 4)
        app.tabBars.buttons["Ask"].tap()
        let field = app.textFields["Ask Muisti"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("What was the dentist's number?\n")
        sleep(8)
        assertAlive(app, "after a typed question")
        app.tabBars.buttons["Memory"].tap()
        sleep(2)
        assertAlive(app, "on the memory list")
    }

    /// Island → "Details" (the island may already be expanded after a status change).
    private func openCapturePanel(_ app: XCUIApplication) {
        let details = app.buttons["Details"]
        if !details.waitForExistence(timeout: 3) {
            let island = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Glasses:")).firstMatch
            if island.waitForExistence(timeout: 5) { island.tap() }
        }
        if details.waitForExistence(timeout: 5) { details.tap() }
    }
}
