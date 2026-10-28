import AppKit
import ApplicationServices
#if SWIFT_PACKAGE
import OmniDockMenuBarRuntime
#endif

struct MenuBarShelfItemPosition {
    let bundleIdentifier: String
    let frame: CGRect
}

struct MenuBarShelfLayoutSnapshot {
    let boundary: CGRect?
    let screen: CGRect?
    let items: [MenuBarShelfItemPosition]
    let runningBundleIdentifiers: Set<String>
    let isComplete: Bool
    var mainItemFrame: CGRect? = nil

    func mainItemStaysVisible(isRightToLeft: Bool) -> Bool {
        guard isComplete, let boundary, let screen, let mainItemFrame,
              Self.isUsable(boundary), Self.isUsable(screen), Self.isUsable(mainItemFrame),
              screen.contains(boundary), screen.contains(mainItemFrame),
              abs(mainItemFrame.midY - boundary.midY) < max(mainItemFrame.height, boundary.height) else {
            return true
        }
        return isRightToLeft
            ? mainItemFrame.minX < boundary.maxX
            : mainItemFrame.maxX > boundary.minX
    }

    func applicationsToKeepVisible(isRightToLeft: Bool) -> Set<String>? {
        guard isComplete, let boundary, let screen,
              Self.isUsable(boundary), Self.isUsable(screen), screen.contains(boundary) else {
            return nil
        }
        let grouped = Dictionary(grouping: items, by: \.bundleIdentifier)
        let hidden = grouped.compactMap { bundle, positions -> String? in
            let allOnHiddenSide = positions.allSatisfy { item in
                guard Self.isUsable(item.frame), screen.contains(item.frame),
                      abs(item.frame.midY - boundary.midY) < max(item.frame.height, boundary.height) else {
                    return false
                }
                return isRightToLeft
                    ? item.frame.minX >= boundary.maxX
                    : item.frame.maxX <= boundary.minX
            }
            return allOnHiddenSide ? bundle : nil
        }
        // Only positively identified hidden apps are excluded; unreadable owners stay visible.
        return runningBundleIdentifiers.subtracting(hidden).union(["com.quanzhankeji.OmniDock"])
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
}

@MainActor
protocol MenuBarShelfRestricting: AnyObject {
    func keepVisible(_ bundles: Set<String>, completion: @escaping (Bool) -> Void)
    func restore()
}

@MainActor
final class MenuBarShelfRuntimeRestriction: MenuBarShelfRestricting {
    private var session: AnyObject?
    private var revision = 0

    func keepVisible(_ bundles: Set<String>, completion: @escaping (Bool) -> Void) {
        restore()
        let request = revision
        session = ODMenuBarBeginVisibility(bundles.sorted()) { [weak self] activatedSession, succeeded in
            DispatchQueue.main.async {
                guard let self, self.revision == request else {
                    ODMenuBarEndVisibility(activatedSession)
                    return
                }
                let active = succeeded && self.session != nil
                if !active { self.restore() }
                completion(active)
            }
        } as AnyObject?
    }

    func restore() {
        revision &+= 1
        ODMenuBarEndVisibility(session)
        session = nil
    }

    deinit {
        ODMenuBarEndVisibility(session)
    }
}

@MainActor
final class MenuBarShelfVisibility {
    typealias ReadLayout = (@escaping (MenuBarShelfLayoutSnapshot) -> Void) -> Void
    nonisolated static let boundaryIdentifier = "OmniDock.MenuBarShelf.Boundary"
    private let restriction: MenuBarShelfRestricting
    private let readLayout: ReadLayout
    private let isAuthorized: () -> Bool
    private let onMainItemVisibilityChanged: (Bool) -> Void
    private var revision = 0

    init(
        restriction: MenuBarShelfRestricting? = nil,
        isAuthorized: @escaping () -> Bool = { AXIsProcessTrusted() },
        onMainItemVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        readLayout: ReadLayout? = nil
    ) {
        self.restriction = restriction ?? MenuBarShelfRuntimeRestriction()
        self.isAuthorized = isAuthorized
        self.onMainItemVisibilityChanged = onMainItemVisibilityChanged
        self.readLayout = readLayout ?? Self.readCurrentLayout
    }

    func tuck(isRightToLeft: Bool, completion: @escaping (Bool) -> Void) {
        restore()
        guard isAuthorized() else {
            completion(false)
            return
        }
        let request = revision
        readLayout { [weak self] snapshot in
            guard let self, self.revision == request else { return }
            guard self.isAuthorized(),
                  let allowed = snapshot.applicationsToKeepVisible(isRightToLeft: isRightToLeft) else {
                completion(false)
                return
            }
            self.restriction.keepVisible(allowed) { [weak self] succeeded in
                guard let self, self.revision == request else { return }
                if !self.isAuthorized() {
                    self.restore()
                    completion(false)
                } else {
                    if !succeeded { self.restriction.restore() }
                    if succeeded {
                        self.onMainItemVisibilityChanged(snapshot.mainItemStaysVisible(isRightToLeft: isRightToLeft))
                    }
                    completion(succeeded)
                }
            }
        }
    }

    func restore() {
        revision &+= 1
        restriction.restore()
        onMainItemVisibilityChanged(true)
    }

    private static func readCurrentLayout(completion: @escaping (MenuBarShelfLayoutSnapshot) -> Void) {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard let bundle = app.bundleIdentifier else { return nil }
            return (app.processIdentifier, bundle)
        }
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = collectLayout(applications: applications, ownPID: ownPID, screens: screens)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    nonisolated private static func collectLayout(
        applications: [(pid_t, String)], ownPID: pid_t, screens: [CGRect]
    ) -> MenuBarShelfLayoutSnapshot {
        var boundary: CGRect?
        var mainItemFrame: CGRect?
        var items: [MenuBarShelfItemPosition] = []
        var complete = true
        for (pid, bundle) in applications {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var rawBar: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &rawBar)
            guard result == .success, let rawBar else {
                // A process without menu bar items is expected, unlike an interrupted AX read.
                if pid == ownPID { complete = false }
                continue
            }
            var rawItems: CFTypeRef?
            guard AXUIElementCopyAttributeValue(rawBar as! AXUIElement, kAXChildrenAttribute as CFString, &rawItems) == .success,
                  let children = rawItems as? [AXUIElement] else {
                continue
            }
            var positions: [MenuBarShelfItemPosition] = []
            var readable = true
            for child in children {
                guard let frame = frame(of: child) else {
                    readable = false
                    continue
                }
                if pid == ownPID {
                    var identifier: CFTypeRef?
                    AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier)
                    if identifier as? String == boundaryIdentifier { boundary = frame }
                    if identifier as? String == StatusMenuController.mainItemIdentifier { mainItemFrame = frame }
                } else {
                    positions.append(MenuBarShelfItemPosition(bundleIdentifier: bundle, frame: frame))
                }
            }
            if readable { items.append(contentsOf: positions) }
        }
        return MenuBarShelfLayoutSnapshot(
            boundary: boundary,
            screen: boundary.flatMap { marker in screens.first { $0.contains(marker) } },
            items: items,
            runningBundleIdentifiers: Set(applications.map(\.1)),
            isComplete: complete,
            mainItemFrame: mainItemFrame
        )
    }

    nonisolated private static func frame(of item: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
