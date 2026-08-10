import Darwin
import Foundation
import LoupeCore

/// The adapters → daemon ingest path: a Unix-domain listener that validates
/// every NDJSON line through the protocol decoder. All socket work happens on
/// GCD dispatch sources (never a blocked cooperative thread); envelopes cross
/// into async land through one stream.
///
/// Adapters are untrusted input: lines are bounded before buffering, malformed
/// lines become counted drops, and a hostile connection cannot allocate more
/// than the line cap per read.
public actor EventSocketServer {
    public private(set) var drops = EventDropCounter()

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [Int32: ConnectionState] = [:]
    private var continuation: AsyncStream<EventEnvelope>.Continuation?
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
        let (stream, continuation) = AsyncStream.makeStream(
            of: EventEnvelope.self, bufferingPolicy: .bufferingNewest(65_536))
        self.continuation = continuation

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0, let self else { return }
            Task { await self.register(client: client) }
        }
        source.resume()
        listenSource = source
        return stream
    }

    public func stop() {
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        for (fd, state) in connections {
            state.source.cancel()
            close(fd)
        }
        connections.removeAll()
        continuation?.finish()
        continuation = nil
        unlink(socketPath)
    }

    private func register(client: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        let state = ConnectionState(source: source)
        connections[client] = state

        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = read(client, &chunk, chunk.count)
            guard let self else { return }
            if count > 0 {
                let data = Data(chunk[0..<count])
                Task { await self.ingest(data, from: client) }
            } else {
                Task { await self.disconnect(client: client) }
            }
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
            case .success(let envelope): continuation?.yield(envelope)
            case .failure(let reason): drops.record(reason)
            }
        }
        // A line that never terminates must not buffer unboundedly.
        if state.buffer.count > EventLineDecoder.maxLineBytes {
            drops.record(.oversizedLine(bytes: state.buffer.count))
            state.buffer.removeAll(keepingCapacity: false)
        }
    }

    private func disconnect(client: Int32) {
        guard let state = connections.removeValue(forKey: client) else { return }
        state.source.cancel()
        close(client)
    }

    public enum SocketError: Error, Equatable {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case pathTooLong(String)
    }
}
