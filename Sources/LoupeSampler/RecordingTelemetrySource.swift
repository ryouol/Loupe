import Foundation
import LoupeCore
import LoupeTelemetry

private final class RecordingTelemetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var outputDrops = 0
    private var outputComplete = false
    private var local: TelemetryAcquisitionStats?
    private var helper: TelemetryAcquisitionStats?

    func record<T>(_ result: AsyncStream<T>.Continuation.YieldResult) {
        if case .dropped = result {
            lock.withLock { if outputDrops < Int.max { outputDrops += 1 } }
        }
    }

    func setLocal(_ value: TelemetryAcquisitionStats) {
        lock.withLock { local = value }
    }

    func setHelper(_ value: TelemetryAcquisitionStats) {
        lock.withLock { helper = value }
    }

    func markComplete() {
        lock.withLock { outputComplete = true }
    }

    func snapshot() -> TelemetryAcquisitionStats {
        lock.withLock {
            let localStats = local ?? .unknown
            let helperStats = helper ?? .unknown
            let helperContributed = helperStats.sourceWasActive
            let knownLosses = Self.adding(
                Self.adding(localStats.lowerBound, helperContributed ? helperStats.lowerBound : 0),
                outputDrops)
            return TelemetryAcquisitionStats(
                droppedSamples: knownLosses,
                malformedSamples: 0,
                complete: outputComplete && localStats.complete
                    && (!helperContributed || helperStats.complete),
                sourceWasActive: true)
        }
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
    }
}

/// Latest privileged power fields, isolated from the local sampling loop.
private actor PrivilegedPowerCache {
    private var sample: SystemWideSample?

    func update(_ value: SystemWideSample) {
        sample = value
    }

    func latest() -> SystemWideSample? { sample }
}

/// Recording telemetry that is useful with or without the optional helper.
///
/// Local sampling owns timestamps, process CPU/RSS, memory, swap, and thermal
/// state. A signed helper connection is attempted concurrently and, when it
/// succeeds, contributes only its latest GPU/power fields. Keeping the local
/// timestamp as the row clock preserves the `SystemSample` alignment
/// invariant instead of pretending two independently sampled rows happened
/// at exactly the same instant.
public actor RecordingTelemetrySource: TelemetrySource {
    private let targetPID: Int32?
    private let intervalMs: Int
    private let counter = RecordingTelemetryCounter()

    public init(
        targetPID: Int32?, intervalMs: Int = Sampling.defaultIntervalMs
    ) {
        self.targetPID = targetPID
        self.intervalMs = max(
            Sampling.minIntervalMs, min(intervalMs, Sampling.maxIntervalMs))
    }

    public func stream() -> AsyncStream<SystemSample> {
        let pid = targetPID
        let interval = intervalMs
        let counter = counter
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                let powerCache = PrivilegedPowerCache()
                let daemon = DaemonXPCClient()
                let privilegedStream = daemon.activate()
                let privilegedTask = Task {
                    guard let handshake = await daemon.handshake(),
                        handshake.protocolVersion == EventProtocol.version,
                        !Task.isCancelled
                    else {
                        daemon.stopAndInvalidate()
                        return
                    }
                    daemon.startStream(intervalMs: interval)
                    for await sample in privilegedStream {
                        // Preserve a row already accepted from XPC; the next
                        // iterator step observes cancellation.
                        await powerCache.update(sample.system)
                    }
                    await daemon.requestStop()
                    counter.setHelper(daemon.acquisitionStats())
                    daemon.invalidate()
                }

                let local = LiveTelemetrySource(
                    targetPID: pid,
                    cadence: Sampling.clampedCadence(intervalMs: interval),
                    makePowerReader: { IOReportPowerReader() })
                for await sample in await local.stream() {
                    let privileged = await powerCache.latest()
                    counter.record(
                        continuation.yield(
                            Self.merging(
                                local: sample, privileged: privileged,
                                maximumSkewNs: UInt64(interval) * 3_000_000)))
                }

                privilegedTask.cancel()
                await privilegedTask.value
                counter.setLocal(await local.acquisitionStats())
                counter.markComplete()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func acquisitionStats() -> TelemetryAcquisitionStats {
        counter.snapshot()
    }

    static func merging(
        local: SystemSample, privileged: SystemWideSample?,
        maximumSkewNs: UInt64 = 5_000_000_000
    ) -> SystemSample {
        guard let privileged else { return local }
        let system = local.system
        let skew = max(system.ts, privileged.ts) - min(system.ts, privileged.ts)
        guard skew <= maximumSkewNs else { return local }
        return SystemSample(
            acquisitionSequence: local.acquisitionSequence,
            system: SystemWideSample(
                ts: system.ts,
                thermalState: system.thermalState,
                memoryUsedBytes: system.memoryUsedBytes,
                memoryFreeBytes: system.memoryFreeBytes,
                swapUsedBytes: system.swapUsedBytes,
                gpuBusyPercent: privileged.gpuBusyPercent ?? system.gpuBusyPercent,
                gpuPowerMilliwatts: privileged.gpuPowerMilliwatts
                    ?? system.gpuPowerMilliwatts,
                anePowerMilliwatts: privileged.anePowerMilliwatts
                    ?? system.anePowerMilliwatts,
                packagePowerMilliwatts: privileged.packagePowerMilliwatts
                    ?? system.packagePowerMilliwatts),
            process: local.process)
    }
}
