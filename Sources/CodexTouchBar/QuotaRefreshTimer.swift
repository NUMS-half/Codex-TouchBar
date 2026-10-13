import Foundation

/// Switching between two background apps must not postpone the next quota query.
@MainActor
final class QuotaRefreshTimer {
    private var timer: Timer?
    private var isForeground: Bool?
    private var interval: TimeInterval?

    var nextFireDate: Date? { timer?.fireDate }

    deinit { timer?.invalidate() }

    func update(isForeground: Bool, interval: TimeInterval?, forceRestart: Bool = false,
                onFire: @escaping @MainActor () -> Void) {
        guard forceRestart || self.isForeground != isForeground || self.interval != interval else { return }
        stop()
        self.isForeground = isForeground
        self.interval = interval
        guard let interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            Task { @MainActor in
                guard timer.isValid else { return }
                onFire()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isForeground = nil
        interval = nil
    }
}
