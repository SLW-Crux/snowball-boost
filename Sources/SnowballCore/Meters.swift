import Synchronization

public struct MetersSnapshot: Sendable {
    public var inputPeakDB: Float
    public var inputRMSDB: Float
    public var outputPeakDB: Float
    public var outputRMSDB: Float
    public var gainReductionDB: Float
    public var limiterActive: Bool

    public static let silent = MetersSnapshot(
        inputPeakDB: -120, inputRMSDB: -120,
        outputPeakDB: -120, outputRMSDB: -120,
        gainReductionDB: 0, limiterActive: false
    )
}

/// Lock-free store for the values the menu-bar app and `sbboost status`/`diagnose` poll. Written
/// from the engine's periodic (non-realtime) meter-publish timer; read from the UI/CLI thread.
public final class Meters: Sendable {
    private let inputPeak = Atomic<UInt32>(0)
    private let inputRMS = Atomic<UInt32>(0)
    private let outputPeak = Atomic<UInt32>(0)
    private let outputRMS = Atomic<UInt32>(0)
    private let gainReduction = Atomic<UInt32>(0)
    private let limiterActive = Atomic<Bool>(false)

    public init() {
        update(MetersSnapshot.silent)
    }

    public func update(_ snapshot: MetersSnapshot) {
        inputPeak.store(snapshot.inputPeakDB.bitPattern, ordering: .relaxed)
        inputRMS.store(snapshot.inputRMSDB.bitPattern, ordering: .relaxed)
        outputPeak.store(snapshot.outputPeakDB.bitPattern, ordering: .relaxed)
        outputRMS.store(snapshot.outputRMSDB.bitPattern, ordering: .relaxed)
        gainReduction.store(snapshot.gainReductionDB.bitPattern, ordering: .relaxed)
        limiterActive.store(snapshot.limiterActive, ordering: .relaxed)
    }

    public func snapshot() -> MetersSnapshot {
        MetersSnapshot(
            inputPeakDB: Float(bitPattern: inputPeak.load(ordering: .relaxed)),
            inputRMSDB: Float(bitPattern: inputRMS.load(ordering: .relaxed)),
            outputPeakDB: Float(bitPattern: outputPeak.load(ordering: .relaxed)),
            outputRMSDB: Float(bitPattern: outputRMS.load(ordering: .relaxed)),
            gainReductionDB: Float(bitPattern: gainReduction.load(ordering: .relaxed)),
            limiterActive: limiterActive.load(ordering: .relaxed)
        )
    }
}
