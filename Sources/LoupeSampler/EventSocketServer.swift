import Darwin
import Foundation
import LoupeCore

/// The adapters → daemon ingest path: a Unix-domain listener that validates
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

    private enum Command: Sendable {
        case accepted(Int32)
        case data(Int32, Data)
        case closed(Int32)
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [Int32: ConnectionState] = [:]
    private var envelopeContinuation: AsyncStream<EventEnvelope>.Continuation?
    private var commandContinuation: AsyncStream<Command>.Continuation?
    private var pump: Task<Void, Never>?
    private let queue = DispatchQueue(label: "ai.squint.loupe.event-socket")

    private final class ConnectionState {
        let source: any DispatchSourceRead
        var buffer = Data()
        init(source: any DispatchSourceRead) { self.source = source }
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Binds, listens, and returns the envelope stream. Throws when the path
    /// can't be bound (permissions, stale socket held by a live process).
    public func start() throws -> AsyncStream<EventEnvelope> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }

        // A previous daemon instance leaves the filesystem entry behind.
        unlink(socketPath)

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
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw SocketError.listen(errno)
        }

        listenFD = fd
        let (envelopes, envelopeContinuation) = AsyncStream.makeStream(
            of: EventEnvelope.self, bufferingPolicy: .bufferingNewest(65_536))
        self.envelopeContinuation = envelopeContinuation
        let (commands, commandContinuation) = AsyncStream.makeStream(of: Command.self)
        self.commandContinuation = commandContinuation

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            commandContinuation.yield(.accepted(client))
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
        return envelopes
    }

    public func stop() {
        commandContinuation?.finish()
        commandContinuation = nil
        pump?.cancel()
        pump = nil
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        for state in connections.values {
            // The cancel handler owns the fd close — closing here would race
            // a handler mid-read on the socket queue.
            state.source.cancel()
        }
        connections.removeAll()
        envelopeContinuation?.finish()
        envelopeContinuation = nil
        unlink(socketPath)
    }

    private func register(client: Int32) {
        guard let commandContinuation else {
            close(client)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        connections[client] = ConnectionState(source: source)

        source.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = read(client, &chunk, chunk.count)
            if count > 0 {
                commandContinuation.yield(.data(client, Data(chunk[0..<count])))
            } else {
                commandContinuation.yield(.closed(client))
            }
        }
        source.setCancelHandler {
            close(client)
        }
        source.resume()
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
                    overflowDrops += 1
                }
            case .failure(let reason):
                drops.record(reason)
            }
        }
        // A line that never terminates must not buffer unboundedly.
        if state.buffer.count > EventLineDecoder.maxLineBytes {
            drops.record(.oversizedLine(bytes: state.buffer.count))
            state.buffer.removeAll(keepingCapacity: false)
        }
    }

    private func disconnect(client: Int32) {
        // Ordered after every .data this connection yielded, so its final
        // line is always ingested before teardown.
        guard let state = connections.removeValue(forKey: client) else { return }
        state.source.cancel()
    }

    public enum SocketError: Error, Equatable {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case pathTooLong(String)
    }
}
