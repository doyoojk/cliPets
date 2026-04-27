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
    /// Ordered list of session_ids — index determines slot (0 = rightmost).
    private var sessionOrder: [String] = []

    private let maxPetSize: CGFloat = 70
    private let minPetSize: CGFloat = 22
    private let petGap: CGFloat = 6
    private let rightInset: CGFloat = 12
    /// Reserved on the left so pets don't run off screen.
    private let leftMargin: CGFloat = 90

    private var lastScreenFrame: CGRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let granted = ensureAccessibilityPermission(prompt: true)
        buildSpriteFrames()
        startFrameSync()
        startEventServer()
        if granted {
            adoptRecentSessions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        sessionOrder.removeAll()
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

    // MARK: - Adopt pre-existing sessions

    /// At launch, find running `claude` processes via lsof, derive their
    /// project directories, and spawn a pet for the most recent session in
    /// each. No time filter — if a `claude` process is running, it gets a pet.
    private func adoptRecentSessions() {
        let cwds = runningClaudeCwds()
        NSLog("cliPets: adoptRecentSessions — found \(cwds.count) running claude cwd(s): \(cwds.joined(separator: ", "))")

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsRoot = URL(fileURLWithPath: "\(home)/.claude/projects")

        for cwd in cwds {
            let encoded = Self.encodeProjectDirName(cwd: cwd)
            let projectDir = projectsRoot.appendingPathComponent(encoded)

            NSLog("cliPets: adoptRecentSessions — checking \(projectDir.path)")

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else {
                NSLog("cliPets: adoptRecentSessions — no project dir at \(projectDir.path)")
                continue
            }

            let sorted = files
                .filter { $0.pathExtension == "jsonl" }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }

            guard let file = sorted.first else {
                NSLog("cliPets: adoptRecentSessions — no session files in \(projectDir.path)")
                continue
            }

            let sessionId = file.deletingPathExtension().lastPathComponent
            guard overlays[sessionId] == nil else {
                NSLog("cliPets: adoptRecentSessions — session \(sessionId.prefix(8)) already has an overlay")
                continue
            }

            NSLog("cliPets: adoptRecentSessions — spawning pet for session \(sessionId.prefix(8)) cwd=\(cwd)")
            spawnOverlay(
                sessionId: sessionId,
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

    /// Run `lsof` to find the working directories of all processes named `claude`.
    private func runningClaudeCwds() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        // pgrep -x matches the exact process name; xargs feeds each PID to lsof.
        task.arguments = [
            "-c",
            "pgrep -x claude | xargs -I{} lsof -p {} -a -d cwd -Fn 2>/dev/null | grep '^n' | sort -u | sed 's/^n//'"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Encode a filesystem path to the format Claude uses for project directory names:
    /// replace `/` with `-` then `.` with `-`.
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

    private func handleHookEvent(_ event: HookEvent) {
        NSLog(
            "cliPets: hook \(event.eventType) tool=\(event.toolName ?? "-") session=\(event.sessionId?.prefix(8) ?? "-") cwd=\(event.cwd ?? "-")"
        )
        guard let sessionId = event.sessionId else { return }

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

        // New session — spawn a pet and place it at the screen top.
        NSLog("cliPets: new session \(sessionId.prefix(8)) — spawning pet")
        spawnOverlay(sessionId: sessionId, event: event)
    }

    private func spawnOverlay(sessionId: String, event: HookEvent) {
        sessionOrder.append(sessionId)
        let petSize = computePetSize(count: sessionOrder.count)
        let overlay = PetOverlay(
            sessionId: sessionId,
            slotIndex: sessionOrder.count - 1,
            petSize: petSize,
            frames: spriteFrames
        )
        overlay.recordEvent(event)
        overlay.onClosed = { [weak self, sessionId] in
            self?.overlayDidClose(sessionId: sessionId)
        }
        overlays[sessionId] = overlay
        relayoutAllPets()

        NSLog(
            "cliPets: spawned pet for session \(sessionId.prefix(8)); \(sessionOrder.count) pet(s) total, size \(Int(petSize))pt"
        )
    }

    private func overlayDidClose(sessionId: String) {
        overlays.removeValue(forKey: sessionId)
        sessionOrder.removeAll { $0 == sessionId }
        relayoutAllPets()
    }

    /// Recompute petSize and slot indices for every pet.
    private func relayoutAllPets() {
        let petSize = computePetSize(count: sessionOrder.count)
        for (index, sessionId) in sessionOrder.enumerated() {
            guard let overlay = overlays[sessionId] else { continue }
            overlay.slotIndex = index
            overlay.petSize = petSize
        }
    }

    /// Shrink pets uniformly so all fit between the left margin and right edge.
    private func computePetSize(count: Int) -> CGFloat {
        guard count > 0 else { return maxPetSize }
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let available = max(0, screenWidth - leftMargin - rightInset)
        let perPet = available / CGFloat(count) - petGap
        return min(maxPetSize, max(minPetSize, perPet))
    }

    // MARK: - Display link — reposition pets when screen changes

    private func startFrameSync() {
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard err == kCVReturnSuccess, let link else {
            NSLog("cliPets: CVDisplayLink unavailable (\(err))")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, cliPetsDisplayLinkCallback, refcon)
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    fileprivate func displayLinkTick() {
        let frame = NSScreen.main?.frame
        guard frame != lastScreenFrame else { return }
        lastScreenFrame = frame
        relayoutAllPets()
    }

    // MARK: - Shared helpers

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
