import XCTest
@testable import OmniDockCore

@MainActor
final class MenuBarShelfVisibilityTests: XCTestCase {
    func testNewSystemKeepsTheDividerCompactWithoutChangingOlderSystems() {
        XCTAssertEqual(MenuBarShelfLayoutPolicy.boundaryLength(
            for: .tucked, widestScreen: 6_016, operatingSystemMajorVersion: 27
        ), MenuBarShelfLayoutPolicy.visibleDividerLength)
        XCTAssertEqual(MenuBarShelfLayoutPolicy.boundaryLength(
            for: .tucked, widestScreen: 6_016, operatingSystemMajorVersion: 26
        ), 12_032)
    }

    func testOnlyConfirmedHiddenOwnersAreExcluded() throws {
        let allowed = try XCTUnwrap(snapshot().applicationsToKeepVisible(isRightToLeft: false))
        XCTAssertFalse(allowed.contains("example.hidden"))
        XCTAssertTrue(allowed.contains("example.visible"))
        XCTAssertTrue(allowed.contains("example.unreadable"))
        XCTAssertTrue(allowed.contains("com.quanzhankeji.OmniDock"))
    }

    func testAnApplicationWithAnIconOnEachSideStaysVisible() throws {
        let layout = snapshot(extra: [position("example.hidden", x: 800)])
        XCTAssertTrue(try XCTUnwrap(layout.applicationsToKeepVisible(isRightToLeft: false)).contains("example.hidden"))
    }

    func testMainMenuCanHideWithoutExcludingTheShelfControls() throws {
        var layout = snapshot()
        layout.mainItemFrame = CGRect(x: 500, y: 3, width: 37, height: 24)
        XCTAssertFalse(layout.mainItemStaysVisible(isRightToLeft: false))
        XCTAssertTrue(try XCTUnwrap(layout.applicationsToKeepVisible(isRightToLeft: false))
            .contains("com.quanzhankeji.OmniDock"))
        XCTAssertTrue(layout.mainItemStaysVisible(isRightToLeft: true))
    }

    func testMainMenuOnTheVisibleSideIsPreserved() {
        var layout = snapshot()
        layout.mainItemFrame = CGRect(x: 700, y: 3, width: 37, height: 24)
        XCTAssertTrue(layout.mainItemStaysVisible(isRightToLeft: false))
        XCTAssertFalse(layout.mainItemStaysVisible(isRightToLeft: true))
    }

    func testUnknownMainMenuGeometryIsPreserved() {
        for frame: CGRect? in [nil, .zero, CGRect(x: -100, y: 3, width: 37, height: 24),
                               CGRect(x: 500, y: 300, width: 37, height: 24)] {
            var layout = snapshot()
            layout.mainItemFrame = frame
            XCTAssertTrue(layout.mainItemStaysVisible(isRightToLeft: false))
        }
        var incomplete = snapshot(complete: false)
        incomplete.mainItemFrame = CGRect(x: 500, y: 3, width: 37, height: 24)
        XCTAssertTrue(incomplete.mainItemStaysVisible(isRightToLeft: false))
    }

    func testMainMenuHidesOnlyAfterSuccessfulActivationAndReturnsOnExpand() {
        let restriction = Restriction()
        var changes: [Bool] = []
        var layout = snapshot()
        layout.mainItemFrame = CGRect(x: 500, y: 3, width: 37, height: 24)
        let visibility = MenuBarShelfVisibility(
            restriction: restriction, isAuthorized: { true },
            onMainItemVisibilityChanged: { changes.append($0) }, readLayout: { $0(layout) }
        )
        visibility.tuck(isRightToLeft: false) { XCTAssertTrue($0) }
        XCTAssertEqual(changes, [true])
        restriction.completion?(true)
        XCTAssertEqual(changes, [true, false])
        visibility.restore()
        XCTAssertEqual(changes, [true, false, true])
    }

    func testFailedOrCancelledActivationNeverHidesMainMenu() {
        for cancel in [false, true] {
            let restriction = Restriction()
            var changes: [Bool] = []
            var layout = snapshot()
            layout.mainItemFrame = CGRect(x: 500, y: 3, width: 37, height: 24)
            let visibility = MenuBarShelfVisibility(
                restriction: restriction, isAuthorized: { true },
                onMainItemVisibilityChanged: { changes.append($0) }, readLayout: { $0(layout) }
            )
            visibility.tuck(isRightToLeft: false) { XCTAssertFalse($0) }
            if cancel { visibility.restore() }
            restriction.completion?(cancel)
            XCTAssertFalse(changes.contains(false))
        }
    }

    func testAnOpenMainMenuDefersAutomaticHiding() {
        XCTAssertTrue(MenuBarShelfAutoHidePolicy.deferAutoHide(
            isCommandHeld: false, isMouseButtonDown: false, didItemsMove: false, isMenuOpen: true
        ))
    }

    func testAnotherScreenOrMenuBarIsNotClassifiedAsHidden() throws {
        for frame in [CGRect(x: -400, y: 3, width: 24, height: 24),
                      CGRect(x: 30, y: 300, width: 24, height: 24)] {
            let layout = snapshot(extra: [MenuBarShelfItemPosition(bundleIdentifier: "example.hidden", frame: frame)])
            XCTAssertTrue(try XCTUnwrap(layout.applicationsToKeepVisible(isRightToLeft: false)).contains("example.hidden"))
        }
    }

    func testRightToLeftUsesTheOppositeSide() throws {
        let allowed = try XCTUnwrap(snapshot().applicationsToKeepVisible(isRightToLeft: true))
        XCTAssertTrue(allowed.contains("example.hidden"))
        XCTAssertFalse(allowed.contains("example.visible"))
    }

    func testMissingInvalidOrOffscreenDividerDoesNotHideAnything() {
        for marker: CGRect? in [nil, .zero, CGRect(x: -20, y: 3, width: 10, height: 24),
                                CGRect(x: CGFloat.nan, y: 3, width: 10, height: 24)] {
            XCTAssertNil(snapshot(boundary: marker).applicationsToKeepVisible(isRightToLeft: false))
        }
        XCTAssertNil(snapshot(complete: false).applicationsToKeepVisible(isRightToLeft: false))
    }

    func testNoPermissionLeavesTheMenuBarExpandedWithoutReadingLayout() {
        let restriction = Restriction()
        let visibility = MenuBarShelfVisibility(restriction: restriction, isAuthorized: { false }, readLayout: { _ in
            XCTFail("Denied access must not scan applications")
        })
        var result: Bool?
        visibility.tuck(isRightToLeft: false) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(restriction.requests.isEmpty)
    }

    func testExpandingWhileLayoutLoadsRejectsTheOldResult() {
        let restriction = Restriction()
        var reply: ((MenuBarShelfLayoutSnapshot) -> Void)?
        let visibility = MenuBarShelfVisibility(restriction: restriction, isAuthorized: { true }, readLayout: { reply = $0 })
        visibility.tuck(isRightToLeft: false) { _ in XCTFail("Cancelled read must not change state") }
        visibility.restore()
        reply?(snapshot())
        XCTAssertTrue(restriction.requests.isEmpty)
    }

    func testLosingPermissionWhileLayoutLoadsDoesNotActivateARestriction() {
        let restriction = Restriction()
        var authorized = true
        var reply: ((MenuBarShelfLayoutSnapshot) -> Void)?
        let visibility = MenuBarShelfVisibility(restriction: restriction, isAuthorized: { authorized }, readLayout: { reply = $0 })
        var result: Bool?
        visibility.tuck(isRightToLeft: false) { result = $0 }
        authorized = false
        reply?(snapshot())
        XCTAssertEqual(result, false)
        XCTAssertTrue(restriction.requests.isEmpty)
    }

    func testALateActivationCannotCloseAnExpandedShelf() {
        let restriction = Restriction()
        let visibility = MenuBarShelfVisibility(restriction: restriction, isAuthorized: { true }, readLayout: { $0(self.snapshot()) })
        visibility.tuck(isRightToLeft: false) { _ in XCTFail("Cancelled activation must not change state") }
        XCTAssertEqual(restriction.requests.count, 1)
        visibility.restore()
        restriction.completion?(true)
        XCTAssertEqual(restriction.restoreCount, 2)
    }

    func testFailureAndPermissionLossDuringActivationRestoreVisibility() {
        for success in [false, true] {
            let restriction = Restriction()
            var authorized = true
            let visibility = MenuBarShelfVisibility(restriction: restriction, isAuthorized: { authorized }, readLayout: { $0(self.snapshot()) })
            var result: Bool?
            visibility.tuck(isRightToLeft: false) { result = $0 }
            if success { authorized = false }
            restriction.completion?(success)
            XCTAssertEqual(result, false)
            XCTAssertEqual(restriction.restoreCount, 2)
        }
    }

    private func position(_ bundle: String, x: CGFloat) -> MenuBarShelfItemPosition {
        MenuBarShelfItemPosition(bundleIdentifier: bundle, frame: CGRect(x: x, y: 3, width: 24, height: 24))
    }

    private func snapshot(
        boundary: CGRect? = CGRect(x: 600, y: 3, width: 10, height: 24),
        complete: Bool = true,
        extra: [MenuBarShelfItemPosition] = []
    ) -> MenuBarShelfLayoutSnapshot {
        MenuBarShelfLayoutSnapshot(
            boundary: boundary, screen: CGRect(x: 0, y: 0, width: 1_200, height: 900),
            items: [position("example.hidden", x: 300), position("example.visible", x: 800)] + extra,
            runningBundleIdentifiers: ["example.hidden", "example.visible", "example.unreadable"],
            isComplete: complete
        )
    }

    private final class Restriction: MenuBarShelfRestricting {
        var requests: [Set<String>] = []
        var completion: ((Bool) -> Void)?
        var restoreCount = 0
        func keepVisible(_ bundles: Set<String>, completion: @escaping (Bool) -> Void) {
            requests.append(bundles)
            self.completion = completion
        }
        func restore() { restoreCount += 1 }
    }
}
