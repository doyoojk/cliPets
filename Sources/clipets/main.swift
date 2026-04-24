// Placeholder. Phase 3 will implement: read hook JSON from stdin,
// forward to petd over unix socket at ~/.clipets/clipets.sock.
import Foundation

let args = CommandLine.arguments.dropFirst()

switch args.first {
case "notify":
    FileHandle.standardError.write(Data("clipets: notify not yet implemented (Phase 3)\n".utf8))
    exit(0)
case "install-hooks":
    FileHandle.standardError.write(Data("clipets: install-hooks not yet implemented (Phase 3)\n".utf8))
    exit(0)
case nil, "--help", "-h":
    print("""
        clipets — Claude Code hook relay
        Usage:
          clipets notify          (read hook JSON from stdin, forward to petd)
          clipets install-hooks   (write hook entries to ~/.claude/settings.json)
        """)
default:
    FileHandle.standardError.write(Data("clipets: unknown command \(args.first!)\n".utf8))
    exit(1)
}
