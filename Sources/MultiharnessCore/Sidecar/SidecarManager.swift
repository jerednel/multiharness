import Foundation

@MainActor
public final class SidecarManager {
    public enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case crashed(reason: String)
    }

    public private(set) var status: Status = .stopped
    public var onStatusChange: ((Status) -> Void)?
    /// Fires whenever a freshly-started (or restarted) sidecar is ready,
    /// carrying the new port. Consumers should re-bind their ControlClient.
    public var onPortBound: ((Int) -> Void)?

    public let dataDir: URL
    /// "127.0.0.1" by default. Set to "0.0.0.0" to expose on LAN.
    public var bindAddress: String = "127.0.0.1"
    /// Required when `bindAddress` is non-loopback. The sidecar refuses to
    /// start unauthenticated on a non-loopback bind.
    public var authToken: String?
    /// Optional preferred port. If set, the sidecar tries to bind it; if it
    /// is in use, Bun falls through to a random port (the actual port is
    /// reported via onPortBound).
    public var preferredPort: Int?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stderrBuffer = Data()

    /// True when `stop()` was called explicitly. Used to suppress auto-restart.
    private var explicitStop = false
    /// Increments on each unintended exit; used for backoff.
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?

    public init(dataDir: URL) {
        self.dataDir = dataDir
    }

    /// Locate the sidecar binary. Search order:
    /// 1. `MULTIHARNESS_SIDECAR_PATH` env var (developer override)
    /// 2. `Bundle.main.url(forResource: "multiharness-sidecar", withExtension: nil)` in `Contents/Resources/`
    /// 3. `<executable parent>/../sidecar/dist/multiharness-sidecar` (SPM dev layout)
    public nonisolated static func locateBinary() -> URL? {
        if let p = ProcessInfo.processInfo.environment["MULTIHARNESS_SIDECAR_PATH"] {
            let u = URL(fileURLWithPath: p)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        if let u = Bundle.main.url(forResource: "multiharness-sidecar", withExtension: nil) {
            return u
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates = [
            exe.deletingLastPathComponent().appendingPathComponent("multiharness-sidecar"),
            // SPM `.build/<config>/Multiharness` -> ../../../sidecar/dist
            exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("sidecar/dist/multiharness-sidecar"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("sidecar/dist/multiharness-sidecar"),
        ]
        for u in candidates {
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    public func start() async throws -> Int {
        if case .running(let port) = status { return port }
        explicitStop = false
        guard let binary = Self.locateBinary() else {
            throw SidecarError.binaryNotFound
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        Self.reapStaleSidecar(dataDir: dataDir)

        let p = Process()
        p.executableURL = binary
        var sidecarEnv: [String: String] = [
            "MULTIHARNESS_PORT": String(preferredPort ?? 0),
            "MULTIHARNESS_DATA_DIR": dataDir.path,
            "MULTIHARNESS_BIND": bindAddress,
        ]
        if let token = authToken { sidecarEnv["MULTIHARNESS_AUTH_TOKEN"] = token }
        p.environment = ProcessInfo.processInfo.environment.merging(
            sidecarEnv,
            uniquingKeysWith: { _, new in new }
        )
        let stderr = Pipe()
        p.standardError = stderr
        p.standardOutput = Pipe()

        let portWaiter = PortWaiter()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(chunk: chunk, waiter: portWaiter)
        }
        stderrPipe = stderr

        // Detect unintended exits and trigger auto-restart.
        p.terminationHandler = { [weak self] proc in
            // Hops onto MainActor — terminationHandler fires on a private queue.
            Task { @MainActor [weak self] in
                self?.onProcessExit(code: proc.terminationStatus)
            }
        }

        try p.run()
        process = p
        setStatus(.starting)

        // Wait up to 5 seconds for the READY line to be observed.
        let port = try await waitForReady(portWaiter: portWaiter, timeout: 5.0)
        restartAttempts = 0    // success → reset backoff
        setStatus(.running(port: port))
        onPortBound?(port)
        return port
    }

    private func onProcessExit(code: Int32) {
        // Tear down the dead pipe so it doesn't leak.
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        let wasExplicit = explicitStop
        process = nil
        if wasExplicit {
            setStatus(.stopped)
            return
        }
        setStatus(.crashed(reason: "exit \(code)"))
        // Schedule a restart with capped exponential backoff.
        restartAttempts += 1
        let delaySec = min(pow(2.0, Double(restartAttempts - 1)), 30.0)
        FileHandle.standardError.write(
            "[sidecar-mgr] crashed (exit \(code)); restarting in \(delaySec)s (attempt \(restartAttempts))\n"
                .data(using: .utf8) ?? Data()
        )
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard let self else { return }
            do {
                _ = try await self.start()
            } catch {
                FileHandle.standardError.write(
                    "[sidecar-mgr] restart failed: \(error)\n".data(using: .utf8) ?? Data()
                )
                // The next exit (which won't fire again because we never started)
                // would normally re-arm. Since start() failed, we manually
                // schedule another attempt by re-entering onProcessExit.
                self.onProcessExit(code: -1)
            }
        }
    }

    nonisolated private func appendStderr(chunk: Data, waiter: PortWaiter) {
        Task { @MainActor in
            self.stderrBuffer.append(chunk)
            while let nl = self.stderrBuffer.firstIndex(of: 0x0A) {
                let lineData = self.stderrBuffer.prefix(upTo: nl)
                self.stderrBuffer = self.stderrBuffer.suffix(from: self.stderrBuffer.index(after: nl))
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                FileHandle.standardError.write(("[sidecar] " + line + "\n").data(using: .utf8)!)
                if line.contains("READY") {
                    await waiter.markReadyPending()
                }
                if line.contains("\"port\":") || line.contains("\"port\": ") {
                    if let port = Self.parsePort(from: line) {
                        await waiter.setPort(port)
                    }
                }
            }
        }
    }

    public func stop() {
        explicitStop = true
        restartTask?.cancel()
        restartTask = nil
        guard let p = process else {
            setStatus(.stopped)
            return
        }
        p.terminate()
        // terminationHandler will hop in onProcessExit and call setStatus(.stopped).
        DispatchQueue.global().async {
            usleep(2_000_000)
            if p.isRunning { p.interrupt() }
            usleep(2_000_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    public func ping() async throws -> Bool {
        guard case .running(let port) = status else { return false }
        // Best-effort TCP probe.
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        do {
            let (_, _) = try await URLSession.shared.data(for: req)
            return true
        } catch {
            return false
        }
    }

    private func waitForReady(portWaiter: PortWaiter, timeout: TimeInterval) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                await portWaiter.awaitReady()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SidecarError.timeout
            }
            let port = try await group.next()!
            group.cancelAll()
            return port
        }
    }

    /// If an orphaned sidecar from a previous Mac-app run is still bound to
    /// the data dir, kill it before we spawn ours. Without this, the new
    /// sidecar silently falls back to a random port and Bonjour-published
    /// remote-access pairings stop resolving until the orphan is reaped by
    /// hand. The PID file is `<dataDir>/sidecar.pid`; we treat it as advisory
    /// and only act if the live process at that PID is actually our sidecar.
    nonisolated static func reapStaleSidecar(dataDir: URL) {
        let pidFile = dataDir.appendingPathComponent("sidecar.pid")
        guard let contents = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        guard let pid = Int32(firstLine), pid > 1 else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        // kill(pid, 0) returns 0 if signal could be sent (process exists).
        if kill(pid, 0) != 0 {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        let exe = processExePath(pid: pid) ?? ""
        guard exe.hasSuffix("multiharness-sidecar") else {
            FileHandle.standardError.write(
                "[sidecar-mgr] stale PID \(pid) belongs to '\(exe)', not our sidecar; ignoring\n"
                    .data(using: .utf8) ?? Data()
            )
            return
        }
        FileHandle.standardError.write(
            "[sidecar-mgr] reaping stale sidecar pid=\(pid) exe=\(exe)\n"
                .data(using: .utf8) ?? Data()
        )
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
        if kill(pid, 0) == 0 {
            FileHandle.standardError.write(
                "[sidecar-mgr] pid=\(pid) survived SIGTERM; SIGKILLing\n"
                    .data(using: .utf8) ?? Data()
            )
            _ = kill(pid, SIGKILL)
            usleep(500_000)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    nonisolated private static func processExePath(pid: Int32) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "comm="]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        } catch {
            return nil
        }
    }

    static func parsePort(from line: String) -> Int? {
        // Expect a JSON-ish blob in the structured log payload:
        // ... listening {"socket":null,"port":54321}
        guard let range = line.range(of: "\"port\"") else { return nil }
        let suffix = line[range.upperBound...]
        let digits = suffix.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    private func setStatus(_ s: Status) {
        status = s
        onStatusChange?(s)
    }
}

actor PortWaiter {
    private var port: Int?
    private var readyMarked = false
    private var waiters: [CheckedContinuation<Int, Never>] = []

    func markReadyPending() {
        readyMarked = true
        flush()
    }

    func setPort(_ p: Int) {
        port = p
        flush()
    }

    func awaitReady() async -> Int {
        if readyMarked, let p = port { return p }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            waiters.append(cont)
        }
    }

    private func flush() {
        guard readyMarked, let p = port else { return }
        let pending = waiters
        waiters.removeAll()
        for c in pending { c.resume(returning: p) }
    }
}

public enum SidecarError: Error, CustomStringConvertible {
    case binaryNotFound
    case exitedBeforeReady(code: Int32)
    case timeout
    public var description: String {
        switch self {
        case .binaryNotFound: return "multiharness-sidecar binary not found (set MULTIHARNESS_SIDECAR_PATH or rebuild sidecar)"
        case .exitedBeforeReady(let c): return "sidecar exited before signaling READY (code \(c))"
        case .timeout: return "timed out waiting for sidecar to become ready"
        }
    }
}
