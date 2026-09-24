import AppKit
import SwiftUI
import SnowballCore

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snowball: \(model.snowballInfo)")
            Text("Status: \(statusText)")

            Divider()

            Picker("Gain", selection: Binding(get: { model.gainDB }, set: { model.setGain($0) })) {
                ForEach(Settings.allowedGainsDB, id: \.self) { value in
                    Text("+\(Int(value)) dB").tag(value)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Text(String(format: "In:  %.1f dBFS", model.meters.inputPeakDB))
                .monospacedDigit()
            Text(String(format: "Out: %.1f dBFS", model.meters.outputPeakDB))
                .monospacedDigit()
            Text(limiterText)
                .monospacedDigit()

            Divider()

            Button("Open Audio MIDI Setup") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private var statusText: String {
        switch model.engineState {
        case .noDriver: return "driver not installed"
        case .noSnowball: return "Snowball not connected"
        case .idle: return "ready (nothing using the mic)"
        case .running: return "running"
        case .error(let message): return "error: \(message)"
        }
    }

    private var limiterText: String {
        model.meters.limiterActive
            ? String(format: "Limiter: active (%.1f dB)", model.meters.gainReductionDB)
            : "Limiter: idle"
    }
}
