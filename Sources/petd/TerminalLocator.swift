import AppKit
@preconcurrency import ApplicationServices

/// One-shot lookup of the currently focused terminal window across all
/// supported terminal apps. Used at hook-event time to bind a fresh Claude
/// session to a window: when an event arrives, the user is typically focused
/// on the terminal that produced it.
@MainActor
enum TerminalLocator {
    struct Match {
        let pid: pid_t
        let element: AXUIElement
        let windowID: CGWindowID
    }

    static func focusedTerminalWindow() -> Match? {
        let candidates = NSWorkspace.shared.runningApplications
            .filter {
                guard let id = $0.bundleIdentifier else { return false }
                return SupportedTerminal.bundleIds.contains(id)
            }
            .sorted { $0.isActive && !$1.isActive }

        for app in candidates {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)

            // Prefer the app's currently focused window; fall back to the
            // first window in the list.
            let candidate: AXUIElement?
            if let ref = WindowTracker.copyAttribute(appEl, kAXFocusedWindowAttribute),
               CFGetTypeID(ref) == AXUIElementGetTypeID() {
                candidate = (ref as! AXUIElement)
            } else if let ref = WindowTracker.copyAttribute(appEl, kAXWindowsAttribute),
                      let arr = ref as? [AXUIElement],
                      let first = arr.first {
                candidate = first
            } else {
                candidate = nil
            }

            guard let element = candidate else { continue }
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { continue }
            return Match(pid: pid, element: element, windowID: wid)
        }
        return nil
    }
}
