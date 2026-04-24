import Darwin
import Foundation

let args = CommandLine.arguments.dropFirst()

switch args.first {
case "notify":
    runNotify()
case "install-hooks":
    FileHandle.standardError.write(Data("clipets: install-hooks not yet implemented\n".utf8))
    exit(0)
case nil, "--help", "-h":
    print(
        """
        clipets — Claude Code hook relay
        Usage:
          clipets notify          (read hook JSON from stdin, forward to petd)
          clipets install-hooks   (write hook entries to ~/.claude/settings.json)
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

    let socketPath = defaultSocketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        // Don't break the hook — exit silently.
        exit(0)
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8) + [0]
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else { exit(0) }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        pathBytes.withUnsafeBytes { src in
            _ = memcpy(dst.baseAddress!, src.baseAddress!, pathBytes.count)
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    // petd may not be running — silently no-op so we don't break Claude hooks.
    guard connectResult == 0 else { exit(0) }

    stdinData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var remaining = raw.count
        var ptr = base
        while remaining > 0 {
            let n = write(fd, ptr, remaining)
            if n <= 0 { break }
            ptr = ptr.advanced(by: n)
            remaining -= n
        }
    }
    // Half-close write side so the server reads EOF and processes the message.
    shutdown(fd, SHUT_WR)
    exit(0)
}

func defaultSocketPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.clipets/clipets.sock"
}
