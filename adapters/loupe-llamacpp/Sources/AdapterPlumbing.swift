import Darwin
import Foundation

/// Client half of the adapter → daemon socket: best-effort line writer.
/// Writes are synchronous, which is fine here and only here: this executable
/// emits a request's whole trace after the stream completes, so a slow write
/// never sits inside a generation loop (the in-process Python adapter uses a
/// queue for exactly that reason). @unchecked because every access to `fd`
/// and the drop counter goes through `lock`.
public final class UnixSocketLineWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var droppedCount = 0

    public var dropped: Int {
        lock.withLock { droppedCount }
    }

    public init(socketPath: String) {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketFD)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 {
            fd = socketFD
        } else {
            close(socketFD)
        }
    }

    public func send(_ line: Data) {
        lock.withLock {
            guard fd >= 0 else {
                droppedCount += 1
                return
            }
            var payload = line
            payload.append(UInt8(ascii: "\n"))
            let written = payload.withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            if written != payload.count {
                droppedCount += 1
                close(fd)
                fd = -1
            }
        }
    }

    public func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    private func close(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }
}

/// Polls `/metrics` at the spec's 10 Hz, keeping the latest snapshot and the
/// running maxima — a gauge's peak is gone by the time a request finishes,
/// so "latest" alone cannot answer "how high did it get".
public actor MetricsPoller {
    public private(set) var latest: [String: Double] = [:]
    public private(set) var maxima: [String: Double] = [:]
    private let url: URL
    private var task: Task<Void, Never>?

    public init(url: URL) {
        self.url = url
    }

    deinit {
        // `start`'s task captures self; without this, an abandoned poller
        // polls forever.
        task?.cancel()
    }

    public func start(intervalMs: Int = 100) {
        stop()
        let url = url
        task = Task {
            while !Task.isCancelled {
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    let parsed = PrometheusParser.parse(String(decoding: data, as: UTF8.self))
                    if !parsed.isEmpty {
                        self.record(parsed)
                    }
                }
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func record(_ parsed: [String: Double]) {
        latest = parsed
        for (name, value) in parsed {
            maxima[name] = max(maxima[name] ?? -.infinity, value)
        }
    }
}
