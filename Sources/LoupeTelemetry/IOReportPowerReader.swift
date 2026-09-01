import Darwin
import Foundation
import LoupeCore

/// GPU busy% and GPU/ANE/package power via IOReport — the private framework
/// powermetrics uses. Symbols are resolved at runtime and every failure path
/// returns nil readings; on machines or contexts where channels are missing
/// the samples simply carry nil GPU fields and the UI hides those charts.
///
/// Private API is acceptable here: Loupe is a developer tool distributed
/// outside the App Store, and this is the only sudo-less source for these
/// counters (the daemon provides the privileged context when installed).
public final class IOReportPowerReader: PowerChannelReading {
    private typealias CopyChannelsInGroup =
        @convention(c) (
            CFString?, CFString?, UInt64, UInt64, UInt64
        ) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels =
        @convention(c) (
            CFMutableDictionary, CFDictionary, CFTypeRef?
        ) -> Void
    private typealias CreateSubscription =
        @convention(c) (
            UnsafeRawPointer?, CFMutableDictionary,
            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
        ) -> UnsafeMutableRawPointer?
    private typealias CreateSamples =
        @convention(c) (
            UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?
        ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta =
        @convention(c) (
            CFDictionary, CFDictionary, CFTypeRef?
        ) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copySamples: () -> CFDictionary?
    private let samplesDelta: CreateSamplesDelta
    private let channelName: ChannelGetString
    private let channelGroup: ChannelGetString
    private let unitLabel: ChannelGetString
    private let simpleValue: SimpleGetInteger
    private let stateCount: StateGetCount
    private let stateName: StateGetName
    private let stateResidency: StateGetResidency

    private let selection: IOReportChannelLogic.Selection
    private var previous: (sample: CFDictionary, atNs: UInt64)?
    private let timebase: Timebase

    public init?(timebase: Timebase = .live()) {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: type)
        }

        guard
            let copyChannels = symbol(
                "IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
            let merge = symbol("IOReportMergeChannels", as: MergeChannels.self),
            let createSubscription = symbol(
                "IOReportCreateSubscription", as: CreateSubscription.self),
            let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
            let createDelta = symbol("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
            let getName = symbol("IOReportChannelGetChannelName", as: ChannelGetString.self),
            let getGroup = symbol("IOReportChannelGetGroup", as: ChannelGetString.self),
            let getUnit = symbol("IOReportChannelGetUnitLabel", as: ChannelGetString.self),
            let getSimple = symbol("IOReportSimpleGetIntegerValue", as: SimpleGetInteger.self),
            let getStateCount = symbol("IOReportStateGetCount", as: StateGetCount.self),
            let getStateName = symbol("IOReportStateGetNameForIndex", as: StateGetName.self),
            let getResidency = symbol("IOReportStateGetResidency", as: StateGetResidency.self)
        else { return nil }

        guard
            let energyChannels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?
                .takeRetainedValue()
        else { return nil }
        if let gpuStats = copyChannels("GPU Stats" as CFString, nil, 0, 0, 0)?
            .takeRetainedValue()
        {
            merge(energyChannels, gpuStats, nil)
        }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, energyChannels, &subscribed, 0, nil),
            let subscribedChannels = subscribed?.takeRetainedValue()
        else { return nil }

        self.samplesDelta = createDelta
        self.channelName = getName
        self.channelGroup = getGroup
        self.unitLabel = getUnit
        self.simpleValue = getSimple
        self.stateCount = getStateCount
        self.stateName = getStateName
        self.stateResidency = getResidency
        self.timebase = timebase
        self.copySamples = {
            createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        }

        // Resolve semantic slots by name, never by index; missing names stay
        // nil and their fields degrade.
        guard let discovery = self.copySamples() else { return nil }
        var energyNames: [String] = []
        var gpuStatNames: [String] = []
        Self.forEachChannel(in: discovery) { item in
            guard let name = getName(item)?.takeUnretainedValue() as String? else { return }
            let group = getGroup(item)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" { energyNames.append(name) }
            if group == "GPU Stats" { gpuStatNames.append(name) }
        }
        self.selection = IOReportChannelLogic.resolve(
            energyChannels: energyNames, gpuStatsChannels: gpuStatNames)
        if selection == IOReportChannelLogic.Selection() { return nil }
    }

    public func sample() -> PowerReading {
        guard let current = copySamples() else { return PowerReading() }
        let now = timebase.nowNanoseconds()
        defer { previous = (current, now) }
        guard let previous,
            let delta = samplesDelta(previous.sample, current, nil)?.takeRetainedValue()
        else { return PowerReading() }

        let intervalNs = now &- previous.atNs
        var reading = PowerReading()
        var packageMilliwatts = 0.0
        var sawEnergy = false

        Self.forEachChannel(in: delta) { item in
            guard let name = channelName(item)?.takeUnretainedValue() as String? else { return }

            if name == selection.gpuPerformanceStates {
                let count = stateCount(item)
                guard count > 0 else { return }
                let states = (0..<count).map { index in
                    (
                        name: (stateName(item, index)?.takeUnretainedValue() as String?) ?? "",
                        residency: stateResidency(item, index)
                    )
                }
                reading.gpuBusyPercent = IOReportChannelLogic.busyPercent(states: states)
                return
            }

            let isEnergySlot =
                name == selection.gpuEnergy || name == selection.aneEnergy
                || name == selection.cpuEnergy
            guard isEnergySlot,
                let unit = unitLabel(item)?.takeUnretainedValue() as String?,
                let millijoules = IOReportChannelLogic.millijoules(
                    simpleValue(item, 0), unitLabel: unit),
                let milliwatts = IOReportChannelLogic.milliwatts(
                    energyMillijoules: millijoules, intervalNs: intervalNs)
            else { return }

            sawEnergy = true
            packageMilliwatts += milliwatts
            if name == selection.gpuEnergy { reading.gpuPowerMilliwatts = milliwatts }
            if name == selection.aneEnergy { reading.anePowerMilliwatts = milliwatts }
        }

        // Package here means CPU+GPU+ANE — the sum of the energy channels we
        // resolve — which is what powermetrics reports as combined power.
        if sawEnergy { reading.packagePowerMilliwatts = packageMilliwatts }
        return reading
    }

    private static func forEachChannel(
        in samples: CFDictionary, _ body: (CFDictionary) -> Void
    ) {
        let key = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let raw = CFDictionaryGetValue(samples, key) else { return }
        let array = unsafeBitCast(raw, to: CFArray.self)
        for index in 0..<CFArrayGetCount(array) {
            guard let itemRaw = CFArrayGetValueAtIndex(array, index) else { continue }
            body(unsafeBitCast(itemRaw, to: CFDictionary.self))
        }
    }
}
