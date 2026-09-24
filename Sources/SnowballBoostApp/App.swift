import SwiftUI
import SnowballCore

@main
struct SnowballBoostMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Snowball Boost", systemImage: model.menuBarSymbol) {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var engineState: EngineState = .noDriver
    @Published private(set) var meters: MetersSnapshot = .silent
    @Published private(set) var snowballInfo: String = "checking…"
    @Published private(set) var gainDB: Float = Settings.gainDB

    private let engine = BoostEngine()
    private var uiTimer: Timer?

    init() {
        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.engineState = state }
        }
        engine.start()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        meters = engine.meters.snapshot()
        if let snowball = try? DeviceLocator.findSnowball() {
            snowballInfo = snowball.name
        } else {
            snowballInfo = "not connected"
        }
    }

    var menuBarSymbol: String {
        switch engineState {
        case .running: return "mic.fill"
        case .idle: return "mic"
        case .noSnowball, .noDriver: return "mic.slash"
        case .error: return "exclamationmark.triangle"
        }
    }

    func setGain(_ value: Float) {
        Settings.gainDB = value
        gainDB = value
    }
}
