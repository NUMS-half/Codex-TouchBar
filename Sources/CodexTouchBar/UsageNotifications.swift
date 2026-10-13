import AppKit
import UserNotifications

enum UsageNotificationPermission: Equatable {
    case unknown, allowed, denied
}

@MainActor
protocol UsageNotificationSending: AnyObject {
    func send(_ batch: UsageAlertBatch) async throws
}

@MainActor
protocol UsageNotificationManaging: UsageNotificationSending {
    func permission() async -> UsageNotificationPermission
    func requestIfNeeded() async -> UsageNotificationPermission
    func openSystemSettings()
}

@MainActor
final class UsageNotificationService: NSObject, UsageNotificationManaging, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var authorizationTask: Task<UsageNotificationPermission, Never>?
    var onOpenHistory: ((UsageWindowKind) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func permission() async -> UsageNotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .unknown
        case .authorized, .provisional, .ephemeral: return settings.alertSetting == .disabled ? .denied : .allowed
        default: return .denied
        }
    }

    func requestIfNeeded() async -> UsageNotificationPermission {
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { @MainActor in
            let current = await self.permission()
            guard current == .unknown else { return current }
            _ = try? await self.center.requestAuthorization(options: [.alert])
            return await self.permission()
        }
        authorizationTask = task
        let result = await task.value
        authorizationTask = nil
        return result
    }

    func send(_ batch: UsageAlertBatch) async throws {
        guard !batch.events.isEmpty, await permission() == .allowed else { return }
        try Task.checkCancellation()
        let content = UNMutableNotificationContent()
        content.title = "Codex 额度提醒"
        content.body = batch.body
        content.userInfo = ["windowKind": batch.selectedKind.rawValue]
        // No sound, badge or time-sensitive interruption level.
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explicit manual acceptance only; never requests authorization or changes alert preferences.
    func sendTestNotification() async throws -> Bool {
        guard await permission() == .allowed else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Codex 额度提醒 · 测试"
        content.body = "这是一条验收测试通知，不代表额度发生变化。可打开菜单栏中的额度曲线查看实际记录。"
        content.userInfo = ["windowKind": UsageWindowKind.fiveHour.rawValue]
        try await center.add(UNNotificationRequest(identifier: "usage-alert-manual-test", content: content, trigger: nil))
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["windowKind"] as? String ?? "fiveHour"
        let kind = UsageWindowKind(rawValue: raw) ?? .fiveHour
        Task { @MainActor [weak self] in self?.onOpenHistory?(kind) }
        completionHandler()
    }
}

@MainActor
final class UsageMonitoringController {
    let history: UsageHistoryRepository
    private let preferences: Preferences
    private let sender: any UsageNotificationSending
    private var engine: UsageAlertEngine
    private var work: Task<Void, Never>?
    private var maintenanceTimer: Timer?
    private var notificationGeneration = 0
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private(set) var historyError: String?
    private(set) var notificationError: String?
    var onChange: (() -> Void)?

    init(history: UsageHistoryRepository = .init(), preferences: Preferences = .shared,
         sender: any UsageNotificationSending) {
        self.history = history
        self.preferences = preferences
        self.sender = sender
        let saved = preferences.usageAlertState.flatMap { try? JSONDecoder().decode(UsageAlertEngine.self, from: $0) }
        if let saved, saved.version == UsageAlertEngine.currentVersion {
            engine = saved
        } else {
            engine = UsageAlertEngine()
        }
        engine.configure(preferences.usageAlertOptions)
    }

    func start() {
        prune()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        maintenanceTimer?.tolerance = 60
    }

    func configure() {
        notificationGeneration += 1
        cancelDeliveries()
        engine.configure(preferences.usageAlertOptions)
        persist()
    }

    func consume(_ snapshot: UsageSnapshot) {
        let observations = UsageObservation.from(snapshot)
        let events = engine.consume(observations)
        persist()
        let previous = work
        work = Task { [weak self, history] in
            await previous?.value
            do { try await history.append(observations, now: snapshot.fetchedAt); self?.historyError = nil }
            catch { self?.historyError = "历史记录保存失败；当前额度显示不受影响。" }
            self?.onChange?()
        }
        if !events.isEmpty {
            let generation = notificationGeneration
            let id = UUID()
            deliveries[id] = Task { [weak self, sender] in
                guard let self, generation == self.notificationGeneration else { return }
                defer { self.deliveries[id] = nil }
                do { try await sender.send(.init(events: events, observations: observations)); self.notificationError = nil }
                catch is CancellationError { return }
                catch { self.notificationError = "系统通知发送失败，请检查通知设置。" }
                self.onChange?()
            }
        }
    }

    func clearHistory() async -> Bool {
        notificationGeneration += 1
        cancelDeliveries()
        engine.reset()
        persist()
        let previous = work
        var succeeded = false
        let task = Task { [weak self, history] in
            await previous?.value
            do { try await history.clear(); self?.historyError = nil; succeeded = true }
            catch { self?.historyError = "历史记录未能清空，请稍后重试。" }
            self?.onChange?()
        }
        work = task
        await task.value
        return succeeded
    }

    func waitForPendingWrites() async { await work?.value }

    private func cancelDeliveries() {
        deliveries.values.forEach { $0.cancel() }
        deliveries.removeAll()
    }

    private func prune() {
        let previous = work
        work = Task { [weak self, history] in
            await previous?.value
            do { try await history.prune(now: Date()) }
            catch { self?.historyError = "历史记录维护失败；当前额度显示不受影响。" }
            self?.onChange?()
        }
    }
    private func persist() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try? encoder.encode(engine)
        if data != preferences.usageAlertState { preferences.usageAlertState = data }
    }
}
