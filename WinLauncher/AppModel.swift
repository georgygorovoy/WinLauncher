import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var applications: [LibraryApplication] = []
    @Published private(set) var steamGames: [SteamWindowsGame] = []
    @Published private(set) var steamGameLaunchHistory: [String: Date] = [:]
    @Published private(set) var operation: AppOperation = .idle
    @Published private(set) var engineInstalled = false
    @Published private(set) var engineDescription = String(localized: "Not Installed")
    @Published private(set) var engineSetupMessage = String(localized: "Windows Support will be downloaded and installed automatically.")
    @Published private(set) var androidSupportDescription = String(localized: "Not Installed")
    @Published var failure: PresentedFailure?
    @Published var compatibilityHelp: CompatibilityHelp?
    @Published var showingEngineSetup = false
    @Published var showingAndroidSetup = false
    @Published var showingXboxSetup = false
    @Published private(set) var androidSetupMessage = String(localized: "Only the Android emulator, adb, and one compact ARM64 system image will be installed.")
    @Published private(set) var xboxSetupMessage = String(localized: "Sign in with the Microsoft account that owns Minecraft for Windows.")
    @Published private(set) var xboxHelperAvailable = false
    @Published private(set) var xboxGamePrepared = false
    @Published private(set) var xboxRuntimeAvailable = false
    @Published private(set) var xboxAccountConfigured = false
    @Published private(set) var xboxAccountNeedsRepair = false
    @Published private(set) var steamWindowsModeState: SteamWindowsDownloads.State = .unavailable
    @Published private(set) var steamRestartRequired = false
    @Published private(set) var steamPlayBridgeStatus = String(localized: "Checking Steam games…")
    @Published private(set) var steamPlayNeedsAttention = false
    @Published private(set) var steamPlayReady = false
    @Published var advancedMode = false
    @Published var openWindowsFilesDirectly: Bool {
        didSet { UserDefaults.standard.set(openWindowsFilesDirectly, forKey: "openWindowsFilesDirectly") }
    }

    @Published var graphicsMode: String {
        didSet { UserDefaults.standard.set(graphicsMode, forKey: "graphicsMode") }
    }
    @Published var synchronizationEnabled: Bool {
        didSet { UserDefaults.standard.set(synchronizationEnabled, forKey: "synchronizationEnabled") }
    }
    @Published var allowHomeFolder: Bool {
        didSet { UserDefaults.standard.set(allowHomeFolder, forKey: "allowHomeFolder") }
    }
    @Published var diagnosticLogging: Bool {
        didSet { UserDefaults.standard.set(diagnosticLogging, forKey: "diagnosticLogging") }
    }
    @Published var customEnvironmentVariables: String {
        didSet { UserDefaults.standard.set(customEnvironmentVariables, forKey: "customEnvironmentVariables") }
    }

    private let paths = AppPaths()
    private let runner = ProcessRunner()
    private lazy var store = LibraryStore(paths: paths)
    private lazy var engineManager = EngineManager(paths: paths, runner: runner)
    private lazy var prefixManager = PrefixManager(paths: paths, runner: runner)
    private lazy var runtimeManager = RuntimeManager(paths: paths, runner: runner, prefixManager: prefixManager)
    private lazy var androidRuntimeManager = AndroidRuntimeManager(paths: paths, runner: runner)
    private lazy var xboxHelperManager = XboxHelperManager(paths: paths, runner: runner)
    private lazy var xboxRuntimeManager = XboxRuntimeManager(paths: paths, runner: runner)
    private lazy var detector = InstalledApplicationDetector(paths: paths)
    private let steamDownloads = SteamWindowsDownloads()
    private var steamPlayBridgeTask: Task<Void, Never>?
    private var engine: WineEngineInstallation?
    private var pendingAndroidApplication: LibraryApplication?
    private var pendingMinecraftBootstrapper: URL?
    private let minecraftPackageIdentifier = "org.minecraft.windows.gdk"
    private let rawWindowsPackageIdentifier = "org.winlauncher.raw-windows"

    init() {
        let defaults = UserDefaults.standard
        graphicsMode = defaults.string(forKey: "graphicsMode") ?? "Automatic"
        synchronizationEnabled = defaults.object(forKey: "synchronizationEnabled") == nil || defaults.bool(forKey: "synchronizationEnabled")
        allowHomeFolder = defaults.bool(forKey: "allowHomeFolder")
        diagnosticLogging = defaults.bool(forKey: "diagnosticLogging")
        customEnvironmentVariables = defaults.string(forKey: "customEnvironmentVariables") ?? ""
        advancedMode = defaults.bool(forKey: "advancedMode")
        openWindowsFilesDirectly = defaults.object(forKey: "openWindowsFilesDirectly") == nil || defaults.bool(forKey: "openWindowsFilesDirectly")
        steamWindowsModeState = steamDownloads.state()
        if let data = defaults.data(forKey: "steamGameLaunchHistory"),
           let history = try? JSONDecoder().decode([String: Date].self, from: data) {
            steamGameLaunchHistory = history
        }
    }

    func start() async {
        do {
            try paths.createBaseDirectories()
            // Keep the user's explicit Steam platform choice across launches.
            // A fresh installation starts with the macOS default in Steam.
            steamWindowsModeState = steamDownloads.state()
            let loadedApplications = try await store.load()
            applications = normalizeMinecraftLibrary(loadedApplications)
            if applications != loadedApplications {
                try await store.save(applications)
            }
            await refreshInstalledApplications()
            refreshSteamGames()
            startSteamPlayBridgeMonitor()
            await prepareEngineAutomatically()
            await refreshAndroidSupport()
            await refreshXboxSupport()
            try await ensureMinecraftLibraryItemIfReady()
        } catch { present(error) }
    }

    func chooseWindowsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data,
            UTType(filenameExtension: "msi") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importAndLaunch(url) }
    }

    func chooseApplicationFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open an App")
        panel.message = String(localized: "Choose a Windows application, Windows installer, or Android APK.")
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data,
            UTType(filenameExtension: "msi") ?? .data,
            UTType(filenameExtension: "apk") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importAndLaunch(url) }
    }

    func receiveDrop(_ urls: [URL]) {
        let accepted = urls.filter { ["exe", "msi", "apk"].contains($0.pathExtension.lowercased()) }
        guard !accepted.isEmpty else { return }
        if let minecraft = accepted.first(where: isMinecraftBootstrapper) {
            openMinecraftSetup(for: minecraft)
            return
        }
        Task {
            for url in accepted { await importAndLaunch(url) }
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.scheme == "winlauncher", url.host == "minecraft" {
            Task {
                await refreshXboxSupport()
                if xboxGamePrepared && xboxRuntimeAvailable {
                    await launchMinecraft()
                } else {
                    showXboxSetup()
                }
            }
            return
        }
        let isWindowsFile = ["exe", "msi"].contains(url.pathExtension.lowercased())
        if isWindowsFile && operation == .idle && openWindowsFilesDirectly && engineInstalled &&
            !isMinecraftBootstrapper(url) && !WindowsExecutableInspector.requiresWindowsRuntime(url) {
            NSApp.hide(nil)
        }
        receiveDrop([url])
    }

    func openFeaturedURL(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    var nativeSteamInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Steam.app/Contents/Info.plist")
    }

    var installedUbisoftConnect: LibraryApplication? {
        applications.first { application in
            application.effectivePlatform == .windows &&
            application.windowsPath.lowercased().hasSuffix("\\ubisoftconnect.exe") &&
            paths.hostURL(forWindowsPath: application.windowsPath)
                .map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
    }

    var installedEpicWindowsLauncher: LibraryApplication? {
        applications.first { application in
            application.effectivePlatform == .windows &&
            application.windowsPath.lowercased().hasSuffix("\\epicgameslauncher.exe") &&
            paths.hostURL(forWindowsPath: application.windowsPath)
                .map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
    }

    private var nativeEpicURL: URL? {
        let relativeNames = ["Epic Games Launcher.app", "Epic Games.app"]
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        return roots.lazy.flatMap { root in relativeNames.map { root.appendingPathComponent($0, isDirectory: true) } }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }
    }

    var nativeEpicInstalled: Bool { nativeEpicURL != nil }

    func openEpicGames() {
        if let nativeEpicURL {
            NSWorkspace.shared.open(nativeEpicURL)
        } else if let installedEpicWindowsLauncher {
            Task { await launch(installedEpicWindowsLauncher) }
        } else {
            openFeaturedURL("https://store.epicgames.com/download")
        }
    }

    var installedFDroid: LibraryApplication? {
        applications.first { $0.packageIdentifier == "org.fdroid.fdroid" &&
            $0.sourcePath.map { FileManager.default.fileExists(atPath: $0) } == true }
    }

    func openFDroid() {
        Task {
            guard operation == .idle else { return }
            let expected = "985f5181d48bb6bafd54083a048b391271e0ab28385881cc41294fb01a222762"
            func verified(_ url: URL) -> Bool {
                guard let data = try? Data(contentsOf: url) else { return false }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
            }
            if let installedFDroid, let sourcePath = installedFDroid.sourcePath,
               verified(URL(fileURLWithPath: sourcePath)) {
                await launchAndroid(installedFDroid)
                return
            }
            operation = .downloadingAndroidStore
            do {
                let apk = paths.androidCache.appendingPathComponent("F-Droid-1.23.2.apk")
                if !verified(apk) {
                    let source = URL(string: "https://f-droid.org/repo/org.fdroid.fdroid_1023052.apk")!
                    let (temporary, response) = try await URLSession.shared.download(from: source)
                    guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
                        throw WinLauncherError.androidDownloadFailed(String(localized: "The F-Droid server did not return an APK."))
                    }
                    guard verified(temporary) else { throw WinLauncherError.androidIntegrityFailed }
                    try FileManager.default.createDirectory(at: paths.androidCache, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: apk.path) { try FileManager.default.removeItem(at: apk) }
                    try FileManager.default.moveItem(at: temporary, to: apk)
                }
                let application = LibraryApplication(name: "F-Droid", windowsPath: "",
                    sourceFileName: apk.lastPathComponent, sourcePath: apk.path,
                    platform: .android, packageIdentifier: "org.fdroid.fdroid")
                if let index = applications.firstIndex(where: { $0.packageIdentifier == "org.fdroid.fdroid" }) {
                    applications[index] = application
                } else {
                    applications.append(application)
                }
                try await store.save(applications)
                operation = .idle
                await launchAndroid(application)
            } catch {
                operation = .idle
                present(error)
            }
        }
    }

    func openNativeSteam() {
        let app = URL(fileURLWithPath: "/Applications/Steam.app", isDirectory: true)
        if nativeSteamInstalled {
            NSWorkspace.shared.open(app)
        } else {
            openFeaturedURL("https://store.steampowered.com/about/")
        }
    }

    func refreshSteamWindowsMode() {
        steamWindowsModeState = steamDownloads.state()
    }

    func setSteamWindowsDownloads(_ enabled: Bool) {
        do {
            if enabled {
                try steamDownloads.enable()
            } else {
                try steamDownloads.disable()
            }
            steamWindowsModeState = steamDownloads.state()
            steamRestartRequired = true
        } catch { present(error) }
    }

    func revealSteamGames() {
        let games = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common", isDirectory: true)
        NSWorkspace.shared.open(games)
    }

    func refreshSteamGames() {
        steamGames = SteamGameDetector().detect()
    }

    private func startSteamPlayBridgeMonitor() {
        guard steamPlayBridgeTask == nil else { return }
        steamPlayBridgeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let running = steamIsRunning()
                let outcome = await Task.detached(priority: .utility) {
                    let games = SteamGameDetector().detect()
                    let bridge = SteamPlayBridge()
                    let result = Swift.Result<SteamPlayBridge.Inspection, Error> {
                        if !running { _ = try bridge.repair(games: games) }
                        return try bridge.inspect(games: games)
                    }
                    let failed = running ? SteamProcessLog().failedLaunchIDsInCurrentSession() : []
                    return (games, result, failed)
                }.value
                guard !Task.isCancelled else { return }
                steamGames = outcome.0
                if outcome.0.isEmpty {
                    steamPlayNeedsAttention = false
                    steamPlayReady = false
                    steamPlayBridgeStatus = String(localized: "No supported Windows Steam games found")
                } else {
                    switch outcome.1 {
                    case .success(let inspection):
                        if running && !outcome.2.isDisjoint(with: Set(outcome.0.map(\.id))) {
                            steamPlayNeedsAttention = true
                            steamPlayReady = false
                            steamPlayBridgeStatus = String(localized: "Steam tried to open a Windows .exe directly. Quit and reopen Steam after WinLauncher repairs it.")
                        } else if inspection.needsRepair > 0 {
                            steamPlayNeedsAttention = true
                            steamPlayReady = false
                            steamPlayBridgeStatus = running
                                ? String(localized: "Steam launch cache needs repair. Quit Steam; WinLauncher will fix it automatically.")
                                : String(localized: "Could not repair every Steam game launch. Open Steam, then quit it to retry.")
                        } else if inspection.unavailable > 0 {
                            steamPlayNeedsAttention = true
                            steamPlayReady = false
                            steamPlayBridgeStatus = String(localized: "Steam has no usable launch entry for an installed Windows game. Open Steam, then quit it to retry.")
                        } else {
                            steamPlayNeedsAttention = false
                            steamPlayReady = inspection.routed > 0
                            steamPlayBridgeStatus = inspection.routed == 0
                                ? String(localized: "No supported Windows Steam games found")
                                : String(localized: "Steam Play is ready for \(inspection.routed) Windows games.")
                        }
                    case .failure(let error):
                        steamPlayNeedsAttention = true
                        steamPlayReady = false
                        steamPlayBridgeStatus = String(localized: "Steam Play check: \(error.localizedDescription)")
                    }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func steamIsRunning() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty {
            return true
        }
        return SteamProcessState.isRunning()
    }

    func launchSteamGame(_ game: SteamWindowsGame) async {
        guard operation == .idle else { return }
        if engine == nil { await prepareEngineAutomatically(installIfNeeded: true) }
        guard let engine else {
            showingEngineSetup = true
            return
        }
        do {
            operation = .launching(game.name)
            try await prefixManager.prepareIfNeeded(engine: engine)
            let folder = try await prefixManager.mapSteamGameFolder(
                game.executable.deletingLastPathComponent(), appID: game.id
            )
            var environment = await prefixManager.wineEnvironment(engine: engine)
            environment["SteamAppId"] = game.id
            environment["SteamGameId"] = game.id
            let command = "cd /d \(folder) & \(game.executable.lastPathComponent)"
            steamGameLaunchHistory[game.id] = Date()
            if let history = try? JSONEncoder().encode(steamGameLaunchHistory) {
                UserDefaults.standard.set(history, forKey: "steamGameLaunchHistory")
            }
            let log = paths.logs.appendingPathComponent("steam-\(game.id)-\(Int(Date().timeIntervalSince1970)).log")
            let result = try await runner.run(
                executable: engine.wineURL,
                arguments: ["cmd", "/c", command],
                environment: environment,
                logURL: log
            )
            guard result.terminationStatus == 0 else {
                throw WinLauncherError.processFailed(game.name, result.terminationStatus, result.logURL)
            }
            operation = .idle
        } catch {
            operation = .idle
            present(error)
        }
    }

    func makeDefaultWindowsFileHandler() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        let types = [
            UTType(importedAs: "org.winlauncher.windows-executable", conformingTo: .data),
            UTType(importedAs: "org.winlauncher.windows-installer", conformingTo: .data)
        ]
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                if let error {
                    Task { @MainActor in self.present(error) }
                }
            }
        }
    }

    func makeDefaultSupportedFileHandler() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        let identifiers = [
            "org.winlauncher.windows-executable",
            "org.winlauncher.windows-installer",
            "org.winlauncher.android-package"
        ]
        for identifier in identifiers {
            let type = UTType(importedAs: identifier, conformingTo: .data)
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                if let error { Task { @MainActor in self.present(error) } }
            }
        }
    }

    func importAndLaunch(_ url: URL, bypassCompatibilityCheck: Bool = false) async {
        if !bypassCompatibilityCheck, isMinecraftBootstrapper(url) {
            openMinecraftSetup(for: url)
            return
        }
        guard operation == .idle else { return }
        if url.pathExtension.lowercased() == "apk" {
            await importAndLaunchAndroid(url)
            return
        }
        if !bypassCompatibilityCheck, WindowsExecutableInspector.requiresWindowsRuntime(url) {
            compatibilityHelp = makeWindowsRuntimeHelp(for: url, canTryAnyway: true, logURL: nil)
            return
        }
        if engine == nil { await prepareEngineAutomatically(installIfNeeded: true) }
        guard let engine else {
            showingEngineSetup = true
            return
        }
        do {
            operation = .preparingEnvironment
            try await prefixManager.prepareIfNeeded(engine: engine)
            let installer = isInstaller(url)
            let imported = installer ? try await prefixManager.importExecutable(url) : nil
            let application = LibraryApplication(
                name: url.deletingPathExtension().lastPathComponent,
                windowsPath: imported?.windowsPath ?? "X:\\\(url.lastPathComponent)",
                sourceFileName: url.lastPathComponent,
                sourcePath: installer ? nil : url.path,
                packageIdentifier: bypassCompatibilityCheck && isMinecraftBootstrapper(url)
                    ? rawWindowsPackageIdentifier
                    : nil
            )
            if !installer {
                applications.append(application)
                try await store.save(applications)
            }
            await launch(application)
            if installer { await refreshInstalledApplications() }
        } catch {
            operation = .idle
            present(error)
        }
    }

    func launch(_ application: LibraryApplication) async {
        guard operation == .idle || operation == .preparingEnvironment else { return }
        if application.packageIdentifier == minecraftPackageIdentifier ||
            (application.packageIdentifier != rawWindowsPackageIdentifier &&
             isMinecraftBootstrapperName(application.sourceFileName)) {
            await launchMinecraft(applicationID: application.id)
            return
        }
        if application.effectivePlatform == .android {
            await launchAndroid(application)
            return
        }
        if engine == nil { await prepareEngineAutomatically(installIfNeeded: true) }
        guard let engine else {
            operation = .idle
            showingEngineSetup = true
            return
        }
        do {
            operation = .launching(application.name)
            try await prefixManager.prepareIfNeeded(engine: engine)
            var launchApplication = application
            if let sourcePath = application.sourcePath {
                launchApplication.windowsPath = try await prefixManager.mapApplicationFolder(
                    for: URL(fileURLWithPath: sourcePath)
                )
            } else if !isInstallerName(application.sourceFileName),
                      application.windowsPath.contains("\\users\\Public\\WinLauncher") {
                throw WinLauncherError.applicationFilesMissing
            }
            if let executableURL = executableURL(for: launchApplication),
               WindowsExecutableInspector.isManaged(executableURL) {
                operation = .installingRuntime
                try await runtimeManager.ensureMono(engine: engine)
                operation = .launching(application.name)
            }
            let log = paths.logs.appendingPathComponent("run-\(application.id.uuidString)-\(Int(Date().timeIntervalSince1970)).log")
            let result = try await runner.run(
                executable: engine.wineURL,
                arguments: launchArguments(for: launchApplication),
                environment: await prefixManager.wineEnvironment(engine: engine),
                logURL: log
            )
            guard result.terminationStatus == 0 else {
                if isWindowsRuntimeIssue(in: result.logURL) {
                    operation = .idle
                    NSApp.unhide(nil)
                    compatibilityHelp = makeWindowsRuntimeHelp(
                        for: executableURL(for: launchApplication),
                        displayName: launchApplication.sourceFileName,
                        canTryAnyway: false,
                        logURL: result.logURL
                    )
                    return
                }
                if let issue = compatibilityIssue(in: result.logURL) { throw issue }
                throw WinLauncherError.processFailed(application.name, result.terminationStatus, result.logURL)
            }
            if let index = applications.firstIndex(where: { $0.id == application.id }) {
                applications[index].lastLaunchedAt = Date()
                try await store.save(applications)
            }
            operation = .idle
        } catch {
            operation = .idle
            present(error)
        }
    }

    func remove(_ application: LibraryApplication) {
        applications.removeAll { $0.id == application.id }
        Task {
            do { try await store.save(applications) }
            catch { present(error) }
        }
    }

    func setAdvancedMode(_ enabled: Bool) {
        advancedMode = enabled
        UserDefaults.standard.set(enabled, forKey: "advancedMode")
    }

    func applicationIcon(for application: LibraryApplication) -> NSImage? {
        if application.packageIdentifier == minecraftPackageIdentifier {
            return NSImage(named: "Minecraft")
        }
        if application.packageIdentifier == "org.fdroid.fdroid" {
            return NSImage(named: "FDroid")
        }
        if application.effectivePlatform == .android,
           let sourcePath = application.sourcePath,
           FileManager.default.fileExists(atPath: sourcePath) {
            let icon = NSWorkspace.shared.icon(forFile: sourcePath)
            icon.size = NSSize(width: 96, height: 96)
            return icon
        }
        let executableName = (application.sourceFileName as NSString).deletingPathExtension
        if let extracted = paths.extractedIcon(for: executableName, applicationName: application.name),
           let image = NSImage(contentsOf: extracted) {
            return image
        }
        let url: URL?
        if let sourcePath = application.sourcePath {
            url = URL(fileURLWithPath: sourcePath)
        } else {
            url = paths.hostURL(forWindowsPath: application.windowsPath)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let generic = NSWorkspace.shared.icon(for: UTType(filenameExtension: "exe") ?? .data)
        if icon.tiffRepresentation == generic.tiffRepresentation { return nil }
        icon.size = NSSize(width: 96, height: 96)
        return icon
    }

    func stopWindowsApps() {
        guard let engine else { return }
        Task { try? await prefixManager.stop(engine: engine) }
    }

    func repairEnvironment() {
        guard let engine, operation == .idle else { return }
        Task {
            do {
                operation = .preparingEnvironment
                try await prefixManager.repair(engine: engine)
                operation = .idle
            } catch {
                operation = .idle
                present(error)
            }
        }
    }

    func runWindowsTool(_ tool: String) {
        guard let engine, operation == .idle else { return }
        Task {
            do { try await prefixManager.runTool([tool], engine: engine) }
            catch { present(error) }
        }
    }

    func installLocalEngine() async {
        await prepareEngineAutomatically(installIfNeeded: true)
        if engineInstalled { showingEngineSetup = false }
    }

    func chooseWineEngine() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Wine Engine")
        panel.message = String(localized: "Choose Wine Stable.app, another Wine app, or the wine executable.")
        panel.prompt = String(localized: "Use Wine")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                engine = try await engineManager.select(url)
                updateEngineState()
                showingEngineSetup = false
            } catch { present(error) }
        }
    }

    func revealWindowsFiles() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.prefix.appendingPathComponent("drive_c")])
    }

    func revealFiles(for application: LibraryApplication) {
        if application.packageIdentifier == "org.minecraft.windows.gdk" {
            revealMinecraftFiles()
        } else if application.effectivePlatform == .android, let sourcePath = application.sourcePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sourcePath)])
        } else {
            revealWindowsFiles()
        }
    }

    func chooseAndroidSDK() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Android SDK")
        panel.message = String(localized: "Choose the SDK folder that contains emulator and platform-tools.")
        panel.prompt = String(localized: "Use SDK")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await androidRuntimeManager.saveSDKRoot(url)
            await refreshAndroidSupport()
        }
    }

    func showAndroidSetup() {
        showingAndroidSetup = true
    }

    func showXboxSetup() {
        openMinecraftSetup()
    }

    func repairMinecraftAccount() async {
        guard operation == .idle else { return }
        operation = .preparingXboxSupport
        xboxSetupMessage = String(localized: "Repairing Microsoft sign-in… A login window will open next.")
        do {
            let result = try await xboxRuntimeManager.repairAccountAndLaunch { [weak self] update in
                await self?.applyXboxProgress(update)
            }
            guard result.terminationStatus == 0 else {
                throw WinLauncherError.xboxLaunchFailed(result.logURL)
            }
            operation = .idle
            await refreshXboxSupport()
            try await ensureMinecraftLibraryItemIfReady()
        } catch {
            operation = .idle
            xboxAccountNeedsRepair = true
            xboxSetupMessage = error.localizedDescription
            present(error)
        }
    }

    func runMinecraftBootstrapperAsWindowsApp() {
        guard let url = pendingMinecraftBootstrapper else { return }
        showingXboxSetup = false
        Task { await importAndLaunch(url, bypassCompatibilityCheck: true) }
    }

    var canRunMinecraftBootstrapperAsWindowsApp: Bool {
        pendingMinecraftBootstrapper != nil
    }

    func dismissAndroidSetup() {
        guard operation != .installingAndroidSupport else { return }
        showingAndroidSetup = false
        pendingAndroidApplication = nil
    }

    func installLightweightAndroidSupport() async {
        guard operation == .idle else { return }
        operation = .installingAndroidSupport
        do {
            _ = try await androidRuntimeManager.installManagedSupport { [weak self] message in
                self?.androidSetupMessage = message
            }
            await refreshAndroidSupport()
            operation = .idle
            showingAndroidSetup = false
            if let pending = pendingAndroidApplication {
                pendingAndroidApplication = nil
                await launchAndroid(pending)
            }
        } catch {
            operation = .idle
            androidSetupMessage = error.localizedDescription
            present(error)
        }
    }

    func installMinecraftSupport() async {
        guard operation == .idle else { return }
        operation = .preparingXboxSupport
        do {
            _ = try await xboxHelperManager.installBundledHelperIfAvailable()
            await refreshXboxSupport()
            guard xboxHelperAvailable else { throw WinLauncherError.xboxHelperNotInstalled }
            guard xboxRuntimeAvailable else { throw WinLauncherError.xboxRuntimeNotInstalled }
            operation = xboxGamePrepared ? .preparingXboxSupport : .downloadingXboxGame
            xboxSetupMessage = xboxGamePrepared
                ? String(localized: "Preparing the player and starting Minecraft… The first launch installs one Microsoft component and can take several minutes.")
                : String(localized: "Signing in, downloading, and preparing Minecraft… Keep WinLauncher open.")
            let result = try await xboxRuntimeManager.installAndLaunch { [weak self] update in
                await self?.applyXboxProgress(update)
            }
            if Task.isCancelled {
                operation = .idle
                xboxSetupMessage = String(localized: "Setup was stopped. Choose Set Up and Download to continue.")
                return
            }
            guard result.terminationStatus == 0 else {
                throw WinLauncherError.xboxLaunchFailed(result.logURL)
            }
            operation = .idle
            await refreshXboxSupport()
            try await ensureMinecraftLibraryItemIfReady()
        } catch {
            operation = .idle
            xboxAccountNeedsRepair = true
            xboxSetupMessage = error.localizedDescription
            present(error)
        }
    }

    func revealMinecraftFiles() {
        guard xboxGamePrepared else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.minecraftGame])
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.logs])
    }

    func copyDiagnosticReport() {
        let report = """
        WinLauncher diagnostic report
        Engine: \(engineDescription)
        Shared environment: \(paths.prefix.path)
        Library applications: \(applications.count)
        Graphics: \(graphicsMode)
        Synchronization: \(synchronizationEnabled ? "Enabled" : "Disabled")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Android support: \(androidSupportDescription)
        Xbox Games Support: \(xboxSetupMessage)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func dismissCompatibilityHelp() {
        compatibilityHelp = nil
    }

    func useRecommendedAlternative() {
        guard let help = compatibilityHelp else { return }
        compatibilityHelp = nil
        if help.recommendedURL?.scheme == "winlauncher",
           help.recommendedURL?.host == "xbox-support" {
            showingXboxSetup = true
        } else if let url = help.recommendedURL {
            NSWorkspace.shared.open(url)
        } else {
            DispatchQueue.main.async { self.chooseWindowsFile() }
        }
    }

    func tryCompatibilityFileAnyway() {
        guard let url = compatibilityHelp?.sourceURL else { return }
        compatibilityHelp = nil
        Task { await importAndLaunch(url, bypassCompatibilityCheck: true) }
    }

    func revealCompatibilityLog() {
        guard let log = compatibilityHelp?.logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    private func present(_ error: Error) {
        NSApp.unhide(nil)
        let logURL: URL?
        switch error {
        case WinLauncherError.processFailed(_, _, let url),
             WinLauncherError.environmentInitializationFailed(let url),
             WinLauncherError.engineInstallationFailed(let url),
             WinLauncherError.engineFilesBlocked(let url),
             WinLauncherError.compatibilityIssue(_, let url):
            logURL = url
        case WinLauncherError.androidEmulatorDidNotStart(let url),
             WinLauncherError.androidInstallFailed(let url),
             WinLauncherError.androidPackageUnknown(let url),
             WinLauncherError.androidInstallationFailed(let url):
            logURL = url
        case WinLauncherError.xboxGameDownloadFailed(let url),
             WinLauncherError.xboxLaunchFailed(let url):
            logURL = url
        default:
            logURL = nil
        }
        let androidError: Bool
        switch error {
        case WinLauncherError.androidSDKNotInstalled,
             WinLauncherError.androidVirtualDeviceMissing,
             WinLauncherError.androidEmulatorDidNotStart,
             WinLauncherError.androidInstallFailed,
             WinLauncherError.androidPackageUnknown,
             WinLauncherError.androidDownloadFailed,
             WinLauncherError.androidIntegrityFailed,
             WinLauncherError.androidInstallationFailed:
            androidError = true
        default:
            androidError = false
        }
        let xboxError: Bool
        switch error {
        case WinLauncherError.xboxHelperNotInstalled,
             WinLauncherError.xboxHelperInvalid,
             WinLauncherError.xboxGameDownloadFailed,
             WinLauncherError.xboxRuntimeNotInstalled,
             WinLauncherError.xboxLaunchFailed:
            xboxError = true
        default:
            xboxError = false
        }
        failure = PresentedFailure(
            title: xboxError ? String(localized: "Xbox Games Support couldn’t start") :
                (androidError ? String(localized: "Android app couldn’t start") : String(localized: "Windows app couldn’t start")),
            message: error.localizedDescription,
            logURL: logURL
        )
    }

    private func updateEngineState() {
        engineInstalled = engine != nil
        engineDescription = engine.map { "\($0.name) · \($0.version)" } ?? String(localized: "Not Installed")
    }

    private func prepareEngineAutomatically(installIfNeeded: Bool = false) async {
        guard engine == nil else { return }
        let previousOperation = operation
        operation = .installingEngine
        do {
            engine = installIfNeeded ? try await engineManager.resolveOrInstall() : await engineManager.resolve()
            engineSetupMessage = String(localized: "Windows Support is ready.")
        } catch {
            engineSetupMessage = error.localizedDescription
            present(error)
        }
        updateEngineState()
        operation = previousOperation == .installingEngine ? .idle : previousOperation
    }

    private func importAndLaunchAndroid(_ url: URL) async {
        let standardized = url.standardizedFileURL
        let existing = applications.first { application in
            application.effectivePlatform == .android &&
                application.sourcePath.map { URL(fileURLWithPath: $0).standardizedFileURL == standardized } == true
        }
        if let existing {
            await launchAndroid(existing)
            return
        }
        let application = LibraryApplication(
            name: url.deletingPathExtension().lastPathComponent,
            windowsPath: "",
            sourceFileName: url.lastPathComponent,
            sourcePath: url.path,
            platform: .android
        )
        applications.append(application)
        try? await store.save(applications)
        await launchAndroid(application)
    }

    private func launchAndroid(_ application: LibraryApplication) async {
        guard let sourcePath = application.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath) else {
            present(WinLauncherError.applicationFilesMissing)
            return
        }
        do {
            operation = .preparingAndroid
            let result = try await androidRuntimeManager.launch(
                apkURL: URL(fileURLWithPath: sourcePath),
                knownPackage: application.packageIdentifier
            )
            if let index = applications.firstIndex(where: { $0.id == application.id }) {
                applications[index].packageIdentifier = result.packageIdentifier
                applications[index].lastLaunchedAt = Date()
                try await store.save(applications)
            }
            androidSupportDescription = String(localized: "Ready")
            operation = .idle
        } catch {
            operation = .idle
            await refreshAndroidSupport()
            if case WinLauncherError.androidSDKNotInstalled = error {
                pendingAndroidApplication = application
                showingAndroidSetup = true
                return
            }
            if case WinLauncherError.androidVirtualDeviceMissing = error {
                pendingAndroidApplication = application
                showingAndroidSetup = true
                return
            }
            present(error)
        }
    }

    private func refreshAndroidSupport() async {
        do {
            let runtime = try await androidRuntimeManager.resolve()
            androidSupportDescription = String(localized: "Ready · \(runtime.virtualDeviceName)")
        } catch WinLauncherError.androidVirtualDeviceMissing {
            androidSupportDescription = String(localized: "SDK installed · Device required")
        } catch {
            androidSupportDescription = String(localized: "Not Installed")
        }
    }

    private func refreshXboxSupport() async {
        let status = await xboxHelperManager.status()
        xboxHelperAvailable = status.helperAvailable
        xboxGamePrepared = status.gamePrepared
        xboxRuntimeAvailable = status.runtimeAvailable
        xboxSetupMessage = status.description
        refreshXboxAccountStateFromLogs()
        if xboxAccountNeedsRepair {
            xboxSetupMessage = String(localized: "Microsoft sign-in needs repair. Your downloaded game and local files are safe.")
        } else if xboxGamePrepared && xboxRuntimeAvailable && !xboxAccountConfigured {
            xboxSetupMessage = String(localized: "Set up your Microsoft account to play Minecraft for Windows.")
        }
    }

    private func launchMinecraft(applicationID: UUID? = nil) async {
        guard operation == .idle else { return }
        operation = .launching("Minecraft for Windows")
        xboxSetupMessage = String(localized: "Starting Minecraft…")
        do {
            let result = try await xboxRuntimeManager.launch { [weak self] update in
                await self?.applyXboxProgress(update)
            }
            if Task.isCancelled {
                operation = .idle
                xboxSetupMessage = String(localized: "Launch was stopped.")
                return
            }
            guard result.terminationStatus == 0 else {
                throw WinLauncherError.xboxLaunchFailed(result.logURL)
            }
            if let applicationID,
               let index = applications.firstIndex(where: { $0.id == applicationID }) {
                applications[index].lastLaunchedAt = Date()
                try await store.save(applications)
            }
            operation = .idle
            await refreshXboxSupport()
        } catch {
            operation = .idle
            xboxAccountNeedsRepair = true
            xboxSetupMessage = error.localizedDescription
            present(error)
        }
    }

    private func ensureMinecraftLibraryItemIfReady() async throws {
        guard xboxGamePrepared else { return }
        try createMinecraftShortcutIfNeeded()
        guard xboxRuntimeAvailable else { return }
        guard !applications.contains(where: { $0.packageIdentifier == minecraftPackageIdentifier }) else { return }
        applications.append(LibraryApplication(
            name: "Minecraft for Windows",
            windowsPath: "Q:\\Minecraft.Windows.exe",
            sourceFileName: "Minecraft.Windows.exe",
            sourcePath: paths.minecraftGame.appendingPathComponent("Minecraft.Windows.exe").path,
            environmentID: "xbox-games",
            packageIdentifier: minecraftPackageIdentifier
        ))
        try await store.save(applications)
    }

    private func createMinecraftShortcutIfNeeded() throws {
        let applicationsFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let preferred = applicationsFolder.appendingPathComponent("Minecraft.app", isDirectory: true)
        let preferredAvailable = !FileManager.default.fileExists(atPath: preferred.path) ||
            Bundle(url: preferred)?.bundleIdentifier == "org.winlauncher.minecraft"
        let shortcut = preferredAvailable
            ? preferred
            : applicationsFolder.appendingPathComponent("Minecraft Bedrock.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: shortcut.path),
           Bundle(url: shortcut)?.bundleIdentifier != "org.winlauncher.minecraft" {
            return
        }
        let contents = shortcut.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let launcher = macOS.appendingPathComponent("launch")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.winlauncher.minecraft",
            "CFBundleName": "Minecraft",
            "CFBundleDisplayName": "Minecraft",
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try Data("#!/bin/sh\nexec /usr/bin/open 'winlauncher://minecraft'\n".utf8)
            .write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        if let icon = NSImage(named: "Minecraft") {
            NSWorkspace.shared.setIcon(icon, forFile: shortcut.path, options: [])
        }
    }

    private func normalizeMinecraftLibrary(_ loaded: [LibraryApplication]) -> [LibraryApplication] {
        var normalized: [LibraryApplication] = []
        var minecraft: LibraryApplication?
        for application in loaded {
            let routesToXbox = application.packageIdentifier == minecraftPackageIdentifier ||
                (application.packageIdentifier != rawWindowsPackageIdentifier &&
                 isMinecraftBootstrapperName(application.sourceFileName))
            guard routesToXbox else {
                normalized.append(application)
                continue
            }
            if minecraft == nil {
                var canonical = application
                canonical.name = "Minecraft for Windows"
                canonical.windowsPath = "Q:\\Minecraft.Windows.exe"
                canonical.sourceFileName = "Minecraft.Windows.exe"
                canonical.sourcePath = paths.minecraftGame.appendingPathComponent("Minecraft.Windows.exe").path
                canonical.environmentID = "xbox-games"
                canonical.packageIdentifier = minecraftPackageIdentifier
                minecraft = canonical
            } else if let launched = application.lastLaunchedAt,
                      minecraft?.lastLaunchedAt.map({ launched > $0 }) ?? true {
                minecraft?.lastLaunchedAt = launched
            }
        }
        if let minecraft { normalized.append(minecraft) }
        return normalized
    }

    private func applyXboxProgress(_ update: XboxRuntimeProgress) async {
        let title = L10n.text(update.title)
        let detail = L10n.text(update.detail)
        xboxSetupMessage = detail.isEmpty ? title : "\(title)\n\(detail)"
        if update.state == "signin" {
            await activateMicrosoftSignIn()
        } else if update.state == "playing" || update.state == "ready" {
            xboxAccountConfigured = true
            xboxAccountNeedsRepair = false
        } else if update.state == "error" {
            xboxAccountNeedsRepair = true
        }
    }

    private func activateMicrosoftSignIn() async {
        guard let helper = Bundle.main.resourceURL?
            .appendingPathComponent("XboxRuntime/standalone_helper")
            .resolvingSymlinksInPath().standardizedFileURL else { return }
        for delay in [200, 700, 1_500, 3_000] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.executableURL?.resolvingSymlinksInPath().standardizedFileURL == helper
            }) {
                running.activate(options: [.activateAllWindows])
            }
        }
    }

    private func launchArguments(for application: LibraryApplication) -> [String] {
        if (application.sourceFileName as NSString).pathExtension.lowercased() == "msi" {
            return ["msiexec", "/i", application.windowsPath]
        }
        return [application.windowsPath]
    }

    private func executableURL(for application: LibraryApplication) -> URL? {
        if let sourcePath = application.sourcePath { return URL(fileURLWithPath: sourcePath) }
        return paths.hostURL(forWindowsPath: application.windowsPath)
    }

    private func compatibilityIssue(in logURL: URL) -> WinLauncherError? {
        guard let data = try? Data(contentsOf: logURL),
              let log = String(data: data.suffix(256_000), encoding: .utf8) else { return nil }
        if log.contains("Windows.Foundation.UniversalApiContract") ||
           log.contains("Windows.ApplicationModel.Store") {
            return .compatibilityIssue(
                String(localized: "This installer requires Microsoft Store components that Wine cannot currently provide. Look for the app's standalone desktop installer instead. For Minecraft, use the native macOS launcher or the legacy Windows 7/8 launcher."),
                logURL
            )
        }
        if log.contains("CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed") ||
           log.contains("mscoree.dll not found") {
            return .compatibilityIssue(
                String(localized: ".NET support could not be prepared. Try Repair Environment, then open the app again."),
                logURL
            )
        }
        return nil
    }

    private func isWindowsRuntimeIssue(in logURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: logURL),
              let log = String(data: data.suffix(256_000), encoding: .utf8) else { return false }
        return log.contains("Windows.Foundation.UniversalApiContract") ||
            log.contains("Windows.ApplicationModel.Store") ||
            log.contains("Microsoft.WindowsAppRuntime") ||
            log.contains("Add-AppxPackage")
    }

    private func makeWindowsRuntimeHelp(
        for sourceURL: URL?,
        displayName: String? = nil,
        canTryAnyway: Bool,
        logURL: URL?
    ) -> CompatibilityHelp {
        let name = (displayName ?? sourceURL?.lastPathComponent ?? "").lowercased()
        if name.contains("minecraftinstaller") || name == "minecraft.exe" {
            return CompatibilityHelp(
                title: String(localized: "Minecraft for Windows needs Xbox Games Support"),
                message: String(localized: "The Store bootstrapper cannot run in ordinary Wine. WinLauncher can use a separate open-source account helper to verify your purchase and download the official Windows game."),
                sourceURL: sourceURL,
                recommendedURL: URL(string: "winlauncher://xbox-support"),
                recommendedTitle: String(localized: "Set Up Xbox Games Support"),
                canTryAnyway: canTryAnyway,
                logURL: logURL
            )
        }
        return CompatibilityHelp(
            title: String(localized: "This installer needs Microsoft Store"),
            message: String(localized: "It depends on Windows package services that Wine cannot currently provide. Download the vendor’s standalone desktop .exe or .msi, then open that file in WinLauncher."),
            sourceURL: sourceURL,
            recommendedURL: nil,
            recommendedTitle: String(localized: "Choose Another Installer"),
            canTryAnyway: canTryAnyway,
            logURL: logURL
        )
    }

    private func openMinecraftSetup(for sourceURL: URL? = nil) {
        pendingMinecraftBootstrapper = sourceURL
        failure = nil
        compatibilityHelp = nil
        showingEngineSetup = false
        showingAndroidSetup = false
        showingXboxSetup = true
    }

    private func refreshXboxAccountStateFromLogs() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: paths.logs,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let latest = files.filter {
            $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("minecraft")
        }.max {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        guard let latest, let data = try? Data(contentsOf: latest),
              let text = String(data: data.suffix(128_000), encoding: .utf8) else { return }
        let states = text.split(separator: "\n").compactMap { line -> String? in
            guard let lineData = String(line).data(using: .utf8),
                  let progress = try? JSONDecoder().decode(XboxRuntimeProgress.self, from: lineData) else { return nil }
            return progress.state
        }
        guard let state = states.last else { return }
        if state == "error" {
            xboxAccountNeedsRepair = true
        } else if state == "playing" || state == "ready" {
            xboxAccountConfigured = true
            xboxAccountNeedsRepair = false
        }
    }

    private func refreshInstalledApplications() async {
        let detected = await detector.detect()
        var changed = false
        for item in detected where !applications.contains(where: {
            $0.windowsPath.caseInsensitiveCompare(item.windowsPath) == .orderedSame
        }) {
            applications.append(LibraryApplication(
                name: item.name,
                windowsPath: item.windowsPath,
                sourceFileName: item.windowsPath.split(separator: "\\").last.map(String.init) ?? item.name
            ))
            changed = true
        }
        if changed { try? await store.save(applications) }
    }

    private func isInstaller(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "msi" || isInstallerName(url.lastPathComponent)
    }

    private func isInstallerName(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("setup") || value.contains("installer") || value.contains("install_")
    }

    private func isMinecraftBootstrapper(_ url: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("exe") == .orderedSame else { return false }
        return isMinecraftBootstrapperName(url.lastPathComponent)
    }

    private func isMinecraftBootstrapperName(_ filename: String) -> Bool {
        let name = (filename as NSString).deletingPathExtension.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return name == "minecraftinstaller" || name == "minecraftlauncher" || name == "minecraft"
    }
}
