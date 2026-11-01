import AppKit
import Carbon
import XCTest
@testable import OmniDockCore

final class ApplicationLaunchPolicyTests: XCTestCase {
    func testOrdinaryLaunchWithoutAnEventIsNotAutomatic() {
        XCTAssertFalse(ApplicationLaunchPolicy.isAutomaticLaunch(event: nil, arguments: ["OmniDock"]))
    }

    func testFinderOpenApplicationIsNotAutomatic() {
        XCTAssertFalse(ApplicationLaunchPolicy.isAutomaticLaunch(event: makeEvent(), arguments: ["OmniDock"]))
    }

    func testLoginItemEventIsAutomatic() {
        let event = makeEvent()
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(ApplicationLaunchPolicy.isAutomaticLaunch(event: event, arguments: ["OmniDock"]))
    }

    func testBackgroundRelaunchArgumentIsAutomatic() {
        XCTAssertTrue(ApplicationLaunchPolicy.isAutomaticLaunch(
            event: nil, arguments: ["OmniDock", ApplicationLaunchPolicy.backgroundArgument]
        ))
    }

    func testUnrelatedArgumentDoesNotSuppressRecovery() {
        XCTAssertFalse(ApplicationLaunchPolicy.isAutomaticLaunch(
            event: makeEvent(), arguments: ["OmniDock", "--unrelated"]
        ))
    }

    private func makeEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}
