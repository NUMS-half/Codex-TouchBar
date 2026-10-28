import Foundation
import Darwin

/// Bounded, read-only parsing. No record text is retained outside the partial-line buffer.
final class SessionRolloutReader {
    static let chunkLimit = 4 * 1_024 * 1_024
    private let url: URL
    private let conversationID: String
    private var identity: UInt64 = 0
    private var offset: UInt64 = 0
    private var observedLength: UInt64 = 0
    private var pending = Data()
    private var droppingLine = false
    private var calculator = SessionTPSCalculator()
    private(set) var needsMore = false
    private var modifiedSeconds: Int64 = -1
    private var modifiedNanos: Int64 = -1
    private var lastSnapshot = SessionTPSSnapshot()
    private(set) var bytesRead = 0
    private(set) var decodedRecords = 0
    private(set) var recoveryPasses = 0

    init(url: URL, conversationID: String) { self.url = url; self.conversationID = conversationID }

    /// Inactive checkpoints keep numeric parser state, never partial raw text.
    func prepareForCaching() {
        offset -= UInt64(pending.count)
        pending.removeAll(keepingCapacity: false)
    }

    func update() throws -> SessionTPSSnapshot {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReaderError.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0 else { throw ReaderError.unavailable }
        let length = UInt64(info.st_size)
        let seconds = Int64(info.st_mtimespec.tv_sec), nanos = Int64(info.st_mtimespec.tv_nsec)
        if identity == UInt64(info.st_ino), length == offset,
           modifiedSeconds == seconds, modifiedNanos == nanos { return lastSnapshot }
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 64 * 1_024) ?? Data()
        bytesRead += header.count
        guard let lineEnd = header.firstIndex(of: 10),
              let meta = try? JSONDecoder().decode(SessionTPSRecord.self, from: header[..<lineEnd]),
              meta.type == "session_meta", meta.payload.id == conversationID,
              ["Codex Desktop", "codex_work_desktop"].contains(meta.payload.originator),
              meta.payload.source == "vscode" else { throw ReaderError.unsupported }
        let rewritten = (seconds != modifiedSeconds || nanos != modifiedNanos) && length <= observedLength
        if identity != UInt64(info.st_ino) || length < offset || rewritten {
            identity = UInt64(info.st_ino)
            var window = UInt64(Self.chunkLimit)
            repeat {
                offset = length > window ? length - window : 0
                recoveryPasses += 1
                calculator = SessionTPSCalculator(fromBeginning: offset == 0)
                pending.removeAll(); droppingLine = offset > 0
                try file.seek(toOffset: offset)
                let bytes = try file.read(upToCount: Int(min(window, length))) ?? Data()
                bytesRead += bytes.count
                consume(bytes); offset += UInt64(bytes.count)
                if calculator.hasCompleteStart || offset == length && length <= window || window >= 16 * 1_024 * 1_024 { break }
                window *= 2
            } while true
        } else {
            try file.seek(toOffset: offset)
            let bytes = try file.read(upToCount: Self.chunkLimit) ?? Data()
            bytesRead += bytes.count
            consume(bytes); offset += UInt64(bytes.count)
        }
        needsMore = offset < length
        modifiedSeconds = seconds; modifiedNanos = nanos; observedLength = length
        lastSnapshot = calculator.snapshot
        return lastSnapshot
    }

    private func consume(_ bytes: Data) {
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let delimiter = bytes[cursor...].firstIndex(of: 10)
            let end = delimiter ?? bytes.endIndex
            if !droppingLine {
                if end - cursor <= Self.chunkLimit - pending.count { pending.append(bytes[cursor..<end]) }
                else { calculator.invalidate(); pending.removeAll(keepingCapacity: false); droppingLine = true }
            }
            guard let delimiter else { return }
            if !droppingLine, !pending.isEmpty {
                if let record = try? JSONDecoder().decode(SessionTPSRecord.self, from: pending) { decodedRecords += 1; calculator.consume(record) }
                else { calculator.invalidate() }
            }
            pending.removeAll(keepingCapacity: true); droppingLine = false; cursor = delimiter + 1
        }
    }

    enum ReaderError: Error { case unavailable, unsupported }
}
