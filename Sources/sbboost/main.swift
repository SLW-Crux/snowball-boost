import BoostDSP
import CoreAudio
import Foundation
import SnowballCore

func printUsage() {
    print("""
    sbboost — Snowball Boost command line tool

    Usage:
      sbboost status
      sbboost gain <0|6|9|12|15|18>
      sbboost diagnose [--seconds N]
      sbboost bench [--seconds N] [--out DIR]
    """)
}

func fmtDB(_ value: Float) -> String {
    String(format: "%.1f", value)
}

func isAgentLoaded() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/com.snowballboost.agent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func firstStreamFormat(of deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
    let streams: [AudioObjectID] = try CA.getArray(deviceID, CA.address(kAudioDevicePropertyStreams, scope: scope))
    guard let stream = streams.first else {
        throw CoreAudioError(status: kAudioHardwareUnknownPropertyError, context: "no streams")
    }
    return try CA.get(stream, CA.address(kAudioStreamPropertyVirtualFormat))
}

func describeFormat(_ f: AudioStreamBasicDescription) -> String {
    let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    return "\(Int(f.mSampleRate)) Hz, \(f.mChannelsPerFrame)ch, \(f.mBitsPerChannel)-bit \(isFloat ? "float" : "int")"
}

// MARK: - status

func runStatus() {
    print("Snowball Boost — status")

    do {
        if let snowball = try DeviceLocator.findSnowball() {
            print("  Snowball:  present  uid=\(snowball.uid)")
            if let rate: Float64 = try? CA.get(snowball.deviceID, CA.address(kAudioDevicePropertyNominalSampleRate)) {
                print("    rate: \(Int(rate)) Hz")
            }
            if let format = try? firstStreamFormat(of: snowball.deviceID, scope: kAudioObjectPropertyScopeInput) {
                print("    format: \(describeFormat(format))")
            }
            let hwGainAddress = CA.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeInput)
            if let hwGain: Float32 = try? CA.get(snowball.deviceID, hwGainAddress) {
                print("    HW input gain: \(fmtDB(hwGain)) dB")
            }
        } else {
            print("  Snowball:  NOT FOUND")
        }
    } catch {
        print("  Snowball:  error querying device list: \(error)")
    }

    if let feed = DeviceLocator.feedDeviceID() {
        print("  Feed:      present (object \(feed), hidden)")
    } else {
        print("  Feed:      NOT FOUND — driver not installed or not loaded")
    }

    if let boosted = DeviceLocator.boostedDeviceID() {
        let running: UInt32 = (try? CA.get(boosted, CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere))) ?? 0
        print("  Boosted:   present (object \(boosted))")
        print("    running somewhere (has a consumer): \(running != 0 ? "yes" : "no")")
    } else {
        print("  Boosted:   NOT FOUND — driver not installed or not loaded")
    }

    print("  Agent:     \(isAgentLoaded() ? "loaded" : "not loaded")")
    print("  Gain:      +\(Int(Settings.gainDB)) dB")
}

// MARK: - gain

func runGain(_ args: [String]) {
    guard let valueString = args.first, let value = Float(valueString) else {
        print("Usage: sbboost gain <0|6|9|12|15|18>")
        exit(1)
    }
    guard Settings.allowedGainsDB.contains(value) else {
        print("Gain must be one of: \(Settings.allowedGainsDB.map { Int($0) })")
        exit(1)
    }
    Settings.gainDB = value
    print("Gain set to +\(Int(value)) dB")
}

// MARK: - shared IO helpers for diagnose/bench

final class SampleSink {
    private let lock = NSLock()
    private var storage: [Float] = []

    func append(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffer = inputData.pointee.mBuffers
        guard let raw = buffer.mData else { return }
        let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }
        let floats = raw.assumingMemoryBound(to: Float.self)
        let chunk = Array(UnsafeBufferPointer(start: floats, count: frameCount))
        lock.lock()
        storage.append(contentsOf: chunk)
        lock.unlock()
    }

    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

func startCapture(deviceID: AudioObjectID, into sink: SampleSink) throws -> AudioDeviceIOProcID {
    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, inputData, _, _, _ in
        sink.append(inputData)
    }
    guard status == noErr, let procID else {
        throw CoreAudioError(status: status, context: "AudioDeviceCreateIOProcIDWithBlock")
    }
    let startStatus = AudioDeviceStart(deviceID, procID)
    guard startStatus == noErr else {
        AudioDeviceDestroyIOProcID(deviceID, procID)
        throw CoreAudioError(status: startStatus, context: "AudioDeviceStart")
    }
    return procID
}

func stopCapture(deviceID: AudioObjectID, procID: AudioDeviceIOProcID) {
    AudioDeviceStop(deviceID, procID)
    AudioDeviceDestroyIOProcID(deviceID, procID)
}

// MARK: - diagnose

func runDiagnose(_ args: [String]) {
    var seconds = 5.0
    if let idx = args.firstIndex(of: "--seconds"), idx + 1 < args.count, let s = Double(args[idx + 1]) {
        seconds = s
    }

    guard let snowball = try? DeviceLocator.findSnowball() else {
        print("Snowball not found."); exit(1)
    }
    guard let boostedID = DeviceLocator.boostedDeviceID() else {
        print("Snowball Boosted not found — is the driver installed? (make install-driver)"); exit(1)
    }

    print("Diagnosing for \(Int(seconds))s — speak normally at ~30 cm from the Snowball...")

    let rawSink = SampleSink()
    let boostedSink = SampleSink()

    do {
        let rawProc = try startCapture(deviceID: snowball.deviceID, into: rawSink)
        let boostedProc = try startCapture(deviceID: boostedID, into: boostedSink)
        Thread.sleep(forTimeInterval: seconds)
        stopCapture(deviceID: snowball.deviceID, procID: rawProc)
        stopCapture(deviceID: boostedID, procID: boostedProc)
    } catch {
        print("Failed to capture: \(error)")
        exit(1)
    }

    let rawSamples = rawSink.samples
    let boostedSamples = boostedSink.samples

    guard !rawSamples.isEmpty, !boostedSamples.isEmpty else {
        print("No audio captured — check microphone permission for this terminal (System Settings > Privacy & Security > Microphone).")
        exit(1)
    }

    let rawRMS = rms(rawSamples), rawPeak = peak(rawSamples)
    let boostedRMS = rms(boostedSamples), boostedPeak = peak(boostedSamples)
    let clipped = clipCount(boostedSamples)

    print("Raw Snowball:")
    print("  RMS: \(fmtDB(dbfs(rawRMS))) dBFS   Peak: \(fmtDB(dbfs(rawPeak))) dBFS   (\(rawSamples.count) samples)")
    print("Snowball Boosted:")
    print("  RMS: \(fmtDB(dbfs(boostedRMS))) dBFS   Peak: \(fmtDB(dbfs(boostedPeak))) dBFS   (\(boostedSamples.count) samples)")
    print("  Clipped samples (|x| >= 0.999 full scale): \(clipped)")
    print("  Measured gain (Boosted RMS - Raw RMS): \(fmtDB(dbfs(boostedRMS) - dbfs(rawRMS))) dB")
    print("  Configured gain setting: +\(Int(Settings.gainDB)) dB")
}

// MARK: - bench

func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum = 0.0
    for x in samples { sum += Double(x) * Double(x) }
    return Float((sum / Double(samples.count)).squareRoot())
}

func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

func clipCount(_ samples: [Float], threshold: Float = 0.999) -> Int {
    samples.reduce(0) { $0 + (abs($1) >= threshold ? 1 : 0) }
}

func noiseFloorDB(_ samples: [Float], sampleRate: Double) -> Float {
    let windowSize = max(1, Int(sampleRate * 0.05)) // 50 ms
    guard samples.count >= windowSize else { return dbfs(rms(samples)) }
    var windowRMSValues: [Float] = []
    var i = 0
    while i + windowSize <= samples.count {
        windowRMSValues.append(rms(Array(samples[i..<(i + windowSize)])))
        i += windowSize
    }
    windowRMSValues.sort()
    let idx = min(windowRMSValues.count - 1, max(0, Int(Double(windowRMSValues.count) * 0.1)))
    return dbfs(windowRMSValues[idx])
}

/// Cross-correlation estimate of how many samples `target` lags `reference` by. Positive means
/// target is delayed relative to reference.
func estimateLagSamples(reference: [Float], target: [Float], sampleRate: Double, maxLagSeconds: Double, analysisSeconds: Double) -> Int {
    let analysisCount = min(reference.count, target.count, Int(sampleRate * analysisSeconds))
    guard analysisCount > 100 else { return 0 }
    let maxLag = max(1, Int(sampleRate * maxLagSeconds))
    var bestLag = 0
    var bestScore = -Double.infinity
    for lag in -maxLag...maxLag {
        var score = 0.0
        var count = 0
        var i = 0
        while i < analysisCount {
            let j = i + lag
            if j >= 0, j < target.count {
                score += Double(reference[i]) * Double(target[j])
                count += 1
            }
            i += 1
        }
        guard count > 0 else { continue }
        score /= Double(count)
        if score > bestScore {
            bestScore = score
            bestLag = lag
        }
    }
    return bestLag
}

func writeWAV(url: URL, samples: [Float], sampleRate: Double) throws {
    var data = Data()
    func appendString(_ s: String) { data.append(s.data(using: .ascii)!) }
    func appendU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    func appendU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

    let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
    let byteRate = UInt32(sampleRate) * 4
    appendString("RIFF"); appendU32(36 + dataSize); appendString("WAVE")
    appendString("fmt "); appendU32(16)
    appendU16(3)  // WAVE_FORMAT_IEEE_FLOAT
    appendU16(1)  // mono
    appendU32(UInt32(sampleRate))
    appendU32(byteRate)
    appendU16(4)  // block align
    appendU16(32) // bits per sample
    appendString("data"); appendU32(dataSize)
    samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }

    try data.write(to: url)
}

func runBench(_ args: [String]) {
    var seconds = 10.0
    var outDirPath = "bench-out"
    if let idx = args.firstIndex(of: "--seconds"), idx + 1 < args.count, let s = Double(args[idx + 1]) {
        seconds = s
    }
    if let idx = args.firstIndex(of: "--out"), idx + 1 < args.count {
        outDirPath = args[idx + 1]
    }

    guard let snowball = try? DeviceLocator.findSnowball() else {
        print("Snowball not found."); exit(1)
    }
    guard let boostedID = DeviceLocator.boostedDeviceID() else {
        print("Snowball Boosted not found — is the driver installed? (make install-driver)"); exit(1)
    }

    print("Recording \(Int(seconds))s from raw Snowball (A) and Snowball Boosted (B) simultaneously — speak normally at ~30 cm...")

    let rawSink = SampleSink()
    let boostedSink = SampleSink()

    do {
        let rawProc = try startCapture(deviceID: snowball.deviceID, into: rawSink)
        let boostedProc = try startCapture(deviceID: boostedID, into: boostedSink)
        Thread.sleep(forTimeInterval: seconds)
        stopCapture(deviceID: snowball.deviceID, procID: rawProc)
        stopCapture(deviceID: boostedID, procID: boostedProc)
    } catch {
        print("Failed to capture: \(error)")
        exit(1)
    }

    let rawSamples = rawSink.samples
    let boostedSamples = boostedSink.samples
    guard !rawSamples.isEmpty, !boostedSamples.isEmpty else {
        print("No audio captured — check microphone permission for this terminal.")
        exit(1)
    }

    let sampleRate = 48000.0
    let rawRMS = rms(rawSamples), rawPeak = peak(rawSamples), rawClips = clipCount(rawSamples)
    let boostedRMS = rms(boostedSamples), boostedPeak = peak(boostedSamples), boostedClips = clipCount(boostedSamples)
    let rawNoiseFloor = noiseFloorDB(rawSamples, sampleRate: sampleRate)
    let boostedNoiseFloor = noiseFloorDB(boostedSamples, sampleRate: sampleRate)
    let lagSamples = estimateLagSamples(reference: rawSamples, target: boostedSamples, sampleRate: sampleRate, maxLagSeconds: 0.05, analysisSeconds: 1.0)
    let lagMS = Double(lagSamples) / sampleRate * 1000.0

    let fm = FileManager.default
    try? fm.createDirectory(atPath: outDirPath, withIntermediateDirectories: true)
    let rawURL = URL(fileURLWithPath: outDirPath).appendingPathComponent("A_raw_snowball.wav")
    let boostedURL = URL(fileURLWithPath: outDirPath).appendingPathComponent("B_snowball_boosted.wav")
    do {
        try writeWAV(url: rawURL, samples: rawSamples, sampleRate: sampleRate)
        try writeWAV(url: boostedURL, samples: boostedSamples, sampleRate: sampleRate)
    } catch {
        print("Warning: failed to write WAV files: \(error)")
    }

    print("")
    print("A) Raw Snowball        -> \(rawURL.path)")
    print("   RMS: \(fmtDB(dbfs(rawRMS))) dBFS   Peak: \(fmtDB(dbfs(rawPeak))) dBFS   Clipped: \(rawClips)   Noise floor: \(fmtDB(rawNoiseFloor)) dBFS")
    print("B) Snowball Boosted    -> \(boostedURL.path)")
    print("   RMS: \(fmtDB(dbfs(boostedRMS))) dBFS   Peak: \(fmtDB(dbfs(boostedPeak))) dBFS   Clipped: \(boostedClips)   Noise floor: \(fmtDB(boostedNoiseFloor)) dBFS")
    print("")
    print("Effective gain (B RMS - A RMS): \(fmtDB(dbfs(boostedRMS) - dbfs(rawRMS))) dB  (configured: +\(Int(Settings.gainDB)) dB)")
    print("Estimated B-vs-A latency: \(String(format: "%.1f", lagMS)) ms (\(lagSamples) samples @ \(Int(sampleRate)) Hz)")
}

// MARK: - entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "status":
    runStatus()
case "gain":
    runGain(Array(arguments.dropFirst()))
case "diagnose":
    runDiagnose(Array(arguments.dropFirst()))
case "bench":
    runBench(Array(arguments.dropFirst()))
case "-h", "--help", "help":
    printUsage()
default:
    FileHandle.standardError.write("Unknown command: \(command)\n\n".data(using: .utf8)!)
    printUsage()
    exit(1)
}
