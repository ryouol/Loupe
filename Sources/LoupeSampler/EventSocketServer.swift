import Darwin
import Foundation
import LoupeCore

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
    public private(set) var drops = EventDropCounter()
    /// Envelopes evicted because the consumer fell behind the stream buffer.
    public private(set) var overflowDrops = 0
    public private(set) var deniedConnections = 0
    public private(set) var resourceRejectedConnections = 0

    private enum Command: Sendable {
        case accepted(Int32)
        case data(Int32, Data)
        case closed(Int32)
    }

    private let socketPath: String
    private let requiredUID: uid_t
    private let maxConnections: Int
    private var listenFD: Int32 = -1
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [Int32: ConnectionState] = [:]
    private var envelopeContinuation: AsyncStream<EventEnvelope>.Continuation?
    private var commandContinuation: AsyncStream<Command>.Continuation?
    private var pump: Task<Void, Never>?
    private let statusStreamValue: AsyncStream<EventSocketStatus>
    private let statusContinuation: AsyncStream<EventSocketStatus>.Continuation
    private let queue = DispatchQueue(label: "ai.squint.loupe.event-socket")

    private final class ConnectionState {
        let source: any DispatchSourceRead
        var buffer = Data()
        init(source: any DispatchSourceRead) { self.source = source }
    }

    public init(
        socketPath: String, requiredUID: uid_t = geteuid(), maxConnections: Int = 16
    ) {
        self.socketPath = socketPath
        self.requiredUID = requiredUID
        self.maxConnections = max(1, min(maxConnections, 64))
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
            of: EventEnvelope.self, bufferingPolicy: .bufferingNewest(1_024))
        self.envelopeContinuation = envelopeContinuation
        let (commands, commandContinuation) = AsyncStream.makeStream(
            of: Command.self, bufferingPolicy: .bufferingOldest(2_048))
        self.commandContinuation = commandContinuation

        let statuses = statusContinuation
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            let result = commandContinuation.yield(.accepted(client))
            if case .dropped = result {
                statuses.yield(.degraded("Connection queue reached its limit"))
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
        statusContinuation.yield(.listening(path: socketPath))
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
        for state in connections.values {
            // The cancel handler owns the fd close — closing here would race
            // a handler mid-read on the socket queue.
            state.source.cancel()
        }
        connections.removeAll()
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
            statusContinuation.yield(.denied(uid: peerResult == 0 ? peerUID : nil))
            close(client)
            return
        }
        guard connections.count < maxConnections else {
            if resourceRejectedConnections < Int.max { resourceRejectedConnections += 1 }
            statusContinuation.yield(.degraded("Concurrent adapter limit reached"))
            close(client)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        connections[client] = ConnectionState(source: source)

        let statuses = statusContinuation
        source.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = read(client, &chunk, chunk.count)
            if count > 0 {
                let result = commandContinuation.yield(.data(client, Data(chunk[0..<count])))
                if case .dropped = result {
                    statuses.yield(.degraded("Ingest queue reached its limit"))
                    shutdown(client, SHUT_RDWR)
                } else if case .terminated = result {
                    shutdown(client, SHUT_RDWR)
                }
            } else {
                commandContinuation.yield(.closed(client))
            }
        }
        source.setCancelHandler {
            close(client)
        }
        source.resume()
        statusContinuation.yield(.connected(uid: peerUID))
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
                if case .dropped = envelopeContinuation?.yield(envelope) {
                    if overflowDrops < Int.max { overflowDrops += 1 }
                    statusContinuation.yield(.degraded("Replay buffer reached its limit"))
                }
            case .failure(let reason):
                drops.record(reason)
                statusContinuation.yield(.degraded("Dropped \(reason.label) adapter input"))
            }
        }
        // A line that never terminates must not buffer unboundedly.
        if state.buffer.count > EventLineDecoder.maxLineBytes {
            drops.record(.oversizedLine(bytes: state.buffer.count))
            statusContinuation.yield(.degraded("Dropped oversized_line adapter input"))
            state.buffer.removeAll(keepingCapacity: false)
        }
    }

    private func disconnect(client: Int32) {
        // Ordered after every .data this connection yielded, so its final
        // line is always ingested before teardown.
        guard let state = connections.removeValue(forKey: client) else { return }
        state.source.cancel()
        statusContinuation.yield(.disconnected)
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
