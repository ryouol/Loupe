import Foundation
import LoupeCore
import LoupeTelemetry

private final class HandshakeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DaemonHandshake?, Never>?

    init(_ continuation: CheckedContinuation<DaemonHandshake?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: DaemonHandshake?) {
        let pending = lock.withLock { () -> CheckedContinuation<DaemonHandshake?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

private final class StopContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(_ data: Data?) {
        let pending = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: data)
    }
}

private final class DaemonReceiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSequence: UInt64?
    private var sequenceGaps = 0
    private var receiverDrops = 0
    private var malformed = 0
    private var received = 0
    private var sourceRequested = false
    private var sourceSummary: TelemetryAcquisitionStats?

    func markSourceRequested() {
        lock.withLock { sourceRequested = true }
    }

    func accept(_ sample: SystemSample) -> Bool {
        lock.withLock {
            guard let sequence = sample.acquisitionSequence else {
                malformed = Self.adding(malformed, 1)
                return false
            }
            if let lastSequence, sequence <= lastSequence {
                malformed = Self.adding(malformed, 1)
                return false
            }
            if let lastSequence, sequence - lastSequence > 1 {
                sequenceGaps = Self.adding(
                    sequenceGaps, Int(clamping: sequence - lastSequence - 1))
            } else if lastSequence == nil, sequence > 1 {
                sequenceGaps = Self.adding(sequenceGaps, Int(clamping: sequence - 1))
            }
            self.lastSequence = sequence
            received = Self.adding(received, 1)
            return true
        }
    }

    func record<T>(_ result: AsyncStream<T>.Continuation.YieldResult) {
        let wasLost: Bool
        switch result {
        case .enqueued: wasLost = false
        case .dropped, .terminated: wasLost = true
        @unknown default: wasLost = true
        }
        guard wasLost else { return }
        lock.withLock { receiverDrops = Self.adding(receiverDrops, 1) }
    }

    func recordMalformed() {
        lock.withLock { malformed = Self.adding(malformed, 1) }
    }

    func setSourceSummary(_ summary: TelemetryAcquisitionStats) {
        lock.withLock { sourceSummary = summary }
    }

    func acceptSummaryData(_ data: Data) {
        guard data.count <= 4_096,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == [
                "droppedSamples", "sequenceGapLowerBound", "malformedSamples", "complete",
                "sourceWasActive",
            ],
            let summary = try? JSONDecoder().decode(
                TelemetryAcquisitionStats.self, from: data),
            summary.droppedSamples >= 0, summary.sequenceGapLowerBound >= 0,
            summary.malformedSamples >= 0
        else {
            recordMalformed()
            return
        }
        setSourceSummary(summary)
    }

    func snapshot() -> TelemetryAcquisitionStats {
        lock.withLock {
            let source = sourceSummary
            return TelemetryAcquisitionStats(
                droppedSamples: Self.adding(source?.droppedSamples ?? 0, receiverDrops),
                sequenceGapLowerBound: max(
                    source?.sequenceGapLowerBound ?? 0, sequenceGaps),
                malformedSamples: Self.adding(source?.malformedSamples ?? 0, malformed),
                complete: source?.complete == true,
                sourceWasActive: source?.sourceWasActive == true || received > 0
                    || sourceRequested)
        }
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
    }
}

/// App-exported receiver. @unchecked is safe: its only state is the
/// continuation, which is Sendable, and NSXPC calls deliver on any queue.
final class SampleReceiver: NSObject, LoupeSampleReceiverXPCProtocol, @unchecked Sendable {
    static let maxPayloadBytes = 65_536

    private let continuation: AsyncStream<SystemSample>.Continuation
    private let counter: DaemonReceiveCounter

    fileprivate init(
        continuation: AsyncStream<SystemSample>.Continuation,
        counter: DaemonReceiveCounter
    ) {
        self.continuation = continuation
        self.counter = counter
    }

    func deliver(sampleData: Data) {
        if sampleData.count <= Self.maxPayloadBytes,
            let sample = SystemSampleWireDecoder.decode(sampleData)
        {
            if counter.accept(sample) {
                counter.record(continuation.yield(sample))
            }
        } else {
            counter.recordMalformed()
        }
    }

    func deliver(summaryData: Data) {
        counter.acceptSummaryData(summaryData)
    }
}

/// Client half of the XPC boundary; NSXPCConnection is documented
/// thread-safe, hence @unchecked.
public final class DaemonXPCClient: @unchecked Sendable {
    public enum Endpoint {
        case machService(name: String, privileged: Bool)
        case anonymous(NSXPCListenerEndpoint)
    }

    private let connection: NSXPCConnection
    private let counter = DaemonReceiveCounter()

    public init(
        endpoint: Endpoint = .machService(name: LoupeDaemon.machServiceName, privileged: true)
    ) {
        switch endpoint {
        case .machService(let name, let privileged):
            connection = NSXPCConnection(
                machServiceName: name, options: privileged ? .privileged : [])
        case .anonymous(let listenerEndpoint):
            connection = NSXPCConnection(listenerEndpoint: listenerEndpoint)
        }
        connection.remoteObjectInterface = NSXPCInterface(with: LoupeDaemonXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: LoupeSampleReceiverXPCProtocol.self)
    }

    public func handshake() async -> DaemonHandshake? {
        await withCheckedContinuation { continuation in
            let pending = HandshakeContinuation(continuation)
            Task {
                try? await Task.sleep(for: .seconds(3))
                pending.resume(returning: nil)
            }
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    pending.resume(returning: nil)
                }) as? LoupeDaemonXPCProtocol
            else {
                pending.resume(returning: nil)
                return
            }
            proxy.handshake(clientProtocolVersion: EventProtocol.version) { data in
                guard data.count <= 4_096,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    Set(object.keys) == ["daemonVersion", "protocolVersion", "pid"],
                    let handshake = try? JSONDecoder().decode(DaemonHandshake.self, from: data),
                    handshake.protocolVersion == EventProtocol.version,
                    handshake.pid > 0,
                    !handshake.daemonVersion.isEmpty,
                    handshake.daemonVersion.utf8.count <= 128
                else {
                    pending.resume(returning: nil)
                    return
                }
                pending.resume(returning: handshake)
            }
        }
    }

    /// Call before `handshake()`/`startStream()`. Connection lifetime is
    /// deliberately not tied to the returned stream (callers may handshake
    /// without consuming samples); end it via `stopAndInvalidate()`.
    public func activate(bufferLimit: Int = 256) -> AsyncStream<SystemSample> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SystemSample.self,
            bufferingPolicy: .bufferingNewest(max(1, min(bufferLimit, 4_096))))
        connection.exportedObject = SampleReceiver(
            continuation: continuation, counter: counter)
        connection.interruptionHandler = { continuation.finish() }
        connection.invalidationHandler = { continuation.finish() }
        connection.resume()
        return stream
    }

    public func startStream(intervalMs: Int = Sampling.defaultIntervalMs) {
        counter.markSourceRequested()
        (connection.remoteObjectProxy as? LoupeDaemonXPCProtocol)?
            .startSampleStream(intervalMs: intervalMs)
    }

    public func stopAndInvalidate() {
        Task { [self] in
            await requestStop()
            invalidate()
        }
    }

    public func requestStop() async {
        let summaryData: Data? = await withCheckedContinuation { continuation in
            let pending = StopContinuation(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                pending.resume(nil)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                pending.resume(nil)
            }
            guard let daemon = proxy as? LoupeDaemonXPCProtocol else {
                pending.resume(nil)
                return
            }
            daemon.stopSampleStream { data in pending.resume(data) }
        }
        if let summaryData, !summaryData.isEmpty {
            counter.acceptSummaryData(summaryData)
        }
    }

    public func invalidate() {
        connection.invalidate()
    }

    public func acquisitionStats() -> TelemetryAcquisitionStats {
        counter.snapshot()
    }
}
