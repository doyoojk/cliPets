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

    /// Finds a terminal window whose AX title hints at the given cwd. We
    /// match the cwd's last path component against the title's lowercase
    /// substring — most shells include the current directory's basename in
    /// the window title, so this is a strong signal even when the user has
    /// switched focus away from the terminal that fired the hook.
    static func windowMatchingCwd(_ cwd: String) -> Match? {
        let needle = (cwd as NSString).lastPathComponent.lowercased()
        guard !needle.isEmpty else { return nil }

        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return SupportedTerminal.bundleIds.contains(id)
        }
        for app in apps {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            guard
                let ref = WindowTracker.copyAttribute(appEl, kAXWindowsAttribute),
                let windows = ref as? [AXUIElement]
            else { continue }
            for element in windows {
                let title = (WindowTracker.copyAttribute(element, kAXTitleAttribute) as? String)?.lowercased() ?? ""
                guard title.contains(needle) else { continue }
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { continue }
                return Match(pid: pid, element: element, windowID: wid)
            }
        }
        return nil
    }

    /// Returns every open window across all supported terminal apps.
    static func allTerminalWindows() -> [Match] {
        var results: [Match] = []
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return SupportedTerminal.bundleIds.contains(id)
        }
        for app in apps {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            guard
                let ref = WindowTracker.copyAttribute(appEl, kAXWindowsAttribute),
                let windows = ref as? [AXUIElement]
            else { continue }
            for element in windows {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { continue }
                results.append(Match(pid: pid, element: element, windowID: wid))
            }
        }
        return results
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
