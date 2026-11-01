import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class ApplicationPresentationCoordinatorTests: XCTestCase {
    func testFirstVisibleSurfaceSwitchesToRegularAndActivates() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(harness.activationCount, 1)
        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
    }

    func testPresentingSameSurfaceTwiceDoesNotDoubleCountOrSwitchAgain() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.present(.settings)

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(harness.activationCount, 2)
        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
    }

    func testAccessoryPresentationWaitsUntilLastSurfaceCloses() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.present(.permissionOnboarding)
        coordinator.dismiss(.settings)

        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
        XCTAssertTrue(harness.deferredActions.isEmpty)

        coordinator.dismiss(.permissionOnboarding)

        XCTAssertEqual(coordinator.activeSurfaceCount, 0)
        XCTAssertEqual(harness.deferredActions.count, 1)
        XCTAssertEqual(harness.policies, [.regular])

        harness.deferredActions[0]()

        XCTAssertEqual(harness.policies, [.regular, .accessory])
    }

    func testDuplicateDismissIsIgnored() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.dismiss(.settings)
        coordinator.present(.settings)
        coordinator.dismiss(.settings)
        coordinator.dismiss(.settings)

        XCTAssertEqual(harness.deferredActions.count, 1)
        XCTAssertEqual(coordinator.activeSurfaceCount, 0)
    }

    func testReopeningBeforeDeferredDismissCancelsAccessoryTransition() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.dismiss(.settings)
        coordinator.present(.permissionOnboarding)
        harness.deferredActions[0]()

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
    }

    func testFailedPolicyTransitionIsNotRetriedForSamePresentationCycle() {
        let harness = PresentationCoordinatorHarness(policyResult: false)
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.present(.settings)

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(harness.activationCount, 2)
    }

    func testSettingsRequestWaitsUntilLaunchFinishes() {
        let harness = PresentationCoordinatorHarness()
        var opened = 0
        harness.coordinator.requestSettings { opened += 1 }
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(harness.deferredActions.isEmpty)
        harness.coordinator.finishLaunching()
        XCTAssertEqual(opened, 0)
        harness.flush()
        XCTAssertEqual(opened, 1)
    }

    func testLaunchWithoutAnExplicitRequestStaysInBackground() {
        let harness = PresentationCoordinatorHarness()
        harness.coordinator.finishLaunching()
        harness.flush()
        XCTAssertTrue(harness.policies.isEmpty)
        XCTAssertEqual(harness.activationCount, 0)
    }

    func testRepeatedRequestsBeforeLaunchOpenSettingsOnce() {
        let harness = PresentationCoordinatorHarness()
        var opened = 0
        harness.coordinator.requestSettings { opened += 1 }
        harness.coordinator.requestSettings { opened += 1 }
        harness.coordinator.finishLaunching()
        harness.flush()
        XCTAssertEqual(opened, 1)
    }

    func testReopenAfterClosingSettingsDoesNotLoseRegularPresentation() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator
        coordinator.finishLaunching()
        coordinator.present(.settings)
        coordinator.dismiss(.settings)
        coordinator.requestSettings { coordinator.present(.settings) }
        harness.flush()
        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertTrue(coordinator.isPresenting(.settings))
    }

    func testReopenAfterAccessoryTransitionRestoresSettingsPresentation() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator
        coordinator.finishLaunching()
        coordinator.present(.settings)
        coordinator.dismiss(.settings)
        harness.flush()
        coordinator.requestSettings { coordinator.present(.settings) }
        harness.flush()
        XCTAssertEqual(harness.policies, [.regular, .accessory, .regular])
        XCTAssertTrue(coordinator.isPresenting(.settings))
    }

    func testReopenFocusesAnExistingPermissionOrUpdateSurface() {
        for surface in [ApplicationPresentationSurface.permissionOnboarding, .update] {
            let harness = PresentationCoordinatorHarness()
            let coordinator = harness.coordinator
            coordinator.finishLaunching()
            coordinator.present(surface)
            var opened = false
            coordinator.requestSettings { opened = true }
            harness.flush()
            XCTAssertFalse(opened)
            XCTAssertTrue(coordinator.isPresenting(surface))
            XCTAssertEqual(harness.activationCount, 2)
        }
    }

    func testDeferredReopenRechecksWhetherAnotherSurfaceHasOpened() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator
        coordinator.finishLaunching()
        var opened = false
        coordinator.requestSettings { opened = true }
        coordinator.present(.update)
        harness.flush()
        XCTAssertFalse(opened)
    }
}

@MainActor
private final class PresentationCoordinatorHarness {
    var policies: [NSApplication.ActivationPolicy] = []
    var activationCount = 0
    var deferredActions: [ApplicationPresentationCoordinator.DeferredAction] = []

    private let policyResult: Bool

    init(policyResult: Bool = true) {
        self.policyResult = policyResult
    }

    lazy var coordinator = ApplicationPresentationCoordinator(
        setActivationPolicy: { policy in
            self.policies.append(policy)
            return self.policyResult
        },
        activateApplication: {
            self.activationCount += 1
        },
        scheduleDeferred: { action in
            self.deferredActions.append(action)
        }
    )

    func flush() {
        let actions = deferredActions
        deferredActions.removeAll()
        actions.forEach { $0() }
    }
}
