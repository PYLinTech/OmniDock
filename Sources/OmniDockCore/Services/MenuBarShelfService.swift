import AppKit
import ApplicationServices

enum MenuBarShelfState: Equatable {
    case tucked
    case visible

    var toggled: MenuBarShelfState {
        self == .tucked ? .visible : .tucked
    }

    var dividerTitle: String {
        self == .visible ? "│" : ""
    }
}

enum MenuBarShelfLayoutPolicy {
    static let visibleDividerLength: CGFloat = 10

    static func boundaryLength(
        for state: MenuBarShelfState,
        widestScreen: CGFloat,
        operatingSystemMajorVersion: Int
    ) -> CGFloat {
        if operatingSystemMajorVersion >= 27 { return visibleDividerLength }
        switch state {
        case .visible:
            return visibleDividerLength
        case .tucked:
            return min(max(10_000, widestScreen * 2), 32_768)
        }
    }
}

enum MenuBarShelfAutoHidePolicy {
    static let allowedDelays = [5, 10, 15, 30, 60]

    static func normalizedDelay(_ value: Int) -> Int {
        allowedDelays.min { lhs, rhs in
            let lhsDistance = abs(lhs - value)
            let rhsDistance = abs(rhs - value)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        } ?? 10
    }

    /// Whether closing the shelf should wait. Arranging the menu bar means
    /// holding Command and dragging, which can easily outlast the delay - and
    /// closing the shelf mid-drag puts the icon being placed out of reach.
    ///
    /// Sampling current state avoids installing another keyboard event monitor.
    static func deferAutoHide(
        isCommandHeld: Bool,
        isMouseButtonDown: Bool,
        didItemsMove: Bool,
        isMenuOpen: Bool = false
    ) -> Bool {
        isCommandHeld || isMouseButtonDown || didItemsMove || isMenuOpen
    }
}

@MainActor
final class MenuBarShelfService: NSObject {
    private let settings: SettingsStore
    private let onOpenSettings: () -> Void
    private let onMainItemVisibilityChanged: (Bool) -> Void
    private let isMainMenuOpen: () -> Bool
    private var toggleItem: NSStatusItem?
    private var boundaryItem: NSStatusItem?
    private var boundaryMenu: NSMenu?
    private var autoHideTimer: Timer?
    private var lastKnownItemPositions: [CGFloat] = []
    private var isRepairingArrangement = false
    private var state: MenuBarShelfState = .visible
    private var isRunning = false
    private var isCollapsing = false
    private var hasVisibilityRestriction = false
    private var screenFrames: [CGRect] = []
    private let usesVisibilityRestriction = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    private lazy var visibility = MenuBarShelfVisibility(onMainItemVisibilityChanged: onMainItemVisibilityChanged)

    init(
        settings: SettingsStore,
        onMainItemVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        isMainMenuOpen: @escaping () -> Bool = { false },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.onMainItemVisibilityChanged = onMainItemVisibilityChanged
        self.isMainMenuOpen = isMainMenuOpen
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        screenFrames = NSScreen.screens.map(\.frame)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: SettingsStore.changedNotification,
            object: settings
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenLayoutChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(workspaceChanged(_:)), name: name, object: nil
            )
        }
        refresh()
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        NotificationCenter.default.removeObserver(
            self,
            name: SettingsStore.changedNotification,
            object: settings
        )
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeItems()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        let change = SettingsStore.change(in: notification)
        guard change == .menuBarShelf || change == .language || change == .all
                || (usesVisibilityRestriction && change == .permissionState) else {
            return
        }
        if usesVisibilityRestriction && change == .permissionState && !AXIsProcessTrusted() {
            revealShelf()
        }
        refresh()
    }

    @objc private func toggleShelf(_ sender: NSStatusBarButton) {
        if isCollapsing {
            revealShelf()
            return
        }
        state = state.toggled
        applyState()
    }

    @objc private func screenLayoutChanged(_ notification: Notification) {
        guard isRunning, settings.menuBarShelfEnabled else { return }
        let frames = NSScreen.screens.map(\.frame)
        guard frames != screenFrames else { return }
        screenFrames = frames
        if usesVisibilityRestriction { revealShelf() } else { applyState() }
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        guard isRunning, settings.menuBarShelfEnabled, usesVisibilityRestriction else { return }
        if notification.name != NSWorkspace.didWakeNotification {
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleURL?.pathExtension == "app",
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        }
        // Re-read from an unrestricted bar after application membership or the display session changes.
        revealShelf()
    }

    private func revealShelf() {
        isCollapsing = false
        hasVisibilityRestriction = false
        visibility.restore()
        state = .visible
        applyState()
    }

    @objc private func autoHideTimerFired(_ timer: Timer) {
        guard settings.menuBarShelfEnabled, state == .visible else {
            return
        }

        let positions = currentItemPositions()
        let didItemsMove = positions != lastKnownItemPositions
        lastKnownItemPositions = positions

        if MenuBarShelfAutoHidePolicy.deferAutoHide(
            isCommandHeld: NSEvent.modifierFlags.contains(.command),
            isMouseButtonDown: NSEvent.pressedMouseButtons != 0,
            didItemsMove: didItemsMove,
            isMenuOpen: isMainMenuOpen()
        ) {
            // Start the wait over rather than shorten it: the delay is how long
            // the shelf stays open once someone has stopped, not a deadline.
            scheduleAutoHideIfNeeded()
            return
        }

        state = .tucked
        applyState()
    }

    private func currentItemPositions() -> [CGFloat] {
        [toggleItem, boundaryItem].compactMap {
            $0?.button?.window?.frame.origin.x
        }
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        onOpenSettings()
    }

    func refreshPermissions() {
        guard isRunning, settings.menuBarShelfEnabled, usesVisibilityRestriction else { return }
        if !AXIsProcessTrusted() {
            revealShelf()
        } else if state == .visible, !isCollapsing {
            scheduleAutoHideIfNeeded()
        }
    }

    private func refresh() {
        guard settings.menuBarShelfEnabled else {
            removeItems()
            return
        }
        installItemsIfNeeded()
        updateLocalizedContent()
        applyState()
    }

    private func installItemsIfNeeded() {
        guard toggleItem == nil, boundaryItem == nil else {
            return
        }

        let toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggleItem.autosaveName = "OmniDock.MenuBarShelf.Toggle"
        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(toggleShelf(_:))
            button.sendAction(on: .leftMouseUp)
            button.imagePosition = .imageOnly
        }

        let boundaryItem = NSStatusBar.system.statusItem(
            withLength: MenuBarShelfLayoutPolicy.visibleDividerLength
        )
        boundaryItem.autosaveName = "OmniDock.MenuBarShelf.Boundary"
        if let button = boundaryItem.button {
            button.title = state.dividerTitle
            button.font = .systemFont(ofSize: 14, weight: .regular)
            button.setAccessibilityIdentifier(MenuBarShelfVisibility.boundaryIdentifier)
        }
        let boundaryMenu = makeBoundaryMenu()
        boundaryItem.menu = boundaryMenu

        // Removing a status item records it against its autosave name as one
        // the user put away, and it comes back that way the next time it is
        // built. Turning the feature off and on again is enough to lose the
        // divider for good, so say plainly that both belong on screen.
        toggleItem.isVisible = true
        boundaryItem.isVisible = true

        self.toggleItem = toggleItem
        self.boundaryItem = boundaryItem
        self.boundaryMenu = boundaryMenu
        state = .visible
    }

    func makeBoundaryMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: AppStrings.text(.menuSettings),
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    private func applyState() {
        guard let boundaryItem, toggleItem?.button != nil else {
            return
        }
        boundaryItem.length = MenuBarShelfLayoutPolicy.boundaryLength(
            for: state,
            widestScreen: NSScreen.screens.map(\.frame.width).max() ?? 4_096,
            operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )

        if usesVisibilityRestriction, state == .tucked {
            guard !isCollapsing, !hasVisibilityRestriction else { return }
            isCollapsing = true
            autoHideTimer?.invalidate()
            autoHideTimer = nil
            visibility.tuck(isRightToLeft: NSApp.userInterfaceLayoutDirection == .rightToLeft) { [weak self] succeeded in
                guard let self, self.isRunning, self.isCollapsing, self.settings.menuBarShelfEnabled else { return }
                self.isCollapsing = false
                self.hasVisibilityRestriction = succeeded
                self.state = succeeded ? .tucked : .visible
                self.updateItemAppearance()
                if !succeeded {
                    self.toggleItem?.button?.toolTip = AppStrings.text(.menuBarShelfUnavailable)
                }
            }
            return
        } else if usesVisibilityRestriction {
            isCollapsing = false
            hasVisibilityRestriction = false
            visibility.restore()
        } else if state == .tucked {
            verifyArrangementAfterTucking()
        }

        updateItemAppearance()
        scheduleAutoHideIfNeeded()
    }

    private func updateItemAppearance() {
        boundaryItem?.button?.title = state.dividerTitle
        guard let button = toggleItem?.button else { return }
        let symbolName = state == .tucked ? "chevron.left" : "chevron.right"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: AppStrings.text(.menuBarShelfToggleTooltip)
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = AppStrings.text(.menuBarShelfToggleTooltip)
    }

    // The expanded divider pushes whatever sits beside it past the edge of the
    // screen. That is the point - it is how the shelf hides icons - but if the
    // divider has been dragged to the other side of the arrow it takes both of
    // this app's own buttons with it, leaving no way to bring them back.
    //
    // Checked rather than predicted: which side is which depends on where macOS
    // placed the items and where the user has since dragged them, and the only
    // reliable answer is whether the arrow is still on a screen afterwards.
    private func verifyArrangementAfterTucking() {
        guard !isRepairingArrangement else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.state == .tucked,
                  let frame = self.toggleItem?.button?.window?.frame,
                  !NSScreen.screens.contains(where: { $0.frame.intersects(frame) })
            else {
                return
            }
            self.repairArrangement()
        }
    }

    private func repairArrangement() {
        isRepairingArrangement = true
        defer { isRepairingArrangement = false }

        // Drop the remembered positions and build the items again, which puts
        // them back where macOS would have placed them.
        for name in ["OmniDock.MenuBarShelf.Toggle", "OmniDock.MenuBarShelf.Boundary"] {
            UserDefaults.standard.removeObject(
                forKey: "NSStatusItem Preferred Position \(name)"
            )
        }
        removeItems()
        state = .visible
        installItemsIfNeeded()
        applyState()
    }

    private func updateLocalizedContent() {
        toggleItem?.button?.toolTip = AppStrings.text(.menuBarShelfToggleTooltip)
        if let button = boundaryItem?.button {
            let label = AppStrings.text(.menuBarShelfDividerTooltip)
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        boundaryMenu?.item(at: 0)?.title = AppStrings.text(.menuSettings)
    }

    private func scheduleAutoHideIfNeeded() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        guard state == .visible, settings.menuBarShelfAutoHideEnabled else {
            return
        }

        lastKnownItemPositions = currentItemPositions()
        let timer = Timer(
            timeInterval: TimeInterval(settings.menuBarShelfAutoHideDelay),
            target: self,
            selector: #selector(autoHideTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        autoHideTimer = timer
    }

    private func removeItems() {
        isCollapsing = false
        hasVisibilityRestriction = false
        if usesVisibilityRestriction { visibility.restore() }
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        if let toggleItem {
            NSStatusBar.system.removeStatusItem(toggleItem)
        }
        if let boundaryItem {
            NSStatusBar.system.removeStatusItem(boundaryItem)
        }
        toggleItem = nil
        boundaryItem = nil
        boundaryMenu = nil
        state = .visible
    }
}
