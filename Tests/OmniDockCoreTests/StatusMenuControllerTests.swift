import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class StatusMenuControllerTests: XCTestCase {
    func testPreferenceAndShelfMustBothAllowTheIcon() {
        let (settings, menu) = makeMenu()
        for preferred in [false, true] {
            for allowed in [false, true] {
                settings.menuBarIconVisible = preferred
                menu.setMenuBarItemVisible(allowed)
                XCTAssertEqual(menu.isMenuBarItemVisible, preferred && allowed)
            }
        }
    }

    func testChangingPreferenceDoesNotOverrideATuckedShelf() {
        let (settings, menu) = makeMenu()
        menu.setMenuBarItemVisible(false)
        settings.menuBarIconVisible = false
        settings.menuBarIconVisible = true
        XCTAssertFalse(menu.isMenuBarItemVisible)
    }

    func testShelfRestoreDoesNotOverrideAHiddenPreference() {
        let (settings, menu) = makeMenu()
        settings.menuBarIconVisible = false
        let visibility = makeVisibility(menu: menu)
        visibility.restore()
        XCTAssertFalse(menu.isMenuBarItemVisible)
    }

    func testDisabledShelfStartupPreservesHiddenPreference() {
        let (settings, menu) = makeMenu()
        settings.menuBarIconVisible = false
        let shelf = MenuBarShelfService(
            settings: settings,
            onMainItemVisibilityChanged: { menu.setMenuBarItemVisible($0) }
        )
        shelf.start()
        XCTAssertFalse(menu.isMenuBarItemVisible)
        shelf.stop()
        XCTAssertFalse(menu.isMenuBarItemVisible)
    }

    func testSuccessfulShelfCyclesRespectBothInputs() {
        let (settings, menu) = makeMenu()
        let restriction = MenuIconRestriction()
        let visibility = makeVisibility(menu: menu, restriction: restriction)
        for _ in 0..<3 {
            visibility.tuck(isRightToLeft: false) { XCTAssertTrue($0) }
            restriction.completion?(true)
            XCTAssertFalse(menu.isMenuBarItemVisible)
            visibility.restore()
            XCTAssertTrue(menu.isMenuBarItemVisible)
        }
        settings.menuBarIconVisible = false
        visibility.restore()
        XCTAssertFalse(menu.isMenuBarItemVisible)
    }

    func testFailedActivationDoesNotShowAManuallyHiddenIcon() {
        let (settings, menu) = makeMenu()
        settings.menuBarIconVisible = false
        let restriction = MenuIconRestriction()
        let visibility = makeVisibility(menu: menu, restriction: restriction)
        visibility.tuck(isRightToLeft: false) { XCTAssertFalse($0) }
        restriction.completion?(false)
        XCTAssertFalse(menu.isMenuBarItemVisible)
    }

    func testPermissionLossDuringActivationPreservesPreference() {
        let (settings, menu) = makeMenu()
        settings.menuBarIconVisible = false
        var authorized = true
        let restriction = MenuIconRestriction()
        let visibility = makeVisibility(
            menu: menu, restriction: restriction, isAuthorized: { authorized }
        )
        visibility.tuck(isRightToLeft: false) { XCTAssertFalse($0) }
        authorized = false
        restriction.completion?(true)
        XCTAssertFalse(menu.isMenuBarItemVisible)
    }

    private func makeMenu() -> (SettingsStore, StatusMenuController) {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "StatusMenuControllerTests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        let permissions = PermissionService()
        let control = WindowControlService()
        let inventory = WindowInventoryService()
        let preview = ScreenCapturePreviewService(windowInventory: inventory)
        let coordinator = DockInteractionCoordinator(
            settings: settings, permissionService: permissions,
            dockHitTester: DockHitTester(permissionService: permissions),
            windowControlService: control, previewService: preview,
            previewPanelController: PreviewPanelController(windowControlService: control)
        )
        let menu = StatusMenuController(
            settings: settings, permissionService: permissions,
            coordinator: coordinator,
            hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore(),
            onPermissionGateRequired: { _ in }
        )
        return (settings, menu)
    }

    private func makeVisibility(
        menu: StatusMenuController,
        restriction: MenuIconRestriction? = nil,
        isAuthorized: @escaping () -> Bool = { true }
    ) -> MenuBarShelfVisibility {
        MenuBarShelfVisibility(
            restriction: restriction ?? MenuIconRestriction(), isAuthorized: isAuthorized,
            onMainItemVisibilityChanged: { menu.setMenuBarItemVisible($0) },
            readLayout: { reply in
                reply(MenuBarShelfLayoutSnapshot(
                    boundary: CGRect(x: 100, y: 3, width: 12, height: 24),
                    screen: CGRect(x: 0, y: 0, width: 1_024, height: 768),
                    items: [], runningBundleIdentifiers: ["com.quanzhankeji.OmniDock"],
                    isComplete: true,
                    mainItemFrame: CGRect(x: 40, y: 3, width: 37, height: 24)
                ))
            }
        )
    }
}

@MainActor
private final class MenuIconRestriction: MenuBarShelfRestricting {
    var completion: ((Bool) -> Void)?
    func keepVisible(_ bundles: Set<String>, completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }
    func restore() {}
}
