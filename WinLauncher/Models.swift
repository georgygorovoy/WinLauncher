import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

enum ApplicationPlatform: String, Codable, Hashable {
    case windows
    case android
}

struct LibraryApplication: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var windowsPath: String
    var sourceFileName: String
    var sourcePath: String?
    var lastLaunchedAt: Date?
    var environmentID: String
    var platform: ApplicationPlatform?
    var packageIdentifier: String?

    var effectivePlatform: ApplicationPlatform { platform ?? .windows }

    init(id: UUID = UUID(), name: String, windowsPath: String, sourceFileName: String,
         sourcePath: String? = nil,
         lastLaunchedAt: Date? = nil, environmentID: String = "default",
         platform: ApplicationPlatform = .windows,
         packageIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.windowsPath = windowsPath
        self.sourceFileName = sourceFileName
        self.sourcePath = sourcePath
        self.lastLaunchedAt = lastLaunchedAt
        self.environmentID = environmentID
        self.platform = platform
        self.packageIdentifier = packageIdentifier
    }
}

struct LibraryDocument: Codable {
    var schemaVersion = 1
    var applications: [LibraryApplication] = []
}

enum AppOperation: Equatable {
    case idle
    case installingEngine
    case installingRuntime
    case preparingEnvironment
    case launching(String)
    case preparingAndroid
    case installingAndroidApp
    case downloadingAndroidStore
    case installingAndroidSupport
    case preparingXboxSupport
    case downloadingXboxGame

    var message: String? {
        switch self {
        case .idle: nil
        case .installingEngine: String(localized: "Installing the Windows engine…")
        case .installingRuntime: String(localized: "Adding .NET support…")
        case .preparingEnvironment: String(localized: "Preparing the Windows Environment…")
        case .launching(let name): String(localized: "Opening \(name)…")
        case .preparingAndroid: String(localized: "Starting Android…")
        case .installingAndroidApp: String(localized: "Installing Android app…")
        case .downloadingAndroidStore: String(localized: "Downloading and verifying F-Droid…")
        case .installingAndroidSupport: String(localized: "Installing Android Support…")
        case .preparingXboxSupport: String(localized: "Preparing Xbox Games Support…")
        case .downloadingXboxGame: String(localized: "Downloading your Windows game…")
        }
    }
}

struct PresentedFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let logURL: URL?
}

struct CompatibilityHelp: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let sourceURL: URL?
    let recommendedURL: URL?
    let recommendedTitle: String
    let canTryAnyway: Bool
    let logURL: URL?
}

enum WinLauncherError: LocalizedError {
    case engineNotInstalled
    case environmentInitializationFailed(URL)
    case noApprovedEngine
    case invalidEngine
    case engineDownloadFailed(String)
    case engineIntegrityFailed
    case engineInstallationFailed(URL)
    case engineFilesBlocked(URL)
    case applicationFilesMissing
    case compatibilityIssue(String, URL)
    case processFailed(String, Int32, URL)
    case androidSDKNotInstalled
    case androidVirtualDeviceMissing
    case androidEmulatorDidNotStart(URL)
    case androidInstallFailed(URL)
    case androidPackageUnknown(URL)
    case androidDownloadFailed(String)
    case androidIntegrityFailed
    case androidInstallationFailed(URL)
    case xboxHelperNotInstalled
    case xboxHelperInvalid
    case xboxGameDownloadFailed(URL)
    case xboxRuntimeNotInstalled
    case xboxLaunchFailed(URL)

    var errorDescription: String? {
        switch self {
        case .engineNotInstalled:
            String(localized: "A Windows engine must be installed before opening an app.")
        case .environmentInitializationFailed:
            String(localized: "The Windows Environment was not created completely. Open the diagnostic log for details.")
        case .noApprovedEngine:
            String(localized: "Wine is not installed. Choose an existing Wine application or executable.")
        case .invalidEngine:
            String(localized: "The selected item does not contain a working Wine engine.")
        case .engineDownloadFailed(let reason):
            String(localized: "Windows Support could not be downloaded. \(reason)")
        case .engineIntegrityFailed:
            String(localized: "The Windows Support download did not pass its integrity check.")
        case .engineInstallationFailed:
            String(localized: "Windows Support could not be installed completely. Open the diagnostic log for details.")
        case .engineFilesBlocked:
            String(localized: "Windows Support was downloaded and verified, but its runtime files could not be installed completely. Open the diagnostic log for details.")
        case .applicationFilesMissing:
            String(localized: "This game was imported as a single .exe by an older build. Choose the original .exe again so its neighboring game files remain available.")
        case .compatibilityIssue(let message, _):
            message
        case .processFailed(let name, let status, _):
            String(localized: "\(name) stopped with status \(status).")
        case .androidSDKNotInstalled:
            String(localized: "Android Support is not installed. WinLauncher can download the lightweight components automatically, or you can choose an existing Android SDK in Settings.")
        case .androidVirtualDeviceMissing:
            String(localized: "No compatible Android environment was found. Reinstall the lightweight Android Support or choose an existing SDK with an ARM64 virtual device.")
        case .androidEmulatorDidNotStart:
            String(localized: "The Android virtual device did not finish starting. Open the diagnostic log for details.")
        case .androidInstallFailed:
            String(localized: "The APK could not be installed. It may target an unsupported Android version or processor architecture.")
        case .androidPackageUnknown:
            String(localized: "The APK was installed, but its launchable application could not be identified.")
        case .androidDownloadFailed(let reason):
            String(localized: "Android Support could not be downloaded. \(reason)")
        case .androidIntegrityFailed:
            String(localized: "The Android Support download did not pass its integrity check.")
        case .androidInstallationFailed:
            String(localized: "Android Support could not be installed completely. Open the diagnostic log for details.")
        case .xboxHelperNotInstalled:
            String(localized: "The separate Xbox account helper is not installed in this build yet. It must be built and distributed with its GPL source and notices.")
        case .xboxHelperInvalid:
            String(localized: "Xbox Games Support contains an invalid or non-executable helper.")
        case .xboxGameDownloadFailed:
            String(localized: "Minecraft for Windows could not be prepared. Open the diagnostic log for details.")
        case .xboxRuntimeNotInstalled:
            String(localized: "The Minecraft player runtime is missing from this build. Reinstall WinLauncher from the complete DMG.")
        case .xboxLaunchFailed:
            String(localized: "Minecraft could not start. Open the diagnostic log for details.")
        }
    }
}
