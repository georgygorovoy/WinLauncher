import SwiftUI

struct XboxSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var setupTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: model.xboxGamePrepared ? "checkmark.circle.fill" : "gamecontroller.fill")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.xboxGamePrepared ? Color.green : Color.accentColor)
            VStack(spacing: 8) {
                Text("Minecraft for Windows")
                    .font(.title2.weight(.semibold))
                Text(model.xboxSetupMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if model.xboxGamePrepared {
                        Label("Official game downloaded and verified", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if model.xboxRuntimeAvailable {
                            Label("Player runtime installed — ready to play", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Player runtime is not installed in this build", systemImage: "clock")
                            Text("Your download and Microsoft sign-in are saved. You do not need to repeat them. A compatible WineGDK/DXMT runtime is still required before the game can launch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Uses your Microsoft account and verifies ownership", systemImage: "person.badge.key")
                        Label("Downloads the official Windows game you own", systemImage: "arrow.down.circle")
                        Label("Account helper runs as a separate open-source component", systemImage: "puzzlepiece.extension")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
                .padding(4)
            }
            if model.operation == .preparingXboxSupport || model.operation == .downloadingXboxGame {
                ProgressView().controlSize(.small)
            }
            HStack {
                if model.operation == .preparingXboxSupport || model.operation == .downloadingXboxGame {
                    Button("Stop Setup") {
                        setupTask?.cancel()
                        setupTask = nil
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.xboxGamePrepared && model.xboxRuntimeAvailable {
                    Button("Play Minecraft") { Task { await model.installMinecraftSupport() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.operation != .idle)
                } else if model.xboxGamePrepared {
                    Button("Show Game Files", action: model.revealMinecraftFiles)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Set Up and Download") { startSetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.operation != .idle || !model.xboxHelperAvailable)
                }
            }
            if !model.xboxHelperAvailable {
                Text("This development build does not yet contain the separately built GPL helper binary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("WinLauncher \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(width: 590)
        .interactiveDismissDisabled(model.operation != .idle)
    }

    private func startSetup() {
        setupTask?.cancel()
        setupTask = Task {
            await model.installMinecraftSupport()
            setupTask = nil
        }
    }
}
