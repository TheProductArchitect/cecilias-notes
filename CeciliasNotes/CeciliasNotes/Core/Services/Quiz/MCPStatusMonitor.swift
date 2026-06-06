import Combine
import Foundation

/// Tracks whether the `cecilias-notes-mcp` helper on the user's Mac has
/// ever been seen, and whether it looks reachable right now. The app
/// has no live socket to the Mac — the only signal is files appearing
/// in the iCloud Inbox. So "connected" is a heuristic: we mark a
/// timestamp every time we import an MCP-authored file (a quiz response
/// or an `.inkbook`), and treat the helper as reachable if that
/// happened recently. The Settings MCP section only appears once
/// `hasEverConnected` is true.
@MainActor
final class MCPStatusMonitor: ObservableObject {

    static let shared = MCPStatusMonitor()
    private init() {}

    private let everConnectedKey = "ceciliasnotes.mcp.everConnected"
    private let lastSeenKey       = "ceciliasnotes.mcp.lastSeenAt"

    /// Reachable if we've seen MCP-authored activity within this window.
    private let reachableWindow: TimeInterval = 60

    @Published private(set) var lastSeenAt: Date? = {
        let t = UserDefaults.standard.double(forKey: "ceciliasnotes.mcp.lastSeenAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    var hasEverConnected: Bool {
        UserDefaults.standard.bool(forKey: everConnectedKey)
    }

    var isReachable: Bool {
        guard let lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeenAt) < reachableWindow
    }

    /// Call when an MCP-authored file is imported from the Inbox.
    func recordActivity(at date: Date = Date()) {
        UserDefaults.standard.set(true, forKey: everConnectedKey)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSeenKey)
        lastSeenAt = date
    }
}
