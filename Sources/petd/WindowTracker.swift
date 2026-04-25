import AppKit
@preconcurrency import ApplicationServices

// Private but stable-for-years AX SPI used by Rectangle, yabai, etc. Returns
// the CGWindowID for an AXUIElement so we can Z-order cross-app windows
// with NSWindow.order(.above, relativeTo:).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Watches a single terminal window via AXObserver. One instance per pet.
/// Multiple WindowTrackers can co-exist for the same pid (AX allows multiple
/// observers per process).
@MainActor
final class WindowTracker {
    let pid: pid_t
    let element: AXUIElement
    let windowID: CGWindowID

    /// Fires with the terminal window's frame in AX coordinates (top-left
    /// origin, Y grows downward). Callers translate to NS coords.
    var onFrameChange: ((CGRect) -> Void)?
    /// Fires when the window is destroyed (closed) or its app terminates.
    /// Indicates the pet should tear down permanently.
    var onWindowLost: (() -> Void)?
    /// Fires when the window is miniaturized into the Dock. Pet should hide
    /// but not destroy itself — onWindowShown will fire when it comes back.
    var onWindowHidden: (() -> Void)?
    /// Fires when the window is deminiaturized (returns from the Dock).
    var onWindowShown: (() -> Void)?
    /// Fires when the terminal app is brought to the front. Used to re-anchor
    /// pet Z-order above the terminal.
    var onTerminalActivated: (() -> Void)?

    private var observer: AXObserver?
    private var quitObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    init(pid: pid_t, element: AXUIElement, windowID: CGWindowID) {
        self.pid = pid
        self.element = element
        self.windowID = windowID
    }

    func start() {
        installObserver()
        watchForAppTermination()
        watchForAppActivation()
        if let frame = Self.frame(of: element) {
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
        quitObserver = nil
        activationObserver = nil
    }

    // MARK: - Observer

    private func installObserver() {
        var obs: AXObserver?
        let err = AXObserverCreate(pid, windowTrackerAXCallback, &obs)
        guard err == .success, let obs else {
            NSLog("cliPets: AXObserverCreate failed (\(err.rawValue))")
            return
        }
        self.observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let names: [String] = [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]
        for name in names {
            let r = AXObserverAddNotification(obs, element, name as CFString, refcon)
            if r != .success && r != .notificationAlreadyRegistered {
                NSLog("cliPets: AXObserverAddNotification(\(name)) failed: \(r.rawValue)")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
    }

    private func watchForAppTermination() {
        let center = NSWorkspace.shared.notificationCenter
        quitObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let me = self,
                app.processIdentifier == me.pid
            else { return }
            MainActor.assumeIsolated {
                me.onWindowLost?()
            }
        }
    }

    private func watchForAppActivation() {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let me = self,
                app.processIdentifier == me.pid
            else { return }
            MainActor.assumeIsolated {
                me.onTerminalActivated?()
            }
        }
    }

    fileprivate func handle(notification: String) {
        switch notification {
        case kAXMovedNotification, kAXResizedNotification:
            if let frame = Self.frame(of: element) {
                onFrameChange?(frame)
            }
        case kAXWindowMiniaturizedNotification:
            onWindowHidden?()
        case kAXWindowDeminiaturizedNotification:
            onWindowShown?()
            if let frame = Self.frame(of: element) {
                onFrameChange?(frame)
            }
        case kAXUIElementDestroyedNotification:
            onWindowLost?()
        default:
            break
        }
    }

    // MARK: - AX helpers

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

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }
}

// MARK: - Permission

func ensureAccessibilityPermission(prompt: Bool) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - C callback

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
