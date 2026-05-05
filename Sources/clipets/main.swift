import Darwin
import Foundation

let args = CommandLine.arguments.dropFirst()

switch args.first {
case "notify":
    runNotify()
case "test":
    let testArgs = Array(args.dropFirst())
    let loop = testArgs.contains("--loop")
    let animation = testArgs.first(where: { !$0.hasPrefix("-") })
    runTest(animation: animation, loop: loop)
case "install-hooks":
    runInstallHooks()
    exit(0)
case nil, "--help", "-h":
    print(
        """
        clipets — Claude Code hook relay
        Usage:
          clipets notify                     read hook JSON from stdin, forward to petd
          clipets test [animation]           trigger an animation on all active pets
                                             animations: celebrate alert working writing listening idle
          clipets install-hooks              write hook entries to ~/.claude/settings.json
        """
    )
    exit(0)
default:
    FileHandle.standardError.write(Data("clipets: unknown command \(args.first!)\n".utf8))
    exit(1)
}

func runNotify() {
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    guard !stdinData.isEmpty else { exit(0) }
    sendToSocket(stdinData)
    exit(0)
}

func runTest(animation: String?, loop: Bool) {
    let anim = animation ?? "celebrate"
    let eventName: String
    switch anim {
    case "celebrate":   eventName = "Stop"
    case "alert":       eventName = "Notification"
    case "working":     eventName = "PreToolUse"
    case "writing":     eventName = "PreToolUse"
    case "listening":   eventName = "UserPromptSubmit"
    case "idle":        eventName = "SessionStart"
    default:
        FileHandle.standardError.write(Data("clipets test: unknown animation '\(anim)'\n".utf8))
        exit(1)
    }
    let toolName: String?
    switch anim {
    case "working": toolName = "Bash"
    case "writing": toolName = "Write"
    default:        toolName = nil
    }
    var payload: [String: String] = [
        "hook_event_name": eventName,
        "session_id":      "*",
        "cwd":             "/",
    ]
    if let t = toolName { payload["tool_name"] = t }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { exit(1) }

    // One-shot animations (celebrate=2s, alert=2s) need periodic re-triggers.
    // Looping animations (working/writing/listening) timeout after 8s so re-trigger every 6s.
    let interval: TimeInterval
    switch anim {
    case "celebrate": interval = 2.5
    case "alert":     interval = 2.5
    default:          interval = 6.0
    }

    sendToSocket(data)
    guard loop else { return }
    print("clipets test: looping '\(anim)' — press Ctrl-C to stop")
    while true {
        Thread.sleep(forTimeInterval: interval)
        sendToSocket(data)
    }
}

func sendToSocket(_ data: Data) {
    let socketPath = defaultSocketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(0) }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8) + [0]
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        pathBytes.withUnsafeBytes { src in _ = memcpy(dst.baseAddress!, src.baseAddress!, pathBytes.count) }
    }
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else {
        FileHandle.standardError.write(Data("clipets: petd not running\n".utf8))
        exit(1)
    }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var rem = raw.count; var ptr = base
        while rem > 0 { let n = write(fd, ptr, rem); guard n > 0 else { break }; ptr = ptr.advanced(by: n); rem -= n }
    }
    shutdown(fd, SHUT_WR)
}

func defaultSocketPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.clipets/clipets.sock"
}

func runInstallHooks() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let settingsPath = "\(home)/.claude/settings.json"
    let fm = FileManager.default

    // Read existing settings or start fresh.
    var root: [String: Any] = [:]
    if let data = fm.contents(atPath: settingsPath),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        root = parsed
    }

    var hooks = root["hooks"] as? [String: Any] ?? [:]

    let hooksToAdd: [(event: String, matcher: String?)] = [
        ("Notification",     nil),
        ("Stop",             nil),
        ("SubagentStop",     nil),
        ("PreToolUse",       "Bash|Write|Edit|Read|Grep"),
        ("PostToolUse",      nil),
        ("UserPromptSubmit", nil),
    ]

    var added: [String] = []
    for (event, matcher) in hooksToAdd {
        let hookEntry: [String: Any] = [
            "type":    "command",
            "command": "clipets notify",
        ]
        var hookBlock: [String: Any] = ["hooks": [hookEntry]]
        if let m = matcher { hookBlock["matcher"] = m }

        var existing = hooks[event] as? [[String: Any]] ?? []
        let alreadyPresent = existing.contains {
            guard let innerHooks = $0["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { $0["command"] as? String == "clipets notify" }
        }
        if !alreadyPresent {
            existing.append(hookBlock)
            hooks[event] = existing
            added.append(event)
        }
    }

    root["hooks"] = hooks

    guard !added.isEmpty else {
        print("clipets: hooks already installed, nothing to do.")
        return
    }

    // Write back with pretty-printing.
    guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
        FileHandle.standardError.write(Data("clipets: failed to serialize settings\n".utf8))
        exit(1)
    }

    // Ensure directory exists.
    try? fm.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)

    guard fm.createFile(atPath: settingsPath, contents: out) else {
        FileHandle.standardError.write(Data("clipets: could not write \(settingsPath)\n".utf8))
        exit(1)
    }

    print("clipets: added hooks for: \(added.joined(separator: ", "))")
    print("clipets: written to \(settingsPath)")
}
