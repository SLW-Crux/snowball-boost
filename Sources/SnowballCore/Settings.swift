import Foundation

public enum Settings {
    public static let suiteName = "com.snowballboost"
    public static let darwinNotifyName = "com.snowballboost.settings"

    private static let gainKey = "gainDB"
    public static let defaultGainDB: Float = 12
    public static let allowedGainsDB: [Float] = [0, 6, 9, 12, 15, 18]

    private static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    public static var gainDB: Float {
        get {
            guard defaults.object(forKey: gainKey) != nil else { return defaultGainDB }
            let stored = Float(defaults.double(forKey: gainKey))
            return allowedGainsDB.contains(stored) ? stored : defaultGainDB
        }
        set {
            let clamped = allowedGainsDB.contains(newValue) ? newValue : defaultGainDB
            defaults.set(Double(clamped), forKey: gainKey)
            notifyChanged()
        }
    }

    public static func notifyChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotifyName as CFString),
            nil, nil, true
        )
    }
}

/// Observes the Darwin notification posted when gain changes (e.g. from the CLI, while the app
/// is running). CFNotificationCenter's callback is a bare C function pointer, so this wraps the
/// add/remove pair and forwards to a Swift closure via an unmanaged self pointer.
public final class DarwinNotificationObserver {
    private let handler: () -> Void
    private let name: String

    public init(name: String, handler: @escaping () -> Void) {
        self.handler = handler
        self.name = name
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
    }
}
