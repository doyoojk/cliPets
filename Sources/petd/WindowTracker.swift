import AppKit
@preconcurrency import ApplicationServices

/// Finds the frontmost supported terminal window, pins an overlay to it,
/// and keeps the overlay in sync with move/resize/close events via AXObserver.
///
/// Phase 2: single window. Phase 6 will generalize to multiple windows keyed
/// by (bundleId, windowId, sessionId).
@MainActor
final class WindowTracker {
    /// Fires with the terminal window's current frame in AX coordinates
    /// (top-left origin, Y grows downward). Callers translate to NS coords.
    var onFrameChange: ((CGRect) -> Void)?
    /// Fires when the tracked window is closed, miniaturized, or its app quits.
    var onWindowLost: (() -> Void)?
    /// Fires when the tracked terminal app is activated (brought frontmost).
    /// Used to re-order the pet above newly-foremost windows without pinning
    /// it above everything.
    var onTerminalActivated: (() -> Void)?

    private var observer: AXObserver?
    private var trackedWindow: AXUIElement?
    private var trackedPid: pid_t?
    private var quitObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard ensureAccessibilityPermission() else {
            NSLog("cliPets: Accessibility permission not granted. Open System Settings > Privacy & Security > Accessibility and enable the petd binary. Re-run petd after granting.")
            return
        }

        guard let (pid, window) = findFrontmostTerminalWindow() else {
            NSLog("cliPets: no Ghostty or Terminal.app window found. Start a terminal and relaunch petd.")
            return
        }

        trackedPid = pid
        trackedWindow = window
        installObserver(pid: pid, window: window)
        watchForAppTermination(pid: pid)
        watchForAppActivation(pid: pid)

        if let frame = Self.frame(of: window) {
            onFrameChange?(frame)
        }
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        if let quitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(quitObserver)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        observer = nil
        trackedWindow = nil
        trackedPid = nil
        quitObserver = nil
        activationObserver = nil
    }

    // MARK: - Lookup

    private func findFrontmostTerminalWindow() -> (pid_t, AXUIElement)? {
        let candidates = NSWorkspace.shared.runningApplications
            .filter {
                guard let id = $0.bundleIdentifier else { return false }
                return SupportedTerminal.bundleIds.contains(id)
            }
            .sorted { (a, _) in a.isActive } // active-first, stable otherwise

        for app in candidates {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            if let focusedRef = Self.copyAttribute(appEl, kAXFocusedWindowAttribute),
               CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
                let window = focusedRef as! AXUIElement
                return (pid, window)
            }
            if let windowsRef = Self.copyAttribute(appEl, kAXWindowsAttribute),
               let windows = windowsRef as? [AXUIElement],
               let first = windows.first {
                return (pid, first)
            }
        }
        return nil
    }

    // MARK: - Observer

    private func installObserver(pid: pid_t, window: AXUIElement) {
        var obs: AXObserver?
        let err = AXObserverCreate(pid, windowTrackerAXCallback, &obs)
        guard err == .success, let obs else {
            NSLog("cliPets: AXObserverCreate failed with error \(err.rawValue)")
            return
        }
        self.observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [String] = [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]
        for name in notifications {
            let addErr = AXObserverAddNotification(obs, window, name as CFString, refcon)
            if addErr != .success && addErr != .notificationAlreadyRegistered {
                NSLog("cliPets: AXObserverAddNotification(\(name)) failed: \(addErr.rawValue)")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
    }

    private func watchForAppTermination(pid: pid_t) {
        let center = NSWorkspace.shared.notificationCenter
        quitObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier == pid
            else { return }
            MainActor.assumeIsolated {
                self?.onWindowLost?()
            }
        }
    }

    private func watchForAppActivation(pid: pid_t) {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier == pid
            else { return }
            MainActor.assumeIsolated {
                self?.onTerminalActivated?()
            }
        }
    }

    fileprivate func handle(notification: String) {
        guard let trackedWindow else { return }
        switch notification {
        case kAXMovedNotification, kAXResizedNotification, kAXWindowDeminiaturizedNotification:
            if let frame = Self.frame(of: trackedWindow) {
                onFrameChange?(frame)
            }
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            onWindowLost?()
        default:
            break
        }
    }

    // MARK: - AX helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard
            let posRef = copyAttribute(window, kAXPositionAttribute),
            let sizeRef = copyAttribute(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let okPos = AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        let okSize = AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard okPos, okSize else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Permission

private func ensureAccessibilityPermission() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - C callback

/// C-callable AX observer callback. Dispatches into the tracker via refcon.
private func windowTrackerAXCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        tracker.handle(notification: name)
    }
}
