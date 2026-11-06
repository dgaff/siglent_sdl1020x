import Foundation
import Network

public enum SCPIError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case connectFailed(String)
    case timeout(command: String)
    case connectionClosed
    case invalidResponse(command: String, response: String)
    case deviceError(code: Int, message: String)

    public var description: String {
        switch self {
        case .notConnected: "Not connected"
        case .connectFailed(let why): "Connect failed: \(why)"
        case .timeout(let cmd): "Timed out waiting for reply to \(cmd)"
        case .connectionClosed: "Connection closed by instrument"
        case .invalidResponse(let cmd, let resp): "Unexpected reply to \(cmd): \(resp)"
        case .deviceError(let code, let msg): "Instrument error \(code): \(msg)"
        }
    }
}

/// One line of the command log (for the debug console).
public struct SCPILogEntry: Sendable, Identifiable {
    public enum Kind: Sendable { case write, query, reply, error, info }
    public let id = UUID()
    public let date: Date
    public let kind: Kind
    public let text: String
}

/// A raw-socket SCPI session (e.g. TCP 5025).
///
/// Guarantees exactly one command in flight: callers are serialized FIFO, so a poll loop,
/// UI edits and scripted profiles can share a connection safely.
///
/// SDL1000X quirks handled here:
/// - Unknown/malformed queries get *no reply at all* → every query has a timeout, after which
///   the session is marked dirty and stray late lines are drained before the next command.
/// - Never send chained queries (`A?;B?`); replies are concatenated without a separator.
public actor SCPIConnection {
    public nonisolated let host: String
    public nonisolated let port: UInt16
    public var defaultTimeout: Duration
    public private(set) var isConnected = false

    /// Optional log sink. Called on the actor; keep it cheap.
    private var logHandler: (@Sendable (SCPILogEntry) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "SCPIConnection")
    private var buffer = Data()
    private var lines: [String] = []
    private var lineWaiter: (id: UInt64, cont: CheckedContinuation<String, Error>)?
    private var waiterSeq: UInt64 = 0
    private var dirty = false

    // FIFO mutex for command exclusivity (actor methods are reentrant across awaits).
    private var busy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    public init(host: String, port: UInt16 = 5025, timeout: Duration = .milliseconds(1500)) {
        self.host = host
        self.port = port
        self.defaultTimeout = timeout
    }

    public func setLogHandler(_ handler: (@Sendable (SCPILogEntry) -> Void)?) {
        logHandler = handler
    }

    // MARK: - Connection lifecycle

    public func connect(timeout: Duration = .seconds(3)) async throws {
        if isConnected { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection = conn
        buffer.removeAll()
        lines.removeAll()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(cont)
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(.success(()))
                case .failed(let err):
                    once.resume(.failure(SCPIError.connectFailed(err.localizedDescription)))
                    Task { await self?.handleClosed() }
                case .waiting(let err):
                    // Host unreachable / refused: fail fast rather than waiting forever.
                    once.resume(.failure(SCPIError.connectFailed(err.localizedDescription)))
                case .cancelled:
                    once.resume(.failure(SCPIError.connectionClosed))
                    Task { await self?.handleClosed() }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                once.resume(.failure(SCPIError.connectFailed("timed out")))
            }
        }
        isConnected = true
        log(.info, "Connected to \(host):\(port)")
        receiveNext()
    }

    public func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        handleClosed()
    }

    private func handleClosed() {
        guard isConnected || connection != nil else { return }
        isConnected = false
        connection = nil
        if let w = lineWaiter {
            lineWaiter = nil
            w.cont.resume(throwing: SCPIError.connectionClosed)
        }
        log(.info, "Disconnected from \(host):\(port)")
    }

    // MARK: - Public command API

    /// Send a command that produces no reply.
    ///
    /// With `confirm` (the default) the write is followed by `*OPC?` and we wait for the `1`.
    /// The SDL1000X takes ~170–250 ms to *process* each set command (queries take ~10 ms), so
    /// unconfirmed writes pile up in its input buffer and later queries time out behind them.
    /// Confirming every write gives natural back-pressure and keeps replies aligned.
    public func write(_ command: String, confirm: Bool = true, timeout: Duration? = nil) async throws {
        await lock()
        defer { unlock() }
        try await resyncIfDirty()
        try await send(command)
        log(.write, command)
        guard confirm else { return }
        try await send("*OPC?")
        let reply: String
        do {
            reply = try await nextLine(timeout: timeout ?? writeTimeout)
        } catch SCPIError.timeout {
            dirty = true
            consecutiveTimeouts += 1
            log(.error, "No *OPC? confirmation for \(command)")
            throw SCPIError.timeout(command: command)
        }
        if reply.trimmingCharacters(in: .whitespaces) != "1" {
            dirty = true
            log(.error, "Unexpected *OPC? reply '\(reply)' after \(command) — resyncing")
            throw SCPIError.invalidResponse(command: "\(command);*OPC?", response: reply)
        }
    }

    /// How long to wait for a write's `*OPC?` confirmation.
    public var writeTimeout: Duration = .seconds(5)

    /// Send a query and return the reply line (without terminator).
    /// - Parameter retries: extra attempts after a timeout. Only use for side-effect-free
    ///   queries (not `SYST:ERR?`, which pops the error queue). The SDL occasionally stalls
    ///   for a second or two; one retry rides through that.
    public func query(_ command: String, timeout: Duration? = nil, retries: Int = 0) async throws -> String {
        await lock()
        defer { unlock() }
        var attempt = 0
        while true {
            try await resyncIfDirty()
            try await send(command)
            log(.query, command)
            do {
                let reply = try await nextLine(timeout: timeout ?? defaultTimeout)
                log(.reply, reply)
                if command.uppercased() == "*IDN?" { identityLine = reply }
                return reply
            } catch SCPIError.timeout {
                dirty = true
                log(.error, "No reply to \(command)\(attempt < retries ? " — retrying" : "")")
                consecutiveTimeouts += 1
                if attempt >= retries { throw SCPIError.timeout(command: command) }
                attempt += 1
            }
        }
    }

    /// Number of query timeouts since the last successful reply (lets a session decide the
    /// link is dead, e.g. a pulled cable, which TCP itself won't report for a long time).
    public private(set) var consecutiveTimeouts = 0

    // MARK: - Internals

    private func send(_ command: String) async throws {
        guard let conn = connection, isConnected else { throw SCPIError.notConnected }
        let data = Data((command + "\n").utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: SCPIError.connectFailed(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    /// After a timeout the instrument may still be working through a backlog and emit late
    /// replies, which would shift every later reply by one. Resync in two steps:
    /// 1. wait until the link has been quiet for `resyncQuiet` (bounded by `resyncMaxWait`),
    ///    discarding whatever arrives;
    /// 2. send an `*IDN?` sentinel and discard lines until its reply shows up.
    /// If the sentinel never answers, stay dirty and throw — the caller should reconnect.
    private func resyncIfDirty() async throws {
        guard dirty else { return }
        log(.info, "Resynchronizing")
        let clock = ContinuousClock()
        let deadline = clock.now + resyncMaxWait
        var lastCount = linesReceived
        var quietSince = clock.now
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if linesReceived != lastCount { lastCount = linesReceived; quietSince = clock.now }
            else if clock.now - quietSince >= resyncQuiet { break }
        }
        if !lines.isEmpty { log(.info, "Discarded \(lines.count) stale line(s)") }
        lines.removeAll()

        // The sentinel's reply is the *last* line the instrument will send (it processes in
        // order and we send nothing after it). A stale `*IDN?` reply from the timed-out query
        // can arrive first, so only accept an identity line once the link stays quiet after it.
        try await send("*IDN?")
        let sentinelDeadline = clock.now + resyncMaxWait
        var sawIdentity = false
        while true {
            let remaining = sentinelDeadline - clock.now
            guard remaining > .zero else { throw SCPIError.timeout(command: "*IDN? (resync)") }
            let line: String
            do { line = try await nextLine(timeout: sawIdentity ? min(resyncQuiet, remaining) : remaining) }
            catch SCPIError.timeout {
                if sawIdentity { break }
                throw SCPIError.timeout(command: "*IDN? (resync)")
            }
            if isIdentityLine(line) {
                if sawIdentity { log(.info, "Discarded stale *IDN? reply during resync") }
                sawIdentity = true
            } else {
                sawIdentity = false
                log(.info, "Discarded stale line during resync: \(line.prefix(60))")
            }
        }
        dirty = false
        log(.info, "Resynchronized")
    }

    public var resyncQuiet: Duration = .milliseconds(300)
    public var resyncMaxWait: Duration = .seconds(8)
    private var identityLine: String?
    private var linesReceived = 0

    private func isIdentityLine(_ s: String) -> Bool {
        if let identityLine { return s == identityLine }
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count == 4 && (s.first?.isLetter ?? false)
    }

    private func nextLine(timeout: Duration) async throws -> String {
        if !lines.isEmpty { return lines.removeFirst() }
        guard isConnected else { throw SCPIError.notConnected }
        waiterSeq &+= 1
        let id = waiterSeq
        return try await withCheckedThrowingContinuation { cont in
            lineWaiter = (id, cont)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireWaiter(id: id)
            }
        }
    }

    private func expireWaiter(id: UInt64) {
        guard let w = lineWaiter, w.id == id else { return }
        lineWaiter = nil
        w.cont.resume(throwing: SCPIError.timeout(command: ""))
    }

    private func receiveNext() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                var lineData = buffer[buffer.startIndex..<nl]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self)
                consecutiveTimeouts = 0
                linesReceived += 1
                if let w = lineWaiter {
                    lineWaiter = nil
                    w.cont.resume(returning: line)
                } else {
                    lines.append(line)
                }
            }
        }
        if isComplete || error != nil {
            handleClosed()
            return
        }
        receiveNext()
    }

    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func unlock() {
        if lockWaiters.isEmpty { busy = false }
        else { lockWaiters.removeFirst().resume() }
    }

    private func log(_ kind: SCPILogEntry.Kind, _ text: String) {
        logHandler?(SCPILogEntry(date: Date(), kind: kind, text: text))
    }
}

/// Resume a continuation at most once (connect races state updates against a timer).
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }
    func resume(_ result: Result<T, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: result)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (s, atto) = components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }
}
