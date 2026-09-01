import Darwin
import Foundation

public enum PromptInputError: Error, Equatable {
    case empty
    case tooLarge
    case invalidUTF8
    case inlinePromptUnsupported
}

/// Prompt transport for the standalone adapter. Prompt bytes arrive through
/// a bounded pipe/file descriptor and never become visible in process argv.
public enum PromptInput {
    public static let maxBytes = 65_536

    public static func validateCommandLine(_ arguments: [String]) throws {
        if arguments.contains(where: { $0 == "--prompt" || $0.hasPrefix("--prompt=") }) {
            throw PromptInputError.inlinePromptUnsupported
        }
    }

    public static func read(from handle: FileHandle = .standardInput) throws -> String {
        var data = Data()
        while data.count <= maxBytes {
            let remaining = maxBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw PromptInputError.empty }
        guard data.count <= maxBytes else { throw PromptInputError.tooLarge }
        guard let prompt = String(data: data, encoding: .utf8) else {
            throw PromptInputError.invalidUTF8
        }
        return prompt
    }
}

/// Client half of the adapter → user app socket: best-effort line writer.
/// Writes are synchronous, which is fine here and only here: this executable
/// emits a request's whole trace after the stream completes, so a slow write
/// never sits inside a generation loop (the in-process Python adapter uses a
/// queue for exactly that reason). @unchecked because every access to `fd`
/// and the drop counter goes through `lock`.
public final class UnixSocketLineWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let socketPath: String
    private var fd: Int32 = -1
    private var droppedCount = 0
    private var nextConnectAttemptNs: UInt64 = 0
    private static let reconnectBackoffNs: UInt64 = 500_000_000

    public var dropped: Int {
        lock.withLock { droppedCount }
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ line: Data) {
        lock.withLock {
            var payload = line
            payload.append(UInt8(ascii: "\n"))
            if fd < 0, !connectLocked() {
                droppedCount += 1
                return
            }
            if writeAllLocked(payload) { return }

            // A short write leaves only an unterminated fragment on the old
            // connection. Reconnect once and replay the complete line. If
            // that bounded retry fails, sequence/summary accounting records
            // the drop; no code claims the app observed a summary it did not.
            disconnectLocked()
            if connectLocked(ignoringBackoff: true), writeAllLocked(payload) { return }
            disconnectLocked()
            droppedCount += 1
        }
    }

    public func close() {
        lock.withLock { disconnectLocked() }
    }

    private func connectLocked(ignoringBackoff: Bool = false) -> Bool {
        if fd >= 0 { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        guard ignoringBackoff || now >= nextConnectAttemptNs else { return false }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            setConnectBackoff(after: now)
            return false
        }
        var enabled: Int32 = 1
        guard
            setsockopt(
                socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            Darwin.close(socketFD)
            setConnectBackoff(after: now)
            return false
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD)
            setConnectBackoff(after: now)
            return false
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
            nextConnectAttemptNs = 0
            return true
        } else {
            Darwin.close(socketFD)
            setConnectBackoff(after: now)
            return false
        }
    }

    private func setConnectBackoff(after now: UInt64) {
        nextConnectAttemptNs =
            now > UInt64.max - Self.reconnectBackoffNs
            ? UInt64.max : now + Self.reconnectBackoffNs
    }

    private func writeAllLocked(_ payload: Data) -> Bool {
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func disconnectLocked() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

/// Polls `/metrics` at the spec's 10 Hz, keeping the latest snapshot and the
/// running maxima — a gauge's peak is gone by the time a request finishes,
/// so "latest" alone cannot answer "how high did it get".
public actor MetricsPoller {
    public private(set) var latest: [String: Double] = [:]
    public private(set) var maxima: [String: Double] = [:]
    private let url: URL
    private let session: URLSession
    private var task: Task<Void, Never>?

    public init(url: URL, session: URLSession = AdapterHTTP.session()) {
        self.url = url
        self.session = session
    }

    deinit {
        // Defensive cancellation; the task captures this actor weakly so an
        // abandoned poller can deinitialize even after a request fails.
        task?.cancel()
    }

    public func start(intervalMs: Int = 100) {
        stop()
        let url = url
        let session = session
        let cadence = max(50, min(intervalMs, 5_000))
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let (data, response) = try? await AdapterHTTP.boundedData(
                    from: url, session: session,
                    maximumBytes: AdapterHTTP.maxMetadataBytes),
                    AdapterHTTP.isSuccessful(response)
                {
                    let parsed = PrometheusParser.parse(String(decoding: data, as: UTF8.self))
                    if !parsed.isEmpty {
                        await self?.record(parsed)
                    }
                }
                try? await Task.sleep(for: .milliseconds(cadence))
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

public enum AdapterHTTP {
    public static let maxMetadataBytes = 1_048_576
    public static let maxStreamBytes = 16_777_216
    public static let maxLineBytes = 65_536

    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A loopback URL that redirects to a remote origin would otherwise
        // exfiltrate the prompt despite the CLI's initial host allow-list.
        // Disable both redirects and configured proxies for this local-only
        // adapter rather than attempting to validate after transmission.
        configuration.connectionProxyDictionary = [:]
        return URLSession(
            configuration: configuration,
            delegate: LocalOnlySessionDelegate(),
            delegateQueue: nil)
    }

    public static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// URLSession's convenience `data` API buffers the entire response
    /// before a caller can inspect its length. Consume the async byte stream
    /// instead so a hostile local server cannot exceed the declared cap.
    public static func boundedData(
        from url: URL, session: URLSession, maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw AdapterHTTPError.responseTooLarge }
        let (bytes, response) = try await session.bytes(from: url)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw AdapterHTTPError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(
            response.expectedContentLength > 0
                ? min(Int(response.expectedContentLength), maximumBytes)
                : min(16_384, maximumBytes))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw AdapterHTTPError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

public enum AdapterHTTPError: Error {
    case responseTooLarge
}

final class LocalOnlySessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
