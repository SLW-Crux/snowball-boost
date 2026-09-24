import CoreAudio
import Foundation

public struct SnowballDevice: Equatable, Sendable {
    public let deviceID: AudioObjectID
    public let uid: String
    public let name: String
}

/// Locates the physical Blue Snowball. Scoped deliberately to only this recognised USB mic
/// (VID 0x0D8C / PID 0x0005) — no device picker, per the owner's requirement. See
/// docs/PLAN.md "Measured facts".
public enum DeviceLocator {
    /// ModelUID measured on the reference Mac: "Blue Snowball :0D8C:0005". Matching on the
    /// ":0D8C:0005" (USB VID:PID) suffix is more stable than matching the full string or the
    /// display name, which can be renamed by the user or vary by locale.
    public static let modelUIDSuffix = ":0D8C:0005"

    public static let feedDeviceUID = "com.snowballboost.feed"
    public static let boostedDeviceUID = "com.snowballboost.boosted"

    public static func matches(transportType: UInt32, modelUID: String) -> Bool {
        transportType == kAudioDeviceTransportTypeUSB && modelUID.hasSuffix(modelUIDSuffix)
    }

    /// Deterministic selection when more than one match exists: sort by UID, first wins.
    public static func selectDeterministic(_ candidates: [SnowballDevice]) -> SnowballDevice? {
        candidates.sorted { $0.uid < $1.uid }.first
    }

    public static func findSnowball() throws -> SnowballDevice? {
        let deviceIDs = try CA.allDeviceIDs()
        var candidates: [SnowballDevice] = []
        for id in deviceIDs {
            guard let transport: UInt32 = try? CA.get(id, CA.address(kAudioDevicePropertyTransportType)) else { continue }
            guard let modelUID = try? CA.getString(id, CA.address(kAudioDevicePropertyModelUID)) else { continue }
            guard matches(transportType: transport, modelUID: modelUID) else { continue }
            guard let uid = try? CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID)) else { continue }
            let name = (try? CA.getString(id, CA.address(kAudioObjectPropertyName))) ?? "Blue Snowball"
            candidates.append(SnowballDevice(deviceID: id, uid: uid, name: name))
        }
        return selectDeterministic(candidates)
    }

    public static func feedDeviceID() -> AudioObjectID? { CA.deviceID(forUID: feedDeviceUID) }
    public static func boostedDeviceID() -> AudioObjectID? { CA.deviceID(forUID: boostedDeviceUID) }
}
