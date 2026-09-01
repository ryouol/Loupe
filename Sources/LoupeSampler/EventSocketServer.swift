import Darwin
import Foundation
import LoupeCore

private final class EventSocketYieldCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var dataCommandDrops = 0
    private var connectionCommandDrops = 0
    private var statusDrops = 0

    func recordCommand<T>(
        _ result: AsyncStream<T>.Continuation.YieldResult,
        carriesData: Bool
    ) {
        let wasLost: Bool
        switch result {
        case .dropped:
            wasLost = true
        case .terminated:
            // Once stop closes the command stream, a read handler can still
            // return bytes already in the kernel socket buffer. Those bytes
            // are a real ingest loss; terminal connection notifications are
            // control-plane only and do not imply an application-event loss.
            wasLost = carriesData
        case .enqueued:
            wasLost = false
        @unknown default:
            wasLost = carriesData
        }
        guard wasLost else { return }
        lock.withLock {
            if carriesData {
                if dataCommandDrops < Int.max { dataCommandDrops += 1 }
            } else if connectionCommandDrops < Int.max {
                connectionCommandDrops += 1
            }
        }
    }

    func recordStatus<T>(_ result: AsyncStream<T>.Continuation.YieldResult) {
        guard case .dropped = result else { return }
        lock.withLock { if statusDrops < Int.max { statusDrops += 1 } }
    }

    func snapshot() -> (data: Int, connection: Int, status: Int) {
        lock.withLock { (dataCommandDrops, connectionCommandDrops, statusDrops) }
    }
}

public enum EventSocketStatus: Sendable, Equatable {
    case listening(path: String)
    case connected(uid: uid_t)
    case disconnected
    case denied(uid: uid_t?)
    case degraded(String)
}

/// The adapters → user app ingest path: a Unix-domain listener that validates
/// every NDJSON line through the protocol decoder. Socket work happens on
/// GCD dispatch sources; their handlers yield synchronously into one command
/// stream consumed by one pump task, so a connection's bytes reach the actor
/// in exactly the order they arrived — independent Task hops would not
/// guarantee that (same hazard DaemonXPCService documents for start/stop).
///
/// Adapters are untrusted input: lines are bounded, malformed lines become
/// counted drops, buffered unterminated data is capped, and consumer
/// backpressure past the stream buffer is counted, never silent.
public actor EventSocketServer {
    private enum ProducerWindow: Equatable {
        case none
        case open
        case closed
    }

    public private(set) var drops = EventDropCounter()
    /// Envelopes evicted because the consumer fell behind the stream buffer.
    public private(set) var overflowDrops = 0
    public private(set) var deniedConnections = 0
    public private(set) var resourceRejectedConnections = 0
    public private(set) var observedSequenceGaps = 0
    public private(set) var producerReportedDrops: Int?
    public private(set) var sequenceIntegrityViolations = 0

    private enum Command: Sendable {
        case accepted(Int32)
        case data(Int32, Data)
        case closed(Int32)
    }

    private let socketPath: String
    private let requiredUID: uid_t
    private let maxConnections: Int
    private let maxBufferedEvents: Int
    private var listenFD: Int32 = -1
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [Int32: ConnectionState] = [:]
    private var envelopeContinuation: AsyncStream<EventEnvelope>.Continuation?
    private var commandContinuation: AsyncStream<Command>.Continuation?
    private var pump: Task<Void, Never>?
    private let statusStreamValue: AsyncStream<EventSocketStatus>
    private let statusContinuation: AsyncStream<EventSocketStatus>.Continuation
    private let queue = DispatchQueue(label: "ai.squint.loupe.event-socket")
    private let yieldCounters = EventSocketYieldCounters()
    private var lastSequence: UInt64?
    private var producerWindow: ProducerWindow = .none
    private var allProducerWindowsClosed = true
    private var sawLegacyProtocol = false

    private final class ConnectionState {
        let source: any DispatchSourceRead
        var buffer = Data()
        init(source: any DispatchSourceRead) { self.source = source }
    }

    public init(
        socketPath: String, requiredUID: uid_t = geteuid(), maxConnections: Int = 16,
        maxBufferedEvents: Int = 1_024
    ) {
        self.socketPath = socketPath
        self.requiredUID = requiredUID
        self.maxConnections = max(1, min(maxConnections, 64))
        self.maxBufferedEvents = max(1, min(maxBufferedEvents, 65_536))
        let (stream, continuation) = AsyncStream.makeStream(
            of: EventSocketStatus.self, bufferingPolicy: .bufferingNewest(128))
        self.statusStreamValue = stream
        self.statusContinuation = continuation
    }

    public func statusEvents() -> AsyncStream<EventSocketStatus> { statusStreamValue }

    /// Binds, listens, and returns the envelope stream. Throws when the path
    /// can't be bound (permissions, stale socket held by a live process).
    public func start() throws -> AsyncStream<EventEnvelope> {
        guard listenFD < 0 else { throw SocketError.alreadyStarted }
        try prepareSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw SocketError.pathTooLong(socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketError.bind(errno)
        }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            let failure = errno
            close(fd)
            unlink(socketPath)
            throw SocketError.permissions(failure)
        }
        guard listen(fd, Int32(maxConnections)) == 0 else {
            close(fd)
            unlink(socketPath)
            throw SocketError.listen(errno)
        }

        listenFD = fd
        let (envelopes, envelopeContinuation) = AsyncStream.makeStream(
            of: EventEnvelope.self, bufferingPolicy: .bufferingNewest(maxBufferedEvents))
        self.envelopeContinuation = envelopeContinuation
        let (commands, commandContinuation) = AsyncStream.makeStream(
            of: Command.self, bufferingPolicy: .bufferingOldest(2_048))
        self.commandContinuation = commandContinuation

        let statuses = statusContinuation
        let yieldCounters = yieldCounters
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            let result = commandContinuation.yield(.accepted(client))
            yieldCounters.recordCommand(result, carriesData: false)
            if case .dropped = result {
                yieldCounters.recordStatus(
                    statuses.yield(.degraded("Connection queue reached its limit")))
                close(client)
            } else if case .terminated = result {
                close(client)
            }
        }
        source.resume()
        listenSource = source

        pump = Task {
            for await command in commands {
                switch command {
                case .accepted(let client): self.register(client: client)
                case .data(let client, let data): self.ingest(data, from: client)
                case .closed(let client): self.disconnect(client: client)
                }
            }
        }
        yieldCounters.recordStatus(statusContinuation.yield(.listening(path: socketPath)))
        return envelopes
    }

    public func stop() async {
        let listener = listenSource
        let listenerFD = listenFD
        listenSource = nil
        listenFD = -1
        queue.sync {
            listener?.cancel()
            if listenerFD >= 0 { close(listenerFD) }
        }
        commandContinuation?.finish()
        commandContinuation = nil
        let drainingPump = pump
        pump = nil
        await drainingPump?.value
        // Finalize any unterminated buffered line exactly as a peer EOF would
        // before cancelling the dispatch source that owns its descriptor.
        for client in Array(connections.keys) { disconnect(client: client) }
        envelopeContinuation?.finish()
        envelopeContinuation = nil
        unlink(socketPath)
        statusContinuation.finish()
    }

    private func register(client: Int32) {
        guard let commandContinuation else {
            close(client)
            return
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        let peerResult = getpeereid(client, &peerUID, &peerGID)
        guard peerResult == 0, peerUID == requiredUID else {
            if deniedConnections < Int.max { deniedConnections += 1 }
            yieldCounters.recordStatus(
                statusContinuation.yield(.denied(uid: peerResult == 0 ? peerUID : nil)))
            close(client)
            return
        }
        guard connections.count < maxConnections else {
            if resourceRejectedConnections < Int.max { resourceRejectedConnections += 1 }
            yieldCounters.recordStatus(
                statusContinuation.yield(.degraded("Concurrent adapter limit reached")))
            close(client)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        connections[client] = ConnectionState(source: source)

        let statuses = statusContinuation
        let yieldCounters = yieldCounters
        source.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = read(client, &chunk, chunk.count)
            if count > 0 {
                let result = commandContinuation.yield(.data(client, Data(chunk[0..<count])))
                yieldCounters.recordCommand(result, carriesData: true)
                if case .dropped = result {
                    yieldCounters.recordStatus(
                        statuses.yield(.degraded("Ingest queue reached its limit")))
                    shutdown(client, SHUT_RDWR)
                } else if case .terminated = result {
                    shutdown(client, SHUT_RDWR)
                }
            } else {
                let result = commandContinuation.yield(.closed(client))
                yieldCounters.recordCommand(result, carriesData: false)
            }
        }
        source.setCancelHandler {
            close(client)
        }
        source.resume()
        yieldCounters.recordStatus(statusContinuation.yield(.connected(uid: peerUID)))
    }

    private func ingest(_ data: Data, from client: Int32) {
        guard let state = connections[client] else { return }
        state.buffer.append(data)

        let decoder = EventLineDecoder()
        while let newline = state.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = state.buffer.subdata(in: state.buffer.startIndex..<newline)
            state.buffer.removeSubrange(state.buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            switch decoder.decode(line: line) {
            case .success(let envelope):
                recordSequence(envelope)
                let result = envelopeContinuation?.yield(envelope)
                let wasLost = result.map(\.isLost) ?? true
                if wasLost {
                    if overflowDrops < Int.max { overflowDrops += 1 }
                    yieldCounters.recordStatus(
                        statusContinuation.yield(
                            .degraded("Replay buffer reached its limit")))
                }
            case .failure(let reason):
                drops.record(reason)
                yieldCounters.recordStatus(
                    statusContinuation.yield(
                        .degraded("Dropped \(reason.label) adapter input")))
            }
        }
        // A line that never terminates must not buffer unboundedly.
        if state.buffer.count > EventLineDecoder.maxLineBytes {
            drops.record(.oversizedLine(bytes: state.buffer.count))
            yieldCounters.recordStatus(
                statusContinuation.yield(.degraded("Dropped oversized_line adapter input")))
            state.buffer.removeAll(keepingCapacity: false)
        }
    }

    private func disconnect(client: Int32) {
        // Ordered after every .data this connection yielded, so its final
        // bytes are always ingested before teardown. Treat EOF as a framing
        // boundary: a complete final JSON object remains usable without its
        // newline, while a truncated fragment becomes a counted parser drop.
        guard let state = connections[client] else { return }
        if !state.buffer.isEmpty {
            ingest(Data([UInt8(ascii: "\n")]), from: client)
        }
        guard connections.removeValue(forKey: client) != nil else { return }
        state.source.cancel()
        yieldCounters.recordStatus(statusContinuation.yield(.disconnected))
    }

    public func acquisitionLosses() -> AcquisitionLossCount {
        let counters = yieldCounters.snapshot()
        let observedBeforeReplayBuffer = Self.saturatingSum([
            producerReportedDrops ?? 0, drops.total, counters.data,
        ])
        let lowerBound = Self.saturatingSum([
            max(observedBeforeReplayBuffer, observedSequenceGaps), overflowDrops,
        ])
        let exact = producerReportedDrops.flatMap { producer -> Int? in
            let explainedSequenceLoss = Self.saturatingSum([producer, drops.total])
            guard counters.data == 0, counters.connection == 0,
                sequenceIntegrityViolations == 0,
                !sawLegacyProtocol, allProducerWindowsClosed,
                producerWindow == .closed,
                observedSequenceGaps <= explainedSequenceLoss
            else {
                return nil
            }
            return Self.saturatingSum([producer, drops.total, overflowDrops])
        }
        return AcquisitionLossCount(
            exact: exact,
            lowerBound: lowerBound,
            breakdown: [
                "producer_reported": producerReportedDrops ?? 0,
                "producer_sequence_gap_lower_bound": observedSequenceGaps,
                "sequence_integrity_violations": sequenceIntegrityViolations,
                "socket_parser": drops.total,
                "event_buffer": overflowDrops,
                "ingest_chunk_lower_bound": counters.data,
                "connection_commands": counters.connection,
                "status_notifications": counters.status,
            ])
    }

    private func recordSequence(_ envelope: EventEnvelope) {
        guard EventProtocol.versionsWithSequencing.contains(envelope.v),
            let sequence = envelope.sequence
        else {
            sawLegacyProtocol = true
            return
        }
        if envelope.kind == .sessionStart {
            if producerWindow == .open { allProducerWindowsClosed = false }
            producerWindow = .open
            lastSequence = nil
        } else if producerWindow == .closed {
            recordSequenceIntegrityViolation()
        } else if producerWindow == .none {
            allProducerWindowsClosed = false
            producerWindow = .open
        }
        if envelope.kind == .sessionStart {
            if sequence > 1 {
                observedSequenceGaps = Self.saturatingSum([
                    observedSequenceGaps, Int(clamping: sequence - 1),
                ])
            }
            lastSequence = sequence
        } else if let previous = lastSequence {
            if sequence > previous {
                if sequence - previous > 1 {
                    observedSequenceGaps = Self.saturatingSum([
                        observedSequenceGaps, Int(clamping: sequence - previous - 1),
                    ])
                }
                lastSequence = sequence
            } else {
                recordSequenceIntegrityViolation()
            }
        } else {
            if sequence > 1 {
                observedSequenceGaps = Self.saturatingSum([
                    observedSequenceGaps, Int(clamping: sequence - 1),
                ])
            }
            lastSequence = sequence
        }
        if case .transportSummary(let summary) = envelope.payload {
            if producerWindow == .open, summary.attemptedEvents == sequence - 1 {
                producerReportedDrops = Self.saturatingSum([
                    producerReportedDrops ?? 0,
                    Int(clamping: summary.producerDroppedEvents),
                ])
                producerWindow = .closed
            } else {
                recordSequenceIntegrityViolation()
            }
        }
    }

    private func recordSequenceIntegrityViolation() {
        if sequenceIntegrityViolations < Int.max { sequenceIntegrityViolations += 1 }
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            partial > Int.max - value ? Int.max : partial + value
        }
    }

    private func prepareSocketPath() throws {
        let parentPath = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        var parent = stat()
        guard lstat(parentPath, &parent) == 0,
            parent.st_mode & S_IFMT == S_IFDIR,
            parent.st_uid == requiredUID,
            parent.st_mode & 0o077 == 0
        else {
            throw SocketError.unsafeParentDirectory(parentPath)
        }

        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == requiredUID else {
                throw SocketError.unsafeExistingNode(socketPath)
            }
            if Self.hasLiveListener(at: socketPath) {
                throw SocketError.socketInUse(socketPath)
            }
            guard unlink(socketPath) == 0 else { throw SocketError.unlink(errno) }
        } else if errno != ENOENT {
            throw SocketError.bind(errno)
        }
    }

    private static func hasLiveListener(at path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 || (errno != ECONNREFUSED && errno != ENOENT)
    }

    public enum SocketError: LocalizedError, Equatable {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case permissions(Int32)
        case unlink(Int32)
        case pathTooLong(String)
        case unsafeParentDirectory(String)
        case unsafeExistingNode(String)
        case socketInUse(String)
        case alreadyStarted

        public var errorDescription: String? {
            switch self {
            case .socket(let code): return "The adapter socket could not be created (\(code))."
            case .bind(let code): return "The adapter socket could not be bound (\(code))."
            case .listen(let code): return "The adapter socket could not listen (\(code))."
            case .permissions(let code):
                return "Owner-only adapter socket permissions could not be applied (\(code))."
            case .unlink(let code):
                return "A stale adapter socket could not be removed (\(code))."
            case .pathTooLong: return "The adapter socket path is too long."
            case .unsafeParentDirectory:
                return "The adapter socket directory is not owner-controlled."
            case .unsafeExistingNode:
                return "Loupe refused to replace an unsafe adapter socket node."
            case .socketInUse: return "Another Loupe recording is already using the adapter socket."
            case .alreadyStarted: return "The adapter socket is already running."
            }
        }
    }
}

private extension AsyncStream.Continuation.YieldResult {
    var isLost: Bool {
        switch self {
        case .dropped, .terminated: return true
        case .enqueued: return false
        @unknown default: return true
        }
    }
}
