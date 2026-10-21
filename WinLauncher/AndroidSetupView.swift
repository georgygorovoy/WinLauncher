import SwiftUI

struct AndroidSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var acceptedLicense = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "apps.iphone")
                .font(.system(size: 50, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Add Android Support")
                    .font(.title2.weight(.semibold))
                Text("WinLauncher downloads only adb, the Apple Silicon emulator, and one compact Android 11 ARM64 image. Android Studio and Java are not required.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("About 985 MB to download", systemImage: "arrow.down.circle")
                Label("About 2.5–3 GB after installation", systemImage: "internaldrive")
                Label("Stored only inside WinLauncher Application Support", systemImage: "folder")
            }
            .frame(maxWidth: 430, alignment: .leading)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Toggle(isOn: $acceptedLicense) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("I accept the Android SDK License Agreement")
                    Link("Read Google’s license", destination: URL(string: "https://developer.android.com/studio/terms")!)
                        .font(.caption)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 430, alignment: .leading)

            if model.operation == .installingAndroidSupport {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(model.androidSetupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel", action: model.dismissAndroidSetup)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.operation == .installingAndroidSupport)
                Spacer()
                Button("Download and Install") {
                    Task { await model.installLightweightAndroidSupport() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acceptedLicense || model.operation != .idle)
            }
        }
        .padding(34)
        .frame(width: 600)
        .frame(minHeight: 500)
    }
}
