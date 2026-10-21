import Foundation

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
    case installingAndroidSupport
    case preparingXboxSupport
    case downloadingXboxGame

    var message: String? {
        switch self {
        case .idle: nil
        case .installingEngine: "Installing the Windows engine…"
        case .installingRuntime: "Adding .NET support…"
        case .preparingEnvironment: "Preparing the Windows Environment…"
        case .launching(let name): "Opening \(name)…"
        case .preparingAndroid: "Starting Android…"
        case .installingAndroidApp: "Installing Android app…"
        case .installingAndroidSupport: "Installing Android Support…"
        case .preparingXboxSupport: "Preparing Xbox Games Support…"
        case .downloadingXboxGame: "Downloading your Windows game…"
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
            "A Windows engine must be installed before opening an app."
        case .environmentInitializationFailed:
            "The Windows Environment was not created completely. Open the diagnostic log for details."
        case .noApprovedEngine:
            "Wine is not installed. Choose an existing Wine application or executable."
        case .invalidEngine:
            "The selected item does not contain a working Wine engine."
        case .engineDownloadFailed(let reason):
            "Windows Support could not be downloaded. \(reason)"
        case .engineIntegrityFailed:
            "The Windows Support download did not pass its integrity check."
        case .engineInstallationFailed:
            "Windows Support could not be installed completely. Open the diagnostic log for details."
        case .engineFilesBlocked:
            "Windows Support was downloaded and verified, but its runtime files could not be installed completely. Open the diagnostic log for details."
        case .applicationFilesMissing:
            "This game was imported as a single .exe by an older build. Choose the original .exe again so its neighboring game files remain available."
        case .compatibilityIssue(let message, _):
            message
        case .processFailed(let name, let status, _):
            "\(name) stopped with status \(status)."
        case .androidSDKNotInstalled:
            "Android Support is not installed. WinLauncher can download the lightweight components automatically, or you can choose an existing Android SDK in Settings."
        case .androidVirtualDeviceMissing:
            "No compatible Android environment was found. Reinstall the lightweight Android Support or choose an existing SDK with an ARM64 virtual device."
        case .androidEmulatorDidNotStart:
            "The Android virtual device did not finish starting. Open the diagnostic log for details."
        case .androidInstallFailed:
            "The APK could not be installed. It may target an unsupported Android version or processor architecture."
        case .androidPackageUnknown:
            "The APK was installed, but its launchable application could not be identified."
        case .androidDownloadFailed(let reason):
            "Android Support could not be downloaded. \(reason)"
        case .androidIntegrityFailed:
            "The Android Support download did not pass its integrity check."
        case .androidInstallationFailed:
            "Android Support could not be installed completely. Open the diagnostic log for details."
        case .xboxHelperNotInstalled:
            "The separate Xbox account helper is not installed in this build yet. It must be built and distributed with its GPL source and notices."
        case .xboxHelperInvalid:
            "Xbox Games Support contains an invalid or non-executable helper."
        case .xboxGameDownloadFailed:
            "Minecraft for Windows could not be prepared. Open the diagnostic log for details."
        case .xboxRuntimeNotInstalled:
            "The Minecraft player runtime is missing from this build. Reinstall WinLauncher from the complete DMG."
        case .xboxLaunchFailed:
            "Minecraft could not start. Open the diagnostic log for details."
        }
    }
}
