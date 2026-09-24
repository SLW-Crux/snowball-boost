import Testing
import Foundation
import BoostDSP

private let sampleRate: Double = 48_000
private let ceilingDBFS: Float = -1.0
private let ceilingLinear: Float = powf(10.0, ceilingDBFS / 20.0)
private let lookahead = Int((sampleRate * 0.001).rounded()) // matches boost_dsp_create's 1 ms formula

private func makeState(gainDB: Float? = nil) -> OpaquePointer {
    let state = boost_dsp_create(sampleRate, ceilingDBFS)!
    if let gainDB {
        boost_dsp_set_gain_db(state, gainDB)
        // Run the ramp to completion (silence in, so no limiting) before real test signal.
        var zerosIn = [Float](repeating: 0, count: 4096)
        var zerosOut = zerosIn
        boost_dsp_process(state, &zerosIn, &zerosOut, zerosIn.count)
        boost_dsp_reset_meters(state)
    }
    return state
}

private func process(_ state: OpaquePointer, _ input: [Float]) -> [Float] {
    var input = input
    var output = [Float](repeating: 0, count: input.count)
    boost_dsp_process(state, &input, &output, input.count)
    return output
}

private func dbfs(_ linear: Float) -> Float {
    20.0 * log10f(max(linear, 1e-9))
}

@Test func unityGainAtZeroDB() {
    let state = makeState(gainDB: 0)
    defer { boost_dsp_destroy(state) }

    let n = 8000
    var input = [Float](repeating: 0, count: n)
    for i in 0..<n { input[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) }
    let output = process(state, input)

    // No limiting expected (well below ceiling); output should equal input delayed by `lookahead`.
    for i in (lookahead + 200)..<(n - 1) {
        #expect(abs(output[i] - input[i - lookahead]) < 1e-5)
    }
}

@Test func gainStepsAreMathematicallyCorrect() {
    for gainDB: Float in [6, 9, 12, 18] {
        let state = makeState(gainDB: gainDB)
        defer { boost_dsp_destroy(state) }

        let n = 8000
        var input = [Float](repeating: 0, count: n)
        // Small amplitude so even +18 dB stays well under the ceiling: 0.03 * 10^(18/20) ≈ 0.238.
        for i in 0..<n { input[i] = 0.03 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) }
        let output = process(state, input)

        let expectedMult = powf(10.0, gainDB / 20.0)
        #expect(abs(boost_dsp_current_gain_db(state) - gainDB) < 1e-3)

        // Exact per-sample check (no limiting active): output[i] == input[i - lookahead] * mult.
        for i in (lookahead + 200)..<(n - 1) {
            let expected = input[i - lookahead] * expectedMult
            let tolerance = max(1e-5, abs(expected) * 1e-5)
            #expect(abs(output[i] - expected) < tolerance)
        }
    }
}

@Test func silenceStaysSilence() {
    let state = makeState(gainDB: 18)
    defer { boost_dsp_destroy(state) }

    let output = process(state, [Float](repeating: 0, count: 4000))
    for sample in output {
        #expect(sample == 0)
    }
    let meters = boost_dsp_get_meters(state)
    #expect(meters.outputPeak == 0)
    #expect(meters.limitedSampleCount == 0)
}

@Test func positiveNegativeSymmetry() {
    let n = 4000
    var input = [Float](repeating: 0, count: n)
    var rng = SystemRandomNumberGenerator()
    for i in 0..<n { input[i] = Float.random(in: -0.4...0.4, using: &rng) }
    let negated = input.map { -$0 }

    let stateA = makeState(gainDB: 12)
    defer { boost_dsp_destroy(stateA) }
    let stateB = makeState(gainDB: 12)
    defer { boost_dsp_destroy(stateB) }

    let outA = process(stateA, input)
    let outB = process(stateB, negated)

    for i in 0..<n {
        #expect(abs(outA[i] + outB[i]) < 1e-6)
    }
}

@Test func outputNeverExceedsCeiling() {
    let state = makeState(gainDB: 18)
    defer { boost_dsp_destroy(state) }

    var input = [Float](repeating: 0, count: 2000)
    input[0] = 1.0
    input[1] = -1.0
    input[500] = 2.0     // over full scale
    input[501] = -2.0
    input[1000] = 5.0    // impulse well beyond full scale
    for i in 1500..<1600 { input[i] = (i % 2 == 0) ? 1.5 : -1.5 } // sustained over-range burst

    let output = process(state, input)
    for sample in output {
        #expect(abs(sample) <= ceilingLinear + 1e-4)
    }
}

@Test func speechLikeSignalBelowCeilingCausesNoLimiting() {
    let state = makeState(gainDB: 12)
    defer { boost_dsp_destroy(state) }

    let n = 20_000
    var input = [Float](repeating: 0, count: n)
    // Amplitude-modulated tone; peak after +12 dB gain stays at ~70% of ceiling.
    let targetPeakIn = (ceilingLinear * 0.7) / powf(10.0, 12.0 / 20.0)
    for i in 0..<n {
        let t = Float(i) / Float(sampleRate)
        let envelope = 0.5 + 0.5 * sinf(2 * .pi * 3 * t) // slow "speech-like" envelope
        input[i] = targetPeakIn * envelope * sinf(2 * .pi * 220 * t)
    }
    _ = process(state, input)

    let meters = boost_dsp_get_meters(state)
    #expect(meters.limitedSampleCount == 0)
    #expect(meters.maxGainReductionDB == 0)
}

@Test func steadyLoudToneLimitsWithLowRipple() {
    let state = makeState(gainDB: 12)
    defer { boost_dsp_destroy(state) }

    let n = 24_000
    var input = [Float](repeating: 0, count: n)
    for i in 0..<n {
        // 0.5 amplitude * +12 dB (~3.98x) => ~1.99 linear, well over the -1 dBFS ceiling: sustained limiting.
        input[i] = 0.5 * sinf(2 * .pi * 220 * Float(i) / Float(sampleRate))
    }
    let output = process(state, input)

    // Steady-state region: skip the initial attack transient.
    let steady = 4000..<n
    let windowSize = 400 // ~ a handful of cycles at 220 Hz / 48 kHz
    var windowPeaksDB: [Float] = []
    var idx = steady.lowerBound
    while idx + windowSize <= steady.upperBound {
        var peak: Float = 0
        for j in idx..<(idx + windowSize) { peak = max(peak, abs(output[j])) }
        windowPeaksDB.append(dbfs(peak))
        idx += windowSize
    }

    let maxDB = windowPeaksDB.max()!
    let minDB = windowPeaksDB.min()!
    #expect((maxDB - minDB) < 0.5)

    let meters = boost_dsp_get_meters(state)
    #expect(meters.limitedSampleCount > 0)
    #expect(meters.maxGainReductionDB > 0)
}

@Test func nonFiniteInputProducesFiniteOutput() {
    let state = makeState(gainDB: 12)
    defer { boost_dsp_destroy(state) }

    var input = [Float](repeating: 0.1, count: 1000)
    input[10] = .nan
    input[11] = .infinity
    input[12] = -.infinity
    input[500] = .nan

    let output = process(state, input)
    for sample in output {
        #expect(sample.isFinite)
    }
}

@Test func monoFrameCountAndOrderPreserved() {
    let state = makeState(gainDB: 0)
    defer { boost_dsp_destroy(state) }

    let n = 5000
    var input = [Float](repeating: 0, count: n)
    for i in 0..<n { input[i] = 0.2 * sinf(2 * .pi * 300 * Float(i) / Float(sampleRate)) }

    let output = process(state, input)
    #expect(output.count == input.count)

    // Unity gain, no limiting: output[i] must equal input[i - lookahead] exactly, in order.
    for i in lookahead..<n {
        #expect(abs(output[i] - input[i - lookahead]) < 1e-5)
    }
}

@Test func gainRampIsMonotone() {
    let state = boost_dsp_create(sampleRate, ceilingDBFS)!
    defer { boost_dsp_destroy(state) }

    boost_dsp_set_gain_db(state, 0)
    var frame: [Float] = [0]
    var out: [Float] = [0]
    boost_dsp_process(state, &frame, &out, 1) // let it settle at 0 dB
    var settleFrame: [Float] = [Float](repeating: 0, count: 4096)
    var settleOut = settleFrame
    boost_dsp_process(state, &settleFrame, &settleOut, settleFrame.count)
    #expect(abs(boost_dsp_current_gain_db(state) - 0) < 1e-3)

    boost_dsp_set_gain_db(state, 18)
    var last = boost_dsp_current_gain_db(state)
    for _ in 0..<2000 {
        boost_dsp_process(state, &frame, &out, 1)
        let current = boost_dsp_current_gain_db(state)
        #expect(current >= last - 1e-6) // non-decreasing while ramping up
        last = current
    }
    #expect(abs(last - 18) < 1e-2)

    boost_dsp_set_gain_db(state, 6)
    last = boost_dsp_current_gain_db(state)
    for _ in 0..<3000 {
        boost_dsp_process(state, &frame, &out, 1)
        let current = boost_dsp_current_gain_db(state)
        #expect(current <= last + 1e-6) // non-increasing while ramping down
        last = current
    }
    #expect(abs(last - 6) < 1e-2)
}

@Test func int16ToFloatIsSymmetricAndInRange() {
    let ints: [Int16] = [0, 1, -1, 32767, -32768, 16384, -16384]
    var floats = [Float](repeating: 0, count: ints.count)
    var mutableInts = ints
    boost_dsp_int16_to_float(&mutableInts, &floats, ints.count)

    #expect(floats[0] == 0)
    #expect(abs(floats[1] - (-floats[2])) < 1e-9) // +1 / -1 symmetric
    #expect(abs(floats[5] - (-floats[6])) < 1e-9) // +16384 / -16384 symmetric
    for f in floats { #expect(f >= -1.0 && f < 1.0) }
    #expect(abs(Double(floats[4]) - (-1.0)) < 1e-9) // -32768 -> exactly -1.0
}
