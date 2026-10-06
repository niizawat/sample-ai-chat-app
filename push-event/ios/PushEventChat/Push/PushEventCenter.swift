import Foundation
import Observation

/// Holds the latest push event id until the chat screen consumes it.
@MainActor
@Observable
final class PushEventCenter {
    static let shared = PushEventCenter()

    var pendingEventId: String?
    var registrationError: String?

    private init() {}

    func setPendingEventId(_ eventId: String?) {
        guard let eventId, !eventId.isEmpty else { return }
        pendingEventId = eventId
    }

    func consumePendingEventId() -> String? {
        let value = pendingEventId
        pendingEventId = nil
        return value
    }
}
