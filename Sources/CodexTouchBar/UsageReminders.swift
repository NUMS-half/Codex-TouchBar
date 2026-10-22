import Foundation

/// Opt-in reset-expiry reminder. Retired one-shot recovery fields are ignored on decode.
struct UsageReminderEngine: Codable {
    private var notifiedExpiry: Date?
    private var expiryEnabled = false

    mutating func configure(expiryEnabled: Bool) {
        self.expiryEnabled = expiryEnabled
    }

    mutating func consume(_ snapshot: UsageSnapshot, now: Date) -> [UsageAlertEvent] {
        guard now >= snapshot.fetchedAt, now.timeIntervalSince(snapshot.fetchedAt) <= 900,
              expiryEnabled, let count = snapshot.availableResetCredits, count > 0,
              let expiry = snapshot.earliestAvailableResetExpiry,
              expiry > now, expiry.timeIntervalSince(now) <= 86_400, expiry != notifiedExpiry else { return [] }
        return [.init(kind: .weekly, remaining: snapshot.weekly?.remainingPercent ?? 0,
                      reason: .resetExpiring(expiry))]
    }

    /// Failed or cancelled submissions remain eligible on the next successful query.
    mutating func acknowledge(_ events: [UsageAlertEvent]) {
        for event in events {
            if case .resetExpiring(let date) = event.reason { notifiedExpiry = date }
        }
    }
}
