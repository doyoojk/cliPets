import AppKit
import CoreVideo
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var displayLink: CVDisplayLink?
    private var eventServer: EventServer?
    private var spriteFrames: [CGImage] = []

    /// One pet per terminal window we've seen Claude activity on, keyed by
    /// CGWindowID.
    private var overlays: [CGWindowID: PetOverlay] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let granted = ensureAccessibilityPermission(prompt: true)
        buildSpriteFrames()
        startFrameSync()
        startEventServer()
        if granted {
            discoverExistingTerminalWindows()
        } else {
            NSLog("cliPets: Accessibility permission missing; pets will only spawn when hook events fire from a focused terminal")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        eventServer?.stop()
    }

    // MARK: - Sprite frames (shared across all overlays)

    private func buildSpriteFrames() {
        spriteFrames = [
            SpriteBuilder.makeCat(state: .idle),
            SpriteBuilder.makeCat(state: .blink),
        ]
    }

    // MARK: - Event server

    private func startEventServer() {
        let path = Self.defaultSocketPath()
        let server = EventServer(socketPath: path)
        server.start { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppDelegate.shared?.handleHookEvent(event)
                }
            }
        }
        eventServer = server
    }

    /// Phase 4 will branch on event.eventType to drive different animations.
    /// For now we just ensure a pet exists on whichever terminal window
    /// the user was focused on when the event fired, and log.
    private func handleHookEvent(_ event: HookEvent) {
        NSLog(
            "cliPets: hook \(event.eventType) tool=\(event.toolName ?? "-") session=\(event.sessionId?.prefix(8) ?? "-") cwd=\(event.cwd ?? "-")"
        )
        guard let match = TerminalLocator.focusedTerminalWindow() else {
            NSLog("cliPets: no terminal window focused at hook time; skipping pet spawn")
            return
        }
        ensureOverlay(pid: match.pid, element: match.element, windowID: match.windowID)
        overlays[match.windowID]?.recordEvent(event)
    }

    /// At launch, spawn a pet on every visible Ghostty / Terminal.app window
    /// the user already has open. Without this, petd waits for a hook event
    /// to fire before any pets appear — confusing if you already have several
    /// Claude sessions running idle.
    private func discoverExistingTerminalWindows() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return SupportedTerminal.bundleIds.contains(id)
        }
        for app in apps {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            guard
                let windowsRef = WindowTracker.copyAttribute(appEl, kAXWindowsAttribute),
                let windows = windowsRef as? [AXUIElement]
            else { continue }
            for element in windows {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { continue }
                ensureOverlay(pid: pid, element: element, windowID: wid)
            }
        }
        NSLog("cliPets: discovered \(overlays.count) terminal window(s) at startup")
    }

    private func ensureOverlay(pid: pid_t, element: AXUIElement, windowID: CGWindowID) {
        if overlays[windowID] != nil { return }
        let overlay = PetOverlay(pid: pid, element: element, windowID: windowID, frames: spriteFrames)
        overlay.onClosed = { [weak self, windowID] in
            self?.overlays.removeValue(forKey: windowID)
        }
        overlays[windowID] = overlay
        NSLog("cliPets: spawned pet for window \(windowID) (pid \(pid)). Active pets: \(overlays.count)")
    }

    // MARK: - Display link drives all overlays

    private func startFrameSync() {
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard err == kCVReturnSuccess, let link else {
            NSLog("cliPets: CVDisplayLink unavailable (\(err)); pet positions will be tracker-driven only")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, cliPetsDisplayLinkCallback, refcon)
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    fileprivate func displayLinkTick() {
        for overlay in overlays.values {
            overlay.syncFromCGWindowList()
        }
    }

    // MARK: - Static helpers (used by PetOverlay)

    /// Pet positions read from CGWindowList in the hot loop instead of AX
    /// (no IPC to the terminal app, just a cached lookup). Returns the
    /// terminal's bounds in screen coordinates with origin at upper-left
    /// (same orientation as AX).
    static func frameFromCGWindowList(windowID: CGWindowID) -> CGRect? {
        let opts: CGWindowListOption = .optionIncludingWindow
        guard
            let info = CGWindowListCopyWindowInfo(opts, windowID) as? [[String: Any]],
            let dict = info.first,
            let boundsCF = dict[kCGWindowBounds as String] as CFTypeRef?
        else { return nil }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsCF as! CFDictionary, &rect) else {
            return nil
        }
        return rect
    }

    /// Converts an AX rect (top-left origin, Y downward, relative to primary
    /// display) to an NS rect (bottom-left origin, Y upward, primary screen's
    /// bottom-left at (0,0)).
    static func nsRect(fromAX axRect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        return NSRect(
            x: axRect.origin.x,
            y: primary.frame.height - axRect.origin.y - axRect.size.height,
            width: axRect.size.width,
            height: axRect.size.height
        )
    }

    static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.clipets/clipets.sock"
    }

    /// EventServer's @Sendable callback fires off the main actor and can't
    /// directly capture a non-Sendable AppDelegate, so we publish a weak
    /// global reference set during applicationDidFinishLaunching.
    fileprivate static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }
}

/// CVDisplayLink output callback. Runs on the CV thread; hops to main to
/// touch AppKit. Captures AppDelegate via Unmanaged so we don't fight Swift's
/// strict concurrency about C function pointers.
private func cliPetsDisplayLinkCallback(
    displayLink: CVDisplayLink,
    inNow: UnsafePointer<CVTimeStamp>,
    inOutputTime: UnsafePointer<CVTimeStamp>,
    flagsIn: CVOptionFlags,
    flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    refcon: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let refcon else { return kCVReturnSuccess }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            appDelegate.displayLinkTick()
        }
    }
    return kCVReturnSuccess
}
