import SwiftUI

struct EngineSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Windows Support")
                    .font(.title2.weight(.semibold))
                Text(model.operation == .installingEngine
                     ? "Downloading and preparing Windows Support…"
                     : model.engineSetupMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                        .foregroundStyle(.tint)
                    Text("WinLauncher installs and verifies Wine 11 automatically. You never need to choose an engine for normal use.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check Windows Support") { Task { await model.installLocalEngine() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.operation != .idle)
            }
        }
        .padding(30)
        .frame(width: 540)
        .interactiveDismissDisabled(model.operation != .idle)
    }
}
