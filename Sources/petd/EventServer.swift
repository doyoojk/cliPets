import Darwin
import Foundation

/// Unix domain socket listener at ~/.clipets/clipets.sock. Each accepted
/// connection is expected to write one JSON-encoded HookEvent and close.
/// Decoded events are handed to the caller-supplied callback.
///
/// Phase 6 may switch to newline-delimited streams of multiple events per
/// connection; for now, "one event per connection" is enough and dead simple.
final class EventServer: @unchecked Sendable {
    private let socketPath: String
    private var serverFd: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        ensureParentDirectoryExists()

        // Remove any stale socket file from a prior run.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("cliPets: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            NSLog("cliPets: socket path too long (\(pathBytes.count) > \(maxLen))")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                _ = memcpy(dst.baseAddress!, src.baseAddress!, pathBytes.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("cliPets: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Tighten permissions to user-only — only this user's hooks should
        // be able to talk to the daemon.
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            NSLog("cliPets: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(socketPath)
            return
        }

        self.serverFd = fd
        NSLog("cliPets: event server listening at \(socketPath)")

        DispatchQueue.global(qos: .userInitiated).async {
            Self.acceptLoop(fd: fd, onEvent: onEvent)
        }
    }

    func stop() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }

    private func ensureParentDirectoryExists() {
        let parent = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func acceptLoop(fd: Int32, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        let decoder = JSONDecoder()
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                // EBADF means the listening socket was closed (shutdown).
                break
            }
            defer { close(client) }

            var buffer = Data()
            var temp = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &temp, temp.count)
                if n <= 0 { break }
                buffer.append(temp, count: n)
            }

            guard !buffer.isEmpty else { continue }
            do {
                let event = try decoder.decode(HookEvent.self, from: buffer)
                onEvent(event)
            } catch {
                let preview = String(data: buffer.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                NSLog("cliPets: failed to decode hook event: \(error). Payload preview: \(preview)")
            }
        }
    }
}
