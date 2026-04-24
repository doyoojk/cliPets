import Foundation

/// Supported terminal emulators for window tracking.
/// Expanded in future phases — Phase 2 only needs the bundle id list.
enum SupportedTerminal {
    static let bundleIds: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
    ]
}
