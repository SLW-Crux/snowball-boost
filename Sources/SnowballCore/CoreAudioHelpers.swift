import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let context: String
    public init(status: OSStatus, context: String) {
        self.status = status
        self.context = context
    }
    public var description: String { "\(context) failed: OSStatus \(status) (\(fourCC(status)))" }
}

public func fourCC(_ value: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return "\(value)"
}

/// Converts a linear amplitude (0...) to dBFS. Silence maps to a very low floor, not -infinity,
/// so it prints/compares sanely.
public func dbfs(_ linear: Float) -> Float {
    20.0 * log10f(max(linear, 1e-9))
}

public enum CA {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func hasProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(objectID, &addr)
    }

    public static func get<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "GetPropertyData(\(fourCC(OSStatus(bitPattern: address.mSelector))))")
        }
        return raw.load(as: T.self)
    }

    public static func getArray<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, context: "GetPropertyDataSize") }
        if size == 0 { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw)
        guard status == noErr else { throw CoreAudioError(status: status, context: "GetPropertyData(array)") }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    /// Fetches a CFString-typed property. Uses `Unmanaged` so ownership matches the HAL's
    /// documented convention ("the caller is responsible for releasing the returned CFObject")
    /// without either leaking or double-releasing.
    public static func getString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged else {
            throw CoreAudioError(status: status, context: "GetPropertyData(string)")
        }
        return unmanaged.takeRetainedValue() as String
    }

    public static func set<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var addr = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeBytes(of: &v) { raw -> OSStatus in
            AudioObjectSetPropertyData(objectID, &addr, 0, nil, size, raw.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: "SetPropertyData") }
    }

    /// Resolves a Core Audio device by its stable UID (works for both real and driver-published
    /// devices). Returns nil if no device with that UID currently exists.
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qPtr,
                &size, &result
            )
        }
        guard status == noErr, result != kAudioObjectUnknown else { return nil }
        return result
    }

    public static func allDeviceIDs() throws -> [AudioObjectID] {
        try getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
    }
}
