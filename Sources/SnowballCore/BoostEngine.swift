import CoreAudio
import Foundation
import BoostDSP
#if canImport(AppKit)
import AppKit
#endif

public enum EngineState: Equatable, Sendable {
    case noDriver
    case noSnowball
    case idle      // driver + Snowball present, nobody has Boosted open
    case running
    case error(String)
}

enum EngineError: Error {
    case dspCreateFailed
}

/// Owns the private aggregate device (Snowball + hidden Feed, drift-compensated), the single
/// IOProc that runs gain + limiter, and the reconcile loop that keeps all of that in sync with
/// device presence and consumer state.
///
/// Simplification vs. docs/PLAN.md: rather than a fine-grained listener per property (Snowball
/// DeviceIsAlive, NominalSampleRate; Boosted DeviceIsRunningSomewhere; ...), this uses one
/// listener on the system device list (covers hot-plug/unplug and most coreaudiod restarts) plus
/// a 1 Hz poll as a robust fallback that also catches consumer start/stop and rate changes.
/// Given the "do not over-engineer" / "keep it small" project rules, a 1 Hz worst-case reconcile
/// latency was judged an acceptable trade for a much smaller amount of listener bookkeeping code.
public final class BoostEngine: @unchecked Sendable {
    public static let targetSampleRate: Double = 48000

    private let queue = DispatchQueue(label: "com.snowballboost.engine")
    private var _state: EngineState = .noDriver
    public var onStateChange: (@Sendable (EngineState) -> Void)?
    public let meters = Meters()

    private var aggregateID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?

    private var reconcileWorkItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var settingsObserver: DarwinNotificationObserver?
    private var started = false

    public init() {}

    public var state: EngineState {
        queue.sync { _state }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installListeners()
            self.reconcile()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.started = false
        }
    }

    // MARK: - Listeners

    private func installListeners() {
        var devicesAddress = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue) { [weak self] _, _ in
            self?.reconcileDebounced()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        pollTimer = timer

        let mTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.snowballboost.meters"))
        mTimer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        mTimer.setEventHandler { [weak self] in self?.publishMeters() }
        mTimer.resume()
        meterTimer = mTimer

        settingsObserver = DarwinNotificationObserver(name: Settings.darwinNotifyName) { [weak self] in
            guard let self else { return }
            self.queue.async { [self] in self.applyGain() }
        }

        #if canImport(AppKit)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.reconcileDebounced()
        }
        #endif
    }

    private func reconcileDebounced() {
        dispatchPrecondition(condition: .onQueue(queue))
        reconcileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    // MARK: - Reconcile

    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            guard let snowball = try DeviceLocator.findSnowball() else {
                teardown()
                setState(.noSnowball)
                return
            }
            guard let feed = DeviceLocator.feedDeviceID(), let boosted = DeviceLocator.boostedDeviceID() else {
                teardown()
                setState(.noDriver)
                return
            }

            let runningSomewhere: UInt32 = (try? CA.get(boosted, CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere))) ?? 0
            guard runningSomewhere != 0 else {
                teardown()
                setState(.idle)
                return
            }

            guard aggregateID == nil else {
                setState(.running) // already built and running; nothing to do
                return
            }

            try buildAggregateAndStart(snowball: snowball, feed: feed)
            setState(.running)
        } catch {
            teardown()
            setState(.error("\(error)"))
        }
    }

    private func buildAggregateAndStart(snowball: SnowballDevice, feed: AudioObjectID) throws {
        // V1 simplification: always target 48 kHz rather than negotiating whatever rate Boosted's
        // client requested. The Snowball supports 48 kHz natively (measured fact in docs/PLAN.md)
        // and the driver still advertises 44.1 kHz as available, satisfying "44.1 kHz too if
        // straightforward" without dynamic rate-matching logic on the app side.
        _ = try? CA.set(snowball.deviceID, CA.address(kAudioDevicePropertyNominalSampleRate), Self.targetSampleRate)

        let feedUID = try CA.getString(feed, CA.address(kAudioDevicePropertyDeviceUID))
        let subSnowball: [String: Any] = [kAudioSubDeviceUIDKey: snowball.uid]
        let subFeed: [String: Any] = [kAudioSubDeviceUIDKey: feedUID, kAudioSubDeviceDriftCompensationKey: 1]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Snowball Boost Aggregate",
            kAudioAggregateDeviceUIDKey: "com.snowballboost.aggregate",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: snowball.uid,
            kAudioAggregateDeviceSubDeviceListKey: [subSnowball, subFeed],
        ]

        var newAggregateID: AudioObjectID = 0
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard createStatus == noErr else {
            throw CoreAudioError(status: createStatus, context: "AudioHardwareCreateAggregateDevice")
        }
        _ = try? CA.set(newAggregateID, CA.address(kAudioDevicePropertyNominalSampleRate), Self.targetSampleRate)

        guard let dspState = boost_dsp_create(Self.targetSampleRate, -1.0) else {
            _ = AudioHardwareDestroyAggregateDevice(newAggregateID)
            throw EngineError.dspCreateFailed
        }
        boost_dsp_set_gain_db(dspState, Settings.gainDB)

        var newIOProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateID, nil) { [weak self] _, inputData, _, outputData, _ in
            self?.ioCallback(inputData: inputData, outputData: outputData)
        }
        guard procStatus == noErr, let procID = newIOProcID else {
            boost_dsp_destroy(dspState)
            _ = AudioHardwareDestroyAggregateDevice(newAggregateID)
            throw CoreAudioError(status: procStatus, context: "AudioDeviceCreateIOProcIDWithBlock")
        }

        let startStatus = AudioDeviceStart(newAggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, procID)
            boost_dsp_destroy(dspState)
            _ = AudioHardwareDestroyAggregateDevice(newAggregateID)
            throw CoreAudioError(status: startStatus, context: "AudioDeviceStart")
        }

        aggregateID = newAggregateID
        ioProcID = procID
        dsp = dspState
    }

    // Realtime: called on Core Audio's IO thread. No allocation, no locks — boost_dsp_process is
    // RT-safe by construction (see Sources/BoostDSP).
    private func ioCallback(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>) {
        guard let dsp else { return }
        let inBuffer = inputData.pointee.mBuffers
        let outBuffer = outputData.pointee.mBuffers
        guard let inRaw = inBuffer.mData, let outRaw = outBuffer.mData else { return }

        let inFrames = Int(inBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let outFrames = Int(outBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = min(inFrames, outFrames)
        guard frameCount > 0 else { return }

        let inFloats = inRaw.assumingMemoryBound(to: Float.self)
        let outFloats = outRaw.assumingMemoryBound(to: Float.self)
        boost_dsp_process(dsp, inFloats, outFloats, frameCount)
    }

    private func applyGain() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let dsp else { return }
        boost_dsp_set_gain_db(dsp, Settings.gainDB)
    }

    private func publishMeters() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let dsp = self.dsp else {
                self.meters.update(.silent)
                return
            }
            let snap = boost_dsp_get_meters(dsp)
            boost_dsp_reset_meters(dsp)
            self.meters.update(MetersSnapshot(
                inputPeakDB: dbfs(snap.inputPeak),
                inputRMSDB: dbfs(snap.inputRMS),
                outputPeakDB: dbfs(snap.outputPeak),
                outputRMSDB: dbfs(snap.outputRMS),
                gainReductionDB: snap.maxGainReductionDB,
                limiterActive: snap.maxGainReductionDB > 0.05
            ))
        }
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let aggID = aggregateID, let procID = ioProcID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if let aggID = aggregateID {
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if let dsp {
            boost_dsp_destroy(dsp)
        }
        aggregateID = nil
        ioProcID = nil
        dsp = nil
    }

    private func setState(_ newState: EngineState) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard newState != _state else { return }
        _state = newState
        if let onStateChange {
            DispatchQueue.main.async { onStateChange(newState) }
        }
    }
}
