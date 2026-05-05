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
                let title = (WindowTracker.copyAttribute(element, kAXTitleAttribute) as? String) ?? ""
                // Skip windows whose title is a Claude Code session description
                // (they begin with "✳" and contain session state, not a shell cwd).
                guard !title.hasPrefix("✳") else { continue }
                guard title.lowercased().contains(needle) else { continue }
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

    /// Finds the terminal window owned by the given pid. Useful for matching
    /// a running claude process to its parent terminal by walking the process
    /// parent chain until we hit a known terminal app.
    static func windowForTerminalPid(_ terminalPid: pid_t) -> Match? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return SupportedTerminal.bundleIds.contains(id) && $0.processIdentifier == terminalPid
        }
        guard let app = apps.first else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)

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
        guard let element = candidate else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return Match(pid: pid, element: element, windowID: wid)
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
