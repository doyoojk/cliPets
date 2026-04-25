import AppKit
import CoreVideo
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var displayLink: CVDisplayLink?
    private var eventServer: EventServer?
    private var spriteFrames: [CGImage] = []

    /// One pet per Claude session, keyed by session_id.
    private var overlays: [String: PetOverlay] = [:]
    /// Ordered slot list of session_ids per terminal window. The slot index
    /// determines stacking position along the window's top-right edge, and
    /// the count determines auto-fit pet size.
    private var sessionsByWindow: [CGWindowID: [String]] = [:]

    private let maxPetSize: CGFloat = 70
    private let minPetSize: CGFloat = 22
    private let petGap: CGFloat = 6
    /// Reserved on the left of the window for the traffic-light buttons and
    /// any window-title controls; we don't try to stack pets across that area.
    private let leftReserved: CGFloat = 90
    private let rightInset: CGFloat = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ensureAccessibilityPermission(prompt: true)
        buildSpriteFrames()
        startFrameSync()
        startEventServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        sessionsByWindow.removeAll()
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

    /// One pet per Claude session. The session is bound to whichever terminal
    /// window is focused at the moment the first hook for that session
    /// arrives — wire up the SessionStart hook (in ~/.claude/settings.json)
    /// so this happens the instant a session opens, while the user is still
    /// looking at the right terminal.
    private func handleHookEvent(_ event: HookEvent) {
        NSLog(
            "cliPets: hook \(event.eventType) tool=\(event.toolName ?? "-") session=\(event.sessionId?.prefix(8) ?? "-") cwd=\(event.cwd ?? "-")"
        )
        guard let sessionId = event.sessionId else { return }

        // Session ended → remove the pet for that session.
        if event.eventType == "SessionEnd" {
            if let overlay = overlays[sessionId] {
                NSLog("cliPets: closing pet for session \(sessionId.prefix(8)) (SessionEnd)")
                overlay.close()
            }
            return
        }

        if let existing = overlays[sessionId] {
            existing.recordEvent(event)
            return
        }

        // For a new session, prefer matching the hook's cwd against terminal
        // window titles (most shells embed the cwd basename in the title).
        // This gives us the right window even when the user has switched
        // focus elsewhere. Fall back to the focused terminal otherwise.
        var match: TerminalLocator.Match?
        if let cwd = event.cwd, let m = TerminalLocator.windowMatchingCwd(cwd) {
            NSLog("cliPets: bound new session \(sessionId.prefix(8)) by cwd match (\(cwd))")
            match = m
        }
        if match == nil, let m = TerminalLocator.focusedTerminalWindow() {
            NSLog("cliPets: bound new session \(sessionId.prefix(8)) to focused terminal")
            match = m
        }
        guard let match else {
            NSLog("cliPets: no terminal window matched for session \(sessionId.prefix(8))")
            return
        }

        spawnOverlay(
            sessionId: sessionId,
            pid: match.pid,
            element: match.element,
            windowID: match.windowID,
            event: event
        )
    }

    private func spawnOverlay(
        sessionId: String,
        pid: pid_t,
        element: AXUIElement,
        windowID: CGWindowID,
        event: HookEvent
    ) {
        var sessions = sessionsByWindow[windowID, default: []]
        sessions.append(sessionId)
        sessionsByWindow[windowID] = sessions

        let petSize = computePetSize(forWindowID: windowID, count: sessions.count)
        let overlay = PetOverlay(
            sessionId: sessionId,
            pid: pid,
            element: element,
            windowID: windowID,
            slotIndex: sessions.count - 1,
            petSize: petSize,
            frames: spriteFrames
        )
        overlay.recordEvent(event)
        overlay.onClosed = { [weak self, sessionId, windowID] in
            self?.overlayDidClose(sessionId: sessionId, windowID: windowID)
        }
        overlays[sessionId] = overlay

        // After mutation, resize all siblings on this window so the new
        // count fits.
        relayoutPets(forWindowID: windowID)

        NSLog(
            "cliPets: spawned pet for session \(sessionId.prefix(8)) on window \(windowID); now \(sessions.count) pet(s) on this window, size \(Int(petSize))pt"
        )
    }

    private func overlayDidClose(sessionId: String, windowID: CGWindowID) {
        overlays.removeValue(forKey: sessionId)
        guard var sessions = sessionsByWindow[windowID] else { return }
        sessions.removeAll { $0 == sessionId }
        if sessions.isEmpty {
            sessionsByWindow.removeValue(forKey: windowID)
            return
        }
        sessionsByWindow[windowID] = sessions
        relayoutPets(forWindowID: windowID)
    }

    /// Recompute petSize and reassign slot indices for every pet on a window.
    private func relayoutPets(forWindowID windowID: CGWindowID) {
        guard let sessions = sessionsByWindow[windowID] else { return }
        let petSize = computePetSize(forWindowID: windowID, count: sessions.count)
        for (index, sessionId) in sessions.enumerated() {
            guard let overlay = overlays[sessionId] else { continue }
            overlay.slotIndex = index
            overlay.petSize = petSize
        }
    }

    /// Per-window pet sizing: shrink uniformly so all pets fit between the
    /// traffic-light area and the right edge.
    private func computePetSize(forWindowID windowID: CGWindowID, count: Int) -> CGFloat {
        let windowWidth = Self.frameFromCGWindowList(windowID: windowID)?.width ?? 800
        let available = max(0, windowWidth - leftReserved - rightInset)
        let perPet = available / CGFloat(count) - petGap
        return min(maxPetSize, max(minPetSize, perPet))
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
        // First, recompute pet size if any tracked window changed width.
        // Only triggers a relayout if the recomputed size differs by ≥1pt
        // from the current size, so this is cheap on idle frames.
        for (windowID, sessions) in sessionsByWindow where sessions.count > 1 {
            guard
                let firstSession = sessions.first,
                let firstOverlay = overlays[firstSession]
            else { continue }
            let target = computePetSize(forWindowID: windowID, count: sessions.count)
            if abs(target - firstOverlay.petSize) >= 1 {
                relayoutPets(forWindowID: windowID)
            }
        }

        // Then sync each pet's position from the cheap CGWindowList.
        for overlay in overlays.values {
            overlay.syncFromCGWindowList()
        }
    }

    // MARK: - Static helpers (used by PetOverlay)

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

    fileprivate static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }
}

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
