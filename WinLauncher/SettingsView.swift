import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            steam.tabItem { Label("Steam", systemImage: "gamecontroller") }
            environment.tabItem { Label("Environment", systemImage: "shippingbox") }
            android.tabItem { Label("Android", systemImage: "app.badge") }
            xbox.tabItem { Label("Xbox Games", systemImage: "gamecontroller") }
            graphics.tabItem { Label("Graphics", systemImage: "display") }
            compatibility.tabItem { Label("Compatibility", systemImage: "wrench.and.screwdriver") }
            diagnostics.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .sheet(isPresented: $model.showingAndroidSetup) {
            AndroidSetupView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingXboxSetup) {
            XboxSetupView()
                .environmentObject(model)
        }
    }

    private var general: some View {
        Form {
            Section("Defaults") {
                LabeledContent("Windows Environment", value: String(localized: "Shared"))
                Text("All apps use the same Windows installation by default, so launchers and games can find each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Advanced Mode", isOn: Binding(
                    get: { model.advancedMode },
                    set: { model.setAdvancedMode($0) }
                ))
            }
            Section("Finder") {
                Toggle("Open Windows files directly", isOn: $model.openWindowsFilesDirectly)
                Text("Enabled by default. Double-clicking an .exe or .msi starts the Windows app and hides the WinLauncher window when Windows Support is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Make WinLauncher Default for .exe, .msi, and .apk") {
                    model.makeDefaultSupportedFileHandler()
                }
                Text("After this, double-click a supported Windows or Android file in Finder to open it directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Windows engine", value: model.engineInstalled ? model.engineDescription : String(localized: "Installed automatically"))
                LabeledContent("Android support", value: model.androidSupportDescription)
                LabeledContent("Xbox Games Support", value: model.xboxSetupMessage)
            } header: {
                HStack(spacing: 6) {
                    Text("About")
                    TechnologyGuideButton()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var android: some View {
        Form {
            Section {
                LabeledContent("Status", value: model.androidSupportDescription)
                Button("Install Lightweight Android Support", action: model.showAndroidSetup)
                    .disabled(model.operation != .idle)
                Button(model.installedFDroid == nil ? "Install F-Droid App Store" : "Open F-Droid App Store",
                       action: model.openFDroid)
                    .disabled(model.operation != .idle)
                Button("Choose Existing Android SDK…", action: model.chooseAndroidSDK)
                Text("Downloads only adb, the Apple Silicon emulator, and one compact Android 11 ARM64 image. Android Studio and Java are not required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("F-Droid is an open-source app store inside the emulator. Android may ask once to allow F-Droid to install apps. Google Play is not included in this AOSP image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) {
                    Text("Android Support")
                    TechnologyGuideButton()
                }
            }
            Section("Compatibility") {
                Text("ARM64 and universal APKs work best on Apple Silicon. Apps may reject emulators, require Google Play installation, or depend on device hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var steam: some View {
        Form {
            Section {
                LabeledContent("Windows downloads", value: steamModeDescription)
                Toggle("Download Windows versions in Steam (all games)", isOn: Binding(
                    get: { model.steamWindowsModeState == .enabled || model.steamWindowsModeState == .enabledOutsideWinLauncher },
                    set: { model.setSteamWindowsDownloads($0) }
                ))
                .disabled(model.steamWindowsModeState == .unavailable ||
                          model.steamWindowsModeState == .enabledOutsideWinLauncher ||
                          model.steamWindowsModeState == .conflictingOverride)
                Text("Steam prefers native macOS versions when this switch is off. Turn it on to download a Windows-only game, then turn it off again before installing or updating Mac games. WinLauncher launches installed Windows games with WineForge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.steamRestartRequired {
                    Label("Restart Steam to apply the change", systemImage: "arrow.clockwise")
                        .foregroundStyle(.orange)
                }
                Button("Open Steam", action: model.openNativeSteam)
                Button("Refresh Status", action: model.refreshSteamWindowsMode)
            } header: {
                HStack(spacing: 6) {
                    Text("Steam for macOS")
                    SteamGuideButton()
                }
            }
            Section {
                Button("Open Steam Game Folder", action: model.revealSteamGames)
                Button("Refresh Steam Games", action: model.refreshSteamGames)
                LabeledContent("Steam Play", value: model.steamPlayBridgeStatus)
                if model.steamPlayNeedsAttention {
                    Label(model.steamPlayBridgeStatus, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("WinLauncher checks installed Windows launch entries after Steam closes. Steam's platform setting is global, so downloading Windows games requires temporarily enabling the switch above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) {
                    Text("Game files")
                    SteamGuideButton()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.refreshSteamWindowsMode)
    }

    private var steamModeDescription: String {
        switch model.steamWindowsModeState {
        case .unavailable: String(localized: "Steam client not found")
        case .disabled: String(localized: "Off")
        case .enabled: String(localized: "On · WinLauncher")
        case .enabledOutsideWinLauncher: String(localized: "On · External configuration")
        case .conflictingOverride: String(localized: "Another platform setting is present")
        }
    }

    private var environment: some View {
        Form {
            Section {
                Button("Open C: Drive", action: model.revealWindowsFiles)
                Button("Stop All Windows Apps", action: model.stopWindowsApps)
                Button("Repair Environment", action: model.repairEnvironment)
                    .disabled(!model.engineInstalled)
                Text("Repair keeps installed applications and rebuilds the essential Wine configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) {
                    Text("Shared Windows Environment")
                    TechnologyGuideButton()
                }
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

    private var xbox: some View {
        Form {
            Section {
                LabeledContent("Status", value: model.xboxSetupMessage)
                if model.xboxGamePrepared && model.xboxRuntimeAvailable {
                    Button("Play Minecraft") {
                        Task { await model.installMinecraftSupport() }
                    }
                    .disabled(model.operation != .idle)
                } else if model.xboxGamePrepared {
                    Button("Show Downloaded Game", action: model.revealMinecraftFiles)
                } else {
                    Button("Set Up Xbox Games Support", action: model.showXboxSetup)
                        .disabled(model.operation != .idle)
                }
                Button("View Xbox Games Support Details", action: model.showXboxSetup)
                    .disabled(model.operation != .idle)
                Text("Uses a separate open-source helper for Microsoft sign-in, ownership verification, and the official Windows game download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) {
                    Text("Minecraft for Windows")
                    TechnologyGuideButton()
                }
            }
            Section("Privacy") {
                Text("Microsoft tokens are stored in WinLauncher's private data folder with access limited to your macOS account. WinLauncher does not receive or log your password or account tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var graphics: some View {
        Form {
            Section {
                Picker("Graphics mode", selection: $model.graphicsMode) {
                    Text("Automatic").tag("Automatic")
                    Text("Performance").tag("Performance")
                    Text("Compatibility").tag("Compatibility")
                }
                Text(L10n.text(graphicsExplanation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) {
                    Text("Rendering")
                    TechnologyGuideButton()
                }
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
}

struct SteamGuideButton: View {
    @State private var showingGuide = false

    var body: some View {
        Button {
            showingGuide = true
        } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .accessibilityLabel("How Steam games work in WinLauncher")
        }
        .buttonStyle(.borderless)
        .help("How to download and play Steam games")
        .popover(isPresented: $showingGuide, arrowEdge: .bottom) {
            SteamGuideView()
        }
    }
}

private struct SteamGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Steam games", systemImage: "gamecontroller.fill")
                    .font(.title3.weight(.semibold))

                Text("What to do")
                    .font(.headline)
                guideStep("1", "Mac games", "Leave Windows downloads off. Install and play the Mac version in Steam as usual.")
                guideStep("2", "Windows-only games", "In WinLauncher, open Settings → Steam and turn on Windows downloads. Restart Steam, then install the game there.")
                guideStep("3", "After downloading", "Turn Windows downloads off and restart Steam. Open Profile → Steam Windows games in WinLauncher to play. Keep the switch off for Mac game installs and updates.")

                Divider()

                Text("How it works")
                    .font(.headline)
                Text("The switch changes one Steam setting that makes Steam download Windows versions. It affects the whole library, so it must be used temporarily. Steam reads it when Steam starts.")
                Text("After Steam closes, WinLauncher checks the launch data for installed Windows games and repairs supported Play commands. It keeps a backup. When you play, WineForge runs the game's .exe inside WinLauncher's shared Windows environment. Mac versions stay with Steam's normal Mac launcher.")
                Text("Steam stores games in steamapps/common inside its library. Some Windows games may still need features that WineForge does not support.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 440, height: 460)
    }

    private func guideStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).fontWeight(.semibold)
                Text(L10n.text(detail)).foregroundStyle(.secondary)
            }
        }
    }
}

struct TechnologyGuideButton: View {
    @State private var showingGuide = false

    var body: some View {
        Button { showingGuide = true } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .accessibilityLabel("How WinLauncher works")
        }
        .buttonStyle(.borderless)
        .help("How WinLauncher works")
        .popover(isPresented: $showingGuide, arrowEdge: .bottom) {
            TechnologyGuideView()
        }
    }
}

private struct TechnologyGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Label("How WinLauncher works", systemImage: "gearshape.2.fill")
                    .font(.title3.weight(.semibold))
                technology("shippingbox.fill", "Windows apps · WineForge",
                           "WineForge translates Windows app calls so a .exe can run on macOS. WinLauncher downloads a checked engine and keeps apps in one shared Windows environment (the C: drive).")
                technology("display", "Game graphics · DXMT",
                           "When available, DXMT translates DirectX graphics calls to Metal. Compatibility mode uses Wine's built-in renderer instead.")
                technology("bolt.fill", "Fast synchronization",
                           "Wine's synchronization settings help Windows processes coordinate efficiently. The switch in Graphics can be turned off when diagnosing a game problem.")
                technology("gamecontroller.fill", "Steam games",
                           "Mac games stay in Steam. For Windows-only downloads, WinLauncher temporarily changes Steam's global platform setting. After Steam closes, it checks supported Play entries and runs installed .exe games through WineForge.")
                technology("bag.fill", "Store and Profile",
                           "Store searches public Steam and GOG game lists together. Epic and Ubisoft open their official sites. Profile lists apps known to WinLauncher and records launches made through it.")
                technology("app.badge.fill", "Android apps · Emulator and ADB",
                           "WinLauncher downloads an Android 11 ARM64 AOSP image and emulator. ADB installs your APK and opens it inside that virtual Android device.")
                technology("bag.fill", "Android store · F-Droid",
                           "WinLauncher checks a pinned official F-Droid APK before installing it in the emulator. F-Droid then downloads open-source Android apps from its own repository. Android may ask you to allow installs from F-Droid once. Google Play is not part of this emulator.")
                technology("cube.fill", "Minecraft for Windows",
                           "A separate open-source Xbox helper signs in to Microsoft, checks ownership and downloads the owned game. WinLauncher starts it using its Windows runtime and WineGDK support.")
                technology("doc.fill", "Files and diagnostics",
                           "The + button imports .exe, .msi and .apk files. Installed apps appear under Your apps. WinLauncher maps only needed folders unless you allow Home as H:, and keeps logs in Application Support.")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 490, height: 525)
    }

    private func technology(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).fontWeight(.semibold)
                Text(L10n.text(detail)).foregroundStyle(.secondary)
            }
        }
    }
}
