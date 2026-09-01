import Darwin
import Foundation
import LoupeCore
import LoupeSampler
import LoupeTelemetry

private enum SessionRecordingLimits {
    static let maxDisplayNameCharacters = 120
    static let maxDisplayNameBytes = 512
    static let maxEvents = 100_000
    static let maxEventBytes = 64 * 1_024 * 1_024
    static let maxSamples = 100_000
    static let maxTransitions = 256
    static let maxTransitionDetailBytes = 4_096
}

public enum SessionLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case preparing
    case waitingForAdapter
    case recording
    case reconnecting
    case adapterDisconnected
    case degraded
    case denied
    case stopped
    case failed
    case interrupted

    public var isTerminal: Bool {
        self == .stopped || self == .failed || self == .interrupted
    }
}

public struct SessionTransition: Codable, Sendable, Equatable {
    public let state: SessionLifecycleState
    public let atNs: UInt64
    public let detail: String

    public init(state: SessionLifecycleState, atNs: UInt64, detail: String) {
        self.state = state
        self.atNs = atNs
        self.detail = detail
    }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let storageID: UUID
    public let runID: String
    public let displayName: String
    public let createdAt: Date
    public let state: SessionLifecycleState
    public let statusDetail: String
    public let eventCount: Int
    public let sampleCount: Int
    public let transitions: [SessionTransition]
    public let basePath: String

    public var id: UUID { storageID }
    public var filePair: SessionFilePair { SessionFilePair(basePath: basePath) }
    public var isReplayAvailable: Bool {
        FileManager.default.isReadableFile(atPath: filePair.eventsURL.path)
            && FileManager.default.isReadableFile(atPath: filePair.systemURL.path)
    }
}

public struct LoupeStoragePaths: Sendable, Equatable {
    public let rootDirectory: URL
    public let runtimeDirectory: URL
    public let sessionsDirectory: URL

    public init(applicationSupportDirectory: URL) {
        rootDirectory = applicationSupportDirectory.appendingPathComponent(
            "Loupe", isDirectory: true)
        runtimeDirectory = rootDirectory.appendingPathComponent(
            LoupeUserRuntime.directoryName, isDirectory: true)
        sessionsDirectory = rootDirectory.appendingPathComponent(
            LoupeUserRuntime.sessionsDirectoryName, isDirectory: true)
    }

    public static func userDefault() throws -> LoupeStoragePaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return LoupeStoragePaths(applicationSupportDirectory: support)
    }

    public var adapterSocketURL: URL {
        runtimeDirectory.appendingPathComponent(LoupeUserRuntime.adapterSocketName)
    }

    public func prepare() throws {
        for directory in [rootDirectory, runtimeDirectory, sessionsDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFDIR,
                metadata.st_uid == geteuid()
            else { throw SessionRecordingError.unsafeStorage(directory.path) }
            guard chmod(directory.path, S_IRWXU) == 0 else {
                throw SessionRecordingError.unsafeStorage(directory.path)
            }
            guard lstat(directory.path, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFDIR,
                metadata.st_uid == geteuid(),
                metadata.st_mode & 0o077 == 0
            else { throw SessionRecordingError.unsafeStorage(directory.path) }
        }
    }
}

public enum SessionRecordingError: LocalizedError, Sendable, Equatable {
    case alreadyRecording
    case noActiveRecording
    case unsafeStorage(String)
    case runtimeProtocol(String)
    case invalidSessionIdentifier

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already active."
        case .noActiveRecording: return "There is no active recording to stop."
        case .unsafeStorage:
            return "Loupe refused local storage that is not owner-controlled."
        case .runtimeProtocol(let detail):
            return "The adapter protocol was rejected: \(detail)"
        case .invalidSessionIdentifier:
            return "The selected session does not belong to Loupe's session library."
        }
    }
}

private struct SessionManifest: Codable, Sendable {
    let schemaVersion: Int
    let storageID: UUID
    let runID: String
    let displayName: String
    let createdAt: Date
    var eventCount: Int
    var sampleCount: Int
    var transitions: [SessionTransition]
    let basePath: String

    var latest: SessionTransition {
        transitions.last
            ?? SessionTransition(state: .failed, atNs: 0, detail: "Missing lifecycle state")
    }

    func summary(recoverInterruptedSession: Bool = false) -> SessionSummary {
        let recovered = recoverInterruptedSession && !latest.state.isTerminal
        return SessionSummary(
            storageID: storageID,
            runID: runID,
            displayName: displayName,
            createdAt: createdAt,
            state: recovered ? .interrupted : latest.state,
            statusDetail: recovered
                ? "The app closed before this recording stopped. Durable rows were retained."
                : latest.detail,
            eventCount: eventCount,
            sampleCount: sampleCount,
            transitions: transitions,
            basePath: basePath)
    }
}

public actor SessionLibrary {
    private let paths: LoupeStoragePaths

    public init(paths: LoupeStoragePaths) {
        self.paths = paths
    }

    public func sessions() throws -> [SessionSummary] {
        try paths.prepare()
        let urls = try FileManager.default.contentsOfDirectory(
            at: paths.sessionsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])
        return
            urls
            .filter { $0.lastPathComponent.hasSuffix(".session.json") }
            .prefix(10_000)
            .compactMap { url in
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0,
                    metadata.st_mode & S_IFMT == S_IFREG,
                    metadata.st_uid == geteuid(),
                    metadata.st_nlink == 1,
                    metadata.st_mode & 0o077 == 0
                else { return nil }
                // Open the manifest through the same bounded, no-follow
                // snapshot reader as replay files. The earlier lstat proves
                // owner/mode/link policy; O_NOFOLLOW closes the substitution
                // window before bytes are parsed.
                guard
                    let data = try? ReplayResourceLimits.read(
                        url, maximumBytes: 1_048_576),
                    let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    Set(object.keys) == [
                        "schemaVersion", "storageID", "runID", "displayName", "createdAt",
                        "eventCount", "sampleCount", "transitions", "basePath",
                    ],
                    let transitions = object["transitions"] as? [[String: Any]],
                    transitions.allSatisfy({
                        Set($0.keys) == ["state", "atNs", "detail"]
                    }),
                    let manifest = try? JSONDecoder().decode(SessionManifest.self, from: data)
                else { return nil }
                let expectedName = manifest.storageID.uuidString.lowercased() + ".session.json"
                let expectedBase = paths.sessionsDirectory
                    .appendingPathComponent(manifest.storageID.uuidString.lowercased()).path
                guard url.lastPathComponent == expectedName,
                    manifest.schemaVersion == 1,
                    manifest.basePath == expectedBase,
                    !manifest.runID.isEmpty,
                    manifest.runID.utf8.count <= 128,
                    !manifest.displayName.isEmpty,
                    manifest.displayName.count
                        <= SessionRecordingLimits.maxDisplayNameCharacters,
                    manifest.displayName.utf8.count <= SessionRecordingLimits.maxDisplayNameBytes,
                    (0...SessionRecordingLimits.maxEvents).contains(manifest.eventCount),
                    (0...SessionRecordingLimits.maxSamples).contains(manifest.sampleCount),
                    !manifest.transitions.isEmpty,
                    manifest.transitions.count <= SessionRecordingLimits.maxTransitions,
                    manifest.transitions.allSatisfy({
                        !$0.detail.isEmpty
                            && $0.detail.utf8.count
                                <= SessionRecordingLimits.maxTransitionDetailBytes
                    }),
                    zip(manifest.transitions, manifest.transitions.dropFirst())
                        .allSatisfy({ pair in pair.0.atNs <= pair.1.atNs })
                else { return nil }
                return manifest.summary(recoverInterruptedSession: true)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ session: SessionSummary) throws {
        try paths.prepare()
        let stem = session.storageID.uuidString.lowercased()
        let expectedBase = paths.sessionsDirectory.appendingPathComponent(stem).path
        guard session.basePath == expectedBase else {
            throw SessionRecordingError.invalidSessionIdentifier
        }
        let pathsToDelete = [
            expectedBase + ".sqlite",
            expectedBase + ".sqlite-wal",
            expectedBase + ".sqlite-shm",
            expectedBase + ".session.json",
            expectedBase + SessionFilePair.eventsSuffix,
            expectedBase + SessionFilePair.systemSuffix,
        ]
        var validatedPaths: [String] = []
        for path in pathsToDelete {
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                throw SessionRecordingError.unsafeStorage(path)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_uid == geteuid(), metadata.st_nlink == 1
            else { throw SessionRecordingError.unsafeStorage(path) }
            validatedPaths.append(path)
        }
        // Validate the entire deletion set before removing its first member;
        // one substituted sidecar must not leave a half-deleted session.
        for path in validatedPaths {
            guard unlink(path) == 0 else {
                throw SessionRecordingError.unsafeStorage(path)
            }
        }
    }
}

private struct RuntimeEventState: Sendable {
    var didStart = false
    var activeRequests: Set<String> = []
    var prefilledRequests: Set<String> = []
    var seenRequestIDs: Set<String> = []
    var lastOutputTokens: [String: UInt32] = [:]
    var lastTimestamp: UInt64?

    mutating func resetRuntimeSequenceForReconnect() {
        // A new adapter connection must prove a fresh session_start, but its
        // clock cannot move behind evidence already accepted for this Loupe
        // session. Keep the global watermark while clearing request state.
        didStart = false
        activeRequests.removeAll(keepingCapacity: true)
        prefilledRequests.removeAll(keepingCapacity: true)
        lastOutputTokens.removeAll(keepingCapacity: true)
    }

    mutating func accept(
        _ envelope: EventEnvelope, expectedRunID: String, requiredUID: uid_t
    ) -> Result<Int32?, SessionRecordingError> {
        guard envelope.runId == expectedRunID else {
            return .failure(.runtimeProtocol("Unexpected run id"))
        }
        guard lastTimestamp.map({ envelope.ts >= $0 }) ?? true else {
            return .failure(.runtimeProtocol("Event timestamps must be monotonic"))
        }

        var targetPID: Int32?
        switch envelope.payload {
        case .sessionStart(let payload):
            guard !didStart else {
                return .failure(.runtimeProtocol("Duplicate session_start"))
            }
            guard processOwner(pid: payload.pid) == requiredUID else {
                return .failure(.runtimeProtocol("Claimed pid is not owned by this user"))
            }
            didStart = true
            targetPID = payload.pid
        case .clockSync, .modelLoadStart, .modelLoadEnd, .error:
            guard didStart else {
                return .failure(.runtimeProtocol("session_start must be first"))
            }
        case .requestStart:
            guard didStart, let requestID = envelope.requestId,
                activeRequests.count < 1_024,
                !seenRequestIDs.contains(requestID),
                activeRequests.insert(requestID).inserted
            else { return .failure(.runtimeProtocol("Invalid request_start sequence")) }
            seenRequestIDs.insert(requestID)
            lastOutputTokens[requestID] = 0
        case .prefillEnd:
            guard let requestID = envelope.requestId, activeRequests.contains(requestID),
                prefilledRequests.insert(requestID).inserted
            else {
                return .failure(.runtimeProtocol("Invalid prefill_end sequence"))
            }
        case .decodeTick(let payload):
            guard let requestID = envelope.requestId, activeRequests.contains(requestID),
                prefilledRequests.contains(requestID),
                payload.outputTokens >= (lastOutputTokens[requestID] ?? 0)
            else { return .failure(.runtimeProtocol("Non-monotonic decode_tick")) }
            lastOutputTokens[requestID] = payload.outputTokens
        case .requestEnd(let payload):
            guard let requestID = envelope.requestId, activeRequests.contains(requestID),
                payload.outputTokens >= (lastOutputTokens[requestID] ?? 0)
            else { return .failure(.runtimeProtocol("request_end has no active request")) }
            activeRequests.remove(requestID)
            prefilledRequests.remove(requestID)
            lastOutputTokens.removeValue(forKey: requestID)
        }
        lastTimestamp = envelope.ts
        return .success(targetPID)
    }
}

private func processOwner(pid: Int32) -> uid_t? {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
    }
    guard actualSize == expectedSize else { return nil }
    return info.pbi_uid
}

public actor SessionRecorder {
    public typealias TelemetryFactory = @Sendable (Int32?) -> any TelemetrySource

    private let paths: LoupeStoragePaths
    private let host: HostFingerprint
    private let timebase: Timebase
    private let makeTelemetry: TelemetryFactory
    private let requiredUID: uid_t
    private let updatesValue: AsyncStream<SessionSummary>
    private let updatesContinuation: AsyncStream<SessionSummary>.Continuation

    private var manifest: SessionManifest?
    private var store: SessionStore?
    private var socketServer: EventSocketServer?
    private var protocolState = RuntimeEventState()
    private var eventTask: Task<Void, Never>?
    private var socketStatusTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var isStopping = false
    private var recordedEventBytes = 0

    public init(
        paths: LoupeStoragePaths,
        host: HostFingerprint,
        timebase: Timebase = .live(),
        requiredUID: uid_t = geteuid(),
        makeTelemetry: @escaping TelemetryFactory = { pid in
            RecordingTelemetrySource(targetPID: pid)
        }
    ) {
        self.paths = paths
        self.host = host
        self.timebase = timebase
        self.requiredUID = requiredUID
        self.makeTelemetry = makeTelemetry
        let (stream, continuation) = AsyncStream.makeStream(
            of: SessionSummary.self, bufferingPolicy: .bufferingNewest(128))
        self.updatesValue = stream
        self.updatesContinuation = continuation
    }

    public func updates() -> AsyncStream<SessionSummary> { updatesValue }

    public func currentSession() -> SessionSummary? { manifest?.summary() }

    @discardableResult
    public func start(displayName: String? = nil) async throws -> SessionSummary {
        guard manifest == nil else { throw SessionRecordingError.alreadyRecording }
        try paths.prepare()

        let storageID = UUID()
        let runID =
            "r-\(storageID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
        let name = displayName.map {
            Self.utf8Prefix($0, maximumBytes: SessionRecordingLimits.maxDisplayNameBytes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let resolvedName = String(
            ((name?.isEmpty == false ? name : nil) ?? "Local inference session")
                .prefix(SessionRecordingLimits.maxDisplayNameCharacters))
        let basePath = paths.sessionsDirectory
            .appendingPathComponent(storageID.uuidString.lowercased()).path
        let initial = SessionTransition(
            state: .preparing, atNs: timebase.nowNanoseconds(),
            detail: "Preparing owner-only local storage")
        manifest = SessionManifest(
            schemaVersion: 1,
            storageID: storageID,
            runID: runID,
            displayName: resolvedName,
            createdAt: Date(),
            eventCount: 0,
            sampleCount: 0,
            transitions: [initial],
            basePath: basePath)
        protocolState = RuntimeEventState()
        isStopping = false
        recordedEventBytes = 0

        do {
            let sessionStore = try SessionStore(
                storageID: storageID, runId: runID,
                directory: paths.sessionsDirectory,
                startedAtNs: initial.atNs, host: host)
            let server = EventSocketServer(
                socketPath: paths.adapterSocketURL.path, requiredUID: requiredUID,
                maxConnections: 1)
            let statuses = await server.statusEvents()
            let events = try await server.start()
            store = sessionStore
            socketServer = server
            try persistManifest()
            emitCurrent()

            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.consume(event, sessionID: storageID)
                }
            }
            socketStatusTask = Task { [weak self] in
                for await status in statuses {
                    guard !Task.isCancelled else { break }
                    await self?.consume(status, sessionID: storageID)
                }
            }
            await restartTelemetry(targetPID: nil, sessionID: storageID)
            try transition(
                to: .waitingForAdapter,
                detail: "Listening for a same-user adapter")
            return manifest?.summary()
                ?? SessionSummary(
                    storageID: storageID, runID: runID, displayName: resolvedName,
                    createdAt: Date(), state: .failed, statusDetail: "State unavailable",
                    eventCount: 0, sampleCount: 0, transitions: [], basePath: basePath)
        } catch {
            try? transition(
                to: .failed,
                detail: "Could not prepare protected local recording storage")
            if let socketServer {
                await socketServer.stop()
            }
            clearActiveResources()
            throw error
        }
    }

    @discardableResult
    public func stop() async throws -> SessionSummary {
        guard let activeManifest = manifest else {
            throw SessionRecordingError.noActiveRecording
        }
        isStopping = true
        if let socketServer {
            await socketServer.stop()
        }
        await eventTask?.value
        socketStatusTask?.cancel()
        await socketStatusTask?.value
        telemetryTask?.cancel()
        await telemetryTask?.value

        let stoppedAt = timebase.nowNanoseconds()
        do {
            try await store?.end(atNs: stoppedAt)
            _ = try await store?.exportReplayPair(to: paths.sessionsDirectory)
            if let counts = try await store?.counts() {
                manifest?.eventCount = counts.events
                manifest?.sampleCount = counts.system
            }
            let stoppedDetail: String
            if manifest?.eventCount == 0, manifest?.sampleCount == 0 {
                stoppedDetail = "Recording stopped before any adapter events or telemetry arrived"
            } else if manifest?.eventCount == 0 {
                stoppedDetail =
                    "Recording stopped without adapter events; system telemetry is ready"
            } else {
                stoppedDetail = "Recording stopped; portable evidence files are ready"
            }
            try transition(
                to: .stopped,
                detail: stoppedDetail)
        } catch {
            try? transition(
                to: .failed,
                detail: "Final evidence export failed; the durable database was retained")
        }

        let final =
            manifest?.summary()
            ?? activeManifest.summary()
        clearActiveResources(keepingManifest: false)
        return final
    }

    private func consume(_ status: EventSocketStatus, sessionID: UUID) {
        guard manifest?.storageID == sessionID, !isStopping else { return }
        switch status {
        case .listening:
            break
        case .connected:
            if manifest?.latest.state == .adapterDisconnected {
                try? transition(to: .reconnecting, detail: "Adapter reconnected; validating stream")
            }
        case .disconnected:
            try? transition(
                to: .adapterDisconnected,
                detail: "Adapter disconnected; telemetry continues and reconnection is available")
        case .denied(let uid):
            let identity = uid.map(String.init) ?? "unknown"
            try? transition(
                to: .denied,
                detail: "Denied adapter connection from uid \(identity)")
        case .degraded(let detail):
            try? transition(to: .degraded, detail: detail)
        }
    }

    private func consume(_ envelope: EventEnvelope, sessionID: UUID) async {
        // `stop()` first closes the listener, drains EventSocketServer's
        // already-accepted command prefix, and awaits this consumer before
        // exporting. Do not discard that durable prefix merely because a
        // stop was requested; no envelope can reach this task after its
        // stream finishes and the export begins.
        guard manifest?.storageID == sessionID, let store else { return }
        let encodedSize = ((try? EventLineEncoder().encode(envelope).count) ?? Int.max)
            .addingReportingOverflow(1)
        guard !encodedSize.overflow,
            (manifest?.eventCount ?? 0) < SessionRecordingLimits.maxEvents,
            recordedEventBytes <= SessionRecordingLimits.maxEventBytes - encodedSize.partialValue
        else {
            try? transition(
                to: .degraded,
                detail: "Event evidence limit reached; stop and start a new recording")
            return
        }
        let stateBeforeEvent = manifest?.latest.state
        // Socket statuses and envelopes are intentionally separate streams,
        // so a reconnecting adapter's first line can win the scheduling race
        // against `.connected`. Any state that represents a broken/invalid
        // transport may begin a fresh, fully validated runtime sequence.
        if envelope.kind == .sessionStart,
            stateBeforeEvent == .reconnecting
                || stateBeforeEvent == .adapterDisconnected
                || stateBeforeEvent == .degraded
                || stateBeforeEvent == .denied
        {
            protocolState.resetRuntimeSequenceForReconnect()
        }
        switch protocolState.accept(
            envelope, expectedRunID: manifest?.runID ?? "", requiredUID: requiredUID)
        {
        case .failure(let failure):
            // Once the semantic stream is broken, accepting later request
            // events against stale state would create plausible-looking but
            // incomplete evidence. Require a fresh session_start.
            protocolState.resetRuntimeSequenceForReconnect()
            try? transition(
                to: .denied,
                detail: "Dropped runtime event: \(failure.localizedDescription)")
        case .success(let targetPID):
            do {
                try await store.append(events: [envelope])
                recordedEventBytes += encodedSize.partialValue
                manifest?.eventCount += 1
                if let targetPID {
                    await restartTelemetry(targetPID: targetPID, sessionID: sessionID)
                    try transition(
                        to: .recording,
                        detail: "Correlating runtime events with pid \(targetPID) telemetry")
                } else if stateBeforeEvent == .reconnecting
                    || stateBeforeEvent == .adapterDisconnected
                    || stateBeforeEvent == .degraded
                    || stateBeforeEvent == .denied
                {
                    try transition(
                        to: .recording,
                        detail: "Adapter stream resumed; correlation is active")
                } else if envelope.kind == .requestEnd {
                    try persistManifest()
                    emitCurrent()
                }
            } catch {
                protocolState.resetRuntimeSequenceForReconnect()
                try? transition(
                    to: .degraded,
                    detail: "Runtime event persistence failed; stop this recording")
            }
        }
    }

    private func restartTelemetry(targetPID: Int32?, sessionID: UUID) async {
        let previous = telemetryTask
        telemetryTask = nil
        previous?.cancel()
        await previous?.value
        guard manifest?.storageID == sessionID, !isStopping else { return }
        let source = makeTelemetry(targetPID)
        telemetryTask = Task { [weak self] in
            var batch: [SystemSample] = []
            for await sample in await source.stream() {
                guard !Task.isCancelled else { break }
                batch.append(sample)
                if batch.count >= 20 {
                    await self?.persist(samples: batch, sessionID: sessionID)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                await self?.persist(samples: batch, sessionID: sessionID)
            }
        }
    }

    private func persist(samples: [SystemSample], sessionID: UUID) async {
        guard manifest?.storageID == sessionID, let store else { return }
        do {
            let remaining = max(
                0, SessionRecordingLimits.maxSamples - (manifest?.sampleCount ?? 0))
            let accepted = Array(samples.prefix(remaining))
            if !accepted.isEmpty {
                try await store.append(samples: accepted)
                manifest?.sampleCount += accepted.count
            }
            if accepted.count < samples.count {
                try transition(
                    to: .degraded,
                    detail: "Telemetry limit reached; stop and start a new recording")
                telemetryTask?.cancel()
                return
            }
            if (manifest?.sampleCount ?? 0).isMultiple(of: 100) {
                try persistManifest()
                emitCurrent()
            }
        } catch {
            try? transition(
                to: .degraded,
                detail: "Telemetry persistence failed; stop this recording")
        }
    }

    private func transition(to state: SessionLifecycleState, detail: String) throws {
        guard var active = manifest else { return }
        let boundedDetail = Self.utf8Prefix(
            detail, maximumBytes: SessionRecordingLimits.maxTransitionDetailBytes)
        if active.latest.state == state && active.latest.detail == boundedDetail { return }
        if active.transitions.count >= SessionRecordingLimits.maxTransitions {
            active.transitions.remove(at: 1)
        }
        active.transitions.append(
            SessionTransition(
                state: state, atNs: timebase.nowNanoseconds(), detail: boundedDetail))
        manifest = active
        try persistManifest()
        emitCurrent()
    }

    private func persistManifest() throws {
        guard let manifest else { return }
        let url = paths.sessionsDirectory.appendingPathComponent(
            manifest.storageID.uuidString.lowercased() + ".session.json")
        let data = try JSONEncoder.deterministic().encode(manifest)

        // Foundation's atomic writer can briefly create the first manifest
        // with the process umask's mode before a later chmod. Write an
        // exclusive 0600 sibling instead, sync it, then rename it into place
        // so a manifest is never visible with broader permissions.
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG,
                existing.st_uid == requiredUID,
                existing.st_nlink == 1
            else { throw SessionRecordingError.unsafeStorage(url.path) }
        } else if errno != ENOENT {
            throw SessionRecordingError.unsafeStorage(url.path)
        }

        let temporaryURL = paths.sessionsDirectory.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).manifest.tmp")
        var descriptor = open(
            temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SessionRecordingError.unsafeStorage(temporaryURL.path)
        }
        defer {
            if descriptor >= 0 { close(descriptor) }
            unlink(temporaryURL.path)
        }
        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw SessionRecordingError.unsafeStorage(temporaryURL.path)
            }
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        descriptor, base.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw SessionRecordingError.unsafeStorage(temporaryURL.path)
                    }
                }
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else {
                throw SessionRecordingError.unsafeStorage(temporaryURL.path)
            }
            descriptor = -1
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw SessionRecordingError.unsafeStorage(url.path)
            }
        } catch {
            throw error
        }
    }

    private func emitCurrent() {
        if let summary = manifest?.summary() {
            updatesContinuation.yield(summary)
        }
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var bytes = Array(value.utf8.prefix(maximumBytes))
        // At most three removals are needed to back out of a partial UTF-8
        // scalar. Avoid replacement characters that could exceed the bound.
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func clearActiveResources(keepingManifest: Bool = false) {
        eventTask?.cancel()
        socketStatusTask?.cancel()
        telemetryTask?.cancel()
        eventTask = nil
        socketStatusTask = nil
        telemetryTask = nil
        socketServer = nil
        store = nil
        protocolState = RuntimeEventState()
        recordedEventBytes = 0
        isStopping = false
        if !keepingManifest { manifest = nil }
    }
}
