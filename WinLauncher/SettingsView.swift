import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            environment.tabItem { Label("Environment", systemImage: "shippingbox") }
            android.tabItem { Label("Android", systemImage: "app.badge") }
            graphics.tabItem { Label("Graphics", systemImage: "display") }
            compatibility.tabItem { Label("Compatibility", systemImage: "wrench.and.screwdriver") }
            diagnostics.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .sheet(isPresented: $model.showingAndroidSetup) {
            AndroidSetupView()
                .environmentObject(model)
        }
    }

    private var general: some View {
        Form {
            Section("Defaults") {
                LabeledContent("Windows Environment", value: "Shared")
                Text("All apps use the same Windows installation by default, so launchers and games can find each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Advanced Mode", isOn: Binding(
                    get: { model.advancedMode },
                    set: { model.setAdvancedMode($0) }
                ))
            }
            Section("Finder") {
                Button("Make WinLauncher Default for .exe, .msi, and .apk") {
                    model.makeDefaultSupportedFileHandler()
                }
                Text("After this, double-click a supported Windows or Android file in Finder to open it directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: "1.1.0")
                LabeledContent("Windows engine", value: model.engineInstalled ? model.engineDescription : "Installed automatically")
                LabeledContent("Android support", value: model.androidSupportDescription)
            }
        }
        .formStyle(.grouped)
    }

    private var android: some View {
        Form {
            Section("Android Support") {
                LabeledContent("Status", value: model.androidSupportDescription)
                Button("Install Lightweight Android Support", action: model.showAndroidSetup)
                    .disabled(model.operation != .idle)
                Button("Choose Existing Android SDK…", action: model.chooseAndroidSDK)
                Text("Downloads only adb, the Apple Silicon emulator, and one compact Android 11 ARM64 image. Android Studio and Java are not required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Compatibility") {
                Text("ARM64 and universal APKs work best on Apple Silicon. Apps may reject emulators, require Google Play installation, or depend on device hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var environment: some View {
        Form {
            Section("Shared Windows Environment") {
                Button("Open C: Drive", action: model.revealWindowsFiles)
                Button("Stop All Windows Apps", action: model.stopWindowsApps)
                Button("Repair Environment", action: model.repairEnvironment)
                    .disabled(!model.engineInstalled)
                Text("Repair keeps installed applications and rebuilds the essential Wine configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("File Access") {
                Toggle("Allow access to my Home folder as drive H:", isOn: $model.allowHomeFolder)
                Text("Off by default. WinLauncher only maps the folder containing an app you explicitly open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var graphics: some View {
        Form {
            Section("Rendering") {
                Picker("Graphics mode", selection: $model.graphicsMode) {
                    Text("Automatic").tag("Automatic")
                    Text("Performance").tag("Performance")
                    Text("Compatibility").tag("Compatibility")
                }
                Text(graphicsExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Performance") {
                Toggle("Fast synchronization", isOn: $model.synchronizationEnabled)
                Text("Improves responsiveness in most apps and games. Turn it off only when troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var compatibility: some View {
        Form {
            Section("Windows Tools") {
                Button("Windows Configuration…") { model.runWindowsTool("winecfg") }
                Button("Registry Editor…") { model.runWindowsTool("regedit") }
                Button("Command Prompt…") { model.runWindowsTool("cmd") }
            }
            .disabled(!model.engineInstalled || !model.advancedMode)

            if model.advancedMode {
                Section("Custom Environment Variables") {
                    TextEditor(text: $model.customEnvironmentVariables)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                    Text("One NAME=value entry per line. Changes apply the next time an app starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Wine Engine") {
                    LabeledContent("Current", value: model.engineDescription)
                    Button("Choose Another Wine…", action: model.chooseWineEngine)
                }
            } else {
                ContentUnavailableView(
                    "Advanced Mode Is Off",
                    systemImage: "lock",
                    description: Text("Enable Advanced Mode in General to use Windows tools and custom overrides.")
                )
            }
        }
        .formStyle(.grouped)
    }

    private var diagnostics: some View {
        Form {
            Section("Support") {
                Button("Show Logs", action: model.revealLogs)
                Button("Copy Diagnostic Report", action: model.copyDiagnosticReport)
                Toggle("Detailed Wine logging", isOn: $model.diagnosticLogging)
                Text("Detailed logging can make log files large. Leave it off unless you are investigating a problem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var graphicsExplanation: String {
        switch model.graphicsMode {
        case "Performance": "Uses the accelerated DXMT renderer when available."
        case "Compatibility": "Uses Wine's built-in renderer for apps that do not work with acceleration."
        default: "Selects the best available renderer for the current engine."
        }
    }
}
