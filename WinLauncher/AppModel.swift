import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var applications: [LibraryApplication] = []
    @Published private(set) var operation: AppOperation = .idle
    @Published private(set) var engineInstalled = false
    @Published private(set) var engineDescription = "Not Installed"
    @Published private(set) var engineSetupMessage = "Windows Support will be downloaded and installed automatically."
    @Published private(set) var androidSupportDescription = "Not Installed"
    @Published var failure: PresentedFailure?
    @Published var compatibilityHelp: CompatibilityHelp?
    @Published var showingEngineSetup = false
    @Published var showingAndroidSetup = false
    @Published var showingXboxSetup = false
    @Published private(set) var androidSetupMessage = "Only the Android emulator, adb, and one compact ARM64 system image will be installed."
    @Published private(set) var xboxSetupMessage = "Sign in with the Microsoft account that owns Minecraft for Windows."
    @Published private(set) var xboxHelperAvailable = false
    @Published private(set) var xboxGamePrepared = false
    @Published private(set) var xboxRuntimeAvailable = false
    @Published var advancedMode = false

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
    private var engine: WineEngineInstallation?
    private var pendingAndroidApplication: LibraryApplication?

    init() {
        let defaults = UserDefaults.standard
        graphicsMode = defaults.string(forKey: "graphicsMode") ?? "Automatic"
        synchronizationEnabled = defaults.object(forKey: "synchronizationEnabled") == nil || defaults.bool(forKey: "synchronizationEnabled")
        allowHomeFolder = defaults.bool(forKey: "allowHomeFolder")
        diagnosticLogging = defaults.bool(forKey: "diagnosticLogging")
        customEnvironmentVariables = defaults.string(forKey: "customEnvironmentVariables") ?? ""
        advancedMode = defaults.bool(forKey: "advancedMode")
    }

    func start() async {
        do {
            try paths.createBaseDirectories()
            applications = try await store.load()
            await refreshInstalledApplications()
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
        panel.title = "Open an App"
        panel.message = "Choose a Windows application, Windows installer, or Android APK."
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
        Task {
            for url in accepted { await importAndLaunch(url) }
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
        guard operation == .idle else { return }
        if url.pathExtension.lowercased() == "apk" {
            await importAndLaunchAndroid(url)
            return
        }
        if !bypassCompatibilityCheck, isMinecraftBootstrapper(url) {
            compatibilityHelp = makeWindowsRuntimeHelp(for: url, canTryAnyway: false, logURL: nil)
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
                sourcePath: installer ? nil : url.path
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
        if application.packageIdentifier == "org.minecraft.windows.gdk" {
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
        panel.title = "Choose Wine Engine"
        panel.message = "Choose Wine Stable.app, another Wine app, or the wine executable."
        panel.prompt = "Use Wine"
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
        panel.title = "Choose Android SDK"
        panel.message = "Choose the SDK folder that contains emulator and platform-tools."
        panel.prompt = "Use SDK"
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
        showingXboxSetup = true
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
                ? "Preparing the player and starting Minecraft… The first launch installs one Microsoft component and can take several minutes."
                : "Signing in, downloading, and preparing Minecraft… Keep WinLauncher open."
            let result = try await xboxRuntimeManager.installAndLaunch()
            guard result.terminationStatus == 0 else {
                throw WinLauncherError.xboxLaunchFailed(result.logURL)
            }
            operation = .idle
            await refreshXboxSupport()
            try await ensureMinecraftLibraryItemIfReady()
        } catch {
            operation = .idle
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
            title: xboxError ? "Xbox Games Support couldn’t start" :
                (androidError ? "Android app couldn’t start" : "Windows app couldn’t start"),
            message: error.localizedDescription,
            logURL: logURL
        )
    }

    private func updateEngineState() {
        engineInstalled = engine != nil
        engineDescription = engine.map { "\($0.name) · \($0.version)" } ?? "Not Installed"
    }

    private func prepareEngineAutomatically(installIfNeeded: Bool = false) async {
        guard engine == nil else { return }
        let previousOperation = operation
        operation = .installingEngine
        do {
            engine = installIfNeeded ? try await engineManager.resolveOrInstall() : await engineManager.resolve()
            engineSetupMessage = "Windows Support is ready."
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
            androidSupportDescription = "Ready"
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
            androidSupportDescription = "Ready · \(runtime.virtualDeviceName)"
        } catch WinLauncherError.androidVirtualDeviceMissing {
            androidSupportDescription = "SDK installed · Device required"
        } catch {
            androidSupportDescription = "Not Installed"
        }
    }

    private func refreshXboxSupport() async {
        let status = await xboxHelperManager.status()
        xboxHelperAvailable = status.helperAvailable
        xboxGamePrepared = status.gamePrepared
        xboxRuntimeAvailable = status.runtimeAvailable
        xboxSetupMessage = status.description
    }

    private func launchMinecraft(applicationID: UUID? = nil) async {
        guard operation == .idle else { return }
        operation = .launching("Minecraft for Windows")
        xboxSetupMessage = "Starting Minecraft…"
        do {
            let result = try await xboxRuntimeManager.launch()
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
            xboxSetupMessage = error.localizedDescription
            present(error)
        }
    }

    private func ensureMinecraftLibraryItemIfReady() async throws {
        guard xboxGamePrepared, xboxRuntimeAvailable,
              !applications.contains(where: { $0.packageIdentifier == "org.minecraft.windows.gdk" }) else { return }
        applications.append(LibraryApplication(
            name: "Minecraft for Windows",
            windowsPath: "G:\\Minecraft.Windows.exe",
            sourceFileName: "Minecraft.Windows.exe",
            sourcePath: paths.minecraftGame.appendingPathComponent("Minecraft.Windows.exe").path,
            environmentID: "xbox-games",
            packageIdentifier: "org.minecraft.windows.gdk"
        ))
        try await store.save(applications)
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
                "This installer requires Microsoft Store components that Wine cannot currently provide. Look for the app's standalone desktop installer instead. For Minecraft, use the native macOS launcher or the legacy Windows 7/8 launcher.",
                logURL
            )
        }
        if log.contains("CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed") ||
           log.contains("mscoree.dll not found") {
            return .compatibilityIssue(
                ".NET support could not be prepared. Try Repair Environment, then open the app again.",
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
                title: "Minecraft for Windows needs Xbox Games Support",
                message: "The Store bootstrapper cannot run in ordinary Wine. WinLauncher can use a separate open-source account helper to verify your purchase and download the official Windows game.",
                sourceURL: sourceURL,
                recommendedURL: URL(string: "winlauncher://xbox-support"),
                recommendedTitle: "Set Up Xbox Games Support",
                canTryAnyway: canTryAnyway,
                logURL: logURL
            )
        }
        return CompatibilityHelp(
            title: "This installer needs Microsoft Store",
            message: "It depends on Windows package services that Wine cannot currently provide. Download the vendor’s standalone desktop .exe or .msi, then open that file in WinLauncher.",
            sourceURL: sourceURL,
            recommendedURL: nil,
            recommendedTitle: "Choose Another Installer",
            canTryAnyway: canTryAnyway,
            logURL: logURL
        )
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
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return name == "minecraftinstaller" || name == "minecraftlauncher" || name == "minecraft"
    }
}
