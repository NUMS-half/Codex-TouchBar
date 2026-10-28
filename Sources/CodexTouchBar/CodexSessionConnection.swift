import Foundation
import Darwin

struct CodexFollowing: Decodable, Hashable, Sendable {
    let conversationId: String
    let hostId: String
    let following: Bool
}

struct CodexFollowingEvent: Decodable {
    let sourceClientId: String?
    let method: String?
    let params: CodexFollowing?
    enum CodingKeys: String, CodingKey { case type, sourceClientId, method, params }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        let type = try c.decodeIfPresent(String.self, forKey: .type)
        if type == "broadcast", method == "thread-stream-following-changed" {
            sourceClientId = try c.decodeIfPresent(String.self, forKey: .sourceClientId)
            params = try c.decodeIfPresent(CodexFollowing.self, forKey: .params)
        } else { sourceClientId = nil; params = nil }
    }
}

struct CodexIPCFrames {
    static let maximumBytes = 8 * 1_024 * 1_024
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [CodexFollowingEvent] {
        guard buffer.count + bytes.count <= Self.maximumBytes + 65_540 else { throw FrameError.invalid }
        buffer.append(bytes)
        var events: [CodexFollowingEvent] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard length > 0, length <= Self.maximumBytes else { throw FrameError.invalid }
            guard buffer.count >= length + 4 else { break }
            let first = buffer.startIndex
            let body = buffer.subdata(in: first + 4..<first + length + 4)
            buffer.removeFirst(length + 4)
            if let event = try? JSONDecoder().decode(CodexFollowingEvent.self, from: body), event.params != nil { events.append(event) }
        }
        return events
    }
    enum FrameError: Error { case invalid }
}

protocol SessionConnecting: AnyObject {
    var onFollowing: ((CodexFollowingEvent) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func connect() -> Bool
    func stop()
}

/// Queue-confined local observer. The sole outgoing method is initialize.
final class CodexSessionConnection: SessionConnecting {
    private let queue: DispatchQueue
    private let socketURL: URL
    private var readSource: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private var frames = CodexIPCFrames()
    var onFollowing: ((CodexFollowingEvent) -> Void)?
    var onDisconnect: (() -> Void)?

    init(home: URL, queue: DispatchQueue) {
        socketURL = home.appendingPathComponent("ipc/ipc.sock"); self.queue = queue
    }
    func connect() -> Bool {
        stop()
        var parent = stat(), endpoint = stat()
        guard lstat(socketURL.deletingLastPathComponent().path, &parent) == 0,
              parent.st_uid == getuid(), parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o022 == 0,
              lstat(socketURL.path, &endpoint) == 0, endpoint.st_uid == getuid(),
              endpoint.st_mode & S_IFMT == S_IFSOCK, endpoint.st_mode & 0o077 == 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        // Nonblocking connect/send have a short, explicit local timeout.
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); return false }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { close(fd); return false }
            var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var socketError: Int32 = 0, errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&wait, 1, 200) > 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorSize) == 0,
                  socketError == 0 else { close(fd); return false }
        }
        let request: [String: Any] = ["type": "request", "requestId": UUID().uuidString,
            "sourceClientId": "codex-touchbar-" + UUID().uuidString, "version": 0, "method": "initialize",
            "params": ["clientType": "codex-touchbar"]]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { close(fd); return false }
        var size = UInt32(body.count).littleEndian
        var message = withUnsafeBytes(of: &size) { Data($0) }; message.append(body)
        let sent = message.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == message.count else { close(fd); return false }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { close(fd) }
        readSource = source; source.resume()
        return true
    }

    func stop() {
        readSource?.cancel(); readSource = nil; descriptor = -1; frames = CodexIPCFrames()
    }

    private func receive() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Yield after a bounded batch so stop/reconfigure cannot starve behind a hot producer.
        for _ in 0..<16 {
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { disconnect(); return }
            do { for event in try frames.append(Data(bytes.prefix(count))) { onFollowing?(event) } }
            catch { disconnect(); return }
        }
    }
    private func disconnect() { stop(); onDisconnect?() }
}
