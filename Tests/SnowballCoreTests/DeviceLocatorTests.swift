import Testing
import CoreAudio
@testable import SnowballCore

@Test func snowballMatchesUSBWithModelUIDSuffix() {
    #expect(DeviceLocator.matches(transportType: kAudioDeviceTransportTypeUSB, modelUID: "Blue Snowball :0D8C:0005"))
}

@Test func snowballDoesNotMatchWrongTransport() {
    #expect(!DeviceLocator.matches(transportType: kAudioDeviceTransportTypeBuiltIn, modelUID: "Blue Snowball :0D8C:0005"))
}

@Test func snowballDoesNotMatchWrongModelUID() {
    #expect(!DeviceLocator.matches(transportType: kAudioDeviceTransportTypeUSB, modelUID: "Some Other Mic :ABCD:1234"))
}

@Test func snowballDoesNotMatchModelUIDSubstringNotSuffix() {
    // ":0D8C:0005" appearing mid-string, not as the suffix, must not match.
    #expect(!DeviceLocator.matches(transportType: kAudioDeviceTransportTypeUSB, modelUID: ":0D8C:0005-extra"))
}

@Test func deterministicSelectionSortsByUIDAscending() {
    let a = SnowballDevice(deviceID: 10, uid: "zzz-second", name: "Snowball A")
    let b = SnowballDevice(deviceID: 20, uid: "aaa-first", name: "Snowball B")
    let selected = DeviceLocator.selectDeterministic([a, b])
    #expect(selected?.uid == "aaa-first")
}

@Test func deterministicSelectionIsStableRegardlessOfInputOrder() {
    let a = SnowballDevice(deviceID: 10, uid: "aaa-first", name: "Snowball A")
    let b = SnowballDevice(deviceID: 20, uid: "zzz-second", name: "Snowball B")
    #expect(DeviceLocator.selectDeterministic([a, b])?.uid == "aaa-first")
    #expect(DeviceLocator.selectDeterministic([b, a])?.uid == "aaa-first")
}

@Test func deterministicSelectionOfEmptyListIsNil() {
    #expect(DeviceLocator.selectDeterministic([]) == nil)
}
