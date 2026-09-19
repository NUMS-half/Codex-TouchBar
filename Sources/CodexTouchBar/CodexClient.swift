import Foundation

struct CodexExecutableResolver: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve() -> URL? {
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let override = environment["CODEX_BIN"], !override.isEmpty {
            candidates.append(override)
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}

protocol AppServerRunning: Sendable {
    func readUsage(from executable: URL) async throws -> Data
}

/// Incrementally extracts request id 2 from stdout. Notifications and the
/// initialize response are deliberately ignored, and callers may append any
/// sized chunk from the pipe.
struct LineDelimitedUsageResponseParser {
    private var buffer = Data()

    mutating func append(_ data: Data) -> Result<Data, Error>? {
        buffer.append(data)
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let line = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            guard !line.isEmpty,
                  let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (envelope["id"] as? NSNumber)?.intValue == 2 else { continue }
            if let error = envelope["error"] as? [String: Any] {
                return .failure(UsageServiceError.rpc(error["message"] as? String ?? "未知 RPC 错误"))
            }
            guard let result = envelope["result"],
                  JSONSerialization.isValidJSONObject(result),
                  let resultData = try? JSONSerialization.data(withJSONObject: result) else {
                return .failure(UsageServiceError.invalidResponse)
            }
            return .success(resultData)
        }
        return nil
    }
}

struct ProcessAppServerRunner: AppServerRunning {
    func readUsage(from executable: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try OneShotAppServerRequest.run(executable: executable)
        }.value
    }
}

actor CodexUsageService: UsageProvider {
    private let resolver: CodexExecutableResolver
    private let runner: any AppServerRunning

    init(
        resolver: CodexExecutableResolver = .init(),
        runner: any AppServerRunning = ProcessAppServerRunner()
    ) {
        self.resolver = resolver
        self.runner = runner
    }

    func fetch() async throws -> UsageSnapshot {
        guard let executable = resolver.resolve() else { throw UsageServiceError.codexNotFound }
        let response = try await runner.readUsage(from: executable)
        return try UsageSnapshotParser.parse(data: response)
    }
}

/// Runs one short-lived JSON-RPC session. Keeping the app-server ephemeral
/// avoids a permanent extra Codex process and makes a wedged server recover on
/// the next scheduled refresh.
private final class OneShotAppServerRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var result: Result<Data, Error>?
    private var responseParser = LineDelimitedUsageResponseParser()
    private var stderr = ""
    private var process: Process?

    static func run(executable: URL) throws -> Data {
        let request = OneShotAppServerRequest()
        return try request.perform(executable: executable)
    }

    private func perform(executable: URL) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.process = process

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeStdout(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeStderr(data)
        }
        process.terminationHandler = { [weak self] terminated in
            self?.processDidTerminate(status: terminated.terminationStatus)
        }

        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: requestPayload())
        } catch {
            finish(.failure(UsageServiceError.launchFailed(error.localizedDescription)))
        }

        if completion.wait(timeout: .now() + 15) == .timedOut {
            if process.isRunning { process.terminate() }
            finish(.failure(UsageServiceError.timedOut))
        }

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        lock.lock()
        let finished = result
        lock.unlock()
        guard let finished else { throw UsageServiceError.timedOut }
        return try finished.get()
    }

    private func requestPayload() throws -> Data {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-touchbar",
                    "title": "Codex TouchBar",
                    "version": "2.0.0",
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ]
        let usage: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "account/rateLimits/read",
            "params": ["excludeResetCreditDetails": true],
        ]
        var payload = try JSONSerialization.data(withJSONObject: initialize)
        payload.append(0x0A)
        payload.append(try JSONSerialization.data(withJSONObject: usage))
        payload.append(0x0A)
        return payload
    }

    private func consumeStdout(_ data: Data) {
        lock.lock()
        let reply = responseParser.append(data)
        lock.unlock()
        guard let reply else { return }
        finish(reply)
        if process?.isRunning == true { process?.terminate() }
    }

    private func consumeStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderr = String((stderr + text).suffix(1_000))
        lock.unlock()
    }

    private func processDidTerminate(status: Int32) {
        lock.lock()
        let diagnostics = stderr
        let hasResult = result != nil
        lock.unlock()
        guard !hasResult else { return }
        let suffix = diagnostics.isEmpty ? "status=\(status)" : "status=\(status) \(diagnostics.prefix(300))"
        finish(.failure(UsageServiceError.processExited(suffix)))
    }

    private func finish(_ newResult: Result<Data, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        lock.unlock()
        completion.signal()
    }
}
