import Foundation

/// Display resolution is independent of history retention and quota window duration.
enum UsageChartRange: CaseIterable {
    case sixHours, twelveHours, tenDays

    static let fiveHourOptions: [Self] = [.sixHours, .twelveHours]
    static func defaultRange(for kind: UsageWindowKind) -> Self { kind == .fiveHour ? .sixHours : .tenDays }
    var kind: UsageWindowKind { self == .tenDays ? .weekly : .fiveHour }
    var duration: TimeInterval {
        switch self {
        case .sixHours: return 6 * 3_600
        case .twelveHours: return 12 * 3_600
        case .tenDays: return 10 * 86_400
        }
    }
    var bucketInterval: TimeInterval {
        switch self {
        case .sixHours: return 600
        case .twelveHours: return 900
        case .tenDays: return 21_600
        }
    }
    var title: String {
        switch self {
        case .sixHours: return "近6小时"
        case .twelveHours: return "近12小时"
        case .tenDays: return "近10天"
        }
    }
    var caption: String {
        let interval: String
        switch self {
        case .sixHours: interval = "10分钟"
        case .twelveHours: interval = "15分钟"
        case .tenDays: interval = "6小时"
        }
        return "每柱\(interval) · 淡色为非实测"
    }
}
