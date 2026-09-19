import AppKit
import Foundation

private let fullDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.setLocalizedDateFormatFromTemplate("MdHm")
    return formatter
}()

private let updatedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.setLocalizedDateFormatFromTemplate("Hm")
    return formatter
}()

func formatResetDate(_ date: Date?) -> String {
    guard let date else { return "暂无" }
    return fullDateFormatter.string(from: date)
}

func formatShortCountdown(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "N/A" }
    let remaining = max(0, Int(date.timeIntervalSince(now)))
    let days = remaining / 86_400
    let hours = (remaining % 86_400) / 3_600
    let minutes = (remaining % 3_600) / 60
    if days > 0 { return "\(days)天\(hours)时" }
    if hours > 0 { return "\(hours)时\(minutes)分" }
    return "\(minutes)分"
}

func formatUpdated(_ date: Date) -> String {
    "更新于 \(updatedFormatter.string(from: date))"
}

/// The four bands are deliberately exposed separately from their AppKit colours
/// so their boundary behaviour stays testable and consistent across views.
enum UsageColorBand: Equatable {
    case critical
    case low
    case moderate
    case healthy

    init(remainingPercent: Int) {
        switch remainingPercent {
        case ...10: self = .critical
        case ...30: self = .low
        case ...60: self = .moderate
        default: self = .healthy
        }
    }
}

func statusColor(remainingPercent: Int) -> NSColor {
    switch UsageColorBand(remainingPercent: remainingPercent) {
    case .critical: return .systemRed
    case .low: return .systemOrange
    case .moderate: return .systemYellow
    case .healthy: return .systemGreen
    }
}
