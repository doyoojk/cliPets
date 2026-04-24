import Foundation

/// Payload that Claude Code hook commands send on stdin. Snake-case fields
/// come straight from Claude Code's hook JSON; CodingKeys map them to Swift
/// camelCase.
struct HookEvent: Decodable, Sendable {
    let eventType: String
    let cwd: String?
    let sessionId: String?
    let transcriptPath: String?
    let toolName: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "hook_event_name"
        case cwd
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
    }
}
