import Foundation
import Darwin

protocol SessionTPSWorking: AnyObject { func start(); func stop(); func setActive(_ active: Bool) }
extension SessionTPSWorking { func setActive(_ active: Bool) {} }
typealias SessionTPSWorkerFactory = (URL, @escaping @Sendable (SessionTPSSnapshot) -> Void) -> any SessionTPSWorking

@MainActor
final class SessionTPSService {
    var onChange: ((SessionTPSSnapshot) -> Void)?
    private var worker: (any SessionTPSWorking)?
    private var generation = UUID()
    private let home: URL
    private let makeWorker: SessionTPSWorkerFactory
    var isRunning: Bool { worker != nil }
    init(home: URL? = nil, makeWorker: SessionTPSWorkerFactory? = nil) {
        self.makeWorker = makeWorker ?? { SessionTPSWorker(home: $0, publish: $1) }
        self.home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    func configure(enabled: Bool, available: Bool, active: Bool = true) {
        guard enabled && available else {
            generation = UUID(); worker?.stop(); worker = nil
            onChange?(.unavailable(enabled ? "Codex 未运行或系统正在睡眠" : "会话速度未开启")); return
        }
        if let worker { worker.setActive(active); return }
        let token = UUID(); generation = token
        let worker = makeWorker(home) { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == token else { return }; self.onChange?(value)
            }
        }
        self.worker = worker; worker.setActive(active); worker.start()
    }
}

/// All connection, index and file state is confined to this utility queue.
final class SessionTPSWorker: SessionTPSWorking, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexTouchBar.SessionTPS", qos: .utility)
    private let home: URL
    private let publish: @Sendable (SessionTPSSnapshot) -> Void
    private var connection: (any SessionConnecting)?
    private var retry: DispatchSourceTimer?
    private var fileChanges: DispatchSourceFileSystemObject?
    private var pendingRead: DispatchWorkItem?
    private var reader: SessionRolloutReader?
    private var selected: CodexFollowing?
    private var followers: [String: Set<CodexFollowing>] = [:]
    private var visibleTimer: DispatchSourceTimer?
    private var fileGeneration = UUID()
    private var connectionGeneration = UUID()
    private var stopped = false
    private var backoff = 1.0
    private let makeConnection: (DispatchQueue) -> any SessionConnecting
    private let visibleSelection: () -> SessionWindowSelection
    private var firstSelectionMiss: TimeInterval?
    private let titleLookup: SessionTitleLookup
    private let makeReader: (URL, String) -> SessionRolloutReader
    private var active = true
    private var pendingSelection: DispatchWorkItem?
    private var readerCache: [String: (url: URL, reader: SessionRolloutReader)] = [:]
    private var readerOrder: [String] = []

    init(home: URL, publish: @escaping @Sendable (SessionTPSSnapshot) -> Void,
         makeConnection: ((DispatchQueue) -> any SessionConnecting)? = nil,
         visibleTitle: (() -> String?)? = nil,
         makeReader: @escaping (URL, String) -> SessionRolloutReader = { SessionRolloutReader(url: $0, conversationID: $1) }) {
        self.home = home; self.publish = publish
        self.titleLookup = SessionTitleLookup(home: home)
        self.makeReader = makeReader
        self.makeConnection = makeConnection ?? { CodexSessionConnection(home: home, queue: $0) }
        self.visibleSelection = visibleTitle.map { read in
            { read().map(SessionWindowSelection.title) ?? .temporaryUnavailable }
        } ?? { SessionVisibleConversation.sample() }
    }
    func setActive(_ value: Bool) { queue.async { [self] in
        guard active != value else { return }
        active = value; firstSelectionMiss = nil
        visibleTimer?.cancel(); visibleTimer = nil
        pendingSelection?.cancel(); pendingSelection = nil
        if active && connection != nil { startVisibleTimer() }
    } }
    func start() { queue.async { [self] in connect() } }
    func stop() { queue.async { [self] in
        stopped = true; pendingSelection?.cancel(); pendingSelection = nil; visibleTimer?.cancel(); visibleTimer = nil; connectionGeneration = UUID(); retry?.cancel(); retry = nil; connection?.stop(); connection = nil
        clearFile(); readerCache.removeAll(); readerOrder.removeAll(); followers.removeAll(); selected = nil
    } }

    private func connect() {
        guard !stopped else { return }
        retry?.cancel(); retry = nil
        let connection = makeConnection(queue)
        self.connection = connection
        let generation = UUID(); connectionGeneration = generation
        connection.onFollowing = { [weak self] event in
            guard let self, self.connectionGeneration == generation else { return }; self.follow(event)
        }
        connection.onDisconnect = { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }; self.disconnected()
        }
        guard connection.connect() else { disconnected(); return }
        backoff = 1
        publish(.unavailable("等待识别当前可见对话"))
        startVisibleTimer()
    }
    private func startVisibleTimer() {
        guard active && !stopped else { return }
        visibleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(500), leeway: .milliseconds(75))
        timer.setEventHandler { [weak self] in self?.refreshVisibleSelection() }
        visibleTimer = timer; timer.resume()
    }
    private func scheduleSelection() {
        guard active, pendingSelection == nil, !stopped else { return }
        let generation = connectionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, !self.stopped, self.connectionGeneration == generation else { return }
            self.pendingSelection = nil; self.refreshVisibleSelection()
        }
        pendingSelection = work; queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    private func disconnected() {
        guard !stopped else { return }
        pendingSelection?.cancel(); pendingSelection = nil
        visibleTimer?.cancel(); visibleTimer = nil; connectionGeneration = UUID()
        connection?.stop(); connection = nil
        clearFile(); selected = nil; followers.removeAll()
        publish(.unavailable("无法连接 Codex 本地会话通道"))
        scheduleRetry(after: backoff) { [weak self] in self?.connect() }
        backoff = min(30, backoff * 2)
    }
    private func follow(_ event: CodexFollowingEvent) {
        guard !stopped, let source = event.sourceClientId, source.count <= 256, let route = event.params else { return }
        guard !source.isEmpty, !route.conversationId.isEmpty, route.conversationId.count <= 128,
              !route.hostId.isEmpty, route.hostId.count <= 128 else { return }
        if route.following { followers[source, default: []].insert(route) }
        else {
            followers[source]?.remove(CodexFollowing(conversationId: route.conversationId, hostId: route.hostId, following: true))
            if followers[source]?.isEmpty == true { followers.removeValue(forKey: source) }
        }
        guard followers.count <= 16, followers.values.reduce(0, { $0 + $1.count }) <= 4_096 else { disconnected(); return }
        scheduleSelection()
    }
    private func refreshVisibleSelection() {
        guard !stopped, active else { return }
        let title: String
        switch visibleSelection() {
        case let .title(value): title = value
        case .temporaryUnavailable:
            selectionTemporarilyUnavailable("暂时无法读取当前对话窗口标题"); return
        case let .unavailable(reason):
            firstSelectionMiss = nil; selected = nil; clearFile(); publish(.unavailable(reason)); return
        }
        let id: String
        switch titleLookup.lookup(title) {
        case let .matched(value): id = value; firstSelectionMiss = nil
        case .unavailable:
            selectionTemporarilyUnavailable("对话索引暂时不可读"); return
        case .unknown, .ambiguous:
            firstSelectionMiss = nil; selected = nil; clearFile()
            publish(.unavailable("无法唯一确认可见对话；请检查重名或当前页面")); return
        }
        let matches = Set(followers.values.flatMap { $0 }.filter { $0.conversationId == id && $0.hostId == "local" })
        guard matches.count == 1, let route = matches.first else {
            selected = nil; clearFile(); publish(.unavailable("等待当前可见对话的本地订阅")); return
        }
        guard route != selected else { return }
        clearFile(); selected = route
        resolve()
    }
    private func selectionTemporarilyUnavailable(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let since = firstSelectionMiss ?? now
        firstSelectionMiss = since
        if selected != nil && now - since < 1.5 { return }
        selected = nil; clearFile(); publish(.unavailable(reason))
    }
    private func resolve() {
        guard !stopped, let route = selected else { return }
        retry?.cancel(); retry = nil
        guard let url = SessionLogIndex(home: home).resolve(conversationID: route.conversationId) else {
            publish(.unavailable("等待当前对话的本地记录"))
            scheduleRetry(after: 5) { [weak self] in self?.resolve() }; return
        }
        let id = route.conversationId
        readerOrder.removeAll { $0 == id }; readerOrder.append(id)
        if let cached = readerCache[id], cached.url == url {
            reader = cached.reader
        } else {
            publish(.init(phase: .waiting, detail: "正在读取当前可见对话"))
            let value = makeReader(url, id)
            readerCache[id] = (url, value); reader = value
        }
        while readerOrder.count > 4 { readerCache.removeValue(forKey: readerOrder.removeFirst()) }
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            reader = nil
            publish(.unavailable("当前对话的本地记录暂不可读"))
            scheduleRetry(after: 5) { [weak self] in self?.resolve() }; return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .attrib, .rename, .delete, .revoke], queue: queue)
        let generation = fileGeneration
        source.setEventHandler { [weak self, weak source] in
            guard let self, self.fileGeneration == generation else { return }
            if source?.data.intersection([.rename, .delete, .revoke]).isEmpty == false {
                if let id = self.selected?.conversationId {
                    self.readerCache.removeValue(forKey: id); self.readerOrder.removeAll { $0 == id }
                }
                self.clearFile(); self.publish(.unavailable("会话日志已移动，等待重新定位"))
                self.scheduleRetry(after: 1) { [weak self] in self?.resolve() }
            } else { self.scheduleRead() }
        }
        source.setCancelHandler { close(descriptor) }
        fileChanges = source; source.resume(); read()
    }
    private func scheduleRead() {
        guard pendingRead == nil, !stopped else { return }
        let generation = fileGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.fileGeneration == generation else { return }
            self.pendingRead = nil; self.read()
        }
        pendingRead = item; queue.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
    private func read() {
        guard !stopped, let reader else { return }
        do {
            let snapshot = try reader.update()
            retry?.cancel(); retry = nil
            publish(snapshot)
            if reader.needsMore { scheduleRead() }
        } catch {
            publish(.unavailable("当前会话记录不可用或格式不支持"))
            scheduleRetry(after: 5) { [weak self] in self?.read() }
        }
    }
    private func scheduleRetry(after delay: Double, _ action: @escaping () -> Void) {
        retry?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.retry?.cancel(); self?.retry = nil
            if self?.stopped == false { action() }
        }
        retry = timer; timer.resume()
    }
    private func clearFile() {
        fileGeneration = UUID()
        retry?.cancel(); retry = nil
        pendingRead?.cancel(); pendingRead = nil
        fileChanges?.cancel(); fileChanges = nil; reader?.prepareForCaching(); reader = nil
    }
}
