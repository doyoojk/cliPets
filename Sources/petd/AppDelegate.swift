import AppKit
import CoreVideo
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var displayLink: CVDisplayLink?
    private var eventServer: EventServer?
    private var variantSprites: [String: [PetAnimationState: [CGImage]]] = [:]
    private var petCollection = PetCollection()
    private var pawMenu: PawMenuController?
    private var overlaysHidden = false

    /// One pet per Claude session, keyed by session_id.
    private var overlays: [String: PetOverlay] = [:]
    /// Ordered slot list of session_ids per terminal window. The slot index
    /// determines stacking position along the window's top-right edge, and
    /// the count determines auto-fit pet size.
    private var sessionsByWindow: [CGWindowID: [String]] = [:]
    private var debugLogTick: Int = 0

    private let maxPetSize: CGFloat = 70
    private let minPetSize: CGFloat = 22
    private let petGap: CGFloat = 6
    /// Reserved on the left of the window for the traffic-light buttons and
    /// any window-title controls; we don't try to stack pets across that area.
    private let leftReserved: CGFloat = 90
    private let rightInset: CGFloat = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        let granted = ensureAccessibilityPermission(prompt: true)
        NSLog("cliPets: AX trusted=\(granted) bundleId=\(Bundle.main.bundleIdentifier ?? "nil") bundlePath=\(Bundle.main.bundlePath)")
        buildVariantSprites()
        startFrameSync()
        startEventServer()
        startPawMenu()
        // Always try to adopt sessions; individual AX calls fail gracefully if not trusted.
        adoptRecentSessions()
        if !granted {
            // Re-check every 2 s until permission is granted, then do a one-shot adoption.
            schedulePermissionRetry()
        }
    }

    private func schedulePermissionRetry() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if ensureAccessibilityPermission(prompt: false) {
                NSLog("cliPets: AX permission now granted — retrying session adoption")
                timer.invalidate()
                MainActor.assumeIsolated { self.adoptRecentSessions() }
            }
        }
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

    // MARK: - Paw menu

    private func startPawMenu() {
        let menu = PawMenuController()
        menu.activeSessionCount = { [weak self] in self?.overlays.count ?? 0 }
        menu.onToggleOverlays = { [weak self] in self?.toggleAllOverlays() }
        menu.onQuit = { NSApp.terminate(nil) }
        pawMenu = menu
    }

    private func toggleAllOverlays() {
        overlaysHidden.toggle()
        for overlay in overlays.values {
            overlaysHidden ? overlay.hide() : overlay.show()
        }
    }

    // MARK: - Sprite frames (one dict per variant, built at startup)

    private func buildVariantSprites() {
        for variant in PetCatalog.all {
            variantSprites[variant.id] = SpriteBuilder.allSprites(palette: variant.palette)
        }
    }

    private func sprites(forVariantId id: String) -> [PetAnimationState: [CGImage]] {
        variantSprites[id] ?? variantSprites[PetCatalog.all[0].id] ?? [:]
    }

    // MARK: - Adopt pre-existing sessions

    /// At launch, find running `claude` processes via pgrep/lsof, derive their
    /// project directories, and spawn a pet for the most recent session in each.
    /// Uses the exact cwd of each running process, so TerminalLocator matching
    /// is precise rather than relying on window titles.
    private func adoptRecentSessions() {
        let pidCwds = runningClaudePidCwds()
        NSLog("cliPets: adoptRecentSessions — \(pidCwds.count) running claude process(es): \(pidCwds.map { "\($0.pid):\($0.cwd)" }.joined(separator: ", "))")

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsRoot = URL(fileURLWithPath: "\(home)/.claude/projects")

        for (claudePid, cwd) in pidCwds {
            let encoded = Self.encodeProjectDirName(cwd: cwd)
            let projectDir = projectsRoot.appendingPathComponent(encoded)

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else {
                NSLog("cliPets: adoptRecentSessions — no project dir for cwd \(cwd)")
                continue
            }

            let sorted = files
                .filter { $0.pathExtension == "jsonl" }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }

            guard let file = sorted.first else { continue }
            let sessionId = file.deletingPathExtension().lastPathComponent
            guard overlays[sessionId] == nil else { continue }

            // Primary: walk the parent-pid chain to find the exact terminal that owns this claude process.
            // Secondary: fall back to cwd-title match (skips ✳-prefixed titles).
            // Tertiary: focused terminal.
            var match: TerminalLocator.Match?
            if let termPid = terminalPidForProcess(claudePid),
               let m = TerminalLocator.windowForTerminalPid(termPid) {
                NSLog("cliPets: adoptRecentSessions — session \(sessionId.prefix(8)) matched window by parent pid \(termPid)")
                match = m
            } else if let m = TerminalLocator.windowMatchingCwd(cwd) {
                NSLog("cliPets: adoptRecentSessions — session \(sessionId.prefix(8)) matched window by cwd title (\(cwd))")
                match = m
            } else if let m = TerminalLocator.focusedTerminalWindow() {
                NSLog("cliPets: adoptRecentSessions — session \(sessionId.prefix(8)) fell back to focused terminal")
                match = m
            }
            guard let match else {
                NSLog("cliPets: adoptRecentSessions — no terminal window found for session \(sessionId.prefix(8))")
                continue
            }

            spawnOverlay(
                sessionId: sessionId,
                pid: match.pid,
                element: match.element,
                windowID: match.windowID,
                event: HookEvent(
                    eventType: "SessionStart",
                    cwd: cwd,
                    sessionId: sessionId,
                    transcriptPath: file.path,
                    toolName: nil
                )
            )
        }
    }

    /// Returns (pid, cwd) pairs for every running `claude` process.
    private func runningClaudePidCwds() -> [(pid: Int32, cwd: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Emit "PID cwd" lines, one per running claude process.
        task.arguments = [
            "-c",
            "pgrep -x claude | while read p; do cwd=$(lsof -p $p -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//'); [ -n \"$cwd\" ] && echo \"$p $cwd\"; done"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            return (pid: pid, cwd: String(parts[1]))
        }
    }

    /// Walk the parent-PID chain from `pid` and return the first pid that
    /// belongs to a running supported terminal app, or nil if none is found.
    private func terminalPidForProcess(_ pid: Int32) -> pid_t? {
        let terminalPids = Set(
            NSWorkspace.shared.runningApplications
                .filter {
                    guard let id = $0.bundleIdentifier else { return false }
                    return SupportedTerminal.bundleIds.contains(id)
                }
                .map { $0.processIdentifier }
        )

        var current = pid
        var visited = Set<Int32>()
        while current > 1, !visited.contains(current) {
            visited.insert(current)
            if terminalPids.contains(current) { return current }
            // Read parent pid via sysctl.
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            let ret = sysctl(&mib, 4, &info, &size, nil, 0)
            guard ret == 0 else { break }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// Encode a filesystem path to the format Claude uses for project directory names:
    /// replace `/` with `-`, then `.` with `-`.
    private static func encodeProjectDirName(cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
           .replacingOccurrences(of: ".", with: "-")
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

        // Wildcard session ID: broadcast the event to all active pets (used by `clipets test`).
        if sessionId == "*" {
            for overlay in overlays.values { overlay.recordEvent(event) }
            return
        }

        // Session ended → remove the pet for that session.
        if event.eventType == "SessionEnd" {
            if let overlay = overlays[sessionId] {
                NSLog("cliPets: closing pet for session \(sessionId.prefix(8)) (SessionEnd)")
                overlay.close()
            }
            petCollection.removeSession(sessionId)
            return
        }

        if let existing = overlays[sessionId] {
            existing.recordEvent(event)
            return
        }

        // Try to find the exact terminal window for this session by scanning running
        // claude processes and matching via parent-PID chain. Falls back to
        // CWD title match, then focused terminal.
        guard let match = findTerminalForSession(sessionId, cwd: event.cwd) else {
            NSLog("cliPets: no terminal window matched for session \(sessionId.prefix(8)) (AX trusted=\(AXIsProcessTrusted()))")
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

    /// Find the terminal window that owns `sessionId` by scanning running claude
    /// processes. Primary: walk parent-PID chain from the claude process to the
    /// terminal. Secondary: CWD title match. Tertiary: focused terminal.
    private func findTerminalForSession(_ sessionId: String, cwd: String?) -> TerminalLocator.Match? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsRoot = URL(fileURLWithPath: "\(home)/.claude/projects")

        for (claudePid, pidCwd) in runningClaudePidCwds() {
            let encoded = Self.encodeProjectDirName(cwd: pidCwd)
            let sessionFile = projectsRoot
                .appendingPathComponent(encoded)
                .appendingPathComponent("\(sessionId).jsonl")
            guard fm.fileExists(atPath: sessionFile.path) else { continue }

            if let termPid = terminalPidForProcess(claudePid),
               let m = TerminalLocator.windowForTerminalPid(termPid) {
                NSLog("cliPets: bound new session \(sessionId.prefix(8)) to terminal via process walk (claude pid \(claudePid))")
                return m
            }
        }

        if let cwd, let m = TerminalLocator.windowMatchingCwd(cwd) {
            NSLog("cliPets: bound new session \(sessionId.prefix(8)) by cwd match (\(cwd))")
            return m
        }

        if let m = TerminalLocator.focusedTerminalWindow() {
            NSLog("cliPets: bound new session \(sessionId.prefix(8)) to focused terminal (fallback)")
            return m
        }

        return nil
    }

    private func spawnOverlay(
        sessionId: String,
        pid: pid_t,
        element: AXUIElement,
        windowID: CGWindowID,
        event: HookEvent
    ) {
        // Ghostty gives each tab its own AXWindow + CGWindowID, but all tabs in
        // the same window share the same terminal pid. Collapse all sessions from
        // the same terminal process into one slot group so pets lay out
        // side-by-side instead of stacking.
        let groupID = canonicalWindowID(for: windowID, pid: pid)

        var sessions = sessionsByWindow[groupID, default: []]
        sessions.append(sessionId)
        sessionsByWindow[groupID] = sessions

        let (variant, isNew) = petCollection.variantForSession(sessionId)
        if isNew {
            NSLog("cliPets: unlocked new variant \(variant.id) (\(variant.name), \(variant.rarity.rawValue))")
        }
        let petSize = computePetSize(forWindowID: groupID, count: sessions.count)
        let overlay = PetOverlay(
            sessionId: sessionId,
            pid: pid,
            element: element,
            windowID: groupID,
            slotIndex: sessions.count - 1,
            petSize: petSize,
            sprites: sprites(forVariantId: variant.id)
        )
        overlay.recordEvent(event)
        overlay.onClosed = { [weak self, sessionId, groupID] in
            self?.overlayDidClose(sessionId: sessionId, windowID: groupID)
        }
        overlays[sessionId] = overlay

        relayoutPets(forWindowID: groupID)

        NSLog(
            "cliPets: spawned pet for session \(sessionId.prefix(8)) on window \(groupID) slot \(sessions.count - 1); \(sessions.count) pet(s) on this window"
        )
    }

    /// Returns the existing group key for the given terminal pid/window, or
    /// `windowID` itself if no matching group exists.
    ///
    /// Ghostty creates a fresh CGWindowID for every tab, so frame-based
    /// matching alone fails for background tabs (they don't appear in
    /// CGWindowList). Instead we match by terminal pid first, then use the
    /// on-screen frame as a tiebreaker: if two groups share the same pid but
    /// we can confirm their frames differ by more than 50pt, they're separate
    /// OS windows and stay in separate groups.
    private func canonicalWindowID(for windowID: CGWindowID, pid: pid_t) -> CGWindowID {
        let newFrame = Self.frameFromCGWindowList(windowID: windowID)

        for (existingGroupID, sessions) in sessionsByWindow {
            // Match by terminal pid — all tabs of a Ghostty window share one pid.
            guard
                let firstSession = sessions.first,
                let existingOverlay = overlays[firstSession],
                existingOverlay.pid == pid
            else { continue }

            // If both frames are available, make sure they're not from a
            // completely different OS window (e.g. two separate Ghostty windows).
            if let nf = newFrame,
               let ef = Self.frameFromCGWindowList(windowID: existingGroupID),
               abs(ef.maxX - nf.maxX) > 50 || abs(ef.minY - nf.minY) > 50 {
                continue
            }

            return existingGroupID
        }
        return windowID
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
        relayoutPets(forWindowID: windowID, animated: true)
    }

    /// Recompute petSize and reassign slot indices for every pet on a window,
    /// then force-sync each pet to the correct position immediately rather than
    /// waiting for the next display-link tick.
    private func relayoutPets(forWindowID windowID: CGWindowID, animated: Bool = false) {
        guard let sessions = sessionsByWindow[windowID] else { return }
        let petSize = computePetSize(forWindowID: windowID, count: sessions.count)
        for (index, sessionId) in sessions.enumerated() {
            guard let overlay = overlays[sessionId] else { continue }
            overlay.slotIndex = index
            overlay.petSize = petSize
            overlay.forceSync(animated: animated)
            NSLog("cliPets: relayout session \(sessionId.prefix(8)) → slot \(index), size \(Int(petSize))pt, window \(windowID)")
        }
    }

    /// Per-window pet sizing: shrink uniformly so all pets fit between the
    /// traffic-light area and the right edge.
    private func computePetSize(forWindowID windowID: CGWindowID, count: Int) -> CGFloat {
        let windowWidth = bestFrame(forGroupID: windowID)?.width ?? 800
        let available = max(0, windowWidth - leftReserved - rightInset)
        let perPet = available / CGFloat(count) - petGap
        return min(maxPetSize, max(minPetSize, perPet))
    }

    /// Best available frame for a window group.
    ///
    /// Strategy:
    /// 1. CGWindowList by canonical group ID — works when that tab is active.
    /// 2. CGWindowList scan by terminal PID — finds whichever Ghostty tab is
    ///    currently in front, so movement tracking works on any tab.
    /// 3. AX direct query — accurate at rest but stale during a drag; kept as
    ///    a last resort so pets at least snap into place after the drag ends.
    private func bestFrame(forGroupID groupID: CGWindowID) -> CGRect? {
        if let f = Self.frameFromCGWindowListAnySpace(windowID: groupID) {
            return f
        }
        guard let sessions = sessionsByWindow[groupID], !sessions.isEmpty else { return nil }
        // Scan all on-screen windows for the terminal PID so we find the active tab.
        if let pid = overlays[sessions[0]]?.pid,
           let f = Self.frameForAnyOnscreenWindow(pid: pid) {
            // if shouldLog { NSLog("cliPets: bestFrame group=\(groupID) source=PIDScan pid=\(pid) frame=\(f)") }
            return f
        }
        for sid in sessions {
            guard let overlay = overlays[sid] else { continue }
            if let f = WindowTracker.frame(of: overlay.element) {
                // if shouldLog { NSLog("cliPets: bestFrame group=\(groupID) source=AX[\(sid.prefix(8))] frame=\(f)") }
                return f
            }
            // if shouldLog { NSLog("cliPets: bestFrame group=\(groupID) AX[\(sid.prefix(8))] returned nil") }
        }
        // if shouldLog { NSLog("cliPets: bestFrame group=\(groupID) NO FRAME FOUND") }
        return nil
    }

    /// Finds the frame of any normal on-screen window owned by the given PID.
    /// Used to locate whichever Ghostty tab is currently active when the
    /// canonical tab's window has been ordered to the background.
    static func frameForAnyOnscreenWindow(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for entry in list {
            guard
                let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == pid,
                let layer = entry[kCGWindowLayer as String] as? Int32,
                layer == 0,
                let boundsCF = entry[kCGWindowBounds as String]
            else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsCF as! CFDictionary, &rect) else { continue }
            // Skip small windows (alert sheets, confirmation dialogs, etc.).
            guard rect.width >= 300, rect.height >= 200 else { continue }
            return rect
        }
        return nil
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
        debugLogTick &+= 1
        for (groupID, sessions) in sessionsByWindow {
            guard !sessions.isEmpty else { continue }

            // Recompute pet size if the window width changed.
            if sessions.count > 1,
               let firstOverlay = overlays[sessions[0]] {
                let target = computePetSize(forWindowID: groupID, count: sessions.count)
                if abs(target - firstOverlay.petSize) >= 1 {
                    relayoutPets(forWindowID: groupID)
                }
            }

            // terminalOnScreen: true only if the terminal window is visible in
            // the current Space. If we can only get the frame via AX (not
            // CGWindowList), the terminal is in a different Space or hidden —
            // hide the pet so it doesn't float over unrelated full-screen apps.
            let terminalPid = overlays[sessions[0]]?.pid
            let byWID = Self.frameFromCGWindowList(windowID: groupID)
            let byPID = terminalPid.flatMap { Self.frameForAnyOnscreenWindow(pid: $0) }
            let onScreenFrame = byWID ?? byPID
            let terminalOnScreen = onScreenFrame != nil
            // byWID==nil + byPID!=nil means the tracked window left the current Space
            // (Ghostty creates a new window for full-screen); treat as full-screen.
            let inferredFullScreen = byWID == nil && byPID != nil

            // Fall back to AX only for positioning, not for showing pets.
            let axFrame = sessions.lazy
                .compactMap { self.overlays[$0].flatMap { WindowTracker.frame(of: $0.element) } }
                .first
            guard let frame = onScreenFrame ?? axFrame else { continue }

            for sid in sessions {
                guard let overlay = overlays[sid] else { continue }
                if terminalOnScreen {
                    overlay.showIfHiddenBySpace()
                } else {
                    overlay.hideForSpace()
                }
                if terminalOnScreen {
                    overlay.applySharedFrame(frame, inferredFullScreen: inferredFullScreen)
                }
            }
        }
    }

    // MARK: - Static helpers (used by PetOverlay)

    /// Returns the on-screen frame of the given window, or nil if the window
    /// is not visible on the current Space.
    static func frameFromCGWindowList(windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for entry in list {
            guard
                let wid = entry[kCGWindowNumber as String] as? CGWindowID,
                wid == windowID,
                let boundsCF = entry[kCGWindowBounds as String]
            else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsCF as! CFDictionary, &rect) else { continue }
            return rect
        }
        return nil
    }

    /// Returns the frame of the given window regardless of which Space it is on.
    /// Used only for positioning when the window is confirmed to be on-screen.
    static func frameFromCGWindowListAnySpace(windowID: CGWindowID) -> CGRect? {
        let opts: CGWindowListOption = .optionIncludingWindow
        guard
            let info = CGWindowListCopyWindowInfo(opts, windowID) as? [[String: Any]],
            let dict = info.first,
            let boundsCF = dict[kCGWindowBounds as String] as CFTypeRef?
        else { return nil }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsCF as! CFDictionary, &rect) else { return nil }
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
